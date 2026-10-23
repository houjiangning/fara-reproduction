#!/bin/sh
#=============================================================================
# run_secure_seal.sh -- ONE-TIME canary seal (run on the board, as root)
#
# Usage:
#   sudo sh run_secure_seal.sh /path/to/ref66.txt
#
# ref66.txt: 17 hex chars, bit i = i-th selected-bit value of the enrollment
#            reference response (produced by PC tools/canary_anchor.py).
#            MUST live on tmpfs (/dev/shm); it is key-equivalent together
#            with helper data and is shredded by this script.
#
# Produces:
#   /opt/fara/puf/canary.bin            (64 B, AES-sealed anchor)
#   /opt/fara/puf/fara_canary_config.txt
#=============================================================================
set -eu

REF="${1:-}"
BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRV=/usr/local/bin/fara_infer_server
ENC_DIR=/opt/fara/models
PUF_DIR=/opt/fara/puf

[ -n "$REF" ] || { echo "usage: $0 <ref66-file-on-tmpfs>"; exit 2; }
[ -f "$REF" ] || { echo "ref66 file not found: $REF"; exit 2; }
[ -x "$SRV" ] || { echo "missing $SRV (run install_weights_service.sh first)"; exit 2; }

# never run against a plaintext-W layout by accident
if [ -f "$ENC_DIR/board_W_transformer_h_0_mlp_c_fc.bin" ]; then
  echo "FATAL: plaintext W still present in $ENC_DIR -- provisioning violated"; exit 3
fi
[ -f "$ENC_DIR/board_W_transformer_h_0_mlp_c_fc.enc" ] || {
  echo "FATAL: $ENC_DIR/board_W_*.enc missing"; exit 3; }

# PL must be up (bitstream loaded)
STATE=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$STATE" = "operating" ] || { echo "FATAL: fpga_manager state=$STATE (need fara-bitstream)"; exit 3; }

echo "[seal] stop weights service during seal"
systemctl stop fara-weights.service >/dev/null 2>&1 || true

echo "[seal] run --seal"
"$SRV" --seal --enc-dir="$ENC_DIR" --puf-dir="$PUF_DIR" --ref66="$REF"

echo "[seal] shred ref66 carrier"
shred -n1 -u "$REF"

echo "[seal] verify artifacts:"
ls -la "$PUF_DIR/canary.bin" "$PUF_DIR/fara_canary_config.txt"
sha256sum "$PUF_DIR/canary.bin"

echo "[seal] DONE. Now: sudo systemctl start fara-weights.service"
