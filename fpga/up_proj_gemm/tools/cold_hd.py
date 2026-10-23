#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cold_hd.py -- 真冷启动样本 vs M31 参考的 HD 分析"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from puf_stability import parse_samples

REF = 0x15000150400300004440011450001082
M31 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "puf_out", "puf_samples_71e_m31.txt")
COLD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "puf_out", "puf_samples_cold.txt")

meta, r31, _ = parse_samples(M31)
n = len(r31)
mask = 0
for b in range(128):
    if sum(((r >> b) & 1) != ((REF >> b) & 1) for r in r31) == 0:
        mask |= 1 << b
sel = [b for b in range(128) if (mask >> b) & 1]

_, rc, _ = parse_samples(COLD)
print("selected bits: %d   samples: %d" % (len(sel), len(rc)))
for i, r in enumerate(rc):
    fh = bin(r ^ REF).count("1")
    sh = sum(((r >> b) & 1) != ((REF >> b) & 1) for b in sel)
    print("cold#%d: full-HD=%3d  selected-HD=%2d/%d" % (i + 1, fh, sh, len(sel)))
