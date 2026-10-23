"""BFA 比特翻转攻击脚本（DeepHammer 式梯度引导）—— 本地 GPT-2。

攻击思路：
  1) 前向+反向获得每个权重梯度
  2) 敏感度 = |weight × gradient|（越大越值得攻击）
  3) 按敏感度把权重位逐一翻转（fp16 视角：把目标 bit 取反）
  4) 每翻若干位，用代表性语料测 perplexity，观察“翻转预算 → 困惑度”曲线

用法：
  python bfa_attack.py                 # 默认：翻 [2,4,8,16,32] 位
  python bfa_attack.py  --max 48       # 自定义最大翻转预算

说明：
  · 攻击只改内存中的权重副本，不写盘，脚本结束后不影响原始模型
  · 默认在 fp16 权重上翻最高有效位段，贴近 FPGA 实际部署格式
"""
import argparse
import math
import os
import random
import statistics
import sys

import torch
import torch.nn.functional as F
from transformers import GPT2LMHeadModel, GPT2TokenizerFast
from eval_perplexity import load, perplexity, REFERENCE_CORPUS

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")

GRADIENTS_TEXT = (
    "Artificial intelligence is changing the way we build systems. "
    "Machine learning models need large amounts of data to learn, "
    "and modern hardware helps them run faster and more efficiently."
)

# PBS 快速评测用的小子集（基线与阈值都在同一子集上测，保证可比）。
# 用少量短文本，让“每候选位测一次 NLL”在 CPU 上可承受。
PBS_CORPUS = [GRADIENTS_TEXT] + list(REFERENCE_CORPUS[:1])


def compute_gradients(model, tok, prompt=GRADIENTS_TEXT):
    """对一段文本做前向+反向，返回每参数梯度到其原名/形状的映射。"""
    ids = torch.tensor([tok(prompt)["input_ids"]])
    model.zero_grad()
    out = model(ids, labels=ids)
    loss = out.loss
    loss.backward()
    grads = {}
    for name, p in model.named_parameters():
        if p.grad is not None:
            grads[name] = p.grad.detach().clone()
    return loss.item(), grads


def iterate_sensitive_weights(model, grads, budget):
    """按敏感度从高到低挑出 floor(budget) 个 (参数名, 元素索引)。

    敏感度 = |w * g|（w/g 均取该元素本身）。返回 (name, elem_idx) 列表。
    """
    scored = []
    for name, p in model.named_parameters():
        g = grads.get(name)
        if g is None or p.dtype != torch.float32:
            continue
        wflat = p.detach().flatten().float()
        gflat = g.flatten().float()
        score = wflat.abs() * gflat.abs()
        top = int(min(budget, p.numel()))
        idxs = torch.topk(score, k=top).indices.tolist()
        for i in idxs:
            scored.append((score[i].item(), name, i))
    scored.sort(reverse=True, key=lambda t: t[0])
    return [(n, i) for _, n, i in scored[:budget]]


def flip_bit(model, name, elem_idx, fp32_bit):
    """在 fp32 权重的指定位（0..31）上取反。

    通过 32 位有符号整数视图写入，fp32_bit 落在指数段（23..30）时
    会直接改变数值量级，产生明显破坏效果。
    """
    p = model.get_parameter(name)
    flat = p.detach().view(torch.int32).flatten()
    orig = flat[elem_idx].item()
    flat[elem_idx] = orig ^ (1 << fp32_bit)
    assert flat[elem_idx].item() != orig


def build_plan(model, grads, budget):
    """翻转计划：(name, elem_idx, fp32_bit)。统一攻击 fp32 指数段(23..30)。"""
    pairs = iterate_sensitive_weights(model, grads, budget)
    plan = []
    for name, idx in pairs:
        bit = 23 + (idx % 8)  # 指数段 8 个位轮换
        plan.append((name, idx, bit))
    return plan


def attack(model, tok, budget):
    """执行攻击并返回 (翻转次数, 平均困惑度) 序列。"""
    loss_val, grads = compute_gradients(model, tok)
    plan = build_plan(model, grads, budget)

    curve = []
    flips_done = 0
    for i, (name, idx, bit) in enumerate(plan, 1):
        flip_bit(model, name, idx, bit)
        flips_done += 1
        if flips_done in (1, 2, 4, 6, 8, 12, 16, 24, 32, 40, 48, 64) or flips_done == len(plan):
            ppls = [perplexity(model, tok, t) for t in REFERENCE_CORPUS]
            mean = statistics.mean(ppls)
            curve.append((flips_done, mean))
            print(f"  已翻转 {flips_done:3d} 位 -> 平均困惑度 {mean:10.2f}")
    return flips_done, curve


# ------------------------------------------------------------------ PBS（Progressive Bit Search）
# 对齐 FaR 论文 §2.3 / §4.1 的 DeepHammer 攻击协议：逐位“翻转→测损失→只提交
# 让损失升高的位(否则回退)→基于当前已攻模型重算梯度再找下一位”。返回「到阈值需
# 提交多少位 flips_to_break」，裸 vs FaR 各跑一遍取比值，即论文口径的防护增益
# (论文区间 ~1.4–4.2×)。


