#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_aes_vectors.py -- AES-256-CTR 向量生成 + Python golden 参考模型

用途（P0 阶段）：
  1) --mode kat : 用 NIST SP 800-38A 的 AES-256-CTR 官方向量自检 Python 实现
  2) --mode gen : 生成随机向量，落成 XSim 可 $readmemh 的 .mem 文件

关键：本文件里的 AES 实现是**零依赖的纯 Python**，它就是 RTL 的 golden 模型。
      与 RTL 的契约（必须严格一致）：

        · 128-bit 块字节序：块字节 j（j=0..15）位于 blk[8*j +: 8]
          ⇔ Python: blk = int.from_bytes(block_bytes, 'little')
        · CTR 计数器块 = [ nonce(12B) | ctr 大端(4B) ]
          由 aes256_ctr.sv 的 counter_block() 注释给出同一定义
        · 流上 16 个连续字节按出现顺序构成块字节 0..15；
          每 2 个 64-bit beat 组成 1 个块，第一拍 = 低 64 位

.mem 文件布局（128-bit/行，XSim $readmemh 读入 reg [127:0] vmem[]）：
      [0] key[255:128]
      [1] key[127:0]
      [2] {32'h0, nonce[95:0]}
      [3] {96'h0, ctr_init[31:0]}
      [4] {96'h0, n_blk[31:0]}
      [5 .. 4+n]        数据块（明文）
      [5+n .. 4+2n]     期望密文块

用法：
    python tools/gen_aes_vectors.py --mode kat
    python tools/gen_aes_vectors.py --mode gen --n-blk 64 --out sim/aes_vectors.mem
"""

import argparse
import os
import random
import sys

# ============================================================================
# 1) 纯 Python AES-256（只实现加密方向 —— CTR 不需要解密）
# ============================================================================

def _gmul(a: int, b: int) -> int:
    """GF(2^8) 乘法，模 AES 不可约多项式 x^8+x^4+x^3+x+1 (0x11B)"""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _make_sbox():
    """按 FIPS-197 定义构造 S-box：GF(2^8) 乘法逆元 + 仿射变换"""
    inv = [0] * 256
    for i in range(1, 256):
        for j in range(1, 256):
            if _gmul(i, j) == 1:
                inv[i] = j
                break
    sb = []
    for i in range(256):
        x = inv[i]
        y = x
        for _ in range(4):
            x = ((x << 1) | (x >> 7)) & 0xFF
            y ^= x
        sb.append(y ^ 0x63)
    return sb


SBOX = _make_sbox()
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40]

# 自检：这三个值是 FIPS-197 里公开的锚点
assert SBOX[0x00] == 0x63 and SBOX[0x01] == 0x7C and SBOX[0x53] == 0xED, "S-box 构造错误"


def key_expansion(key: bytes):
    """AES-256 密钥扩展：32 字节 -> 60 个 32-bit word"""
    assert len(key) == 32, "AES-256 需要 32 字节密钥"
    w = [list(key[4 * i: 4 * i + 4]) for i in range(8)]
    for i in range(8, 60):
        t = list(w[i - 1])
        if i % 8 == 0:
            t = t[1:] + t[:1]                  # RotWord
            t = [SBOX[b] for b in t]           # SubWord
            t[0] ^= RCON[i // 8 - 1]
        elif i % 8 == 4:
            t = [SBOX[b] for b in t]           # SubWord（AES-256 特有）
        w.append([w[i - 8][j] ^ t[j] for j in range(4)])
    return w


def encrypt_block(w, block: bytes) -> bytes:
    """单块 AES-256 加密。block 为 16 字节，state[r][c] = block[r + 4c]"""
    s = list(block)

    def add_rk(ridx):
        # state[r][c] ^= rk_word[c][r]，其中 rk_word[c] = w[4*ridx + c]
        for c in range(4):
            wc = w[4 * ridx + c]
            for r in range(4):
                s[4 * c + r] ^= wc[r]

    def sub_bytes():
        for i in range(16):
            s[i] = SBOX[s[i]]

    def shift_rows():
        old = list(s)
        for r in range(4):
            for c in range(4):
                s[4 * c + r] = old[4 * ((c + r) % 4) + r]

    def mix_columns():
        for c in range(4):
            a0, a1, a2, a3 = s[4 * c:4 * c + 4]
            s[4 * c + 0] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3
            s[4 * c + 1] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3
            s[4 * c + 2] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3)
            s[4 * c + 3] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2)

    add_rk(0)
    for rnd in range(1, 14):
        sub_bytes(); shift_rows(); mix_columns(); add_rk(rnd)
    sub_bytes(); shift_rows(); add_rk(14)
    return bytes(s)


# ============================================================================
# 2) CTR 模式（与 aes256_ctr.sv 的定义严格一致）
# ============================================================================

def counter_block(nonce12: bytes, ctr: int) -> bytes:
    """计数器块 = nonce(12B) || ctr 大端(4B)"""
    assert len(nonce12) == 12
    return nonce12 + (ctr & 0xFFFFFFFF).to_bytes(4, "big")


def ctr_crypt(w, nonce12: bytes, ctr0: int, data: bytes) -> bytes:
    """CTR 加解密（同一函数）。data 不足 16 字节的尾部按流截断处理。"""
    out = bytearray(len(data))
    for i in range(0, len(data), 16):
        blk = counter_block(nonce12, ctr0 + i // 16)
        ks = encrypt_block(w, blk)
        chunk = data[i:i + 16]
        for j, b in enumerate(chunk):
            out[i + j] = b ^ ks[j]
    return bytes(out)


def blk_le(b: bytes) -> int:
    """16 字节 -> 128-bit 整数（小端），对应 RTL 的 blk[8*j +: 8] 约定"""
    return int.from_bytes(b, "little")


def blk_bytes(v: int) -> bytes:
    return (v & ((1 << 128) - 1)).to_bytes(16, "little")


# ============================================================================
# 3) NIST SP 800-38A 官方 KAT（AES-256-CTR，F.5.5）
# ============================================================================
NIST_KEY = bytes.fromhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
NIST_CB0 = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")   # 初始计数器块
NIST_PT = [
    "6bc1bee22e409f96e93d7e117393172a",
    "ae2d8a571e03ac9c9eb76fac45af8e51",
    "30c81c46a35ce411e5fbc1191a0a52ef",
    "f69f2445df4f9b17ad2b417be66c3710",
]
NIST_CT = [
    "601ec313775789a5b7a7f504bbf3d228",
    "f443e3ca4d62b59aca84e990cacaf5c5",
    "2b0930daa23de94ce87017ba2d84988d",
    "dfc9c58db67aada613c2dd08457941a6",
]


def run_kat(out_path: str = None) -> int:
    print("=" * 68)
    print("NIST SP 800-38A  F.5.5  AES-256-CTR  KAT")
    print("=" * 68)

    w = key_expansion(NIST_KEY)
    pt = b"".join(bytes.fromhex(x) for x in NIST_PT)
    expect = b"".join(bytes.fromhex(x) for x in NIST_CT)

    # NIST 向量给的就是初始计数器块本身，直接用它作为 nonce/ctr 拆解
    nonce12 = NIST_CB0[:12]
    ctr0 = int.from_bytes(NIST_CB0[12:], "big")
    got = ctr_crypt(w, nonce12, ctr0, pt)

    ok = True
    for i in range(4):
        g = got[16 * i:16 * (i + 1)].hex()
        e = expect[16 * i:16 * (i + 1)].hex()
        mark = "OK " if g == e else "BAD"
        if g != e:
            ok = False
        print(f"  blk{i}  got={g}")
        print(f"        want={e}   [{mark}]")

    # 顺带验证"块字节序"契约：nonce/ctr 拆解后重组应等于原始计数器块
    rebuilt = counter_block(nonce12, ctr0)
    if rebuilt != NIST_CB0:
        ok = False
        print(f"  !! counter_block 契约不符: {rebuilt.hex()} != {NIST_CB0.hex()}")

    print("-" * 68)
    print("KAT 结果: " + ("=== PASS ===" if ok else "=== FAIL ==="))
    print("=" * 68)

    # ---- 落成 TB 可直接 $readmemh 的 .mem（避免在 RTL 里手抄十六进制）----
    if out_path:
        cb = [counter_block(nonce12, ctr0 + i) for i in range(4)]
        ks = [bytes(a ^ b for a, b in zip(got[16 * i:16 * i + 16], pt[16 * i:16 * i + 16]))
              for i in range(4)]
        lines = [
            f"{int.from_bytes(NIST_KEY[0:16], 'big'):032x}",
            f"{int.from_bytes(NIST_KEY[16:32], 'big'):032x}",
        ]
        lines += [f"{blk_le(c):032x}" for c in cb]
        lines += [f"{blk_le(k):032x}" for k in ks]
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="ascii") as f:
            f.write("\n".join(lines) + "\n")
        print(f"KAT 向量已写入: {out_path}  ({len(lines)} 行)")
        print("  [0]key_hi [1]key_lo [2..5]counter_block [6..9]expected_keystream")
        print("=" * 68)

    return 0 if ok else 1


# ============================================================================
# 4) 随机向量生成 -> .mem
# ============================================================================

def run_gen(n_blk: int, out_path: str, seed: int) -> int:
    rnd = random.Random(seed)

    key = bytes(rnd.getrandbits(8) for _ in range(32))
    nonce = bytes(rnd.getrandbits(8) for _ in range(12))
    ctr0 = rnd.getrandbits(32)

    # 数据块：刻意混合几种边界形态，覆盖 RTL 的位序陷阱
    data_blocks = []
    #  ① 全 0
    data_blocks.append(bytes(16))
    #  ② 递增字节 0x00..0x0F（能一眼看出字节序是否搞反）
    data_blocks.append(bytes(range(16)))
    #  ③ 递减字节
    data_blocks.append(bytes(range(15, -1, -1)))
    #  ④ 单比特游走（8 个）
    for k in range(8):
        b = bytearray(16)
        b[k] = 0x01 << (k % 8)
        data_blocks.append(bytes(b))
    #  ⑤ 其余随机
    while len(data_blocks) < n_blk:
        data_blocks.append(bytes(rnd.getrandbits(8) for _ in range(16)))
    data_blocks = data_blocks[:n_blk]

    w = key_expansion(key)
    data = b"".join(data_blocks)
    cipher = ctr_crypt(w, nonce, ctr0, data)

    lines = []
    lines.append(f"{int.from_bytes(key[0:16], 'big'):032x}")    # key[255:128]
    lines.append(f"{int.from_bytes(key[16:32], 'big'):032x}")   # key[127:0]
    lines.append(f"{int.from_bytes(nonce, 'little'):032x}")     # {32'h0, nonce}
    lines.append(f"{ctr0:032x}")                                # {96'h0, ctr_init}
    lines.append(f"{n_blk:032x}")                               # {96'h0, n_blk}
    for i in range(n_blk):
        lines.append(f"{blk_le(data_blocks[i]):032x}")
    for i in range(n_blk):
        lines.append(f"{blk_le(cipher[16 * i:16 * (i + 1)]):032x}")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="ascii") as f:
        f.write("\n".join(lines) + "\n")

    print("=" * 68)
    print("生成随机向量")
    print("=" * 68)
    print(f"  输出文件   : {out_path}")
    print(f"  块数       : {n_blk}")
    print(f"  key        : {key.hex()}")
    print(f"  nonce      : {nonce.hex()}")
    print(f"  ctr_init   : 0x{ctr0:08x}")
    print(f"  首块明文   : {data_blocks[0].hex()}")
    print(f"  首块密文   : {cipher[0:16].hex()}")
    print(f"  行数       : {len(lines)}  (5 头部 + {n_blk} 明文 + {n_blk} 密文)")
    print("=" * 68)
    return 0


# ============================================================================

def main():
    ap = argparse.ArgumentParser(description="AES-256-CTR 向量生成 / golden 自检")
    ap.add_argument("--mode", choices=["kat", "gen", "all"], default="all")
    ap.add_argument("--n-blk", type=int, default=64, help="随机向量的块数")
    ap.add_argument("--out", default="sim/aes_vectors.mem", help="随机向量 .mem 输出路径")
    ap.add_argument("--kat-out", default="sim/aes_kat.mem", help="KAT .mem 输出路径")
    ap.add_argument("--seed", type=int, default=20261012)
    a = ap.parse_args()

    rc = 0
    if a.mode in ("kat", "all"):
        rc |= run_kat(a.kat_out)
        print()
    if a.mode in ("gen", "all"):
        rc |= run_gen(a.n_blk, a.out, a.seed)
    return rc


if __name__ == "__main__":
    sys.exit(main())