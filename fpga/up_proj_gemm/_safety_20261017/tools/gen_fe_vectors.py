#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_fe_vectors.py -- fuzzy_extract 的 golden 向量（**码偏移 + 重复码**）

算法（必须与 rtl/fuzzy_extract.sv 逐位一致）：
    选中序：b = 0..127，若 mask 的 bit b 为 1，则按顺序取出（i = 0,1,2,...）
        w[i]  = (resp  >> b) & 1          （resp 位 b = (resp >> b) & 1）
    重建判决位：x[i] = w[i] XOR ((helper >> i) & 1)
    每 3 个 x 成一组取多数 -> seed 的 bit g（seed 即密钥材料 c）
    需要 3*k 个选中位；不足则非法（RTL 置 err，本脚本不产出）

Enrollment 侧（本脚本用来造向量）：
    cw = repeat3(c) = [c0,c0,c0, c1,c1,c1, ...]
    helper = w_clean XOR cw

输出 sim/fe_vectors.mem，每行：
    <mask:32hex> <resp:32hex> <helper:32hex> <k:2hex> <seed:32hex>

含特殊向量：
  · 边界：全 1 掩码 + k=42（3k=126）
  · 单点翻转：在选中的 3k 位里翻 1 位 -> seed 必须仍等于 c（真正纠 1 位）
  · 双点异组：在两个**不同**三元组里各翻 1 位 -> seed 仍等于 c
"""

import argparse
import os
import random

NBITS = 128


def sel_positions(mask):
    return [b for b in range(NBITS) if (mask >> b) & 1]


def reconstruct(mask, resp, helper, k):
    pos = sel_positions(mask)
    need = 3 * k
    if len(pos) < need:
        return None
    x = [((resp >> pos[i]) & 1) ^ ((helper >> i) & 1) for i in range(need)]
    c = 0
    for g in range(k):
        if (x[3 * g] + x[3 * g + 1] + x[3 * g + 2]) >= 2:
            c |= (1 << g)
    return c


def enroll(mask, w_clean, c, k):
    """返回 helper（128-bit 整数）：helper = w_clean XOR repeat3(c)"""
    cw = []
    for g in range(k):
        b = (c >> g) & 1
        cw += [b, b, b]
    h = 0
    for i in range(3 * k):
        h |= ((w_clean[i] ^ cw[i]) << i)
    return h


def fmt(mask, resp, helper, k, seed):
    return "%032x %032x %032x %02x %032x" % (mask, resp, helper, k, seed)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sim/fe_vectors.mem")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20261016)
    a = ap.parse_args()

    rnd = random.Random(a.seed)
    lines = []

    # ---- 1) 边界：全 1 掩码 + k=42 ----
    mask = (1 << NBITS) - 1
    resp = rnd.getrandbits(NBITS)
    k = 42
    w_clean = [(resp >> b) & 1 for b in sel_positions(mask)[:3 * k]]
    c = rnd.getrandbits(k)
    h = enroll(mask, w_clean, c, k)
    assert reconstruct(mask, resp, h, k) == c
    lines.append(fmt(mask, resp, h, k, c))

    # ---- 2) 单点翻转（1 位）----
    mask = 0
    pos = rnd.sample(range(NBITS), 66)
    for b in pos:
        mask |= (1 << b)
    resp = rnd.getrandbits(NBITS)
    k = 22
    sel = sel_positions(mask)[:3 * k]
    w_clean = [(resp >> b) & 1 for b in sel]
    c = rnd.getrandbits(k)
    h = enroll(mask, w_clean, c, k)
    resp1 = resp ^ (1 << sel[37])          # 选中位里翻 1 个
    assert reconstruct(mask, resp1, h, k) == c, "单点翻转未被纠正"
    lines.append(fmt(mask, resp1, h, k, c))

    # ---- 3) 双点异组（两个不同三元组各翻 1 位）----
    resp2 = resp ^ (1 << sel[5]) ^ (1 << sel[3 * 13 + 1])
    assert reconstruct(mask, resp2, h, k) == c, "双点异组未被纠正"
    lines.append(fmt(mask, resp2, h, k, c))

    # ---- 4) 随机向量 ----
    while len(lines) < a.n:
        k = rnd.randint(1, 42)
        need = 3 * k
        if need > NBITS:
            continue
        pos = rnd.sample(range(NBITS), need)       # 恰好 3k 个，最紧的选位
        mask = 0
        for b in pos:
            mask |= (1 << b)
        resp = rnd.getrandbits(NBITS)
        w_clean = [(resp >> b) & 1 for b in sel_positions(mask)[:need]]
        c = rnd.getrandbits(k)
        h = enroll(mask, w_clean, c, k)
        assert reconstruct(mask, resp, h, k) == c
        lines.append(fmt(mask, resp, h, k, c))

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print("=" * 68)
    print("FE golden vectors（码偏移 + 重复码）")
    print("=" * 68)
    print("  输出 : %s（%d 条）" % (a.out, len(lines)))
    print("  含边界(k=42) / 单点翻转 / 双点异组 三条特殊向量")
    print("=" * 68)


if __name__ == "__main__":
    main()
