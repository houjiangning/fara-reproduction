"""recheck_threshold_metric.py —— 复核「到阈值需翻位」判据（论文口径）并修正。

为什么要复核
------------
eval_benchmark.py 的 far 模式给出的结论是「裸 4 位 / FaR 4 位 → 比值 1.0×」，
与 FaR 论文（USENIX Security '24）报告的 1.4–4.2× 明显不符。逐项查下来，
1.0× 不是「防护无效」，而是**判据本身在饱和区取数**造成的假象：

  1) 采样点太粗。MEASURE=(1,2,4,6,8,…)，从 2 位到 4 位之间什么都没测。
     而 ppl 恰恰在这两位之间从 ~145 崩到 ~1e5，两个模型都落在同一个粗格子里。
  2) 阈值太高。判据是 ppl ≥ 基线×4 ⇔ NLL ≥ 基线 + ln4 ≈ +1.386。
     在敏感指数位上，**单次**翻位就能把 NLL 抬高 +1.5~+2，
     所以一旦进入敏感区，裸/FaR 都会在同一位越线 → 比值必然退化成 1.0×。
  3) 指标放大。判据用的是 ppl（=exp(NLL)），指数把「损伤减半」放大成
     「数值差 5 倍但同格越线」，离散的「第几位越线」根本分辨不出来。

FaR 的机理决定的理论比值
------------------------
div=2、每条目 1 条 dead lane 时，攻击者翻转敏感位置 (row,A) 的 1 个 bit：
  裸   : ΔY[row] = x[A]·ΔW
  FaR  : 主 lane 被激活规约到 x[A]/div，dead lane 另存一份**未翻**的 W[row,A]，
         故 ΔY[row] = (x[A]/div)·ΔW = ΔY_裸 / div
即**每位翻位的损伤被稀释到 1/div**。因此「攒够同样损伤所需翻位数」应≈div=2，
落在论文 1.4–4.2× 区间内（论文上界来自 div=3 / 多条冗余 lane）。

本脚本做什么
------------
在同一固定语料、同一抽面、同一攻击位点上，**逐位**（k=0,1,2,…,budget）测量：
  · 语料 NLL / ppl（bootstrap 均值±std，口径同 eval_benchmark）
  · 相对未攻击模型的 next-token top-1 一致率（镜像论文 accuracy 判据）
  · 预测分布 KL
并同时报告：
  (A) 逐位曲线（细粒度，能看清 1/div 的斜率差）
  (B) 多阈值下的「到阈值需翻位」与比值：
        ppl×1.25 / ×1.5 / ×2 / ×4（论文用 accuracy drop>10%，此处等价给 ppl 口径）
        acc drop>10% / >50%（论文原生口径）
  (C) 同翻位数下的损伤比 ΔNLL_裸 / ΔNLL_FaR（连续量，不饱和）
  (D) 层输出级「单位翻位损伤」比 |ΔY|_裸 / |ΔY|_FaR（最干净的 1/div 证据，
      在真实激活上测，完全绕开 ppl 的非线性）

用法
  python recheck_threshold_metric.py
  python recheck_threshold_metric.py --layer transformer.h.0.mlp.c_fc --n 16 --div 2 --budget 8
输出
  threshold_metric_recheck.json   （供仪表盘/报告引用）
"""

import argparse
import copy
import json
import math
import os
import random
import statistics

import torch
import torch.nn.functional as F

from eval_perplexity import load
from eval_benchmark import build_corpus, make_subsets, subset_ppl, subset_metrics
from far_defense import build_protected, _flip_entry, _get_module, _weight_tensor_of
from model_profile import layer_count

DIR = os.path.dirname(os.path.abspath(__file__))

