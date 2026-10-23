#!/bin/sh
#=============================================================================
# run_far.sh —— 板卡侧 FaR 验证一键跑（L2 → L3 → L4）
#
# 前置：
#   1) 板卡已启动 Ubuntu，且 PL 里烧的是**含 far_reroute 的 FaR 版 bitstream**
#      （GEMM VERSION 读回 0x0002_0000）。烧录见操作手册「步骤 4」。
#   2) 本目录下已就位：gemm_probe.c gemm_dma_test.c far_bench.c
#      gemm_vectors_k768n1.bin far_bench.bin far_bench.fmap
#
# 用法：
#   sudo sh run_far.sh                         # 全部跑，用默认文件名
#   sudo sh run_far.sh gemm_vectors_k768n1.bin far_bench.bin
#
# 退出码：0=全过  1=环境  2=L2 失败  3=L3 失败  4=L4 失败
#
# 说明：所有产物（可执行文件、日志）都落在当前目录。若当前目录在 /dev/shm
#       下则全程零 SD 卡写入；不要 cd 到 rootfs 上跑编译，避免写坏 ext4。
#=============================================================================
set -eu

VEC="${1:-gemm_vectors_k768n1.bin}"
FBEN="${2:-far_bench.bin}"

cd "$(dirname "$0")"

log() { echo "[run_far] $*"; }
die() { echo "[run_far] ERROR: $*" >&2; exit "${2:-1}"; }

#---------------------------------------------------------------------------
# [0] 环境自检
#---------------------------------------------------------------------------
log "== [0] environment check =="
[ -e /dev/dma_heap/reserved ] || die "/dev/dma_heap/reserved 不存在（内核需 CMA 且注册 dma-heap）" 1

STATE="$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)"
log "    fpga_manager state = $STATE"
[ "$STATE" = "operating" ] || die "FPGA 未在 operating，请先烧 bitstream（见手册步骤 4）" 1

[ -f "$VEC" ]  || die "找不到向量文件 $VEC" 1
[ -f "$FBEN" ] || die "找不到基准包 $FBEN" 1
FMAP="${FBEN%.bin}.fmap"
[ -f "$FMAP" ] || die "找不到 FaRMap $FMAP" 1
log "    vectors = $VEC"
log "    fben    = $FBEN"
log "    fmap    = $FMAP"

#---------------------------------------------------------------------------
# [1] 编译
#---------------------------------------------------------------------------
log "== [1] build =="
CC="${CC:-cc}"
$CC -O2 -o gemm_probe    gemm_probe.c    || die "编译 gemm_probe 失败" 1
$CC -O2 -o gemm_dma_test gemm_dma_test.c || die "编译 gemm_dma_test 失败" 1
$CC -O2 -o far_bench     far_bench.c     || die "编译 far_bench 失败" 1
log "    gemm_probe / gemm_dma_test / far_bench 编译完成"

#---------------------------------------------------------------------------
# [2] L2：AXI-Lite 寄存器探针（含 FaRMap 寄存器组）
#---------------------------------------------------------------------------
log ""
log "== [2] L2: GEMM AXI-Lite + FaRMap registers =="
if ! ./gemm_probe; then
  die "L2 失败：GEMM 从接口或 FaRMap 寄存器组不通" 2
fi

#---------------------------------------------------------------------------
# [3] L3：DMA 端到端对 golden（纯 GEMM 通路，far_en=0）
#---------------------------------------------------------------------------
log ""
log "== [3] L3: DMA end-to-end vs golden (baseline) =="
if ! ./gemm_dma_test "$VEC"; then
  die "L3 失败：GEMM 数据通路或 DMA 通路有问题" 3
fi

#---------------------------------------------------------------------------
# [4] L4：硬件 FaR vs 软件 FaR（far_en=0 / far_en=1 两跑对比）
#---------------------------------------------------------------------------
log ""
log "== [4] L4: hardware FaR vs software FaR =="
if ! ./far_bench "$FBEN" "$FMAP" 3; then
  die "L4 失败：硬件 FaR 与软件 golden 不一致" 4
fi

log ""
log "==== 全部通过：L2 + L3 + L4 ===="
log "  结论：硬件 FaR 输出与软件 FaR bit-exact，且额外时间 ≈ 0（防护吃进数据通路）。"
