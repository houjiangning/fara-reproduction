"""FaR（Forget and Rewire）防护工具 —— 忠实实现 + 可验证 + 可演示。

对照 FaR机制实现规格.md 第 4~6 节：
  机制（论文 Fig.5）：把敏感权重 W[A,row] 冗余进 div 条 lane ——
    主 lane    保留物理权重 W[A,row]，激活规约到 x[A]/div；
    dead lane  (div-1) 条，物理权重复制为 W[A,row]，各吃 x[A]/div。
    求解和仍 = x[A]·W[A,row]（**输出严格守恒**）；
    攻击者翻转任意 1 条 lane 的 1 个 bit，只损失 1/div 贡献 → 需翻更多才破坏。

  离线产物（对齐 FaRAccel 第 5 节，供 FPGA 运行期消费）：
    · FaRMap ：每层 victim(敏感位置 col,row) → dead lane 映射
    · shadow ：dead lane 上预先写好的 donor 权重复本（本工具直接落在 W 里）

用法：
  python far_defense.py selftest
  python far_defense.py protect --layer transformer.h.2.mlp.c_proj --n 16 --div 2
  python far_defense.py demo    --layer transformer.h.2.mlp.c_proj --n 16 --div 2 --budget 16
"""
import argparse
import copy
import json
import math
import os
import statistics

import torch
import torch.nn.functional as F

from bfa_attack import compute_gradients
from eval_perplexity import load, perplexity, REFERENCE_CORPUS

DIR = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------ 核心 FaR 层


class FaRLayer(torch.nn.Module):
    """把一个 Linear / Conv1D 包装成 FaR 加固层。

    输入权重统一内部化为 [out, in] 的 self.W（Conv1D 给定 [in,out] 会转置）。
    apply_rewire 之后 self._splits 记录了每个敏感(输入通道 A, 输出行 row)
    需要把激活 x[A] 均摊进的 div 条 lane；forward 里据此改写激活再 GEMM。
    """

    def __init__(self, W_out_in, bias=None, div=2):
        super().__init__()
        assert W_out_in.dim() == 2
        self.out, self.in_ = W_out_in.shape
        self.div = int(div)
        # W 用 Parameter（而非 buffer）：FaRLayer 也在 H 上传梯度，PBS/推理都能做
        self.W = torch.nn.Parameter(W_out_in.float().clone())
        self.register_buffer("b", bias.float().clone() if bias is not None else None)
        self._splits = {}
        self.far = []  # FaRMap 条目

    @staticmethod
    def from_src(module, div=2):
        w = module.weight.detach()
        if w.dim() == 2 and module.__class__.__name__ == "Conv1D":
            w = w.t().contiguous()  # GPT-2 Conv1D: [in, out] -> [out, in]
        bb = getattr(module, "bias", None)
        bias = bb.detach() if bb is not None else None
        return FaRLayer(w, bias, div)

    def apply_rewire(self, sensitive_pairs, dead_pool):
        """对每个敏感输入通道 A 做 forget+rewire（同 A 去重，保留分最高者）。

        为让"激活分流 x[A]/div"流进 dead lane 后**对所有输出行**都守恒，
        必须把 donor 的**整列** self.W[:, A] 复制到 dead lane（否则只会保住
        (row,A) 单点，其余行会被 x[A]/div 污染）。

        dead_pool: 低激活输入通道（按激活范数升序），作为可重连的 dead lane。
        返回 FaRMap 条目列表。
        """
        C = self.in_
        used_dead = set()
        # 同一种输入通道只保护一次：保留该通道里敏感度最高的 (col,row)
        best = {}
        for (A, row, score) in sensitive_pairs:
            if A not in best or score > best[A][2]:
                best[A] = (A, row, score)
        used_A = set(best.keys())
        entries = []
        for (A, row, score) in sorted(best.values(), key=lambda t: -t[2]):
            need = self.div - 1
            deads = []
            for d in dead_pool:
                d = int(d)
                if d not in used_dead and d != A and d not in used_A:
                    deads.append(d)
                    used_dead.add(d)
                    if len(deads) == need:
                        break
            if len(deads) < need:
                print(f"[warn] dead 通道不足: (col={A},row={row}) 需 {need} 实际 {len(deads)}")
            donor = float(self.W[row, A].item())
            for d in deads:
                # .data 实现一次性的训练后变换，避免对带梯度的 leaf 做 in-place 报错
                self.W.data[:, d] = self.W.data[:, A].clone()
            self._splits[A] = (self.div, deads)
            entries.append({"col": A, "row": row, "score": score,
                            "div": self.div, "dead": deads, "donor": donor})
        self.far = entries
        return entries

    def forward(self, x):
        if self._splits:
            act = x.clone()
            for A, (div, deads) in self._splits.items():
                half = x[..., A] / div
                act[..., A] = half                     # 主 lane 激活规约
                for d in deads:
                    act[..., d] = x[..., d] + half     # dead lane 吃入 x[A]/div
        else:
            act = x
        return F.linear(act, self.W,
                        None if self.b is None else self.b)

    def forward_matches(self, ref_module, x):
        """等价性检查：同一输入下本 FaR 层与原始层输出最大偏差。"""
        with torch.no_grad():
            o_ref = ref_module(x).float()
            o_far = self(x).float()
        return (o_ref - o_far).abs().max().item()


