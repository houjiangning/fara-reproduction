#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
encrypt_vector_pack.py —— 把 GEMM 自检向量包里的 **W 段** 加密（P2 空跑验证用）

背景（为什么只加密 W）：
    真实部署里 PC 只发激活 X，权重 W 常驻板卡 DDR 且是密文；偏置 b 仅 12 KB、
    单独泄漏价值极低，v1 不加密。所以流布局是：
        [ X 明文 : N*K 字 | b 明文 : M_TOTAL 字 | W 密文 : M_TOTAL*K 字 ]
    本工具就是为"在仿真里证明这条布局能跑通"而生的。

输入：gen_golden_vectors.py 产出的 .mem 文本向量包
      （9 个头部整数，随后 N_IN 个输入字，随后 N_OUT 个期望输出字）
输出：同格式的 .mem，其中：
      · 头部与 X/b 段原样保留
      · W 段替换为密文
      · 期望输出**不变**（这正是要证明的：加密对 GEMM 结果透明）

加密契约（必须与 RTL 一致，见 aes256_core.sv / aes256_ctr.sv 文件头）：
    · 16 字节一个块，块字节 j 位于 blk[8*j +: 8]
      ⇔ 把 16 个连续流字节按小端拼成 128 位整数
    · 流上字节的排列 = 输入字**依次**每个按小端展开成 4 字节
    · counter 从 0 起，每 16 字节 +1；计数器块 = [ nonce(12B) | ctr 大端(4B) ]

用法：
    python tools/encrypt_vector_pack.py \\
        --in sim/golden_vectors.mem \\
        --out sim/crypt_vectors.mem \\
        --key-hex <64 hex> --nonce-hex <24 hex> [--ctr-init 0]

    # 自检：加密后再解密应与原文件逐字节一致
    python tools/encrypt_vector_pack.py --selftest
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_aes_vectors import key_expansion, ctr_crypt, run_kat   # noqa: E402

# 空跑验证用固定测试密钥/随机数（**仅供仿真，绝不可用于真实部署**）
TEST_KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
TEST_NONCE_HEX = "a0a1a2a3a4a5a6a7a8a9aaab"


def die(msg, code=1):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def words_to_bytes(words):
    """字序列 -> 字节流：每字按小端展开（与 RTL 的 64-bit beat 低字先发一致）"""
    out = bytearray()
    for w in words:
        out += (w & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(out)


def bytes_to_words(buf):
    """字节流 -> 字序列（小端）"""
    if len(buf) % 4:
        die("字节数不是 4 的倍数")
    return [int.from_bytes(buf[i:i + 4], "little") for i in range(0, len(buf), 4)]


def parse_mem(path):
    with open(path, "r", encoding="ascii") as f:
        toks = f.read().split()
    if len(toks) < 9:
        die("%s 头部不足 9 个整数" % path)
    hdr = [int(toks[i]) for i in range(9)]
    K, N, M_TOTAL, M_TILE, G, AL, ML, N_IN, N_OUT = hdr
    need = 9 + N_IN + N_OUT
    if len(toks) < need:
        die("%s 令牌数 %d < 需要的 %d（N_IN=%d N_OUT=%d）"
            % (path, len(toks), need, N_IN, N_OUT))
    in_words = [int(toks[9 + i], 16) for i in range(N_IN)]
    exp_words = [int(toks[9 + N_IN + i], 16) for i in range(N_OUT)]
    return hdr, in_words, exp_words


def write_mem(path, hdr, in_words, exp_words):
    K, N, M_TOTAL, M_TILE, G, AL, ML, N_IN, N_OUT = hdr
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="ascii") as f:
        f.write("%d %d %d %d %d %d %d %d %d\n" % tuple(hdr))
        for w in in_words:
            f.write("%08x\n" % (w & 0xFFFFFFFF))
        for w in exp_words:
            f.write("%08x\n" % (w & 0xFFFFFFFF))


def segment_boundaries(hdr):
    """返回 (X_WORDS, B_WORDS, W_WORDS, W_OFFSET)"""
    K, N, M_TOTAL, M_TILE, G, AL, ML, N_IN, N_OUT = hdr
    xw = N * K
    bw = M_TOTAL
    ww = M_TOTAL * K
    if xw + bw + ww != N_IN:
        die("段长不自洽：N*K(%d) + M_TOTAL(%d) + M_TOTAL*K(%d) = %d != N_IN(%d)"
            % (xw, bw, ww, xw + bw + ww, N_IN))
    return xw, bw, ww, xw + bw