# 与 eval_benchmark._far_bit 完全一致：指数位 24..26（避开 bit30 上溢成 NaN）
def far_bit(cfg, row, col):
    return 24 + (((row * cfg["in_features"] + col) // 5) % 3)


def first_cross(flips, vals, pred):
    """返回第一个满足 pred(v) 的翻位数；没有则 None。"""
    for f, v in zip(flips, vals):
        if v is not None and math.isfinite(v) and pred(v):
            return f
    return None


def ratio_or_none(far_f, bare_f, last):
    """FaR 需翻位 / 裸 需翻位。裸未越线时按预算上限给下界。"""
    if bare_f is None:
        return None
    return (far_f if far_f is not None else last) / max(bare_f, 1)


def layer_output_flip_damage(clean, prot, layer, x_real, positions, cfg):
    """(D) 层输出级单位翻位损伤比。

    在真实激活 x_real 上，对每个敏感位点翻同一位，
    分别测裸层与 FaR 层输出的最大绝对变化，求比值（理论≈div）。
    """
    lin = _get_module(clean, layer)
    far = _get_module(prot, layer)

    with torch.no_grad():
        y0 = lin(x_real).float()
        z0 = far(x_real).float()

    rows = []
    for (col, row) in positions:
        bit = far_bit(cfg, row, col)

        # 该敏感输入通道在真实激活上的量级（解释"为什么有的位冷、有的位热"）
        act_mag = float(x_real[..., int(col)].abs().mean().item())

        # 裸：翻 W[row,col] 后再前向
        wt = _weight_tensor_of(lin)
        snap = wt.detach().clone()
        _flip_entry(clean, layer, row, col, bit)
        with torch.no_grad():
            y1 = lin(x_real).float()
        wt.data.copy_(snap)

        # FaR：翻同一位置（主 lane 副本）后再前向
        wtf = _weight_tensor_of(far)
        snapf = wtf.detach().clone()
        _flip_entry(prot, layer, row, col, bit)
        with torch.no_grad():
            z1 = far(x_real).float()
        wtf.data.copy_(snapf)

        d_bare = float((y1 - y0).abs().max().item())
        d_far = float((z1 - z0).abs().max().item())
        rows.append({
            "col": int(col), "row": int(row), "bit": int(bit),
            "act_mag": act_mag,
            "dy_bare": d_bare, "dy_far": d_far,
            "ratio": (d_bare / d_far) if d_far > 0 else None,
            "far_suppressed": bool(d_far == 0.0 and d_bare > 0.0),
        })
    ratios = [r["ratio"] for r in rows if r["ratio"] and math.isfinite(r["ratio"])]
    summary = {
        "per_position": rows,
        "mean_ratio": statistics.mean(ratios) if ratios else None,
        "median_ratio": statistics.median(ratios) if ratios else None,
        "n": len(ratios),
        "n_suppressed": sum(1 for r in rows if r["far_suppressed"]),
    }
    return summary


def run(args):
    random.seed(0)
    torch.manual_seed(0)

    model, tok = load()
    model.eval()
    clean = copy.deepcopy(model).eval()
    layer = args.layer
    nlayers = layer_count(clean)

    docs, tags = build_corpus(tok, "english", None)
    windows_by_doc = [_sliding(d) for d in docs]
    all_wins = [w for ws in windows_by_doc for w in ws]
    subsets = make_subsets(windows_by_doc, args.boot, args.frac)
    subset_ids = all_wins[: args.metric_windows]

    # 受护副本 + FaRMap（与板上 board_export 同参数：n=16, div=2）
    model.load_state_dict({k: v.detach().clone() for k, v in clean.state_dict().items()})
    prot, cfg = build_protected(model, tok, layer, args.n, args.div)
    positions = [(e["col"], e["row"]) for e in cfg["far"]]
    budget = min(args.budget, len(positions))
    plan = positions[:budget]

    # ref = 未攻击参照（Top-1/KL 的基准，全程不动）；bare = 会被逐位翻转的裸副本
    ref = clean
    bare = copy.deepcopy(clean).eval()
    subjects = [("裸", bare), ("FaR", prot)]

    print("=" * 82)
    print("『到阈值需翻位』判据复核（论文口径）")
    print("=" * 82)
    print(f"层 = {layer}   保护条目 n_entries = {len(positions)} (n={args.n}, div={args.div})")
    print(f"攻击位点 = FaRMap 覆盖的 {budget} 个敏感位置（同位置、同 bit 打在裸/FaR 上）")
    print(f"语料 = 固定英文内置语料，文档 {len(docs)} 段 / 窗口 {len(all_wins)} 个；"
          f"bootstrap boot={args.boot} frac={args.frac}")
    print(f"采样 = 逐位 k=0..{budget}（细粒度，取代原来的 1,2,4,6,8）")
    print("-" * 82)

    # 基线（k=0）
    base = {}
    for name, m in subjects:
        mean, std, _ = subset_ppl(m, tok, subsets, args.batch)
        base[name] = {"nll": mean, "ppl": math.exp(mean), "std": std}
        print(f"  基线[{name}]  NLL={mean:.4f}  ppl={math.exp(mean):.3f} ± {std:.4f}")

    # 逐位扫描
    flips = []
    curve = {name: {"nll": [], "std": [], "ppl": [], "top1": [], "kl": []} for name, _ in subjects}
    print("-" * 82)
    print(f"{'翻位':>4} | {'裸 NLL':>9} {'裸 ppl':>10} {'裸 top1':>7} {'裸 KL':>8}"
          f" | {'FaR NLL':>9} {'FaR ppl':>10} {'FaR top1':>7} {'FaR KL':>8}")
    print("-" * 82)

    flipped = 0
    for k in range(0, budget + 1):
        while flipped < k:
            # plan 里存的是 (col,row)；_flip_entry 需要 (row,col,bit)
            c, r = plan[flipped]
            b = far_bit(cfg, r, c)
            for name, m in subjects:
                _flip_entry(m, layer, r, c, b)
            flipped += 1

        flips.append(k)
        cells = []
        for name, m in subjects:
            mean, std, _ = subset_ppl(m, tok, subsets, args.batch)
            sm = subset_metrics(ref, m, tok, subset_ids, want_cos=False, n_layers=nlayers)
            curve[name]["nll"].append(mean)
            curve[name]["std"].append(std)
            curve[name]["ppl"].append(math.exp(mean))
            curve[name]["top1"].append(sm["top1"])
            curve[name]["kl"].append(sm["kl"])
            cells.append((mean, math.exp(mean), sm["top1"], sm["kl"]))
        print(f"{k:4d} | {cells[0][0]:9.3f} {cells[0][1]:10.1f} {cells[0][2]:6.1f}% {cells[0][3]:8.4f}"
              f" | {cells[1][0]:9.3f} {cells[1][1]:10.1f} {cells[1][2]:6.1f}% {cells[1][3]:8.4f}")

    # ---------------- (B) 多阈值「到阈值需翻位」 ----------------
    print("-" * 82)
    thresholds = []
    for mult in (1.25, 1.5, 2.0, 4.0):
        thr = {name: base[name]["ppl"] * mult for name, _ in subjects}
        bf = first_cross(flips, curve["裸"]["ppl"], lambda v, t=thr["裸"]: v >= t)
        ff = first_cross(flips, curve["FaR"]["ppl"], lambda v, t=thr["FaR"]: v >= t)
        thresholds.append({
            "kind": f"ppl>={mult}x baseline", "mult": mult,
            "bare_flips": bf, "far_flips": ff,
            "ratio": ratio_or_none(ff, bf, budget),
        })
    for drop in (0.10, 0.50):
        cut = 100.0 * (1.0 - drop)
        bf = first_cross(flips, curve["裸"]["top1"], lambda v, c=cut: v < c)
        ff = first_cross(flips, curve["FaR"]["top1"], lambda v, c=cut: v < c)
        thresholds.append({
            "kind": f"top1 drop>{int(drop*100)}%", "cut": cut,
            "bare_flips": bf, "far_flips": ff,
            "ratio": ratio_or_none(ff, bf, budget),
        })

    print("(B) 多阈值『到阈值需翻位』：")
    print(f"    {'判据':>20} | {'裸':>6} {'FaR':>6} | {'比值':>8}")
    for t in thresholds:
        bf = t["bare_flips"]; ff = t["far_flips"]; ra = t["ratio"]
        bs = str(bf) if bf is not None else f"≥{budget}"
        fs = str(ff) if ff is not None else f"≥{budget}"
        rs = f"{ra:.2f}x" if ra is not None else "n/a"
        print(f"    {t['kind']:>20} | {bs:>6} {fs:>6} | {rs:>8}")

    # ---------------- (C) 同翻位损伤比 ----------------
    print("-" * 82)
    print("(C) 同翻位数下的 NLL 损伤比（连续量，不饱和）：")
    damage_ratio = []
    for i, k in enumerate(flips):
        du = curve["裸"]["nll"][i] - base["裸"]["nll"]
        df = curve["FaR"]["nll"][i] - base["FaR"]["nll"]
        r = (du / df) if (df > 0 and du > 0) else None
        damage_ratio.append({"k": k, "dnll_bare": du, "dnll_far": df, "ratio": r})
        rs = f"{r:.3f}" if r is not None else "  -  "
        print(f"    k={k:2d}  ΔNLL_裸={du:9.4f}  ΔNLL_FaR={df:9.4f}  比 {rs}")

    # ---------------- (D) 层输出级损伤比 ----------------
    x_real = None
    try:
        holder = {}
        tgt = _get_module(clean, layer)
        h = tgt.register_forward_hook(
            lambda mod, inp, out=None: holder.__setitem__("x", inp[0].detach().clone()))
        ids = torch.tensor([list(docs[0])[:64]])
        clean(ids)
        h.remove()
        x_real = holder["x"]
    except Exception as e:  # pragma: no cover
        print(f"    [warn] 取真实激活失败: {e}")

    dmg = None
    if x_real is not None:
        dmg = layer_output_flip_damage(clean, prot, layer, x_real, plan, cfg)
        print("-" * 82)
        print("(D) 层输出级单位翻位损伤比 |ΔY|_裸 / |ΔY|_FaR（理论≈div）：")
        for r in dmg["per_position"]:
            rr = f"{r['ratio']:.3f}" if r["ratio"] else ("∞" if r["far_suppressed"] else "  -  ")
            print(f"    (col={r['col']:4d}, row={r['row']:4d}) bit={r['bit']:2d}"
                  f"  |x[A]|={r['act_mag']:.4f}"
                  f"  |ΔY|裸={r['dy_bare']:.5f}  |ΔY|FaR={r['dy_far']:.5f}  比 {rr}")
        print(f"    平均比 = {dmg['mean_ratio']:.3f}   中位比 = {dmg['median_ratio']:.3f}"
              f"   完全抑制 {dmg['n_suppressed']}/{len(dmg['per_position'])}"
              f"   （理论 div={args.div}）")

    # ---------------- 落盘 ----------------
    out = {
        "layer": layer, "n": args.n, "div": args.div,
        "n_entries": len(positions), "budget": budget,
        "corpus": {"docs": len(docs), "windows": len(all_wins),
                   "boot": args.boot, "frac": args.frac},
        "baseline": base,
        "flips": flips,
        "curve": curve,
        "thresholds": thresholds,
        "damage_ratio": damage_ratio,
        "layer_output_damage": dmg,
        "paper_ratio_range": [1.4, 4.2],
        "old_metric": {"measure_points": [1, 2, 4, 6, 8], "threshold_mult": 4.0,
                       "bare_flips": 4, "far_flips": 4, "ratio": 1.0,
                       "note": "旧口径：粗采样+ppl×4，两模型同格越线 → 1.0×"},
    }
    path = os.path.join(DIR, "threshold_metric_recheck.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("=" * 82)
    print(f"[ok] -> {path}")
    return 0


def _sliding(ids):
    from eval_benchmark import _sliding_windows
    return _sliding_windows(ids)


def main():
    ap = argparse.ArgumentParser(description="复核『到阈值需翻位』判据")
    ap.add_argument("--layer", default="transformer.h.0.mlp.c_fc")
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--div", type=int, default=2, choices=[2, 3])
    ap.add_argument("--budget", type=int, default=8)
    ap.add_argument("--boot", type=int, default=3)
    ap.add_argument("--frac", type=float, default=0.7)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--metric-windows", type=int, default=12)
    args = ap.parse_args()
    raise SystemExit(run(args) or 0)


if __name__ == "__main__":
    main()
