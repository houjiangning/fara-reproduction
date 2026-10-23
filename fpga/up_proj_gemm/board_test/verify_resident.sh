#!/bin/sh
# 独立回读校验：从常驻进程的 /proc/<pid>/mem 按虚拟地址读回 dma_heap 缓冲，
# 与 /opt/fara/models 源文件逐段比 sha256。
# （/dev/mem 被 CONFIG_STRICT_DEVMEM 拦，改走 /proc/<pid>/mem。）
set -e
cd /tmp
cp -f /usr/local/bin/fara-resident.c /tmp/
cc -O2 -o mem_sha mem_sha.c

PID=$(grep -o '"pid": [0-9]*' /run/fara-resident.json | grep -o '[0-9]*')
PA=$(grep -o '"phys_addr": [0-9]*' /run/fara-resident.json | grep -o '[0-9]*')
echo "resident pid = $PID   phys = $PA"

# 在 maps 里找 10MB(10485760) 的映射起点，即缓冲虚拟地址
VADDR=$(sudo cat /proc/$PID/maps | python3 -c '
import sys
for line in sys.stdin:
    p = line.split()
    if len(p) < 2: continue
    a, b = p[0].split("-")
    if int(b, 16) - int(a, 16) == 10485760:
        print(a); break
')
[ -n "$VADDR" ] || { echo "找不到 10MB 映射"; exit 1; }
echo "buffer vaddr = 0x$VADDR"
sudo cat /proc/$PID/maps | grep -iE "dmabuf|$VADDR"

chk() {
  label="$1"; off="$2"; len="$3"; src="$4"
  v=$((0x$VADDR + off))
  printf '%-4s buf  ' "$label"; sudo ./mem_sha /proc/$PID/mem $v "$len"
  printf '%-4s src  ' "$label"; sha256sum "$src" | cut -d' ' -f1
}

echo "=== W   @ vaddr+0        (9437184 B) ==="
chk W   0       9437184 /opt/fara/models/board_W_transformer_h_0_mlp_c_fc.bin
echo "=== b   @ vaddr+9437184  (12288 B)   ==="
chk b   9437184 12288   /opt/fara/models/board_b_transformer_h_0_mlp_c_fc.bin
echo "=== cfg @ vaddr+9449472  (1808 B)    ==="
chk cfg 9449472 1808    /opt/fara/models/board_cfg_transformer_h_0_mlp_c_fc.json