@torch.no_grad()
def _nll(model, tok, texts):
    """小子集平均 NLL（=log 困惑度），基线/阈值同一口径。"""
    total, n = 0.0, 0
    for text in texts:
        ids = tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        logits = model(torch.tensor([ids])).logits[0][:-1].contiguous()
        labels = torch.tensor(ids[1:])
        total += F.cross_entropy(logits, labels, reduction="sum").item()
        n += labels.numel()
    return total / max(n, 1)


def _getattr_path(obj, path):
    for part in path.split("."):
        obj = getattr(obj, part)
    return obj


def _layer_param_name(model, layer_name):
    """取目标层唯一的 fp32 权重参数名（LR 层下通常就是 *.weight）。"""
    fallback = []
    for name, p in model.named_parameters():
        if p.dtype != torch.float32:
            continue
        if name == layer_name + ".weight":
            return name
        if name.startswith(layer_name + "."):
            fallback.append((name, p.numel()))
    if fallback:
        return max(fallback, key=lambda t: t[1])[0]
    raise KeyError(f"层 {layer_name} 下找不到 fp32 权重参数")


def _col_of_flat(model, layer_name, p, flat_idx):
    """把扁平元素下标映射回「输入通道列」（=敏感参数 A 的语义）。

    GPT-2 各线性投影是 Conv1D，weight 为 [in,out]：idx=i*out+o -> col=i；
    普通 Linear [out,in]：idx=r*in+c -> col=c。
    """
    if p.dim() != 2:
        return None
    mod = _getattr_path(model, layer_name)
    if getattr(getattr(mod, "__class__", None), "__name__", "") == "Conv1D":
        return flat_idx // p.size(1)
    return flat_idx % p.size(1)


def pbs_bitsearch(model, tok, layer_name, budget=16, thr=4.0, cands=4,
                  sub=None, exclude_cols=None, quiet=False):
    """DeepHammer 式渐进位搜索，只在目标层权重内翻转 fp32 指数位 24–26。

    参数:
      model/tok   被测模型与分词器（会原地改权重；仅本进程内存）
      layer_name  攻击层（如 transformer.h.2.mlp.c_proj）
      budget      最大可提交位数
      thr         到阈值判据：ppl 达 基线×thr ⇔ NLL ≥ 基线+ln(thr)
      cands       每轮候选元素数（每个元素再试 24/25/26 三个指数位）
      sub         快速评测小子集（缺省 PBS_CORPUS）
      exclude_cols 屏蔽的输入通道列（Expert 攻击者可屏蔽 FaR 的 shadow 列）
    返回: (flips_to_break, base_nll, history[(flips,nll,ppl)])
      flips_to_break: 到小阈值需提交的位数；预算内未达则为 None。
    """
    sub = list(sub if sub is not None else PBS_CORPUS)
    pname = _layer_param_name(model, layer_name)
    p = model.get_parameter(pname)
    flat = p.detach().view(torch.int32).flatten()
    n_elem = p.numel()

    base = _nll(model, tok, sub)
    target = base + math.log(thr)

    def _candidates(score):
        top = torch.topk(score, k=min(int(cands) * 4, n_elem)).indices.tolist()
        out = []
        for idx in top:
            if exclude_cols:
                c = _col_of_flat(model, layer_name, p, idx)
                if c in exclude_cols:
                    continue
            for bit in (24, 25, 26):
                out.append((idx, bit))
                if len(out) >= cands * 3:
                    return out
        return out

    flipped, cur = 0, base
    hist = [(0, base, math.exp(base))]
    while flipped < budget and cur < target:
        _, grads = compute_gradients(model, tok)
        g = grads.get(pname)
        if g is None:
            break
        score = (p.detach().to(torch.float32).flatten().abs() * g.flatten().float().abs())
        cand = _candidates(score)
        if not cand:
            break
        best_nll, best = None, None
        for idx, bit in cand:
            orig = int(flat[idx].item())
            flat[idx] = orig ^ (1 << bit)
            nll = _nll(model, tok, sub)
            flat[idx] = orig                      # 回退（未提交）
            if math.isfinite(nll) and (best_nll is None or nll > best_nll):
                best_nll, best = nll, (idx, bit)
        if best is None or (best_nll <= cur):
            break                                 # 无位能让损失上升 → 停滞
        idx, bit = best
        flat[idx] = int(flat[idx].item()) ^ (1 << bit)   # commit
        flipped += 1
        cur = best_nll
        hist.append((flipped, cur, math.exp(cur)))
        if not quiet and flipped in (1, 2, 4, 6, 8, 12, 16, 24, 32):
            print(f"    PBS 提交 {flipped:3d} 位 -> NLL {cur:.4f}  ppl {math.exp(cur):7.1f}")
    flips_break = flipped if (math.isfinite(cur) and cur >= target) else None
    return flips_break, base, hist


