#!/bin/sh
#=============================================================================
# run_infer_server.sh —— 在板卡上后台常驻启动 fara_infer_server（硬件 FaR 推理服务）
#
# 用法（板卡上）：sudo bash run_infer_server.sh [SRC] [PORT]
#   默认 SRC=/opt/fara/models  PORT=9000
#
# 前提：PL 已加载 FaR 版 bitstream（VERSION 应读回 0x00020000）。
#       若未加载：echo 0 | sudo tee /sys/class/fpga_manager/fpga0/flags
#                 echo up_proj_wrapper.bit.bin | sudo tee /sys/class/fpga_manager/fpga0/firmware
#
# 说明：编译产物与日志都放 /dev/shm（tmpfs），全程零 SD 卡写入。
#=============================================================================
set -eu

SRC="${1:-/opt/fara/models}"
PORT="${2:-9000}"
BIN=/dev/shm/fara_infer_server
LOG=/dev/shm/fara_srv.log

if [ ! -x "$BIN" ]; then
  echo "缺少 $BIN，先编译：gcc -O2 -o $BIN fara_infer_server.c" >&2
  exit 1
fi

pkill -f 'fara_infer_server --src' 2>/dev/null || true
sleep 1

setsid "$BIN" --src="$SRC" --port="$PORT" >"$LOG" 2>&1 </dev/null &
sleep 4

echo "--- proc ---"
pgrep -af fara_infer_server || echo NO_PROC
echo "--- listen ---"
(ss -ltn 2>/dev/null || netstat -ltn) | grep ":$PORT" || echo NO_LISTEN
echo "--- log ---"
cat "$LOG"
