#!/bin/sh
#=============================================================================
# install_weights_service.sh -- install fara-weights v2 (secure boot chain)
#
# Run ON THE BOARD:
#   sudo sh install_weights_service.sh
#
# Installs:
#   fara_infer_server   -> /usr/local/bin/
#   fara-weights.service-> /etc/systemd/system/
#
# NOTE: one-time SEAL is separate (see run_secure_seal.sh). The service will
#       stay skipped (ConditionPathExists) until canary.bin exists.
#=============================================================================
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

[ -f "$HERE/fara_infer_server.c" ] || { echo "missing fara_infer_server.c"; exit 2; }

echo "[i] compiling fara_infer_server -> $HERE/fara_infer_server"
cc -O2 -o "$HERE/fara_infer_server" "$HERE/fara_infer_server.c"

echo "[i] install binary + unit"
install -m0755 "$HERE/fara_infer_server" /usr/local/bin/fara_infer_server
install -m0644 "$HERE/fara-weights.service" /etc/systemd/system/fara-weights.service

echo "[i] retire legacy plaintext chain (fara-resident is no longer used)"
systemctl disable fara-weights.service >/dev/null 2>&1 || true
systemctl enable fara-weights.service >/dev/null 2>&1 || true
systemctl daemon-reload

echo "[i] done. status:"
systemctl status fara-weights.service --no-pager -l | head -8 || true
echo "[i] next: run run_secure_seal.sh <ref66-file> ONCE, then start service."
