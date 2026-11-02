#!/bin/sh
#=============================================================================
# verify_online_decrypt.sh —— P0 验收：常驻缓冲里必须是密文，且与磁盘密文一致
#
# 判据（两条都要成立）：
#   1) DDR 中 W 区 sha256 == /opt/fara/models/*.enc 的 sha256
#      -> 说明常驻的就是磁盘那份密文，没有任何预解密副本
#   2) DDR 中 b 区 sha256 == b 文件 sha256
#      -> b 仍按设计明文直通
#
# 用法（板卡上，root）：
#   sh verify_online_decrypt.sh
#
# 依赖：mem_sha.c 与本脚本同目录（复用 fara-resident.c 的 sha256）
#=============================================================================
set -eu

ENC_DIR="${ENC_DIR:-/opt/fara/models}"
W_ENC="$ENC_DIR/board_W_transformer_h_0_mlp_c_fc.enc"
B_BIN="$ENC_DIR/board_b_transformer_h_0_mlp_c_fc.bin"

# 缓冲布局（与 fara_infer_server.c 一致）
X_BYTES=98304            # 32 token x 768 x 4
B_OFF=$X_BYTES
W_OFF=$((X_BYTES + 12288))
W_BYTES=9437184
BUF_BYTES=10485760       # IN_BYTES+OUT_BYTES 向上取整到 2MB

[ -f "$W_ENC" ] || { echo "缺少 $W_ENC"; exit 2; }
[ -f "$B_BIN" ] || { echo "缺少 $B_BIN"; exit 2; }

PID=$(pidof fara_infer_server 2>/dev/null | awk '{print $1}')
[ -n "$PID" ] || PID=$(pgrep -f 'fara_infer_server' 2>/dev/null | head -1)
[ -n "$PID" ] || { echo "fara_infer_server 未运行"; exit 2; }
echo "pid = $PID"

cd "$(dirname "$0")"
[ -x ./mem_sha ] || cc -O2 -o mem_sha mem_sha.c
[ -x ./mem_sha ] || { echo "mem_sha 编译失败"; exit 2; }

# 找 10485760B（IN+OUT 向上取整到 2MB）的映射起点
VADDR=$(sudo cat /proc/$PID/maps | python3 -c '
import sys
sz = 10485760
for line in sys.stdin:
    p = line.split()
    if len(p) < 2: continue
    a, b = p[0].split("-")
    if int(b, 16) - int(a, 16) == sz:
        print(a); break
')
[ -n "$VADDR" ] || { echo "找不到 ${BUF_BYTES}B 映射"; exit 2; }
echo "buffer vaddr = 0x$VADDR"

FW=$(sha256sum "$W_ENC" | cut -d' ' -f1)
DW=$(sudo ./mem_sha /proc/$PID/mem $((0x$VADDR + W_OFF)) $W_BYTES)
FB=$(sha256sum "$B_BIN" | cut -d' ' -f1)
DB=$(sudo ./mem_sha /proc/$PID/mem $((0x$VADDR + B_OFF)) 12288)

echo "=== W ==="
echo "  file $FW"
echo "  ddr  $DW"
echo "=== b ==="
echo "  file $FB"
echo "  ddr  $DB"

if [ "$FW" = "$DW" ] && [ "$FB" = "$DB" ]; then
  echo "PASS：常驻区 == 磁盘密文（无预解密副本）"
else
  echo "FAIL：常驻区与磁盘不一致 —— 若 W 区不同，说明仍存在解密后回写"
  exit 1
fi