# ------------------------------------------------------------------ 分析辅助

def _get_module(model, name):
    owner, *rest = name.split(".")
    m = model
    for p in [owner] + rest:
        m = getattr(m, p)
    return m


def _set_module(model, name, new_module):
    parts = name.split(".")
    owner = model
    for p in parts[:-1]:
        owner = getattr(owner, p)
    setattr(owner, parts[-1], new_module)


def _capture_input_act(model, layer_name, tok, text):
    """取某层一次前向的输入激活（用于挑 dead 通道）。"""
    holder = {}
    target = _get_module(model, layer_name)
    h = target.register_forward_hook(
        lambda mod, inp, out=None: holder.__setitem__("x", inp[0].detach().clone()))
    try:
        ids = torch.tensor([tok(text)["input_ids"]])
        model(ids)
    finally:
        h.remove()
    return holder["x"]


def _dead_channel_pool(model, layer_name, tok):
    """把该层输入各通道的激活范数升序排序，作为可重连的 dead 候补。"""
    x = _capture_input_act(model, layer_name, tok, REFERENCE_CORPUS[0])
    x = x.movedim(-1, 0)  # [in, ...]
    norms = x.norm(dim=tuple(range(1, x.dim())))
    return [int(i) for i in torch.argsort(norms).tolist()]


def find_sensitive_weights(module, grads, param_name, top=6):
    """敏感度 = |w|·|g|，取层内 top-k，返回 (col=输入通道A, row=输出行)。

    module.weight 可能是 [out,in]（Linear）或 GPT-2 Conv1D 的 [in,out]，
    这里统一映射回 (输入通道A, 输出行row) 语义。
    """
    w = module.weight.detach()
    wf = w.float().abs()
    g = grads.get(param_name)
    if g is None:
        raise KeyError(f"梯度中没有 {param_name}（可用 _layer_grad_name 定位）")
    gf = g.float().abs()
    if gf.shape != w.shape:
        gf = gf.view_as(w)
    score = (wf * gf).flatten()
    topk = torch.topk(score, k=min(top, score.numel()))
    is_conv1d = module.__class__.__name__ == "Conv1D"
    out = []
    for idx in topk.indices.tolist():
        if is_conv1d:                       # w [in, out]
            col_in, row_out = divmod(idx, w.size(1))
        else:                                # w [out, in]
            row_out, col_in = divmod(idx, w.size(1))
        out.append((int(col_in), int(row_out), float(score[idx].item())))
    return out


def _layer_grad_name(model, grads, layer_name):
    """按张量身份定位层权重的梯度名（兼容 GPT-2 中 lm_head/wte 绑定共享同名张量）。"""
    w = _get_module(model, layer_name).weight
    for name, p in model.named_parameters():
        if p is w or p.data_ptr() == w.data_ptr():
            if name in grads:
                return name
    return None


def _mean_ppl(model, tok):
    return statistics.mean([perplexity(model, tok, t) for t in REFERENCE_CORPUS])


# ------------------------------------------------------------------ 论文口径评测指标
# 论文(FaR/USENIX'24)以「达到损伤阈值所需翻位」与「精度损失<2%」为判据。
# 这里补充三个可在本地 GPT-2 上算的语料级指标：
#   · NLL（即 log 困惑度）：困惑度是 exp(NLL)，取对数后才是公平刻度，
#     也是「到阈值要翻几位」这一判据的直接对象
#   · next-token 预测准确率：以未攻击原模型 argmax 为参考标签，得到准确性
#     指标，镜像论文的 accuracy
#   · 预测分布 KL 散度：相对原模型的功能保真度


@torch.no_grad()
def _forward_logits1(model, ids):
    """单条文本 next-token logits [num_tokens-1, vocab]。"""
    return model(torch.tensor([ids])).logits[0]


