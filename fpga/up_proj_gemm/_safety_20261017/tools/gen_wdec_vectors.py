#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_wdec_vectors.py -- wdec_stream 的输入/期望向量

布局契约（与 p2_dryrun_evidence.json 完全一致）：
    流 = [ X 明文 | b 明文 | W 密文 ]，64-bit AXI4-Stream beat 流。
    · 字 -> 字节：每个 32-bit 字按小端展开成 4 字节
    · 字节 -> beat：每 8 个连续字节组成一个 64-bit beat（小端）
    · AES 只作用于 W 段：block = {beat1, beat0}（beat0 为低 64 位），
      等价于 block = int.from_bytes(16 个连续字节, 'little')
    · counter 从 **W 段起点** 归零（ctr_init = 0）

输出（落在 --outdir）：
    wdec_in.mem   ：输入 beat（[X|b|W 密文]）
    wdec_exp.mem  ：期望输出 beat（[X|b|W 明文]）
    wdec_cfg.mem  ：一行 = <key:64hex> <nonce_rtl:24hex> <ctr_init:8hex> <plain_words:8hex>
                    注意 nonce 已**按 RTL 需要的字节序反转**（aes256_ctr 的
                    blk[95:0]=nonce 且 nonce 字节 0 在最低位；B7 踩过的坑）

AES 实现来自 gen_aes_vectors.py（单一可信源，已过 NIST KAT）。
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_aes_vectors import key_expansion, ctr_crypt  # noqa: E402

KEY   = bytes(range(32))            # 00..1f
NONCE = bytes(range(0xA0, 0xAC))    # a0..ab
CTR0  = 0


def words_to_bytes(ws):
    return b"".join(w.to_bytes(4, "little") for w in ws)


def bytes_to_beats(bs):
    assert len(bs) % 8 == 0, "字节数必须是 8 的倍数"
    return [int.from_bytes(bs[i:i + 8], "little") for i in range(0, len(bs), 8)]


def write_hex_lines(path, vals, width):
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for v in vals:
            f.write(("%0" + str(width) + "x\n") % v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, default=16)
    ap.add_argument("--n", type=int, default=2)
    ap.add_argument("--m-total", type=int, default=64)
    ap.add_argument("--outdir", default="sim")
    a = ap.parse_args()

    rnd = random.Random(7)

    Xw = [rnd.getrandbits(32) for _ in range(a.n * a.k)]
    bw = [rnd.getrandbits(32) for _ in range(a.m_total)]
    Ww = [rnd.getrandbits(32) for _ in range(a.m_total * a.k)]

    xb = words_to_bytes(Xw) + words_to_bytes(bw)
    wb = words_to_bytes(Ww)

    w  = key_expansion(KEY)
    wc = ctr_crypt(w, NONCE, CTR0, wb)          # W 段密文

    plain_words = a.n * a.k + a.m_total

    in_beats  = bytes_to_beats(xb + wc)
    exp_beats = bytes_to_beats(xb + wb)

    os.makedirs(a.outdir, exist_ok=True)
    p_in  = os.path.join(a.outdir, "wdec_in.mem")
    p_exp = os.path.join(a.outdir, "wdec_exp.mem")
    p_cfg = os.path.join(a.outdir, "wdec_cfg.mem")

    write_hex_lines(p_in,  in_beats,  16)
    write_hex_lines(p_exp, exp_beats, 16)
    with open(p_cfg, "w", encoding="ascii", newline="\n") as f:
        f.write("%s %s %08x %08x\n" % (
            KEY.hex(),                              # key：大端字面量即可（key_in[255:224]=密钥前 4 字节）
            NONCE[::-1].hex(),                      # nonce：RTL 侧按小端装入，故反转
            CTR0, plain_words))

    print("=" * 70)
    print("wdec_stream 向量")
    print("=" * 70)
    print("  K=%d N=%d M_TOTAL=%d" % (a.k, a.n, a.m_total))
    print("  plain_words = %d（X %d + b %d）-> 明文 beat 数 %d"
          % (plain_words, a.n * a.k, a.m_total, plain_words // 2))
    print("  W 字数 %d -> 密文 beat 数 %d" % (len(Ww), len(wc) // 8))
    print("  输入 beat  %d  -> %s" % (len(in_beats), p_in))
    print("  期望 beat  %d  -> %s" % (len(exp_beats), p_exp))
    print("  配置            -> %s" % p_cfg)
    print("=" * 70)


if __name__ == "__main__":
    main()
