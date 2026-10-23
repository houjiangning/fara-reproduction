#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puf_cold_watch.py -- 方案1：真冷启动 enrollment 半自动采样（PC 端监视循环）

分工：
    用户  ：只管物理断电 -> 上电，循环往复，不需要与 PC 有任何交互
    本脚本：自动检测每次新开机 -> 等开机服务跑完 -> 采样追加到冷启动日志
            -> 取回本地 -> 累计达到目标条数后自动退出

与 puf_coldboot_loop.py 的本质区别：
    那个脚本用 `sudo reboot`（warm reboot，掉电不彻底，已证实产生长尾 HD）；
    本脚本绝不重启板卡，断电动作完全由用户物理完成，保证真冷启动分布。

用法（PC 端，cwd = fpga/up_proj_gemm）：
    python tools/puf_cold_watch.py               # 默认 192.168.1.200 / 目标 32 条
"""

import argparse
import os
import subprocess
import sys
import time


def run(cmd, timeout=20):
    """跑一条命令，返回 (rc, stdout+stderr)。不抛异常，由调用者判断。"""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "<timeout>"
    except FileNotFoundError as e:
        print(f"ERROR: 找不到命令 {cmd[0]}: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="真冷启动 enrollment 半自动采样监视")
    ap.add_argument("--host", default="192.168.1.200")
    ap.add_argument("--user", default="ubuntu")
    ap.add_argument("--target", type=int, default=32, help="冷启动日志目标条数")
    ap.add_argument("--board-log", default="/opt/fara/puf/puf_samples_cold.txt")
    ap.add_argument("--out", default="puf_out/puf_samples_cold.txt")
    ap.add_argument("--new-boot-max-uptime", type=float, default=180.0,
                    help="uptime 低于该值视为本次开机的采样窗口未错过（秒）")
    ap.add_argument("--settle", type=int, default=15,
                    help="SSH 可达后额外等待秒数（让开机服务跑完，与前 7 轮一致）")
    ap.add_argument("--poll", type=int, default=10, help="轮询间隔秒数")
    a = ap.parse_args()

    sample_cmd = ("sudo /usr/local/bin/puf_sample --m 31 --append "
                  f"{a.board_log} --quiet && sync")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=no", f"{a.user}@{a.host}"]

    def remote(cmd, timeout=20):
        return run(ssh + [cmd], timeout=timeout)

    def count():
        """板卡冷启动日志里的合法数据行数（32-hex 开头）。
        不用 grep -vc '^#'：GNU grep 对含 NUL 的文件会把空洞按行计，
        断电留下的零填充空洞曾导致计数假突变（18 -> 83）。"""
        rc, out = remote(f"grep -cE '^[0-9a-fA-F]{{32}} ' {a.board_log}"
                         f" 2>/dev/null || echo 0")
        if rc != 0:
            return -1
        for line in out.strip().splitlines():
            s = line.strip()
            if s.isdigit():
                return int(s)
        return -1

    def fetch():
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        rc, _ = run(["scp", "-O", "-o", "BatchMode=yes",
                     "-o", "StrictHostKeyChecking=no",
                     f"{a.user}@{a.host}:{a.board_log}", a.out], timeout=60)
        if rc != 0:  # 板卡 sshd 不支持 sftp 时退回 ssh cat
            rc, txt = remote(f"cat {a.board_log}", timeout=60)
            if rc == 0 and txt.strip():
                with open(a.out, "w", encoding="ascii") as f:
                    f.write(txt)
            else:
                rc = 1
        if rc == 0:
            print(f"    取回 -> {a.out} ({os.path.getsize(a.out)} B)", flush=True)
        else:
            print("    !! 取回失败（板卡文件仍在，下轮成功后重新取回）", flush=True)

    # ---- 起始状态 ----
    n = count()
    if n < 0:
        print("ERROR: 连不上板卡或读不到采样文件，请确认板卡在线后重跑", file=sys.stderr)
        return 2
    print(f"起始采样条数 = {n} / 目标 {a.target}", flush=True)
    if n >= a.target:
        fetch()
        print("已达目标，无需断电循环", flush=True)
        return 0
    print("监视已挂载：请开始物理断电 -> 上电循环（无需任何其他操作）", flush=True)

    prev_online = None          # None=未连过 / False=离线 / True=在线
    last_ok_ts = 0.0            # 最近一次成功采样时刻；40s 内的"恢复"视为 SSH 抖动
    boot_idx = 0
    consec_fails = 0

    while True:
        time.sleep(a.poll)
        rc, out = remote("cat /proc/uptime", timeout=10)
        if rc != 0:
            if prev_online is not False:
                print("板卡离线（等待上电）…", flush=True)
            prev_online = False
            continue
        try:
            uptime = float(out.strip().split()[0])
        except (ValueError, IndexError):
            continue

        was_offline = (prev_online is False)
        first_contact = (prev_online is None)
        if first_contact:
            print(f"板卡在线 uptime={uptime:.0f}s", flush=True)
        prev_online = True

        # 新开机判定：刚从离线恢复（或首次接触）+ uptime 在窗口内
        #            + 距上次成功采样超过 40s（防止 SSH 抖动把同一开机重复采样；
        #              真实断电循环一轮至少 45s，不受影响）
        is_new_boot = (uptime < a.new_boot_max_uptime
                       and (first_contact or was_offline)
                       and (time.time() - last_ok_ts) > 40)
        if not is_new_boot:
            continue

        boot_idx += 1
        before = count()
        print(f"[boot #{boot_idx}] 检测到新开机 uptime={uptime:.0f}s"
              f"（当前 {before} 条），等 {a.settle}s 后采样 …", flush=True)
        time.sleep(a.settle)
        rc, sout = remote(sample_cmd, timeout=60)
        after = count()
        if after < 0:
            after = count()
        ok = (before >= 0 and after == before + 1)
        if not ok:
            print(f"    !! 第一次采样未确认 (rc={rc}) {sout.strip()[:160]}", flush=True)
            time.sleep(10)
            rc, sout = remote(sample_cmd, timeout=60)
            after = count()
            ok = (before >= 0 and after == before + 1)

        if ok:
            last_ok_ts = time.time()
            consec_fails = 0
            print(f"[boot #{boot_idx}] OK   采样 {before} -> {after}   "
                  f"累计 {after}/{a.target}", flush=True)
            fetch()
            if after >= a.target:
                print("---- 目标达成：真冷启动样本齐备 ----", flush=True)
                print("下一步：python tools/cold_hd.py 分析选中位 HD 分布", flush=True)
                return 0
        else:
            consec_fails += 1
            print(f"[boot #{boot_idx}] !!   采样确认失败 {before} -> {after}"
                  f"（连续 {consec_fails} 次）", flush=True)
            if consec_fails >= 3:
                print("连续 3 轮失败，退出待人工检查", flush=True)
                return 1


if __name__ == "__main__":
    sys.exit(main())
