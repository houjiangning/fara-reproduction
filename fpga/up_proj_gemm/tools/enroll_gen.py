#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
enroll_gen.py -- provisioning（Enrollment）PC 侧生成工具

从冻结比特流上采集的跨冷启动 PUF 采样，生成三件套：
    1. enroll_key.bin          -- 256-bit AES 密钥（32B 原始，仅 provisioning 期间存在）
    2. fara_enroll_config.json -- 公开 helper（mask/helper/k/salt/purpose），存 SD 卡
    3. enroll_report.json      -- 统计与校验记录（归档用）

算法契约（与 RTL 逐位一致，勿改）：
    · 选位序    : b = 0..127，mask 位 b=1 依序取出（gen_fe_vectors.sel_positions）
    · helper    : w_clean XOR repeat3(c)，选中序 i 为低位（gen_fe_vectors.enroll）
    · 重建      : x[i]=w'[i]^helper[i]，每 3 位取多数 -> seed（gen_fe_vectors.reconstruct）
    · KDF       : SHA-256( seed(16B BE) || salt(16B BE) || purpose(16B) )
                  purpose = b"fara-weight-aes\\x00"（gen_kdf_vectors.PURPOSE）
    · AES-CTR   : weight_encrypt.py --key-file enroll_key.bin

安全性质：
    · 本工具在全部历史样本上做重建校验：任一样本重建出 c' != c 即 FAIL，
      不产出密钥 —— 这保证“同一密钥在所有已见上电条件下可恢复”。
    · enroll_key.bin 在加密完成（weight_encrypt 跑完）后必须立刻销毁。

用法：
    python tools/enroll_gen.py --in puf_out/puf_samples_71e.txt --out-dir puf_out/provision
    python tools/enroll_gen.py --selftest          # 不依赖板卡数据的合成自测
