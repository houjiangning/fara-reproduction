#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
farq_check.py —— P0 回归：连续多次推理必须逐位一致

为什么需要这个检查：
    CTR 的块计数器在一次传输结束（tlast）时只回零，不会自动回到 ctr_init。
    如果 run_once 漏掉 ctr_load，第一次推理正确、第二次开始 keystream 错位，
    表现为"结果确定但错误"或全 NaN。这个脚本专门抓这一类问题。

用法（PC 侧，服务起来之后）：
    python farq_check.py <board_ip> [port] [次数]

判据：
    所有次返回的 Y 的 sha256 完全相同 -> PASS
"""
import hashlib
import socket
import struct
import sys

M_TOTAL = 3072
K = 768
RSP_HDR = 32


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise RuntimeError("对端提前关闭")
        buf += c
    return buf


def once(host, port, xbytes):
    s = socket.create_connection((host, port), timeout=30)
    try:
        hdr = struct.pack("<4sIIII", b"FARQ", 0, 0, 1, 0)   # mode=0, n_far=0, n_tok=1
        s.sendall(hdr + xbytes)
        r = recv_exact(s, RSP_HDR)
        magic, status, n_tok, m_total, far_hits, far_phase, ms, rsv = struct.unpack(
            "<4sIIIIIII", r)
        if magic != b"FARS":
            raise RuntimeError("bad response magic %r" % magic)
        if status != 0:
            raise RuntimeError("status=%d" % status)
        y = recv_exact(s, n_tok * m_total * 4)
        return hashlib.sha256(y).hexdigest(), ms
    finally:
        s.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    # 固定的确定性输入（同一份 X 反复送）
    xbytes = struct.pack("<%df" % K, *[((i * 37) % 17) / 17.0 for i in range(K)])

    digests = []
    for i in range(n):
        h, ms = once(host, port, xbytes)
        digests.append(h)
        print("  第 %d 次: %s  (%d ms)" % (i + 1, h, ms))

    if len(set(digests)) == 1:
        print("PASS：%d 次推理逐位一致（CTR 重装正确）" % n)
        return 0
    print("FAIL：多次结果不一致 —— 优先检查 run_once 里的 ctr_load 与 plain_words")
    return 1


if __name__ == "__main__":
    sys.exit(main())
