#!/bin/sh
#=============================================================================
# install_puf_sample_service.sh -- install/enable fara-puf-sample.service
#                                  and do a live sampling test right now
#
# NOTE: keep this file ASCII-only (serial console decodes UTF-8 as GBK).
#
# Run ON THE BOARD:
#   sudo sh install_puf_sample_service.sh
#
# Preconditions:
#   - bitstream already loaded  (fpga_manager state = operating)
#   - fara-puf-sample.sh and fara-puf-sample.service present next to this script
#     (or in /dev/shm)
#
# What it does, in order (fail fast at each gate):
#   1) install files + daemon-reload + enable
#   2) live sampling test (one sample appended NOW)
#   3) print how many samples the log holds
#   4) remind you how to accumulate more and how to stop
#=============================================================================
set -eu

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SH_SRC="$SELF_DIR/fara-puf-sample.sh"
UNIT_SRC="$SELF_DIR/fara-puf-sample.service"

# Fall back to /dev/shm, which is where these are often staged via scp
[ -f "$SH_SRC" ]   || SH_SRC=/dev/shm/fara-puf-sample.sh
[ -f "$UNIT_SRC" ] || UNIT_SRC=/dev/shm/fara-puf-sample.service

[ -f "$SH_SRC" ]   || { echo "missing fara-puf-sample.sh" >&2; exit 1; }
[ -f "$UNIT_SRC" ] || { echo "missing fara-puf-sample.service" >&2; exit 1; }

echo "=== [1] install ==="
install -m0755 "$SH_SRC"   /usr/local/bin/fara-puf-sample.sh
install -m0644 "$UNIT_SRC" /etc/systemd/system/fara-puf-sample.service
systemctl daemon-reload
systemctl enable fara-puf-sample.service
echo "    installed and enabled"

echo
echo "=== [2] PUF register sanity check (before enabling anything) ==="
echo "    fpga_manager state = $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)"
if [ -x /dev/shm/puf_sample ]; then
  /dev/shm/puf_sample --read-only || true
elif command -v puf_sample >/dev/null 2>&1; then
  puf_sample --read-only || true
else
  echo "    (puf_sample not built yet -- will be built by the service)"
fi

echo
echo "=== [3] live sampling test (appends ONE sample now) ==="
/usr/local/bin/fara-puf-sample.sh

echo
echo "=== [4] service status ==="
systemctl status fara-puf-sample.service --no-pager | head -12

echo
echo "=== done ==="
echo "NEXT:"
echo "  - the service now appends one sample per boot; just reboot N times"
echo "  - from the PC you can automate the reboot loop:"
echo "      python tools/puf_coldboot_loop.py --host 192.168.1.200 --user root --n 32"
echo "  - to inspect the log on the board:"
echo "      cat /opt/fara/puf/puf_samples.txt"
echo "  - IMPORTANT: before re-flashing a NEW bitstream, stop accumulation:"
echo "      systemctl disable --now fara-puf-sample.service"
echo "    (a new bitstream changes the PUF response, so samples from the old"
echo "     and new bitstreams must never be mixed in one log file)"