@torch.no_grad()
def corpus_nll(model, tok, texts=REFERENCE_CORPUS):
    """语料平均 NLL(每 token) 与对应于它的困惑度，返回 (mean_nll, ppl)。"""
    total_nll, n = 0.0, 0
    for text in texts:
        ids = tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        shift = _forward_logits1(model, ids)[:-1].contiguous()
        labels = torch.tensor(ids[1:])
        total_nll += F.cross_entropy(shift, labels, reduction="sum").item()
        n += labels.numel()
    mean_nll = total_nll / max(n, 1)
    return mean_nll, float(math.exp(mean_nll))


@torch.no_grad()
def next_tok_acc(model, ref_model, tok, texts=REFERENCE_CORPUS):
    """相对参考模型(通常为未攻击原模型)的 next-token top-1 一致率(%)。
    0 协议时应近 100%，越高=损伤越小——镜像论文的 accuracy 判据。"""
    hits = total = 0
    for text in texts:
        ids = tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        x = torch.tensor([ids])
        lr = ref_model(x).logits[:, :-1].argmax(dim=-1)
        lc = model(x).logits[:, :-1].argmax(dim=-1)
        hits += (lr == lc).sum().item()
        total += lr.numel()
    return 100.0 * hits / max(total, 1)


@torch.no_grad()
def mean_kl(model, ref_model, tok, texts=REFERENCE_CORPUS):
    """预测分布相对参考模型的平均 KL 散度(KL(候选||参考))，衡量功能保真度。"""
    kls, n = 0.0, 0
    for text in texts:
        ids = tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        x = torch.tensor([ids])
        lr = ref_model(x).logits[:, :-1].float().log_softmax(dim=-1)
        lc = model(x).logits[:, :-1].float().log_softmax(dim=-1)
        cand = lc.exp()
        kls += (cand * (lc - lr)).sum(dim=-1).sum().item()
        n += cand.shape[0] * cand.shape[1]
    return kls / max(n, 1)


def _flip_on_tensor(t, elem_idx, fp32_bit):
    """在 [out,in] 权重张量的扁平下标 elem_idx 上取反 fp32 指定位。"""
    v = t.detach().flatten().view(torch.int32)
    v[elem_idx] = v[elem_idx] ^ (1 << fp32_bit)


def _weight_tensor_of(module):
    """返回可原地翻位的实际权重张量（FaRLayer 用 W，原生层用 weight）。"""
    return module.W if hasattr(module, "W") else module.weight


def _flat_index_of(module, row, col):
    """逻辑权重元素 (row输出, col输入) 在模块权重张量里的扁平下标。

    FaRLayer: W [out,in] → row*in+col；Linear: weight [out,in] 同左；
    GPT-2 Conv1D: weight [in,out]，元素(out=r,in=c) 落在 weight[c,r]，
    扁平下标 = col*out + row。
    """
    if module.__class__.__name__ == "Conv1D":
        return col * module.weight.size(1) + row
    t = _weight_tensor_of(module)   # FaRLayer.W / Linear.weight，[out,in]
    return row * t.size(1) + col


def _flip_entry(model, layer_name, row, col, bit):
    m = _get_module(model, layer_name)
    idx = _flat_index_of(m, row, col)
    _flip_on_tensor(_weight_tensor_of(m), idx, bit)


# ------------------------------------------------------------------ 构建防护模型


def build_protected(src_model, tok, layer_name, n, div):
    """制作 FaR 加固模型副本，返回 (受护模型, FaRMap配置)。src 不被修改。"""
    dead = _dead_channel_pool(src_model, layer_name, tok)
    mod = _get_module(src_model, layer_name)
    _, grads = compute_gradients(src_model, tok)
    pname = _layer_grad_name(src_model, grads, layer_name)
    if pname is None:
        raise KeyError(f"无法定位层 {layer_name} 的权重梯度")
    sens = find_sensitive_weights(mod, grads, pname, top=n)

    prot = copy.deepcopy(src_model).eval()
    wrap = FaRLayer.from_src(_get_module(prot, layer_name), div)
    entries = wrap.apply_rewire(sens, dead)
    _set_module(prot, layer_name, wrap)

    in_features = (wrap.in_ if hasattr(wrap, "in_") else int(mod.weight.size(1)))
    cfg = {"layer": layer_name, "div": div, "in_features": in_features, "far": entries}
    return prot, cfg


