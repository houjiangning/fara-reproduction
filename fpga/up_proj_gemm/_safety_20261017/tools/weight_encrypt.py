#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
weight_encrypt.py —— 权重文件 AES-256-CTR 加解密工具（PC 侧 / 板卡侧通用）

CTR 模式下加密与解密是**同一个运算**，所以本工具不区分方向：
    --in A --out B            加密（A 是明文）
    --in A --out B --decrypt  解密（A 是密文）
两条命令做的事完全一样；--decrypt 只是语义标注 + 打开校验开关。

零依赖即可运行：AES 实现从 gen_aes_vectors.py 导入（**单一可信源**，
        避免抄一份加密逻辑导致 golden 与 RTL 漂移）。该实现已通过
        NIST SP 800-38A F.5.5 官方 KAT。

双后端（自动选择，结果完全一致）：
    · 纯 Python 参考实现（gen_aes_vectors.encrypt_block）
        = RTL 的 golden。但很慢，实测仅 ~0.03 MB/s（9.44 MB 要数分钟）。
    · pycryptodome（若已安装）
        = 快通道，实测 ~230-410 MB/s（9.44 MB 秒级完成）。
        启动时会用前 64 个块与参考实现**强制交叉校验**，不一致直接拒绝运行。
        想强制走参考实现请加 --ref。

与 RTL 的契约（必须一致，详见 aes256_core.sv / aes256_ctr.sv 文件头）：
    · 128-bit 块字节序：块字节 j 位于 blk[8*j +: 8]
      ⇔ blk = int.from_bytes(block_bytes, 'little')
    · 计数器块 = [ nonce(12B) | ctr 大端(4B) ]
    · 文件按 16 字节切块，第 i 块用 counter = ctr_init + i

用法示例：
    # 1) 自检（跑 NIST KAT）
    python tools/weight_encrypt.py --selftest

    # 2) 加密真实权重（随机 nonce，会打印出来，必须记下来）
    python tools/weight_encrypt.py \\
        --in  board_export/board_W_transformer_h_0_mlp_c_fc.bin \\
        --out board_export/board_W_enc.bin \\
        --key-file /opt/fara/puf/enroll_key.bin \\
        --verify

    # 3) 解密回去（验证）
    python tools/weight_encrypt.py --decrypt \\
        --in  board_export/board_W_enc.bin \\
        --out /tmp/W_dec.bin \\
        --key-file /opt/fara/puf/enroll_key.bin \\
        --nonce-hex <上一步打印的 nonce>