def process(src, dst, key, nonce, ctr0):
    hdr, in_words, exp_words = parse_mem(src)
    xw, bw, ww, woff = segment_boundaries(hdr)
    K, N, M_TOTAL, M_TILE, G, AL, ML, N_IN, N_OUT = hdr

    print("=" * 68)
    print("加密向量包的 W 段（P2 空跑验证）")
    print("=" * 68)
    print("  输入      : %s" % src)
    print("  输出      : %s" % dst)
    print("  配置      : K=%d N=%d M_TOTAL=%d M_TILE=%d G=%d"
          % (K, N, M_TOTAL, M_TILE, G))
    print("  流分段    : X[0..%d)  b[%d..%d)  W[%d..%d)"
          % (xw, xw, xw + bw, woff, woff + ww))
    print("              X=%d 字, b=%d 字, W=%d 字 (= %d 字节)"
          % (xw, bw, ww, ww * 4))

    if xw % 2:
        die("X 段字数 %d 非偶数，无法按 64-bit beat 打包（RTL 契约要求）" % xw)
    if (xw + bw) % 2:
        die("X+b 段字数 %d 非偶数，X/b 与 W 的边界不在 beat 边界上" % (xw + bw))
    if (ww * 4) % 16:
        die("W 段字节数 %d 不是 16 的倍数，无法整块 CTR 加密" % (ww * 4))

    # ---- 只加密 W 段 ----
    w_words = in_words[woff:woff + ww]
    w_bytes = words_to_bytes(w_words)
    w = key_expansion(key)
    w_enc = ctr_crypt(w, nonce, ctr0, w_bytes)
    if len(w_enc) != len(w_bytes):
        die("密文长度异常")
    w_enc_words = bytes_to_words(w_enc)

    out_in = list(in_words[:woff]) + w_enc_words
    if len(out_in) != N_IN:
        die("输出输入段长度变化：%d != %d" % (len(out_in), N_IN))

    write_mem(dst, hdr, out_in, exp_words)

    # ---- 校验：密文段确实变了，且除 W 外一个字节都没动 ----
    same_xb = (out_in[:woff] == in_words[:woff])
    diff_w = (out_in[woff:] != in_words[woff:])
    print("-" * 68)
    print("  X/b 段未被改动 : %s" % ("是" if same_xb else "否（异常！）"))
    print("  W 段确已变化   : %s" % ("是" if diff_w else "否（异常！）"))
    print("  前 4 个字 W    明文=%08x %08x %08x %08x" % tuple(w_words[:4]))
    print("                 密文=%08x %08x %08x %08x" % tuple(w_enc_words[:4]))
    print("  期望输出       : 原样保留 (%d 字)，这正是要验证的'加密透明'" % N_OUT)

    # ---- 反向解密，确认能还原 ----
    back = ctr_crypt(w, nonce, ctr0, w_enc)
    ok = (back == w_bytes)
    print("  W 段往返解密   : %s" % ("OK" if ok else "BAD"))

    # ---- 写 sidecar，供 TB/日志核对 ----
    meta = {
        "src": os.path.basename(src),
        "dst": os.path.basename(dst),
        "mode": "encrypt_W_segment_only",
        "ctr_init": ctr0,
        "layout": {"X_words": xw, "b_words": bw, "W_words": ww, "W_offset": woff},
        "test_only_key_hex": key.hex(),
        "test_only_nonce_hex": nonce.hex(),
        "verilog_literals": {
            # 给 RTL TB 直接粘贴用的字面量，避免字节序踩坑（见下方 note）
            "key_256bit": "256'h%s" % key.hex(),
            "nonce_96bit": "96'h%s" % nonce[::-1].hex(),
        },
        "roundtrip_ok": ok,
        "note": "固定测试密钥/随机数，仅供仿真；真实部署必须用 PUF 派生密钥",
        "byte_order_warning": (
            "key 的 byte0 位于 key_in[255:224]（即按人读顺序直接写）；"
            "nonce 的 byte0 位于 blk[7:0]（即字面量要反转）。"
            "两者方向相反，写 TB 常量时极易搞错。"
        ),
    }
    mp = os.path.splitext(dst)[0] + ".crypto.json"
    with open(mp, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print("  sidecar        : %s" % mp)
    print("  Verilog 字面量（直接粘进 TB，避免字节序踩坑）:")
    print("    key   = 256'h%s" % key.hex())
    print("    nonce = 96'h%s   <- 注意已反转" % nonce[::-1].hex())

    print("=" * 68)
    print("结果: %s" % ("=== PASS ===" if (ok and same_xb and diff_w) else "=== FAIL ==="))
    print("=" * 68)
    return 0 if (ok and same_xb and diff_w) else 1


def selftest():
    print("=" * 68)
    print("encrypt_vector_pack.py 自检")
    print("=" * 68)
    rc = run_kat(None)
    print()
    # 段边界推算的单元自检
    hdr = [16, 2, 64, 16, 8, 4, 8, 32 + 64 + 1024, 128]
    xw, bw, ww, woff = segment_boundaries(hdr)
    print("  段边界推算: X=%d b=%d W=%d offset=%d  (期望 X=32 b=64 W=1024 offset=96)"
          % (xw, bw, ww, woff))
    ok = (xw == 32 and bw == 64 and ww == 1024 and woff == 96)
    print("  边界自检: %s" % ("OK" if ok else "BAD"))
    print("=" * 68)
    return 0 if (rc == 0 and ok) else 1


def main():
    ap = argparse.ArgumentParser(description="加密 GEMM 向量包的 W 段（P2 空跑）")
    ap.add_argument("--in", dest="src", help="输入 .mem")
    ap.add_argument("--out", dest="dst", help="输出 .mem")
    ap.add_argument("--key-hex", default=TEST_KEY_HEX)
    ap.add_argument("--nonce-hex", default=TEST_NONCE_HEX)
    ap.add_argument("--ctr-init", default="0")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        sys.exit(selftest())
    if not a.src or not a.dst:
        ap.print_help()
        die("必须给 --in 与 --out")

    key = bytes.fromhex(a.key_hex.strip().replace("0x", ""))
    nonce = bytes.fromhex(a.nonce_hex.strip().replace("0x", ""))
    if len(key) != 32:
        die("key 需 32 字节")
    if len(nonce) != 12:
        die("nonce 需 12 字节")
    sys.exit(process(a.src, a.dst, key, nonce, int(a.ctr_init, 0)))


if __name__ == "__main__":
    main()