def _parse_pbs_args(argv):
    ap = argparse.ArgumentParser(prog="bfa_attack.py pbs",
                                 description="DeepHammer 渐进位搜索 PBS：裸 vs FaR 到阈值需翻位比值")
    ap.add_argument("--layer", default="transformer.h.2.mlp.c_proj", help="攻击/被保护层")
    ap.add_argument("--budget", type=int, default=16, help="最大可提交位数")
    ap.add_argument("--thr", type=float, default=4.0, help="到阈值判据：ppl 达基线×THR")
    ap.add_argument("--n", type=int, default=16, help="FaR 保护敏感权重数")
    ap.add_argument("--div", type=int, default=2, choices=[2, 3])
    ap.add_argument("--tier", default="basic", choices=["basic", "expert"],
                    help="basic=不知 FaR 全位搜索；expert=屏蔽 shadow 列后的全位搜索")
    ap.add_argument("--cands", type=int, default=4, help="每轮候选元素数")
    ap.add_argument("--no-far", action="store_true", help="只跑裸模型，不做 FaR 对比")
    return ap.parse_args(argv)


def cmd_pbs(args):
    from far_defense import build_protected          # 惰性导入避免循环依赖

    model, tok = load()
    model = model.eval()

    prot, cfg = None, None
    if not args.no_far:
        print(f"> 制作 FaR 加固副本（层 {args.layer}, n={args.n}, div={args.div}）...")
        prot, cfg = build_protected(model, tok, args.layer, args.n, args.div)
        prot = prot.eval()

    thr = args.thr
    header_extra = f"  阈值判据：ppl ≥ 基线×{thr}（即 NLL ≥ 基线+{math.log(thr):.3f}）"

    print("=" * 74)
    print(f"PBS 渐进位搜索 vs FaR 防护  层={args.layer}  budget={args.budget}  tier={args.tier}")
    print(f"攻击位：fp32 指数位 24–26；快速评测：{len(PBS_CORPUS)} 段短文本")
    print(header_extra)
    print("=" * 74)

    base_n = _nll(model, tok, PBS_CORPUS)
    base_p = _nll(prot, tok, PBS_CORPUS) if prot is not None else None
    print(f"裸模型  基线 NLL={base_n:.4f}  ppl={math.exp(base_n):.2f}")
    if prot is not None:
        print(f"FaR 后  基线 NLL={base_p:.4f}  ppl={math.exp(base_p):.2f}  "
              f"(保护前困惑度应几乎不变)")
        print("")

    excl = set()
    if prot is not None and args.tier == "expert":
        excl = {d for e in cfg["far"] for d in e["dead"]}
        print(f"[expert] 屏蔽 shadow 输入列(dead lanes) {sorted(excl)}")
        print("")
    print("-" * 74)
    print("-- 攻击裸模型 --")
    fn, _, hn = pbs_bitsearch(model, tok, args.layer, budget=args.budget, thr=thr,
                              cands=args.cands, exclude_cols=set())
    print("")
    fp_, _, hp = None, None, None
    if prot is not None:
        print("-- 攻击 FaR 加固模型 --")
        fp_, _, hp = pbs_bitsearch(prot, tok, args.layer, budget=args.budget, thr=thr,
                                   cands=args.cands, exclude_cols=excl)

    print("=" * 74)
    print("到阈值(ppl≥基线×%g)需提交位：" % thr)
    n_txt = f"{fn} 位" if fn is not None else f"≥{args.budget}位(预算内未达)"
    print(f"  裸模型 : {n_txt}")
    if not args.no_far:
        p_txt = f"{fp_} 位" if fp_ is not None else f"≥{args.budget}位(预算内未达)"
        if fn:
            ratio = (fp_ or args.budget) / max(fn, 1)
        else:
            ratio = float("inf")
        ratio_txt = "∞(裸模型预算内未达阈值)" if not math.isfinite(ratio) else f"{ratio:.2f}×"
        print(f"  FaR 后 : {p_txt}")
        print(f"  防护比值(FaR/裸) = {ratio_txt}   （论文区间 ≈1.4–4.2×）")
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "pbs":
        return cmd_pbs(_parse_pbs_args(sys.argv[2:]))

    ap = argparse.ArgumentParser()
    ap.add_argument("--max", type=int, default=32, help="最大翻转预算（默认32）")
    args = ap.parse_args()

    model, tok = load()
    print("=" * 62)
    print(f"BFA 攻击演示 —— 最大翻转预算 {args.max} 位（fp16 指数位）")
    print("=" * 62)

    baseline = statistics.mean([perplexity(model, tok, t) for t in REFERENCE_CORPUS])
    print(f"\n攻击前 平均困惑度 = {baseline:.2f}\n")

    total, curve = attack(model, tok, args.max)

    print("\n" + "=" * 62)
    print("攻击结果汇总")
    print("=" * 62)
    print(f"实际翻转 {total} 位")
    if curve:
        b = baseline
        for k, ppl in curve:
            ratio = ppl / max(b, 1e-9)
            print(f"  翻转 {k:3d} 位 : ppl {ppl:9.2f}  (≈基线×{ratio:6.2f})")
    print("\n注：模型仅在本进程内存中被改，脚本结束即恢复原始权重。")


if __name__ == "__main__":
    main()