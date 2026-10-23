#!/bin/sh
#=============================================================================
# fara-puf-sample.sh -- sample the Butterfly PUF once per boot and append to log
#
# NOTE: keep this file ASCII-only. The serial console / some terminals decode
#       UTF-8 as GBK, so non-ASCII bytes here would show up as mojibake.
#
# WHY a systemd oneshot service instead of doing it by hand:
#   P1 needs the SAME device sampled across MANY cold boots (>= 32) to get a
#   per-bit flip rate. Automating it removes the main source of human error
#   (missing a boot, double-sampling one boot, mixing up t_settle values).
#
# PRECONDITION: PL already configured (fara-bitstream.service ran first).
#               This script does NOT sample unless fpga_manager is operating.
#
# WHERE the samples go:
#   /opt/fara/puf/puf_samples.txt on the SD rootfs. This is the ONE place we
#   deliberately write to persistent storage -- without persistence the samples
#   die with the tmpfs at every reboot and cross-boot statistics are impossible.
#   The write is a few hundred bytes per boot, which is far below the write
#   pattern that previously caused the ext4 journal abort.
#
#   Set PUF_LOG to override the path.
#
# Compile step: puf_sample.c is compiled on demand into /dev/shm (tmpfs), the
#   same trick fara-load-weights.sh uses for fara-resident -- keeps the rootfs
#   clean and survives nothing, which is fine because we recompile per boot.
#
# Exit codes: 0 = ok / skipped  1 = env missing  2 = PL not configured  3 = sample failed
#=============================================================================
set -eu

PUF_LOG="${PUF_LOG:-/opt/fara/puf/puf_samples.txt}"
PUF_BASE="${PUF_BASE:-0xA0030000}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# sampling parameters -- override via /etc/systemd/system/fara-puf-sample.service.d/
M_SAMP="${M_SAMP:-9}"          # odd!
T_FORCE="${T_FORCE:-8}"
T_SETTLE="${T_SETTLE:-64}"

log() { echo "[puf-sample] $*"; }
die() { echo "[puf-sample] ERROR: $*" >&2; exit "${2:-1}"; }

#---------------------------------------------------------------------------
# 0) environment
#---------------------------------------------------------------------------
MGR=/sys/class/fpga_manager/fpga0

if [ ! -d "$MGR" ]; then
  die "$MGR missing (kernel lacks fpga-manager, or the device is not fpga0)" 1
fi

ST=$(cat "$MGR/state" 2>/dev/null || echo unknown)
if [ "$ST" != "operating" ]; then
  log "PL is not configured (state=$ST) -- skipping this boot."
  log "  fix: systemctl start fara-bitstream.service   (or reboot)"
  exit 2
fi

#---------------------------------------------------------------------------
# 1) build puf_sample on demand (into tmpfs, never onto the SD rootfs)
#---------------------------------------------------------------------------
BIN=/dev/shm/puf_sample
if [ ! -x "$BIN" ]; then
  if [ -x "$SELF_DIR/puf_sample" ]; then
    BIN="$SELF_DIR/puf_sample"
  elif [ -f "$SELF_DIR/puf_sample.c" ]; then
    CC="${CC:-cc}"
    command -v "$CC" >/dev/null 2>&1 || CC=gcc
    command -v "$CC" >/dev/null 2>&1 || die "no C compiler (try: apt install gcc)" 1
    log "compiling puf_sample.c -> $BIN"
    "$CC" -O2 -o "$BIN" "$SELF_DIR/puf_sample.c" || die "compile failed" 3
  else
    die "puf_sample.c not found next to this script ($SELF_DIR)" 1
  fi
fi

#---------------------------------------------------------------------------
# 2) make sure the log dir exists
#---------------------------------------------------------------------------
LOGDIR="$(dirname "$PUF_LOG")"
mkdir -p "$LOGDIR" || die "cannot create $LOGDIR" 1

# Warn (do not abort) if the SD already shows errors -- same pattern the
# weights script uses. Keep the pattern narrow: a broad 'ext4.*error' would
# also match the harmless boot-time "re-mounted ... errors=remount-ro" line.
SDERR_RE='EXT4-fs error|EXT4-fs.*aborted|aborted journal|I/O error'
if dmesg 2>/dev/null | grep -qiE "$SDERR_RE"; then
  log "WARNING: mmcblk/ext4 errors present in dmesg:"
  dmesg | grep -iE "$SDERR_RE" | tail -3
  log "consider checking the SD card before continuing to accumulate samples."
fi

#---------------------------------------------------------------------------
# 3) sample
#---------------------------------------------------------------------------
log "sampling PUF (M=$M_SAMP T_FORCE=$T_FORCE T_SETTLE=$T_SETTLE) -> $PUF_LOG"
if ! "$BIN" --base "$PUF_BASE" --m "$M_SAMP" --tforce "$T_FORCE" \
            --tsettle "$T_SETTLE" --append "$PUF_LOG"; then
  die "sampling failed (see the VERSION check above)" 3
fi

# count how many samples the log now holds (excluding comments)
N=$(grep -vc '^#' "$PUF_LOG" 2>/dev/null || echo 0)
log "log now holds $N sample(s): $PUF_LOG"
exit 0
