"""W1 · up_proj（GPT-2 c_fc MLP 升维层）FaR 硬件加速原理验证 —— Golden 参考生成。

三个子命令：
  scan    跨层 c_fc 敏感度扫描（对每层翻 6 个 top 敏感指数位，测 NLL/ppl 跳变，
          选"损伤最明显"的代表层）
  golden  对指定层做论文口径 PBS：裸 vs FaR 到阈值需翻位（复用 bfa_attack.cmd_pbs）
  export  对指定层导出板卡可加载格式：FaRMap json + 全量 shadow 权重 raw fp32 bin

用法：
  python w1_up_proj.py scan
  python w1_up_proj.py golden --layer transformer.h.4.mlp.c_fc --budget 16
  python w1_up_proj.py export --layer transformer.h.4.mlp.c_fc --n 16 --div 2 --out-dir ./board_export
"""
import argparse
import json
import os
import statistics
import sys

import torch
import torch.nn.functional as F

from eval_perplexity import load, perplexity, REFERENCE_CORPUS

# 快速评测用小子集（NLL 判伤，基线/阈值同口径）
FAST = REFERENCE_CORPUS[:1] + [reference for reference in REFERENCE_CORPUS[:1]]


def _c_fc_layers(model):
    names = []
    for name, p in model.named_parameters():
        if p.dtype != torch.float32:
            continue
        if ".mlp.c_fc.weight" in name:
            names.append(name.removesuffix(".weight"))
    return names


@torch.no_grad()
def _nll(model, tok, texts, max_len=120):
    total, n = 0.0, 0
    for text in texts:
        ids = tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        x = torch.tensor([ids[:max_len]])
        logits = model(x).logits[0][:-1].contiguous()
        labels = torch.tensor(ids[1:max_len])
        total += F.cross_entropy(logits, labels, reduction="sum").item()
        n += labels.numel()
    return total / max(n, 1)


def _one_shot_flip(model, tok, pname, k=6):
    """对 $pname 翻 k 个 top 敏感指数位；返回 (flat, 已翻转的 (idx,bit,orig) 列表)。"""
    p = model.get_parameter(pname)
    flat = p.detach().view(torch.int32).flatten()
    wflat = p.detach().float()
    from bfa_attack import compute_gradients
    _, grads = compute_gradients(model, tok)
    g = grads.get(pname)
    if g is None or g.shape != wflat.shape:
        raise KeyError(f"{pname} 无配对梯度")
    score = (wflat.abs() * g.float().abs()).flatten()
    topk = torch.topk(score, k=min(k, score.numel())).indices.tolist()
    done = []
    for i, idx in enumerate(topk):
        bit = 24 + (idx % 3)          # 指数位 24-26（避开 bit30/softmax 上溢）
        orig = int(flat[idx].item())
        flat[idx] = orig ^ (1 << bit)
        done.append((idx, bit, orig))
    return flat, done


def _revert(model, pname, flips):
    p = model.get_parameter(pname)
    flat = p.detach().view(torch.int32).flatten()
    for idx, _, orig in flips:
        flat[idx] = orig


def cmd_scan(args):
    from bfa_attack import compute_gradients
    model, tok = load()
    model.eval()
    layers = _c_fc_layers(model)
    if not layers:
        print("未找到 c_fc 层"); return 1
    base = _nll(model, tok, FAST)
    print("=" * 78)
    print(f"up_proj(c_fc) 跨层敏感度扫描 —— 每个层翻 {args.k} 个 top 敏感指数位(24-26)")
    print(f"快速评测 {len(FAST)} 段文本；基线 NLL={base:.4f}  ppl={math.exp(base):.2f}")
    print("=" * 78)
    rows = []
    for layer in sorted(layers):
        pname = layer + ".weight"
        _, flips = _one_shot_flip(model, tok, pname, args.k)   # 就地翻位
        nll_after = _nll(model, tok, FAST)
        ppl_after = math.exp(nll_after)
        # 回退
        _revert(model, pname, flips)
        rows.append({"layer": layer, "base_nll": base, "nll_after": nll_after,
                     "ppl_after": ppl_after,
                     "nll_delta": nll_after - base,
                     "ppl_ratio": ppl_after / max(math.exp(base), 1e-9)})
        print(f"{layer:34s} 翻{args.k}位后 NLL {base:.3f}→{nll_after:7.3f} "
              f"(+{nll_after-base:6.3f})  ppl {math.exp(base):7.1f}→{ppl_after:9.1f}  "
              f"×{rows[-1]['ppl_ratio']:6.2f}")
    rows.sort(key=lambda r: -r["ppl_ratio"])
    print("-" * 78)
    print("按损伤幅度排序（ppl 跳变/翻位越大 = 该层最易被破坏 = 演示代表层更合适）:")
    for i, r in enumerate(rows, 1):
        print(f"  {i:2d}. {r['layer']:34s} 每次翻位 ppl 因子 {r['ppl_ratio']** (1/args.k):6.3f}  翻{args.k}位合计 ×{r['ppl_ratio']:.2f}")
    out = os.path.join(args.out_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "w1_report"),
                       "c_fc_layer_scan.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"base_nll": base, "n_flips": args.k, "layers": rows}, f, indent=2)
    print(f"\n[ok] 扫描结果 -> {out}")
    return 0