"""

import argparse
import hashlib
import json
import os
import secrets
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_fe_vectors import enroll, reconstruct, sel_positions   # noqa: E402
from puf_stability import parse_samples                         # noqa: E402

NBITS = 128
PURPOSE = b"fara-weight-aes\x00"          # 与 gen_kdf_vectors.PURPOSE 一致
K_DEFAULT = 22                             # 与 puf_dec_axi_lite 复位默认一致


def derive_key(seed, salt, purpose=PURPOSE):
    """KDF：SHA-256( seed(16B BE) || salt(16B BE) || purpose(16B) ) -> 32B"""
    msg = seed.to_bytes(16, "big") + salt.to_bytes(16, "big") + purpose
    return hashlib.sha256(msg).digest()


def pick_mask(resp, max_flips):
    """零翻转（或 <=max_flips）稳定位掩码 + 逐位多数参考值。返回 (mask, maj_bits)"""
    n = len(resp)
    maj = 0
    for b in range(NBITS):
        ones = sum((r >> b) & 1 for r in resp)
        if ones * 2 > n:
            maj |= (1 << b)
    flips = [sum(((r >> b) & 1) != ((maj >> b) & 1) for r in resp) for b in range(NBITS)]
    mask = 0
    for b in range(NBITS):
        if flips[b] <= max_flips:
            mask |= (1 << b)
    return mask, flips


def w_clean_of(resp, mask, k):
    pos = sel_positions(mask)[: 3 * k]
    return [(resp >> b) & 1 for b in pos]


def run_enroll(resp, k, max_flips, rng):
    """核心 enrollment。返回 (mask, helper, c, stats) 或抛 ValueError"""
    mask, flips = pick_mask(resp, max_flips)
    n_stable = bin(mask).count("1")
    need = 3 * k
    if n_stable < need:
        raise ValueError("稳定位 %d < 3k=%d（k=%d）——减少 k 或放宽 max_flips"
                         % (n_stable, need, k))
    w_clean = w_clean_of(resp[0], mask, k)
    c = rng.getrandbits(k)
    helper = enroll(mask, w_clean, c, k)

    # ---- 全样本重建校验：每个历史采样都必须恢复出同一个 c ----
    fails = []
    hd_hist = {}
    for i, r in enumerate(resp):
        c2 = reconstruct(mask, r, helper, k)
        if c2 != c:
            # 统计该样本在选中位上与参考响应的 HD（诊断用）
            w_i = w_clean_of(r, mask, k)
            hd = sum(a != b for a, b in zip(w_clean, w_i))
            fails.append({"sample": i, "hd_on_sel": hd})
        else:
            hd = sum(a != b for a, b in zip(w_clean, w_clean_of(r, mask, k)))
            hd_hist[hd] = hd_hist.get(hd, 0) + 1
    if fails:
        raise ValueError("重建校验失败（%d/%d 样本）：将产生不可恢复密钥，拒绝出 key\n%s"
                         % (len(fails), len(resp), fails[:5]))
    stats = {"n_samples": len(resp), "n_stable": n_stable, "k": k,
             "max_flips": max_flips, "flip_hist_on_sel": hd_hist}
    return mask, helper, c, stats


def selftest():
    """合成数据自测：enroll -> 全样本重建 -> KDF 与 gen_kdf_vectors 口径一致"""
    rng = secrets.SystemRandom()
    ref = rng.getrandbits(NBITS)
    noisy = [ref] + [ref ^ (1 << rng.randrange(NBITS)) if rng.random() < 0.3 else ref
                     for _ in range(31)]
    mask, helper, c, st = run_enroll(noisy, k=22, max_flips=1, rng=rng)
    assert reconstruct(mask, noisy[5], helper, 22) == c
    key = derive_key(c, rng.getrandbits(128))
    assert len(key) == 32
    # KDF 锚点：全零输入的 digest 必须等于 hashlib 直算
    z = derive_key(0, 0, b"\x00" * 16)
    assert z == hashlib.sha256(b"\x00" * 48).digest()
    print("SELFTEST PASS  k=%d n_stable=%d key_head=%s"
          % (st["k"], st["n_stable"], key[:8].hex().upper()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", default="puf_out/puf_samples_71e.txt")
    ap.add_argument("--out-dir", default="puf_out/provision")
    ap.add_argument("--k", type=int, default=K_DEFAULT)
    ap.add_argument("--max-flips", type=int, default=0,
                    help="稳定位判据：批内翻转次数 <= max_flips（默认 0=零翻转位）")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return 0

    meta, resp, unan = parse_samples(a.inp)
    if len(resp) < 8:
        print("ERROR: 样本数 %d < 8，翻转统计置信度不足" % len(resp), file=sys.stderr)
        return 2

    rng = secrets.SystemRandom()
    try:
        mask, helper, c, st = run_enroll(resp, k=a.k, max_flips=a.max_flips, rng=rng)
    except ValueError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 3

    salt = rng.getrandbits(128)
    key = derive_key(c, salt)

    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "enroll_key.bin"), "wb") as f:
        f.write(key)
    cfg = {
        "version": 1,
        "nbits": NBITS,
        "mask": "%032x" % mask,
        "helper": "%032x" % helper,
        "k": st["k"],
        "salt": "%032x" % salt,
        "purpose": PURPOSE.hex(),
        "meta_sample_header": meta,
    }
    with open(os.path.join(a.out_dir, "fara_enroll_config.json"), "w",
              encoding="ascii", newline="\n") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    report = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "input": a.inp,
        "stats": st,
        "key_sha256": hashlib.sha256(key).hexdigest().upper(),
        "config_sha256": hashlib.sha256(
            json.dumps(cfg, sort_keys=True).encode()).hexdigest().upper(),
        "rebuild_check": "PASS (%d/%d samples)" % (st["n_samples"], st["n_samples"]),
    }
    with open(os.path.join(a.out_dir, "enroll_report.json"), "w",
              encoding="ascii", newline="\n") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    print("=" * 68)
    print("Enrollment 生成完成")
    print("=" * 68)
    print("  样本      : %d 次冷启动" % st["n_samples"])
    print("  稳定位    : %d / %d（max_flips<=%d）" % (st["n_stable"], NBITS, a.max_flips))
    print("  k（组数） : %d（密钥材料 %d bit，3k=%d 选中位）"
          % (st["k"], st["k"], 3 * st["k"]))
    print("  重建校验  : PASS %d/%d" % (st["n_samples"], st["n_samples"]))
    print("  key SHA256: %s" % report["key_sha256"])
    print("  产物      : %s/{enroll_key.bin, fara_enroll_config.json, enroll_report.json}"
          % a.out_dir)
    print("-" * 68)
    print("  下一步: python tools/weight_encrypt.py --in <明文W> --out <密文W> \\")
    print("          --key-file %s/enroll_key.bin --verify   （记下打印的 nonce！）" % a.out_dir)
    print("  加密完成后立刻: shred/删除 enroll_key.bin 与明文权重")
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main())
