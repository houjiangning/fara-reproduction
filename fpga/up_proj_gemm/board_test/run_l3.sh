#!/bin/sh
# run_l3.sh -- build and run the GEMM validation ladder (L1~L3) on the ZCU106
#
# NOTE: keep this file ASCII-only. The serial console decodes UTF-8 as GBK,
# so any non-ASCII byte here shows up as mojibake on the terminal.
#
# Preconditions:
#   1) bitstream already loaded, fpga_manager state = operating
#   2) dma_probe.c / gemm_probe.c / gemm_dma_test.c present next to this script
#   3) vector pack gemm_vectors_k8n1.bin (made by gen_golden_vectors.py --bin)
#
# Usage:  sudo sh run_l3.sh [vector.bin]

DIR=$(cd "$(dirname "$0")" && pwd)
VEC=${1:-$DIR/gemm_vectors_k8n1.bin}

echo "== [0] environment check"
if [ ! -e /dev/dma_heap/reserved ]; then
    echo "!! /dev/dma_heap/reserved missing (CMA heap not registered)"
    exit 1
fi
if [ ! -f "$VEC" ]; then
    echo "!! vector file not found: $VEC"
    exit 1
fi
ST=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null)
echo "   fpga_manager state = $ST"
if [ "$ST" != "operating" ]; then
    echo "!! bitstream not loaded. Run:"
    echo "     mkdir -p /dev/shm/fw"
    echo "     cp up_proj_wrapper.bit.bin /dev/shm/fw/"
    echo "     sudo sh -c 'echo -n /dev/shm/fw > /sys/module/firmware_class/parameters/path'"
    echo "     sudo sh -c 'echo up_proj_wrapper.bit.bin > /sys/class/fpga_manager/fpga0/firmware'"
    exit 1
fi

echo
echo "== [1] build"
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || CC=gcc
command -v "$CC" >/dev/null 2>&1 || {
    echo "!! no C compiler found. try: sudo apt install -y gcc"
    exit 1
}
echo "   using $CC"
$CC -O2 -Wall -o "$DIR/dma_probe"     "$DIR/dma_probe.c"     || exit 1
$CC -O2 -Wall -o "$DIR/gemm_probe"    "$DIR/gemm_probe.c"    || exit 1
$CC -O2 -Wall -o "$DIR/gemm_dma_test" "$DIR/gemm_dma_test.c" || exit 1

echo
echo "== [2] L1: AXI DMA control path"
"$DIR/dma_probe" || true

echo
echo "== [3] L2: GEMM AXI-Lite registers"
"$DIR/gemm_probe" || true

echo
echo "== [4] L3: DMA end-to-end vs golden"
"$DIR/gemm_dma_test" "$VEC"
RC=$?

echo
echo "== exit code $RC  (0=PASS, 3=value mismatch, 1/2=env or config)"
exit $RC
