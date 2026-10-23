"""board_ctrl.py -- FARC 控制通道客户端（STATUS / FLIP / WIPE / RESTORE）

8-x 实时集成的 PC 端调用器，attack_dashboard 的 /api/board 直接复用本模块：

  STATUS   查询板卡安全启动链现场（HD/解密耗时/Canary）+ W/密文双 hash
  FLIP     下发位翻转指令（攻击者物理位注入的执行端；决策搜索仍在 PC）
  WIPE     清零板上常驻明文 W
  RESTORE  板上从 SD 密文重新解密（PUF->FE/KDF->AES->Canary，约 100ms）

用法：
  python board_ctrl.py status
  python board_ctrl.py flip <word_idx> <bit>
  python board_ctrl.py wipe
  python board_ctrl.py restore
  python board_ctrl.py smoke        # 一键冒烟：status->wipe->flip->status->restore->status
"""
import socket
import struct
import sys

HOST = "192.168.1.200"
PORT = 9000
FARC_STATUS, FARC_FLIP, FARC_RESTORE, FARC_WIPE = 1, 2, 3, 4
W_WORDS = 3072 * 768          # W[3072,768] fp32
STATUS_WORDS = 24


def recv_all(s, n):
    buf = b""
    while len(buf) < n:
        r = s.recv(n - len(buf))
        if not r:
            raise ConnectionError("板卡连接中断")
        buf += r
    return buf


def connect(host=HOST, port=PORT, timeout=15.0):
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def ctrl(s, op, p0=0, p1=0, p2=0):
    """发一条 FARC 控制报文，返回 (status, words tuple)。"""
    s.sendall(struct.pack("<4s4I", b"FARC", op, p0, p1, p2))
    magic, status, n = struct.unpack("<4s2I", recv_all(s, 12))
    if magic != b"FARC":
        raise RuntimeError(f"坏控制响应 magic={magic!r}")
    words = struct.unpack(f"<{n}I", recv_all(s, 4 * n)) if n else ()
    return status, words


def _hash_hex(words):
    return "".join(f"{x:08x}" for x in words)


def parse_status(words):
    """24 字 STATUS 载荷 -> dict（hash 转 hex 字符串）。"""
    if len(words) < STATUS_WORDS:
        raise RuntimeError(f"STATUS 载荷不足: {len(words)}/24")
    return {
        "boot_ok":    words[0],
        "hd":         words[1],
        "k_used":     words[2],
        "dec_ms":     words[3] / 100.0,
        "n_flips":    words[4],
        "wiped":      words[5],
        "boot_count": words[6],
        "attempts":   words[7],
        "w_hash":     _hash_hex(words[8:16]),
        "enc_hash":   _hash_hex(words[16:24]),
    }


def get_status(s):
    st, w = ctrl(s, FARC_STATUS)
    if st != 0:
        raise RuntimeError(f"STATUS status={st}")
    return parse_status(w)


def flip(s, idx, bit):
    if not (0 <= idx < W_WORDS and 0 <= bit < 32):
        raise ValueError(f"flip 参数越界 idx={idx} bit={bit}")
    st, w = ctrl(s, FARC_FLIP, idx, bit)
    if st != 0:
        raise RuntimeError(f"FLIP status={st}")
    return {"idx": w[0], "old": w[1], "new": w[2]}


def wipe(s):
    st, _ = ctrl(s, FARC_WIPE)
    if st != 0:
        raise RuntimeError(f"WIPE status={st}")
    return True


def restore(s):
    """重解密。status=0 成功；2=安全链拒绝（HD 超限/canary 失败）。"""
    st, w = ctrl(s, FARC_RESTORE)
    return st, parse_status(w)


def _fmt_status(tag, d):
    print(f"[{tag}] boot_ok={d['boot_ok']} HD={d['hd']} k_used={d['k_used']} "
          f"dec={d['dec_ms']:.1f}ms flips={d['n_flips']} wiped={d['wiped']} "
          f"boots={d['boot_count']}/{d['attempts']}")
    print(f"[{tag}] W_hash  = {d['w_hash'][:16]}…")
    print(f"[{tag}] enc_hash= {d['enc_hash'][:16]}…")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    s = connect()
    try:
        if cmd == "status":
            _fmt_status("status", get_status(s))
        elif cmd == "flip":
            r = flip(s, int(argv[2]), int(argv[3]))
            print(f"[flip] W[{r['idx']}] {r['old']:#010x} -> {r['new']:#010x}")
        elif cmd == "wipe":
            wipe(s)
            print("[wipe] 常驻明文 W 已清零")
        elif cmd == "restore":
            st, d = restore(s)
            _fmt_status("restore", d)
            print(f"[restore] {'OK 权重已重解密+Canary 通过' if st == 0 else 'REFUSED 安全链拒绝'}")
        elif cmd == "smoke":
            d0 = get_status(s)
            _fmt_status("0初始", d0)
            assert d0["boot_ok"] == 1, "服务未处于 boot_ok 状态"
            wipe(s)
            d1 = get_status(s)
            _fmt_status("1擦除", d1)
            assert d1["wiped"] == 1 and d1["w_hash"] == "0" * 64, "擦除未生效"
            r = flip(s, 12345, 31)
            print(f"[smoke] flip（擦除态应报参数拒绝或作用在 0 上）: {r}")
            st, d2 = restore(s)
            _fmt_status("2恢复", d2)
            assert st == 0 and d2["boot_ok"] == 1 and d2["wiped"] == 0, "恢复失败"
            assert d2["w_hash"] == d0["w_hash"], \
                f"恢复后 W hash 不一致:\n  {d2['w_hash']}\n  {d0['w_hash']}"
            print("[smoke] PASS：擦除->恢复 闭环成立，W hash 与初始一致")
        else:
            print(__doc__)
            return 2
        return 0
    finally:
        s.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
