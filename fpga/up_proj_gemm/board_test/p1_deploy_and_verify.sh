#!/bin/sh
#=============================================================================
# p1_deploy_and_verify.sh -- Stage 2 tail + Stage 3 (L0~L3 + PUF) on ZCU106
#
# RUN ON THE BOARD, from the directory that holds:
#   puf_sample.c  run_l3.sh  dma_probe.c  gemm_probe.c  gemm_dma_test.c
#   gemm_vectors_k768n1.bin
# The frozen bitstream must already be at
#   /lib/firmware/up_proj_wrapper.bit.bin
# (the PC-side helper p0_out/deploy_p1_to_board.ps1 does that copy).
#
# Usage:  sudo sh p1_deploy_and_verify.sh
# Exit:   0 = all green   1 = env/setup problem   3 = L3 value mismatch
#
# ASCII only (serial console decodes UTF-8 as GBK).
#=============================================================================
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MGR=/sys/class/fpga_manager/fpga0
FW=up_proj_wrapper.bit.bin
FW_DIR=/lib/firmware

rc=0
say()  { echo "[p1] $*"; }
mark() { echo; echo "[p1] ============ $* ============"; }

mark "L0  fpga_manager state BEFORE"
[ -d "$MGR" ] || { say "FAIL: $MGR missing (fpga-manager not enabled)"; exit 1; }
say "state  = $(cat $MGR/state 2>/dev/null || echo unknown)"

mark "L0  load bitstream -- flags=0 (full configuration)"
[ -f "$FW_DIR/$FW" ] || { say "FAIL: $FW_DIR/$FW missing"; exit 1; }
say "size   = $(wc -c < "$FW_DIR/$FW") B"
echo 0 > "$MGR/flags"
echo "$FW" > "$MGR/firmware" || { say "FAIL: writing firmware node failed"; exit 2; }
i=0
while [ "$i" -lt 20 ]; do
  [ "$(cat $MGR/state)" = operating ] && break
  i=$((i + 1)); sleep 0.5
done
ST=$(cat $MGR/state)
say "state  = $ST  (expect operating)"
[ "$ST" = operating ] || { say "FAIL: not operating -- see dmesg | tail"; exit 2; }
say "L0 PASS"

mark "L1  AXI DMA control path (dma_probe)"
if cc -O2 -Wall -o "$DIR/dma_probe" "$DIR/dma_probe.c"; then
  "$DIR/dma_probe" || say "NOTE: dma_probe returned nonzero"
else
  say "FAIL: dma_probe build"; rc=1
fi

mark "L2a PUF registers @ 0xA0030000 (puf_sample --read-only)"
if cc -O2 -Wall -o "$DIR/puf_sample" "$DIR/puf_sample.c"; then
  "$DIR/puf_sample" --read-only || { say "FAIL: puf_sample --read-only"; rc=1; }
else
  say "FAIL: puf_sample build"; rc=1
fi

mark "L2b+L3 GEMM registers + DMA end-to-end vs golden (run_l3.sh)"
sh "$DIR/run_l3.sh"
L3=$?
say "run_l3 exit = $L3  (0=PASS, 3=value mismatch, 1/2=env or config)"
[ "$L3" -eq 0 ] || rc=3

mark "summary"
say "fpga_manager state = $(cat $MGR/state)"
if [ "$rc" -eq 0 ]; then say "RESULT = PASS"; else say "RESULT = CHECK (rc=$rc)"; fi
exit $rc
