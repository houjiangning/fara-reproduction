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
#      因此本脚本的写入目标只有两处：tmpfs（/dev/shm）和 dma_heap（内存）。
#
#   2) 源介质一律只读挂载，拷完立刻 umount，不做长期挂载。
#
#   3) 目标缓冲必须物理连续（PL 侧 AXI DMA 要按物理地址取数），且常驻不释放。
#
# 机制：dma_heap + fara-resident 守护（**不是** u-dma-buf）
#   板上内核没有 u-dma-buf 模块，要装得先编译匹配 Xilinx 内核头文件的模块，
#   风险高。改用内核自带的 dma_heap（cma=1200M 已开，L3 就是走这条路验证通过的）：
#     · 本脚本把权重暂存到 /dev/shm（tmpfs）
#     · 编译并 exec fara-resident，由它分配 dma_heap 缓冲、校验 sha256、
#       把物理地址写进 /run/fara-resident.json，然后**保持运行**持有缓冲
#       （dma_heap 的 fd 一关缓冲就释放，所以必须常驻一个进程）。
#
# 用法（三种源，任选其一）：
#   fara-load-weights.sh http://192.168.1.100:8000    # PC 上的 HTTP 目录
#   fara-load-weights.sh /dev/sda1                    # U 盘（只读挂载）
#   fara-load-weights.sh /dev/shm/fara-models         # 已暂存好的目录
#
# 前台常驻；systemd 下用 Type=simple（见 fara-weights.service）。
#
# 退出码：0=正常退出  1=环境缺失  2=源介质/校验问题  3=sha256 失败
#=============================================================================
set -eu

SRC="${1:-}"
MNT=/mnt/fara-src
STAGE=/dev/shm/fara-models
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# 权重文件名（与 board_export/ 一致）
W_NAME=board_W_transformer_h_0_mlp_c_fc.bin
B_NAME=board_b_transformer_h_0_mlp_c_fc.bin
C_NAME=board_cfg_transformer_h_0_mlp_c_fc.json

# 期望字节数（防止截断/半包写入被当成成功）
W_BYTES=9437184
B_BYTES=12288

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
[ -e /dev/dma_heap/reserved ] || die \
  "/dev/dma_heap/reserved 不存在。检查内核命令行是否有 cma=，以及 dma-heap 是否注册" 1

# 顺带确认 rootfs 没有残留错误（有就直接停手，别再往这块卡上加压）
# 注意：不要用 "ext4.*error" 这种宽泛模式，否则会命中启动时正常的
# "EXT4-fs (mmcblk0p2): re-mounted. Opts: ...errors=remount-ro" 造成误报。
SDERR_RE='EXT4-fs error|EXT4-fs.*aborted|aborted journal|I/O error'
if dmesg 2>/dev/null | grep -qiE "$SDERR_RE"; then
  log "警告：dmesg 中检测到 mmcblk/ext4 错误记录："
  dmesg | grep -iE "$SDERR_RE" | tail -5
  log "建议先排查 SD 卡，不要继续写入。"
fi

#---------------------------------------------------------------------------
# 1) 解析源 -> STAGE（三种模式都落在内存里，零 SD 卡写入）
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
    mkdir -p "$STAGE"
    for f in "$W_NAME" "$B_NAME" "$C_NAME"; do
      log "拷入内存 $f"
      cp "$MNT/$f" "$STAGE/$f" || die "拷贝失败: $MNT/$f" 2
    done
    umount "$MNT" && log "已卸载 $MNT"
    SRC_DIR="$STAGE"
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
# 2) 准备 fara-resident（优先现成可执行，其次就地编译到 /dev/shm）
#---------------------------------------------------------------------------
RES="$STAGE/fara-resident"
if [ ! -x "$RES" ]; then
  if [ -x "$SELF_DIR/fara-resident" ]; then
    RES="$SELF_DIR/fara-resident"
  elif [ -f "$SELF_DIR/fara-resident.c" ]; then
    log "编译 fara-resident -> $STAGE/fara-resident"
    mkdir -p "$STAGE"
    cc -O2 -o "$RES" "$SELF_DIR/fara-resident.c" || die "编译 fara-resident 失败" 1
  else
    die "找不到 fara-resident（可执行或 .c），无法常驻" 1
  fi
fi

#---------------------------------------------------------------------------
# 3) 常驻：exec 交给 fara-resident（它做 sha256 校验 + 发布物理地址）
#---------------------------------------------------------------------------
trap - EXIT INT TERM
log "启动常驻守护：$RES $SRC_DIR"
exec "$RES" "$SRC_DIR"
