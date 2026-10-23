#!/bin/sh
#=============================================================================
# install_bitstream_service.sh —— 在板卡上安装/启用 fara-bitstream.service，
#                                 并实测比特流加载通路（--force 强制重配）。
#
# 用法（板卡上）：sudo bash install_bitstream_service.sh
# 前提：/dev/shm 下已有 fara-load-bitstream.sh 与 fara-bitstream.service
#=============================================================================

BIN_SRC=/dev/shm/fara-load-bitstream.sh
UNIT_SRC=/dev/shm/fara-bitstream.service

if [ ! -f "$BIN_SRC" ] || [ ! -f "$UNIT_SRC" ]; then
  echo "缺少 $BIN_SRC 或 $UNIT_SRC" >&2
  exit 1
fi

install -m0755 "$BIN_SRC" /usr/local/bin/fara-load-bitstream.sh
install -m0644 "$UNIT_SRC" /etc/systemd/system/fara-bitstream.service
systemctl daemon-reload
systemctl enable fara-bitstream.service

echo "=== start unit（PL 已 operating，应幂等跳过）==="
systemctl start fara-bitstream.service
systemctl status fara-bitstream.service --no-pager 2>&1 | head -12

echo "=== force reload test（实测加载通路）==="
/usr/local/bin/fara-load-bitstream.sh --force

echo "=== verify ==="
printf 'state      = '; cat /sys/class/fpga_manager/fpga0/state
printf 'VERSION    = '; busybox devmem 0xA0010018 32
printf 'is-enabled = '; systemctl is-enabled fara-bitstream.service