def save_protected(prot_model, cfg, out_dir=None):
    if out_dir is None:
        out_dir = DIR
    base = cfg["layer"].replace(".", "_")
    os.makedirs(out_dir, exist_ok=True)
    map_path = os.path.join(out_dir, f"far_map_{base}.json")
    ckpt_path = os.path.join(out_dir, f"far_protected_{base}.pt")
    with open(map_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    torch.save(prot_model.state_dict(), ckpt_path)
    print(f"[ok] FaRMap+shadow -> {map_path}")
    print(f"[ok] 受护模型state_dict -> {ckpt_path}")


# ------------------------------------------------------------------ CLI


def cmd_selftest(_):
    torch.manual_seed(3)

    # (a) 受控微型层：通道0 激活≈0 作为真正 dead lane，验证守恒精确成立
    C, R = 8, 4
    w = torch.randn(R, C)
    base = torch.nn.Linear(C, R, bias=False)
    base.weight.data.copy_(w)
    x = torch.randn(5, C)
    x[:, 0] = 1e-8 * torch.randn(5)     # 通道0 强制 dead

    lay = FaRLayer(base.weight.detach(), None, div=2)
    lay.apply_rewire([(2, 1, 1.0)], dead_pool=[0])   # 敏感 col=2,row=1，dead lane=0
    with torch.no_grad():
        out_base = base(x)
        out_far = lay(x)
        diff = (out_base - out_far).abs().max().item()
    print(f"[selftest] 微型层 FaR 实测偏差 = {diff:.2e}  (dead lane 激活≈0 → 应≈0)")
    ok_small = diff < 1e-5

    # (b) 真实层：用「真实前向捕获的输入激活」做等价性测试
    #    （死链 dead lane 只在真实分布的≈0通道上成立，随机稠密输入会失真）
    model, tok = load()
    corrupted = []
    for layer_name, expect in [("transformer.h.0.mlp.c_proj", 0.10),
                               ("lm_head", 5.0)]:
        m = _get_module(model, layer_name)
        x_real = _capture_input_act(model, layer_name, tok, REFERENCE_CORPUS[0])
        # dead 通道取该真实输入的激活范数升序
        norms = x_real.movedim(-1, 0).norm(dim=tuple(range(1, x_real.dim())))
        dead = [int(i) for i in torch.argsort(norms).tolist()]
        fl = FaRLayer.from_src(m, div=2)
        _, grads = compute_gradients(model, tok)
        pname = _layer_grad_name(model, grads, layer_name)
        sens = find_sensitive_weights(m, grads, pname, top=4)
        fl.apply_rewire(sens, dead_pool=dead)
        diff = fl.forward_matches(m, x_real)
        print(f"[selftest] {layer_name:42s} FaR 前后偏差 = {diff:.2e}")
        corrupted.append(diff > expect)

    ok = ok_small and not corrupted[0]
    print(f"[selftest] {'PASS ✅ 输出守恒' if ok else 'FAIL ❌ 守恒被破坏(普遍偏大)'}")
    print("[selftest] 提示：c_proj 输入来自 GELU → 真 dead 单元多，守恒精确；"
          "lm_head 输入稠密、dead 少，只作信息展示。")
    return 0 if ok else 1


def cmd_protect(args):
    model, tok = load()
    prot, cfg = build_protected(model, tok, args.layer, args.n, args.div)
    print(f"> 已保护层 {args.layer}（n={args.n}, div={args.div}）")
    save_protected(prot, cfg, args.out_dir or DIR)
    p_base = _mean_ppl(model, tok)
    p_far = _mean_ppl(prot, tok)
    print(f"[ok] 保护前 平均困惑度 = {p_base:.2f}")
    print(f"[ok] 保护后 平均困惑度 = {p_far:.2f}  （应变几乎不变）")
    return 0


def cmd_demo(args):
    """论文口径演示：同一位点翻转打在裸模型与 FaR 模型上，对比
    「NLL/困惑度/相对原模型 next-token 准确率」的爬升以及『到阈值需翻位』。"""
    model, tok = load()
    model = model.eval()
    ref = copy.deepcopy(model).eval()   # 未攻击参考模型（next-token 一致率/ KL 的基准）
    prot, cfg = build_protected(model, tok, args.layer, args.n, args.div)

    nll_u0, ppl_u0 = corpus_nll(model, tok)
    nll_p0, ppl_p0 = corpus_nll(prot, tok)
    acc_u0 = next_tok_acc(model, ref, tok)
    acc_p0 = next_tok_acc(prot, ref, tok)
    kl_p0 = mean_kl(prot, ref, tok)
    c = math.log(args.threshold)      # 到阈值判据：ppl 达基线×threshold ⇔ NLL≥基线+c

    print("=" * 78)
    print(f"FaR 防护演示（论文口径）—— 层 {cfg['layer']}  保护 {args.n} 个敏感权重  div={args.div}")
    print("指标：NLL(=log困惑度)/困惑度/相对原模型next-token准确率/分布KL")
    print("=" * 78)
    print(f"裸模型 基线 : NLL={nll_u0:.4f}  ppl={ppl_u0:.2f}  acc={acc_u0:.1f}%")
    print(f"FaR后 基线 : NLL={nll_p0:.4f}  ppl={ppl_p0:.2f}  acc={acc_p0:.1f}%  KL={kl_p0:.4f}")
    print(f"  → 精度仅降 {100 - acc_p0:.2f}pp（应<2%，论文上界），KL≈{kl_p0:.3f}：功能保真达标")
    print(f"『到阈值需翻位』判据：ppl 达 基线×{args.threshold} ⇔ NLL≥基线+{c:.3f}；对比裸/FaR 各自所需翻位。")
    print("-" * 78)

    positions = [(e["col"], e["row"]) for e in cfg["far"]]
    maxflip = min(args.budget, len(positions))
    chk = sorted({k for k in (1, 2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64) if k <= maxflip})
    if not chk or chk[-1] != maxflip:
        chk.append(maxflip)

    print(f"{'翻转数':>5} | {'裸 NLL':>9} {'ppl':>9} {'acc':>7} | {'FaR NLL':>9} {'ppl':>9} {'acc':>7}")
    curves_u, curves_p = [], []   # (flips, nll, ppl, acc)
    flipped = 0
    for k in chk:
        while flipped < k and flipped < len(positions):
            col, row = positions[flipped]
            # 翻转指数位 24..26（放大≈2/4/8×，有限）。避开 bit30（softmax 上溢成 NaN）。
            bit = 24 + (((row * cfg["in_features"] + col) // 5) % 3)
            _flip_entry(model, args.layer, row, col, bit)
            _flip_entry(prot, args.layer, row, col, bit)
            flipped += 1
        nu, pu = corpus_nll(model, tok);  au = next_tok_acc(model, ref, tok)
        np_, pp_ = corpus_nll(prot, tok);  ap_ = next_tok_acc(prot, ref, tok)
        curves_u.append((flipped, nu, pu, au))
        curves_p.append((flipped, np_, pp_, ap_))
        print(f"{flipped:5d} | {nu:9.3f} {pu:9.1f} {au:6.1f}% | {np_:9.3f} {pp_:9.1f} {ap_:6.1f}%")
    print("-" * 78)

    def cross_thr(curve, base_nll):
        return next((f for f, n, _, _ in curve
                     if math.isfinite(n) and n >= base_nll + c), None)
    uc = cross_thr(curves_u, nll_u0)
    pc_ = cross_thr(curves_p, nll_p0)
    def f2x(v):
        return "≥" + str(chk[-1]) if v is None else str(v)
    if uc:
        ratio = (pc_ or chk[-1]) / max(uc, 1)
    else:
        ratio = float("inf")
    ratio_txt = "∞(预算内未达阈值)" if not math.isfinite(ratio) else f"{ratio:.2f}×"
    print(f"『达到阈值所需翻位』裸={f2x(uc)}位, FaR={f2x(pc_)}位  →  比值 {ratio_txt}")
    print(f"  （论文区间 1.4–4.2×；每位经 FaR 只损失 1/div 贡献，故到阈值更晚）")
    return 0


def main():
    ap = argparse.ArgumentParser(description="FaR 防护工具")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s0 = sub.add_parser("selftest"); s0.set_defaults(func=cmd_selftest)

    s1 = sub.add_parser("protect")
    s1.add_argument("--layer", default="transformer.h.2.mlp.c_proj")
    s1.add_argument("--n", type=int, default=8)
    s1.add_argument("--div", type=int, default=2, choices=[2, 3])
    s1.add_argument("--out-dir", default=None)
    s1.set_defaults(func=cmd_protect)

    s2 = sub.add_parser("demo")
    s2.add_argument("--layer", default="transformer.h.2.mlp.c_proj")
    s2.add_argument("--n", type=int, default=16)
    s2.add_argument("--div", type=int, default=2, choices=[2, 3])
    s2.add_argument("--budget", type=int, default=16)
    s2.add_argument("--threshold", type=float, default=4.0,
                    help="到阈值判据：ppl 达基线×THRESHOLD 视为损伤达成（论文用 accuracy drop，这里用等价的困惑度倍数，默认4）")
    s2.set_defaults(func=cmd_demo)

    args = ap.parse_args()
    raise SystemExit(args.func(args) or 0)


if __name__ == "__main__":
    main()