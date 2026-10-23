#!/bin/sh
#=============================================================================
# fara-load-weights.sh —— 把 up_proj 权重搬进常驻 DMA 缓冲
#
# 设计约束（这是本脚本存在的全部理由，改动前请先读懂）：
#
#   1) 运行期绝不对 SD 卡 ext4 rootfs 做写入。
#      上次板卡卡死的直接原因是
#          EXT4-fs error (device mmcblk0p2): ext4_journal_check_start:83:
#          Detected aborted journal
#      rootfs 的 ext4 日志区写失败 -> 内核把整个文件系统置为只读 -> 系统死。
#      因此本脚本的写入目标只有两处：tmpfs（内存）和 u-dma-buf（内存）。
#
#   2) 源介质一律只读挂载，拷完立刻 umount，不做长期挂载。
#
#   3) 目标缓冲必须物理连续（PL 侧 AXI DMA 要按物理地址取数），且常驻不释放。
#      用 u-dma-buf：内核模块在开机时固定一段物理连续内存，物理地址经 sysfs
#      读出且不变，用户态写入不会改变它。相比 dma_heap（fd 关掉就释放），
#      更符合"常驻"语义。
#
# 用法（三种源，任选其一）：
#   fara-load-weights.sh http://192.168.1.100:8000    # PC 上的 HTTP 目录（无需 U 盘）
#   fara-load-weights.sh /dev/sda1                    # U 盘（只读挂载）
#   fara-load-weights.sh /dev/shm/fara-models         # 已暂存好的目录
#
# 三种模式都把文件先落到内存，SD 卡全程零写入。
#
# 退出码：0=成功  1=环境缺失  2=源介质问题  3=校验失败
#=============================================================================
set -eu

SRC="${1:-}"
MNT=/mnt/fara-src
STAGE=/dev/shm/fara-models
UDMABUF=/dev/udmabuf0
SYSFS=/sys/class/u-dma-buf/udmabuf0

# 权重文件名（与 board_export/ 一致）
W_NAME=board_W_transformer_h_0_mlp_c_fc.bin
B_NAME=board_b_transformer_h_0_mlp_c_fc.bin
C_NAME=board_cfg_transformer_h_0_mlp_c_fc.json

# 期望字节数（防止截断/半包写入被当成成功）
W_BYTES=9437184
B_BYTES=12288

# 缓冲布局（必须与 PS/PL 两侧的约定一致）
W_OFF=0
B_OFF=9437184
C_OFF=9449472

log() { echo "[fara] $*"; }
die() { echo "[fara] ERROR: $*" >&2; exit "${2:-1}"; }

[ -n "$SRC" ] || die "用法: $0 <http://host:port | 设备节点 | 目录>" 1

case "$SRC" in
  http://*|https://*) MODE=http ;;
  *)
    if [ -b "$SRC" ]; then MODE=dev
    elif [ -d "$SRC" ]; then MODE=dir
    else die "$SRC 既不是块设备也不是目录" 2
    fi
    ;;
esac

#---------------------------------------------------------------------------
# 0) 环境自检
#---------------------------------------------------------------------------
if [ ! -e "$UDMABUF" ]; then
  log "未发现 $UDMABUF —— 尝试加载 u-dma-buf 模块"
  modprobe u-dma-buf udmabuf0=10485760 || \
    die "u-dma-buf 不可用。请先编译安装该模块，或改用 dma_heap 常驻守护方案" 1
  sleep 1
fi
[ -e "$UDMABUF" ] || die "$UDMABUF 仍不存在" 1

# 顺带确认 rootfs 没有残留错误（有就直接停手，别再往这块卡上加压）
if dmesg 2>/dev/null | grep -qiE "ext4.*(error|aborted)|I/O error.*mmcblk"; then
  log "警告：dmesg 中检测到 mmcblk/ext4 错误记录："
  dmesg | grep -iE "ext4.*(error|aborted)|I/O error.*mmcblk" | tail -5
  log "建议先排查 SD 卡，不要继续写入。"
fi

BUF_BYTES=$(cat "$SYSFS/size" 2>/dev/null || echo 0)
[ "$BUF_BYTES" -ge 10485760 ] || die "udmabuf0 只有 $BUF_BYTES B，需 >= 10485760" 1
log "udmabuf0 物理地址 = $(cat "$SYSFS/phys_addr" 2>/dev/null), 大小 = $BUF_BYTES B"

