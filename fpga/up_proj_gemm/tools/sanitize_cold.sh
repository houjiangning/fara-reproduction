#!/bin/sh
# sanitize_cold.sh -- 清洗冷启动采样文件中的 NUL 空洞
# 背景：采样后未落盘即断电，ext4 回放会在文件尾留下零填充空洞，
#       GNU grep 对含 NUL 文件的行计数会把空洞当行（曾致 18->83 假突变）。
# 动作：删除所有 NUL 字节（样本行本身是纯 ASCII hex，不受影响），强制落盘。
set -e
F=/opt/fara/puf/puf_samples_cold.txt
tr -d '\000' < "$F" > "$F.clean"
mv "$F.clean" "$F"
sync
wc -l "$F"
grep -cE '^[0-9a-fA-F]{32} ' "$F"
