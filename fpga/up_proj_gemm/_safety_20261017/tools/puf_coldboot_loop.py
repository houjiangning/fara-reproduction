#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puf_coldboot_loop.py -- 从 PC 自动驱动 N 次冷启动采样，最后把采样文件取回

为什么需要它：
    P1 要的是**跨冷启动**的逐位翻转率，需要同一块板子重复上电几十次。
    手工做必然出错（漏一次、重一次、把 t_settle 不同的批次混进同一个文件）。
    这个脚本把"重启 -> 等板子起来 -> 确认采样数+1"变成一个循环。

前置（在板卡上一次性完成）：
    1) 新比特流已烧录，fpga_manager state = operating
    2) 已安装并启用 fara-puf-sample.service（每开机自动采样一次并追加）
       -> 见 board_test/install_puf_sample_service.sh

强烈建议用 SSH 公钥（否则每次重启后都要手输密码，自动化就废了）：
    ssh-keygen -t ed25519            # 若还没有密钥
    ssh-copy-id root@192.168.1.200

用法：
    python tools/puf_coldboot_loop.py --host 192.168.1.200 --user root --n 32
    python tools/puf_coldboot_loop.py --host 192.168.1.200 --user root --n 8 --no-reboot
        # --no-reboot：只把板卡已有的采样取回并计数，不重启（用于中途查看进度）

输出：
    --out 指定的本地文件（默认 puf_samples.txt，在 puf_out/ 下）
"""

import argparse
import os
import shutil
import subprocess
import sys
import time


def run(cmd, timeout=30, check=False):
    """跑一条命令，返回 (rc, stdout+stderr)。不抛异常，由调用者判断。"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "<timeout>"
    except FileNotFoundError as e:
        print(f"ERROR: 找不到命令 {cmd[0]}：{e}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        if check:
            raise
        return 1, "<failed>"


def ssh_base(a):
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no"] + a.ssh_opt + [f"{a.user}@{a.host}"]


def remote(a, cmd, timeout=30):
    return run(ssh_base(a) + [cmd], timeout=timeout)


def count_samples(a):
    """返回板卡日志里的采样条数（不含 # 注释行）；读不到返回 -1"""
    rc, out = remote(a, f"grep -vc '^#' {a.log} 2>/dev/null || echo 0")
    if rc != 0:
        return -1
    for line in out.strip().splitlines():
        line = line.strip()
        if line.isdigit():
            return int(line)
    return -1


def wait_for_ssh(a, timeout):
    """等板卡重新能 SSH 进来，返回耗时秒数；超时返回 None"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        rc, _ = remote(a, "echo up", timeout=10)
        if rc == 0:
            return time.time() - t0
        time.sleep(3)
    return None


def main():
    ap = argparse.ArgumentParser(description="PUF 冷启动采样自动循环")
    ap.add_argument("--host", required=True, help="板卡 IP")
    ap.add_argument("--user", default="root", help="SSH 用户（默认 root）")
    ap.add_argument("--n", type=int, default=32, help="冷启动次数（默认 32）")
    ap.add_argument("--log", default="/opt/fara/puf/puf_samples.txt",
                    help="板卡上的采样文件路径")
    ap.add_argument("--out", default="puf_out/puf_samples.txt",
                    help="取回后的本地路径")
    ap.add_argument("--ssh-opt", action="append", default=[],
                    help="额外的 ssh 选项，可重复，例如 -i ~/.ssh/id_ed25519")
    ap.add_argument("--wait-timeout", type=int, default=180,
                    help="每次重启后等待 SSH 回来的超时秒数（默认 180）")
    ap.add_argument("--settle", type=int, default=15,
                    help="SSH 回来后额外等待秒数，让开机服务跑完（默认 15）")
    ap.add_argument("--no-reboot", action="store_true",
                    help="不重启，只取回已有采样并计数")
    a = ap.parse_args()

    # --- 先确认能连上 ---
    rc, out = remote(a, "echo ok", timeout=15)
    if rc != 0:
        print(f"ERROR: SSH 连不上 {a.user}@{a.host}", file=sys.stderr)
        print(out.strip()[:400], file=sys.stderr)
        print("\n提示：若每次都要输密码，自动化会卡住。建议先配公钥：", file=sys.stderr)
        print("  ssh-copy-id %s@%s" % (a.user, a.host), file=sys.stderr)
        sys.exit(2)

    rc, st = remote(a, "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown")
    print(f"板卡 fpga_manager state = {st.strip()}")

    n0 = count_samples(a)
    print(f"起始采样条数 = {n0}")

    if a.no_reboot:
        fetch(a)
        print(f"当前采样条数 = {count_samples(a)}")
        return 0

    print()
    print(f"---- 开始 {a.n} 次冷启动循环 ----")
    fails = 0
    for i in range(1, a.n + 1):
        before = count_samples(a)
        t0 = time.time()

        # 重启：连接必然断开，忽略返回码
        run(ssh_base(a) + ["sync; sudo reboot"], timeout=15)
        time.sleep(2)

        up = wait_for_ssh(a, a.wait_timeout)
        if up is None:
            print(f"[{i:2d}/{a.n}] !! 重启后 {a.wait_timeout}s 内 SSH 未恢复 —— 中止")
            fails += 1
            break

        time.sleep(a.settle)   # 让 fara-bitstream / fara-puf-sample 服务跑完
        after = count_samples(a)

        if before >= 0 and after == before + 1:
            print(f"[{i:2d}/{a.n}] OK   采样 {before} -> {after}   "
                  f"(SSH 恢复 {up:.0f}s, 总 {time.time()-t0:.0f}s)")
        elif before < 0 or after < 0:
            print(f"[{i:2d}/{a.n}] ?    读不到计数（before={before} after={after}）"
                  f" —— 检查日志路径 {a.log}")
            fails += 1
        else:
            print(f"[{i:2d}/{a.n}] !!   采样数 {before} -> {after}（期望 +1）"
                  f" —— 服务可能没跑起来：systemctl status fara-puf-sample.service")
            fails += 1

    print()
    print("---- 循环结束 ----")
    print(f"失败次数 = {fails}")
    fetch(a)
    total = count_samples(a)
    print(f"板卡上累计采样 = {total}")

    if total >= 0 and total < 32:
        print()
        print(f"提示：样本数 {total} < 32，翻转率置信度偏低。建议再跑 "
              f"{32 - total} 次：")
        print(f"  python tools/puf_coldboot_loop.py --host {a.host} --user {a.user} "
              f"--n {32 - total}")
    print()
    print("下一步（PC 侧统计）：")
    print(f"  python tools/puf_stability.py --in {a.out} --out-dir puf_out --threshold 0.01")
    return 0 if fails == 0 else 1


def fetch(a):
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    rc, out = run(["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
                  + a.ssh_opt + [f"{a.user}@{a.host}:{a.log}", a.out], timeout=60)
    if rc == 0:
        print(f"已取回采样文件 -> {a.out}  ({os.path.getsize(a.out)} B)")
    else:
        # 退回用 ssh cat（有些板子没装 scp 的 sftp 服务端）
        rc2, txt = remote(a, f"cat {a.log}", timeout=60)
        if rc2 == 0 and txt.strip():
            with open(a.out, "w", encoding="ascii") as f:
                f.write(txt)
            print(f"scp 不可用，改用 ssh cat 取回 -> {a.out} ({os.path.getsize(a.out)} B)")
        else:
            print(f"!! 取回失败：{out.strip()[:200]}")


if __name__ == "__main__":
    sys.exit(main())