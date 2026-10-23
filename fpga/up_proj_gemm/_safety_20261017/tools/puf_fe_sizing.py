#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puf_fe_sizing.py -- 用实测冷启动采样为模糊提取器（Fuzzy Extractor, FE）定容

为什么需要这个脚本（关键）：
  tools/puf_stability.py 把"稳定位掩码"定义为"在**同一批**采样里翻转率 <= 阈值的位"。
  于是**在同一批数据上**这些位必然恒定 —— 直接对这批数据算 HD 会得到 0。这是
  过拟合数字，**不能**用来定纠错码的纠错能力 t。

  FE 定容真正要回答的问题是：若用 N 次冷启动挑出稳定位，在**新的一次**冷启动里
  这些位会有多少翻转？用留一法（leave-one-out, LOO）估计：
      对每个样本 i，用其余 N-1 个样本挑稳定位掩码；
      再量 样本 i 相对"其余样本多数值"在掩码内的 HD。
  LOO 的**最坏值**就是纠错码必须覆盖的 t（再叠加设计余量）。

另附：稳定子集的偏置 -> min-entropy（密钥材料的真实熵下界）。

用法：
  python tools/puf_fe_sizing.py --in puf_out/puf_samples.txt --out-dir puf_out
"""

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from puf_stability import parse_samples  # noqa: E402


def bits_matrix(resp, nbits):
    n = len(resp)
    bits = np.zeros((n, nbits), dtype=np.uint8)
    for i, v in enumerate(resp):
        for b in range(nbits):
            bits[i, b] = (v >> b) & 1
    return bits


def majority_of(rows):
    """按列（逐位）多数值。返回 (maj, p1)。"""
    p1 = rows.mean(axis=0)
    maj = (p1 >= 0.5).astype(np.uint8)
    return maj, p1


def mask_by_max_flips(rows, max_flips):
    """挑出在这批 rows 里翻转次数 <= max_flips 的位。"""
    maj, _ = majority_of(rows)
    flips = np.count_nonzero(rows != maj[None, :], axis=0)
    return flips <= max_flips, flips


def loo(bits, max_flips):
    """留一法：返回每个样本 (idx, n_sel, hd_on_sel)。"""
    n, nbits = bits.shape
    out = []
    for i in range(n):
        others = np.delete(bits, i, axis=0)
        mask, _ = mask_by_max_flips(others, max_flips)
        idx = np.nonzero(mask)[0]
        if len(idx) == 0:
            out.append((i, 0, 0))
            continue
        maj, _ = majority_of(others[:, idx])
        hd = int(np.count_nonzero(bits[i, idx] != maj))
        out.append((i, int(mask.sum()), hd))
    return out


def min_entropy_of(bits, idx):
    """稳定子集的 min-entropy 下界 = sum(-log2(max(p1, 1-p1)))。"""
    if len(idx) == 0:
        return 0.0
    p1 = bits[:, idx].mean(axis=0)
    pmax = np.maximum(p1, 1.0 - p1)
    pmax = np.clip(pmax, 1e-9, 1.0)
    return float(np.sum(-np.log2(pmax)))


def shannon_of(bits, idx):
    """稳定子集的 Shannon 熵（按位 Bernoulli）= sum H2(p1)。"""
    if len(idx) == 0:
        return 0.0
    p1 = np.clip(bits[:, idx].mean(axis=0), 1e-9, 1 - 1e-9)
    return float(np.sum(-(p1 * np.log2(p1) + (1 - p1) * np.log2(1 - p1))))


def main():
    ap = argparse.ArgumentParser(description="PUF FE 定容（LOO 残差翻转）")
    ap.add_argument("--in", dest="src", default="puf_out/puf_samples.txt")
    ap.add_argument("--out-dir", default="puf_out")
    a = ap.parse_args()

    if not os.path.isfile(a.src):
        print(f"ERROR: 找不到采样文件 {a.src}", file=sys.stderr)
        sys.exit(2)

    meta, resp, unan = parse_samples(a.src)
    nbits = int(meta.get("nbits", "128"))
    bits = bits_matrix(resp, nbits)
    n = bits.shape[0]

    print("=" * 72)
    print("PUF 模糊提取器定容（留一法残差翻转）")
    print("=" * 72)
    print(f"  采样文件 : {a.src}")
    print(f"  采样条数 : {n}   位宽 : {nbits}   参数 : "
          f"M={meta.get('n_samp')} T_FORCE={meta.get('t_force')} T_SETTLE={meta.get('t_settle')}")

    result = {"input": a.src, "meta": meta, "n_samples": n, "nbits": nbits, "thresholds": {}}

    for max_flips in (0, 1, 2, 3):
        full_mask, flips = mask_by_max_flips(bits, max_flips)
        n_stable = int(full_mask.sum())
        idx = np.nonzero(full_mask)[0]

        loo_res = loo(bits, max_flips)
        hds = np.array([r[2] for r in loo_res], dtype=np.int64)
        nsel = np.array([r[1] for r in loo_res], dtype=np.int64)
        me = min_entropy_of(bits, idx)

        # 该阈值下（全量选择）稳定位在全部样本上的 HD（预期为 0，作对照）
        maj_full, _ = majority_of(bits[:, idx]) if n_stable else (None, None)
        hd_full = int(np.count_nonzero(bits[:, idx] != maj_full)) if n_stable else 0

        rec = {
            "selection_max_flips": max_flips,
            "stable_bits": n_stable,
            "stable_indices": [int(x) for x in idx],
            "hd_on_sel_same_set": hd_full,
            "loo_n_selected_min": int(nsel.min()) if len(nsel) else 0,
            "loo_n_selected_max": int(nsel.max()) if len(nsel) else 0,
            "loo_hd_mean": float(hds.mean()),
            "loo_hd_max": int(hds.max()),
            "loo_hd_per_boot": [int(x) for x in hds],
            "min_entropy_bits": me,
            "shannon_bits": shannon_of(bits, idx),
        }
        result["thresholds"][f"maxflips{max_flips}"] = rec

        print("-" * 72)
        print(f"  选位条件: 翻转 <= {max_flips} / {n-1} 次")
        print(f"    稳定位数           : {n_stable} / {nbits}")
        print(f"    同批数据上 HD      : {hd_full}  (过拟合对照，恒为 0)")
        print(f"    LOO 选位数         : {rec['loo_n_selected_min']}..{rec['loo_n_selected_max']}")
        print(f"    LOO 残差 HD        : 均值 {rec['loo_hd_mean']:.3f}  最坏 {rec['loo_hd_max']}")
        print(f"    LOO 残差 HD 逐条   : {rec['loo_hd_per_boot']}")
        print(f"    子集 min-entropy   : {me:.2f} bit   (Shannon {rec['shannon_bits']:.2f} bit)")

    os.makedirs(a.out_dir, exist_ok=True)
    op = os.path.join(a.out_dir, "puf_fe_sizing.json")
    with open(op, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print("-" * 72)
    print(f"  结果 JSON: {op}")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