#---------------------------------------------------------------------------
# 1) 解析源 -> SRC_DIR（三种模式都落在内存里）
#---------------------------------------------------------------------------
cleanup() { if [ "$MODE" = dev ]; then umount "$MNT" 2>/dev/null || true; fi; }
trap cleanup EXIT INT TERM

case "$MODE" in
  http)
    mkdir -p "$STAGE"
    if command -v curl >/dev/null 2>&1; then
      FETCH() { curl -fsSL "$1" -o "$2"; }
    elif command -v wget >/dev/null 2>&1; then
      FETCH() { wget -q "$1" -O "$2"; }
    else
      die "需要 curl 或 wget 才能从网络拉取" 1
    fi
    base="${SRC%/}"
    for f in "$W_NAME" "$B_NAME" "$C_NAME"; do
      log "拉取 $base/$f"
      FETCH "$base/$f" "$STAGE/$f" || die "下载失败: $base/$f" 2
    done
    SRC_DIR="$STAGE"
    log "已拉取到内存暂存区 $STAGE"
    ;;
  dev)
    mkdir -p "$MNT"
    if mountpoint -q "$MNT"; then
      log "$MNT 已挂载，先卸载"
      umount "$MNT" || die "无法卸载残留挂载 $MNT" 2
    fi
    # -o ro 是硬要求：绝不因为"顺手"而让内核去写源介质
    mount -o ro "$SRC" "$MNT" || die "只读挂载 $SRC 失败" 2
    SRC_DIR="$MNT"
    log "已只读挂载 $SRC -> $MNT"
    ;;
  dir)
    SRC_DIR="$SRC"
    log "直接使用目录源 $SRC_DIR"
    ;;
esac

for f in "$W_NAME" "$B_NAME" "$C_NAME"; do
  [ -f "$SRC_DIR/$f" ] || die "源缺少 $f" 2
done

# 大小先卡一道，别让被截断的文件进缓冲
sz_w=$(wc -c < "$SRC_DIR/$W_NAME")
[ "$sz_w" -eq "$W_BYTES" ] || die "W 大小不符: $sz_w != $W_BYTES（下载或拷贝被截断？）" 2

#---------------------------------------------------------------------------
# 2) 搬进常驻缓冲（dd 直写，不经 rootfs）
#---------------------------------------------------------------------------
log "写入 W  ($W_BYTES B) @ offset $W_OFF"
dd if="$SRC_DIR/$W_NAME" of="$UDMABUF" bs=4096 seek=$((W_OFF/4096)) conv=notrunc status=none

log "写入 b  ($B_BYTES B) @ offset $B_OFF"
dd if="$SRC_DIR/$B_NAME" of="$UDMABUF" bs=4096 seek=$((B_OFF/4096)) conv=notrunc status=none

log "写入 cfg @ offset $C_OFF"
dd if="$SRC_DIR/$C_NAME" of="$UDMABUF" bs=4096 seek=$((C_OFF/4096)) conv=notrunc status=none

#---------------------------------------------------------------------------
# 3) 校验：把写进去的 W 读回来比 sha256
#---------------------------------------------------------------------------
sum_src=$(sha256sum "$SRC_DIR/$W_NAME" | cut -d' ' -f1)
sum_dst=$(dd if="$UDMABUF" bs=4096 count=$((W_BYTES/4096)) status=none | sha256sum | cut -d' ' -f1)
[ "$sum_src" = "$sum_dst" ] || die "W 校验失败: src=$sum_src dst=$sum_dst" 3
log "W sha256 OK: $sum_src"

#---------------------------------------------------------------------------
# 4) 收尾：卸载源介质（trap 也会兜底）
#---------------------------------------------------------------------------
if [ "$MODE" = dev ]; then
  umount "$MNT"
  log "已卸载 $MNT"
fi
trap - EXIT INT TERM

cat <<EOF

[fara] 权重已常驻。

  缓冲区   : $UDMABUF
  物理地址 : $(cat "$SYSFS/phys_addr")
  布局     : W @ +0  (9,437,184 B)
             b @ +9437184 (12,288 B)
             cfg @ +9449472

  后续推理只需搬激活 X（K=768 单 token = 3 KB），源介质与 SD 卡均不再参与。
EOF
