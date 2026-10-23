#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_kdf_vectors.py -- 生成 sha256_kdf 的 golden 向量

消息格式（必须与 rtl/sha256_kdf.sv 逐位一致）：
    block = seed(16B) || salt(16B) || purpose(16B)   = 48 B = 384 bit，单个 SHA-256 块
    三段都按**大端整数**解释：
        seed_int.to_bytes(16,'big') 等
    RTL 侧 W0..W3 = seed[127:96..0]、W4..W7 = salt[...]、W8..W11 = purpose[...]、
    W12 = 0x80000000, W13=W14=0, W15=384。

输出 sim/kdf_vectors.mem，每行（纯数据，无注释行）：
    <seed:32hex> <salt:32hex> <purpose:32hex> <digest:64hex>

第 0 条是全零向量（消息 = 48 个 0 字节），作为不依赖 RTL 的锚点；
第 1 条的 seed 只有 22 位有效（模拟真实 FE 输出 low-k 有效、其余补 0 的形态）。
"""

import argparse
import hashlib
import os
import random


PURPOSE = b"fara-weight-aes\x00"          # 16 字节用途标签


def one(seed, salt, purpose):
    msg = seed.to_bytes(16, "big") + salt.to_bytes(16, "big") + purpose
    dg = hashlib.sha256(msg).digest()
    return "%032x %032x %032x %064x" % (
        seed, salt, int.from_bytes(purpose, "big"), int.from_bytes(dg, "big"))


def main():
    ap = argparse.ArgumentParser(description="KDF golden vectors")
    ap.add_argument("--out", default="sim/kdf_vectors.mem")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20261016)
    a = ap.parse_args()

    rnd = random.Random(a.seed)
    lines = []

    # 锚点：全零
    lines.append(one(0, 0, b"\x00" * 16))
    # 真实形态：22 位 seed + 随机 salt
    lines.append(one(rnd.getrandbits(22), rnd.getrandbits(128), PURPOSE))
    # 其余随机
    for _ in range(max(0, a.n - 2)):
        lines.append(one(rnd.getrandbits(128), rnd.getrandbits(128), PURPOSE))

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print("=" * 68)
    print("KDF golden vectors")
    print("=" * 68)
    print("  输出 : %s（%d 条）" % (a.out, len(lines)))
    print("  消息 : seed(16B) || salt(16B) || purpose(16B) = 48 B，单块 SHA-256")
    print("  锚点 : 第 0 条为全零向量 digest=%s" % lines[0].split()[-1][:32])
    print("=" * 68)


if __name__ == "__main__":
    main()