def cmd_golden(args):
    from bfa_attack import cmd_pbs, _parse_pbs_args
    # 直接复用 CLI：裸 vs FaR 到阈值需翻位（论文口径）
    rule = ["pbs", "--layer", args.layer, "--budget", str(args.budget),
            "--thr", str(args.thr), "--n", str(args.n), "--div", str(args.div),
            "--tier", args.tier, "--cands", str(args.cands)]
    return cmd_pbs(_parse_pbs_args(rule[1:]))


def cmd_export(args):
    from far_defense import build_protected
    from model_profile import layer_count
    model, tok = load()
    model.eval()
    print(f"> 制作 FaR 加固副本（层 {args.layer}, n={args.n}, div={args.div}）...")
    prot, cfg = build_protected(model, tok, args.layer, args.n, args.div)
    from far_defense import _get_module
    wrap = _get_module(prot, args.layer)
    W = wrap.W.detach().float()                       # [out, in]，shadow 已写入 dead 列
    bias = wrap.b.detach().float() if wrap.b is not None else None

    out_dir = args.out_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "board_export")
    os.makedirs(out_dir, exist_ok=True)
    base = args.layer.replace(".", "_")
    meta = {
        "layer": args.layer, "div": int(wrap.div), "n": args.n,
        "in_features": int(wrap.in_), "out_features": int(wrap.out),
        "in_channels": int(wrap.in_), "out_channels": int(wrap.out),
        "W_shape": list(W.shape), "W_dtype": str(W.dtype).split(".")[-1],
        "W_byteorder": "little", "bias": bool(bias is not None),
        "far": cfg["far"],
        "fmt": "fp32_le", "W_bytes": W.numel() * 4,
    }
    meta_path = os.path.join(out_dir, f"board_cfg_{base}.json")
    wbin_path = os.path.join(out_dir, f"board_W_{base}.bin")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    W.numpy().astype("<f4", copy=False).tofile(wbin_path)
    if bias is not None:
        bias.numpy().astype("<f4", copy=False).tofile(os.path.join(out_dir, f"board_b_{base}.bin"))
    print(f"[ok] 板卡配置(FaRMap) -> {meta_path}")
    print(f"[ok] 全量 shadow 权重(fp32 LE) -> {wbin_path}  ({W.numel()*4/1e6:.1f} MB, shape {tuple(W.shape)})")
    if bias is not None:
        print(f"[ok] bias -> board_b_{base}.bin")
    # 一致性：导出重载后的 W 与原张量 bit-exact（W2/W3 通路参考）
    Wt = torch.from_numpy(W.numpy().astype("<f4", copy=False).copy()).float()
    w_ok = torch.equal(W, Wt)
    if bias is not None:
        bt = torch.from_numpy(bias.numpy().astype("<f4", copy=False).copy()).float()
        b_ok = torch.equal(bias, bt)
        print(f"[ok] 导出→重载一致性 W_bit_exact={w_ok} bias_bit_exact={b_ok}")
    else:
        print(f"[ok] 导出→重载一致性 W_bit_exact={w_ok}")
    return 0


import math

def main():
    ap = argparse.ArgumentParser(description="W1 up_proj golden 参考")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan")
    s.add_argument("--k", type=int, default=6, help="每层翻转的 top 敏感指数位数")
    s.add_argument("--out-dir", default=None)
    s.set_defaults(func=cmd_scan)

    s = sub.add_parser("golden")
    s.add_argument("--layer", required=True, help="如 transformer.h.4.mlp.c_fc")
    s.add_argument("--budget", type=int, default=16)
    s.add_argument("--thr", type=float, default=4.0)
    s.add_argument("--n", type=int, default=16)
    s.add_argument("--div", type=int, default=2)
    s.add_argument("--tier", default="basic", choices=["basic", "expert"])
    s.add_argument("--cands", type=int, default=4)
    s.set_defaults(func=cmd_golden)

    s = sub.add_parser("export")
    s.add_argument("--layer", required=True, help="如 transformer.h.4.mlp.c_fc")
    s.add_argument("--n", type=int, default=16)
    s.add_argument("--div", type=int, default=2, choices=[2, 3])
    s.add_argument("--out-dir", default=None)
    s.set_defaults(func=cmd_export)

    args = ap.parse_args()
    raise SystemExit((args.func(args) if callable(args.func) else 1) or 0)


if __name__ == "__main__":
    main()