"""

import argparse
import hashlib
import os
import sys
import time

# ---- 单一可信源：AES 实现只在 gen_aes_vectors.py 里有一份 ----
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_aes_vectors import (          # noqa: E402
    key_expansion, encrypt_block, counter_block, ctr_crypt, run_kat,
)

BLK = 16


# ============================================================================
# 后端选择：优先 pycryptodome（快），但**必须**与纯 Python 参考实现交叉校验
#
#   为什么不能只用 pycryptodome：
#     纯 Python 的 gen_aes_vectors.encrypt_block 是 RTL 的 golden（已过 NIST KAT），
#     如果为了速度换一套实现又不校验，加密结果可能与 RTL 不一致 —— 那时板卡解
#     出来就是乱码，而且极难排查。所以启动时强制跑一次交叉校验。
# ============================================================================

def _try_fast_backend():
    try:
        from Crypto.Cipher import AES          # pycryptodome
        return AES
    except Exception:
        return None


def _crosscheck(AES, w, key, nonce, ctr0, nblk=64):
    """快速后端 vs 纯 Python 参考实现，前 nblk 个块必须逐字节一致"""
    probe = bytes((i * 37 + 11) & 0xFF for i in range(nblk * BLK))
    ref = ctr_crypt(w, nonce, ctr0, probe)
    c = AES.new(key, AES.MODE_CTR, nonce=nonce, initial_value=ctr0)
    fast = c.encrypt(probe)
    return ref == fast, ref, fast


# ============================================================================
# 工具函数
# ============================================================================

def die(msg, code=1):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(code)


def load_key(args) -> bytes:
    """优先 --key-hex，其次 --key-file（32 字节原始 或 十六进制文本）"""
    if args.key_hex:
        h = args.key_hex.strip().replace(" ", "").replace("0x", "")
        if len(h) != 64:
            die("--key-hex 需要 64 个十六进制字符（256 bit），实得 %d" % len(h))
        return bytes.fromhex(h)

    if args.key_file:
        with open(args.key_file, "rb") as f:
            raw = f.read()
        if len(raw) == 32:
            return raw                       # enrollment 导出的原始 32 字节
        txt = raw.decode("ascii", errors="ignore").strip().replace("\n", "")
        txt = txt.replace(" ", "").replace("0x", "")
        if len(txt) >= 64:
            return bytes.fromhex(txt[:64])
        die("--key-file 内容既不是 32 字节原始密钥，也不是 >=64 字符的十六进制")

    die("必须给 --key-hex 或 --key-file")


def sha256_file(path, limit=None):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        while True:
            c = f.read(1 << 20)
            if not c:
                break
            h.update(c)
            n += len(c)
            if limit and n >= limit:
                break
    return h.hexdigest(), n


def ctr_process_stream(src, dst, w, nonce12, ctr0,
                       chunk_blk=4096, quiet=False, AES=None, key=None):
    """分块处理，counter 随偏移推进。内存占用恒定。

    AES 非 None 时走 pycryptodome 快通道；否则走纯 Python 参考实现。
    两条路径产生完全相同的输出（已由 _crosscheck 保证）。
    """
    total = os.path.getsize(src)
    done = 0
    t0 = time.time()
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        while True:
            data = fi.read(chunk_blk * BLK)
            if not data:
                break
            padded = False
            if len(data) % BLK:
                data += b"\x00" * (BLK - len(data) % BLK)   # 尾部补齐
                padded = True
            bi = done // BLK
            if AES is not None:
                c = AES.new(key, AES.MODE_CTR, nonce=nonce12, initial_value=ctr0 + bi)
                out = c.encrypt(data)
            else:
                out = ctr_crypt(w, nonce12, ctr0 + bi, data)
            fo.write(out)
            done += len(out)
            if padded:
                break
            if not quiet and total > (2 << 20):
                pct = 100.0 * done / max(1, (total + BLK - 1) // BLK * BLK)
                el = time.time() - t0
                sys.stdout.write("\r  进度 %5.1f%%  %7.2f MB/s   " %
                                 (pct, done / 1048576.0 / max(el, 1e-9)))
                sys.stdout.flush()
    if not quiet and total > (2 << 20):
        print()
    return done


# ============================================================================
# 主流程
# ============================================================================

def do_selftest():
    print("=" * 68)
    print("weight_encrypt.py 自检")
    print("=" * 68)
    rc = run_kat(None)
    print()
    print("附加：round-trip（32 字节随机数据，加密后解密应还原）")
    import random
    rnd = random.Random(7)
    k = bytes(rnd.getrandbits(8) for _ in range(32))
    nz = bytes(rnd.getrandbits(8) for _ in range(12))
    data = bytes(rnd.getrandbits(8) for _ in range(32))
    w = key_expansion(k)
    c = ctr_crypt(w, nz, 0, data)
    p = ctr_crypt(w, nz, 0, c)
    ok = (p == data)
    print("  cipher = " + c.hex())
    print("  plain  = " + p.hex())
    print("  round-trip: " + ("OK" if ok else "BAD"))
    print("=" * 68)
    return 0 if (rc == 0 and ok) else 1


def main():
    ap = argparse.ArgumentParser(
        description="AES-256-CTR 权重加解密（零依赖，与 RTL 逐 bit 契约一致）",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", help="输入文件")
    ap.add_argument("--out", dest="dst", help="输出文件")
    ap.add_argument("--decrypt", action="store_true",
                    help="语义标注为解密（运算与加密完全相同）")
    ap.add_argument("--key-hex", help="64 个十六进制字符")
    ap.add_argument("--key-file", help="32 字节原始密钥，或含十六进制的文本文件")
    ap.add_argument("--nonce-hex", help="24 个十六进制字符（96 bit）；解密时必填")
    ap.add_argument("--ctr-init", default="0", help="起始块号（默认 0）")
    ap.add_argument("--verify", action="store_true",
                    help="处理后反向运算一遍并比对 SHA256（慢，建议对真实权重开启）")
    ap.add_argument("--selftest", action="store_true", help="跑 NIST KAT 自检后退出")
    ap.add_argument("--ref", action="store_true",
                    help="强制使用纯 Python 参考实现（慢，仅用于交叉验证）")
    a = ap.parse_args()

    if a.selftest:
        sys.exit(do_selftest())

    if not a.src or not a.dst:
        ap.print_help()
        die("必须给 --in 与 --out")

    key = load_key(a)
    ctr0 = int(a.ctr_init, 0)

    # nonce：加密时可随机生成（必须记录），解密时必须提供
    if a.nonce_hex:
        h = a.nonce_hex.strip().replace(" ", "").replace("0x", "")
        if len(h) != 24:
            die("--nonce-hex 需要 24 个十六进制字符（96 bit），实得 %d" % len(h))
        nonce = bytes.fromhex(h)
        nonce_new = False
    else:
        if a.decrypt:
            die("解密必须提供 --nonce-hex（加密时打印过）")
        nonce = os.urandom(12)
        nonce_new = True

    src_sz = os.path.getsize(a.src)
    print("=" * 68)
    print("AES-256-CTR %s" % ("解密" if a.decrypt else "加密"))
    print("=" * 68)
    print("  输入      : %s  (%d B)" % (a.src, src_sz))
    print("  输出      : %s" % a.dst)
    print("  key       : %s..." % key.hex()[:16])
    print("  nonce     : %s%s" % (nonce.hex(), "   <<< 新生成，务必记录" if nonce_new else ""))
    print("  ctr_init  : %d (0x%08x)" % (ctr0, ctr0))

    if src_sz % BLK:
        print("  !! 注意：输入大小 %d 不是 16 的倍数，尾部会补零" % src_sz)

    w = key_expansion(key)

    # ---- 后端选择 + 强制交叉校验 ----
    AES = None if a.ref else _try_fast_backend()
    if AES is not None:
        ok, ref, fast = _crosscheck(AES, w, key, nonce, ctr0)
        print("  后端      : pycryptodome AES-CTR（已与纯 Python 参考交叉校验）")
        if not ok:
            print("  !! 交叉校验失败：pycryptodome 与参考实现不一致！")
            print("     参考: %s" % ref[:32].hex())
            print("     快速: %s" % fast[:32].hex())
            die("拒绝在未校验通过的实现上继续（回退请加 --ref）", 2)
        print("  交叉校验  : OK（前 64 块逐字节一致）")
    else:
        print("  后端      : 纯 Python 参考实现（未装 pycryptodome 或指定了 --ref）")
        print("  提示      : 9.44 MB 约需数分钟；pip install pycryptodome 可大幅加速")

    t0 = time.time()
    out_sz = ctr_process_stream(a.src, a.dst, w, nonce, ctr0, AES=AES, key=key)
    el = time.time() - t0

    print("  输出大小  : %d B" % out_sz)
    print("  耗时      : %.1f s  (%.2f MB/s)" %
          (el, (out_sz / 1048576.0) / max(el, 1e-9)))

    hs, _ = sha256_file(a.src)
    hd, _ = sha256_file(a.dst)
    print("  sha256(in) : %s" % hs)
    print("  sha256(out): %s" % hd)
    print("  与输入相同？%s  (密文应当与明文不同)" % ("是（异常！）" if hs == hd else "否"))

    rc = 0
    if a.verify:
        print("-" * 68)
        print("反向验证：把输出再解/加密一遍，应与输入逐字节相同")
        tmp = a.dst + ".verify.tmp"
        ctr_process_stream(a.dst, tmp, w, nonce, ctr0, AES=AES, key=key)
        hv, _ = sha256_file(tmp)
        ok = (hv == hs)
        print("  sha256(反向) = %s" % hv)
        print("  往返一致     : %s" % ("OK" if ok else "BAD"))
        try:
            os.remove(tmp)
        except OSError:
            pass
        if not ok:
            rc = 1

    print("=" * 68)
    if nonce_new:
        print()
        print("  ★ 请把下面这行记进 board_crypto.json，解密/上板都要用：")
        print('    { "alg": "AES-256-CTR", "nonce": "%s", "ctr_init": %d }'
              % (nonce.hex(), ctr0))
        print()
    print("结果: %s" % ("=== PASS ===" if rc == 0 else "=== FAIL ==="))
    print("=" * 68)
    sys.exit(rc)


if __name__ == "__main__":
    main()