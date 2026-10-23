#!/bin/sh
#=============================================================================
# fara-load-bitstream.sh —— 开机把 FaR 版 PL 比特流全量配置进 ZynqMP PL
#
# 背景：ZCU106 冷启动后 PL 未配置（fpga_manager state=unknown），
#       必须显式加载 up_proj_wrapper.bit.bin 才能访问 GEMM / FaR 寄存器。
#       此前板上只有权重自加载（fara-weights.service），没有比特流自加载，
#       所以每次冷启动都要手动配一次 PL —— 本脚本补齐这一环。
#
# 用法（板卡上）：
#   sudo bash fara-load-bitstream.sh [--force] [BITSTREAM_NAME]
#     默认 BITSTREAM_NAME=up_proj_wrapper.bit.bin（位于 /lib/firmware/）
#     --force：即使当前 state=operating 也重新配置（用于验证加载通路）
#
# 关键点：
#   · flags=0 → 全量配置（FPGA Manager 的默认语义；DPR 的部分配置才需要别的 flag）
#   · 必须是 bootgen 生成的 .bit.bin（FPGA Manager 可识别的二进制格式），不是 .bit
#   · 加载后校验 state=operating；未加 --force 且已配置时幂等跳过
#
# 退出码：0=成功/已配置  1=环境缺失  2=加载失败
#=============================================================================
set -eu

FORCE=0
FW=up_proj_wrapper.bit.bin
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*) echo "[fara-bit] ERROR: 未知参数 $a" >&2; exit 1 ;;
    *) FW="$a" ;;
  esac
done

MGR=/sys/class/fpga_manager/fpga0
FW_DIR=/lib/firmware

log() { echo "[fara-bit] $*"; }
die() { echo "[fara-bit] ERROR: $*" >&2; exit "${2:-1}"; }
st()  { cat "$MGR/state" 2>/dev/null || echo unknown; }

[ -d "$MGR" ] || die "$MGR 不存在（内核未启用 fpga-manager，或器件不是 fpga0）" 1
[ -f "$FW_DIR/$FW" ] || die "$FW_DIR/$FW 不存在（先放置 bootgen 生成的 .bit.bin）" 1

if [ "$FORCE" -eq 0 ] && [ "$(st)" = operating ]; then
  log "PL 已处于 operating，跳过加载（需要重配请加 --force）"
  exit 0
fi

log "加载 $FW（flags=0 全量配置）"
echo 0 > "$MGR/flags"
echo "$FW" > "$MGR/firmware" || die "写入 firmware 失败" 2

# 加载是同步的，这里留一点余量等状态稳定
i=0
while [ "$i" -lt 20 ]; do
  [ "$(st)" = operating ] && break
  i=$((i + 1)); sleep 0.5
done

s=$(st)
[ "$s" = operating ] || die "加载后 state=$s（期望 operating）" 2
log "PL 配置完成，state=$s"
