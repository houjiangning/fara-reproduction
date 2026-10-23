#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xbatch_check.py -- M9/M31 两批同布局采样的交叉一致性分析"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from puf_stability import parse_samples

NBITS = 128

def maj(resp):
    n = len(resp)
    m = 0
    for b in range(NBITS):
        ones = sum((r >> b) & 1 for r in resp)
        if ones * 2 > n:
            m |= 1 << b
    return m

def hd(a, b):
    return bin(a ^ b).count("1")

m9, r9, _ = parse_samples("puf_out/puf_samples_71e.txt")
m31, r31, _ = parse_samples("puf_out/puf_samples_71e_m31.txt")
print("batch sizes: M9=%d M31=%d" % (len(r9), len(r31)))

maj9, maj31 = maj(r9), maj(r31)
print("maj(M9) vs maj(M31) full-HD = %d / 128" % hd(maj9, maj31))

# 批内 LOO 均值 vs 跨批 HD
for name, resp in (("M9", r9), ("M31", r31)):
    mj = maj(resp)
    hds = [hd(r, mj) for r in resp]
    print("%s: within-batch HD vs own-maj: mean=%.2f max=%d" %
          (name, sum(hds)/len(hds), max(hds)))

cross = [hd(r, maj9) for r in r31]
cross2 = [hd(r, maj31) for r in r9]
print("M31 vs M9-maj : mean=%.2f max=%d" % (sum(cross)/len(cross), max(cross)))
print("M9  vs M31-maj: mean=%.2f max=%d" % (sum(cross2)/len(cross2), max(cross2)))

# 逐位批间多数一致率（本征位应两批同值）
agree = sum(1 for b in range(NBITS) if ((maj9 >> b) & 1) == ((maj31 >> b) & 1))
print("majority-bit agreement between batches: %d/128" % agree)
