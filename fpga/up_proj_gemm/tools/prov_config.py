#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prov_config.py -- 把 fara_enroll_config.json + 加密 nonce 转成板卡端
fara_dec_roundtrip.c 可读的 fara_dec_config.txt（key=value, ASCII）

用法：
    python tools/prov_config.py \
        --enroll puf_out/provision/fara_enroll_config.json \
        --nonce <weight_encrypt.py 打印的 24-hex nonce> \
        --out puf_out/provision/fara_dec_config.txt
"""

import argparse
import json
import sys

K_WORDS = 768      # N=1
B_WORDS = 3072


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--enroll", required=True)
    ap.add_argument("--nonce", required=True, help="24-hex（12 字节，文件序）")
    ap.add_argument("--out", default="fara_dec_config.txt")
    ap.add_argument("--route-mode", type=int, default=1, help="1=供板 0=运行期")
    a = ap.parse_args()

    nonce = a.nonce.strip().lower().replace(" ", "")
    if len(nonce) != 24:
        print("ERROR: nonce 需要 24 个 hex 字符", file=sys.stderr)
        return 2

    with open(a.enroll, "r", encoding="ascii") as f:
        e = json.load(f)

    lines = [
        "MASK=%s"        % e["mask"],
        "HELPER=%s"      % e["helper"],
        "K=%d"           % int(e["k"]),
        "SALT=%s"        % e["salt"],
        "PURPOSE=%s"     % e["purpose"],
        "NONCE=%s"       % nonce,
        "CTR_INIT=0",
        "PLAIN_WORDS=%d" % (K_WORDS + B_WORDS),
        "ROUTE_MODE=%d"  % a.route_mode,
    ]
    with open(a.out, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("config -> %s（k=%s nonce=%s...）" % (a.out, e["k"], nonce[:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
