#=============================================================================
# stage6_puf_board_verify.ps1 -- Stage 6 dynamic half.
#
# Deploys the REBUILT (Stage 5 fixed) bitstream, cold-boot samples the PUF N
# times into a SEPARATE log, then compares the result against the frozen
# baseline. This is the only Stage 6 step that needs the board.
#
# Run on the PC (board powered on and reachable):
#   powershell -ExecutionPolicy Bypass -File p0_out\stage6_puf_board_verify.ps1
#   powershell -ExecutionPolicy Bypass -File p0_out\stage6_puf_board_verify.ps1 -N 8
#   powershell -ExecutionPolicy Bypass -File p0_out\stage6_puf_board_verify.ps1 -SkipDeploy
#
# WHY THE ORDER MATTERS
#   1) The pollution guard is installed BEFORE the first reboot. The
#      fara-puf-sample.service appends one sample at EVERY boot into
#      /opt/fara/puf/puf_samples.txt -- that file is the frozen 32-sample
#      baseline (SHA256 CB790C38...B607). The drop-in redirects PUF_LOG to a
#      separate file so the baseline survives.
#   2) Deploy first, then reboot, then sample: we must measure the REBUILT
#      bitstream, not the previous one.
#
# Artifact under test:
#   p0_out/up_proj_wrapper.bit.bin   19321332 B
#   SHA256 12659FEDB176E932B9D932CE7A77EA52B793F10738B96DB94788369C03D52C3B
#   (the Stage 2/3 frozen build 538CB36E... is archived, not used here)
#
# Frozen baseline to compare against (unchanged since Stage 4):
#   puf_out/puf_stability.json   stable_bits=72  flip_rate_mean=0.0884
#                                hd_cross_boot_mean=16.61  entropy~36.85 bit
#   puf_out/puf_stable_mask.txt  SHA256 B1732DA739F8191E8AA43442D05FAB7C496A59C9FCE29BC167F1CBA7CBA54A8C
#=============================================================================
param(
  [int]$N = 8,
  [string]$Board = "ubuntu@192.168.1.200",
  [switch]$SkipDeploy
)
# NOTE: "Continue", not "Stop". During the post-reboot wait the board is
# unreachable for ~60s and ssh/Test-Connection emit stderr; with "Stop" that
# benign stderr is promoted to a terminating NativeCommandError and kills the
# script even though the reboot itself is fine. We handle failures explicitly
# via $LASTEXITCODE / Die() instead.
$ErrorActionPreference = "Continue"

$Proj    = Split-Path $PSScriptRoot -Parent
$FW      = Join-Path $Proj "p0_out\up_proj_wrapper.bit.bin"
$OVR     = Join-Path $Proj "board_test\fara-puf-sample-stage6.override.conf"
$Expect  = "12659FEDB176E932B9D932CE7A77EA52B793F10738B96DB94788369C03D52C3B"
$BaseLog = "/opt/fara/puf/puf_samples.txt"
$S6Log   = "/opt/fara/puf/puf_samples_stage6.txt"
$Ip      = ($Board -split "@")[-1]
$SSHOPT  = @("-o","BatchMode=yes","-o","ConnectTimeout=5","-o","StrictHostKeyChecking=no")

function Say($m) { Write-Host "[pc] $m" }
function Die($m) { Write-Host "[pc] !! $m"; exit 1 }
function Rsh($cmd) { ssh @SSHOPT $Board $cmd }
function WaitSsh([int]$TimeoutSec) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
    # 2>&1 so the transient "connection refused" on ssh's stderr is consumed
    # instead of surfacing as a PowerShell error record.
    $null = ssh @SSHOPT $Board "echo up" 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Start-Sleep -Seconds 3
  }
  return $false
}

# --- 0) local artifact guard ------------------------------------------------
$Got = (Get-FileHash $FW -Algorithm SHA256).Hash
Say "local bitstream SHA256 = $Got"
if ($Got -ne $Expect) { Die "SHA256 MISMATCH -- expected $Expect (refusing to flash the wrong build)" }
if (-not (Test-Path $OVR)) { Die "missing drop-in: $OVR" }
Say "guard OK -- Stage 6 rebuilt bitstream + pollution drop-in both present"

# --- 1) reachability --------------------------------------------------------
Say "reachability: $Ip"
if (-not (Test-Connection $Ip -Count 2 -Quiet -ErrorAction SilentlyContinue)) { Die "board not responding to ping" }
Rsh "echo ok" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "SSH to $Board failed" }
Say "board reachable"

# --- 2) pollution guard FIRST (before any reboot) ---------------------------
Say "installing PUF_LOG pollution guard (drop-in: stage6-puf-log.conf)"
Rsh "sudo mkdir -p /etc/systemd/system/fara-puf-sample.service.d" | Out-Null
scp @SSHOPT $OVR "${Board}:/tmp/stage6-puf-log.conf" | Out-Null
Rsh "sudo install -m0644 /tmp/stage6-puf-log.conf /etc/systemd/system/fara-puf-sample.service.d/stage6-puf-log.conf && sudo systemctl daemon-reload" | Out-Null
Rsh "ls -l /etc/systemd/system/fara-puf-sample.service.d/" | ForEach-Object { Say "  drop-in: $_" }
$envline = (Rsh "systemctl show fara-puf-sample.service -p Environment") -join " "
Say "service Environment: $envline"
if ($envline -notmatch "puf_samples_stage6") { Die "drop-in did not take effect -- abort before any reboot" }
Say "pollution guard live: new samples -> $S6Log"

$baseCnt = (Rsh "grep -vc '^#' $BaseLog 2>/dev/null || echo 0") -join " "
$baseCnt = $baseCnt.Trim()
Say "baseline log ($BaseLog) holds $baseCnt sample(s) -- will remain untouched"
$s6Cnt = (Rsh "test -f $S6Log && grep -vc '^#' $S6Log || echo 0") -join " "
Say "stage6 log currently holds $($s6Cnt.Trim()) sample(s)"

# --- 3) deploy + cold reboot ------------------------------------------------
if (-not $SkipDeploy) {
  Say "deploying bitstream into /lib/firmware"
  scp @SSHOPT $FW "${Board}:/tmp/" | Out-Null
  Rsh "sudo cp -f /tmp/up_proj_wrapper.bit.bin /lib/firmware/up_proj_wrapper.bit.bin" | Out-Null
  $boardSha = (Rsh "sha256sum /lib/firmware/up_proj_wrapper.bit.bin") -join " "
  Say "board firmware sha256: $boardSha"
  if ($boardSha -notmatch $Expect) { Die "board firmware SHA mismatch after copy" }

  Say "rebooting to load the new bitstream (cold boot)"
  Rsh "sync; sudo systemctl reboot" 2>$null | Out-Null
  Start-Sleep -Seconds 3
  if (-not (WaitSsh 180)) { Die "SSH did not come back within 180s" }
  Start-Sleep -Seconds 15
}

# --- 4) L0 + PUF register sanity -------------------------------------------
$state = (Rsh "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown") -join " "
Say "fpga_manager state = $($state.Trim())"
if ($state -notmatch "operating") { Die "PL not configured (L0 FAIL) -- check fara-bitstream.service" }
Say "L0 OK (PL operating)"

# --- 5) cold-boot sampling loop --------------------------------------------
Say "running $N cold boots (samples -> $S6Log)"
Push-Location $Proj
try {
  python tools\puf_coldboot_loop.py --host $Ip --user ubuntu --n $N --log $S6Log --out p0_out\stage6_new_samples.txt
  if ($LASTEXITCODE -ne 0) { Say "!! cold-boot loop reported failures (rc=$LASTEXITCODE) -- investigate before trusting the stats" }

  # --- 6) stability stats --------------------------------------------------
  Say "computing stability stats"
  python tools\puf_stability.py --in p0_out\stage6_new_samples.txt --out-dir p0_out\stage6_stability --no-plot --threshold 0.01
  if ($LASTEXITCODE -ne 0) { Die "puf_stability.py failed" }

  # --- 7) compare against the frozen baseline ------------------------------
  $new  = Get-Content (Join-Path $Proj "p0_out\stage6_stability\puf_stability.json") -Raw | ConvertFrom-Json
  $base = Get-Content (Join-Path $Proj "puf_out\puf_stability.json") -Raw | ConvertFrom-Json
  Say ("baseline : samples={0} stable={1} flip={2:N4} hd_mean={3:N2} entropy={4:N2}" -f $base.n_samples,$base.stable_bits,$base.flip_rate_mean,$base.hd_cross_boot_mean,$base.entropy_bits_est)
  Say ("stage6   : samples={0} stable={1} flip={2:N4} hd_mean={3:N2} entropy={4:N2}" -f $new.n_samples,$new.stable_bits,$new.flip_rate_mean,$new.hd_cross_boot_mean,$new.entropy_bits_est)

  $bs = (($base.stable_indices | Sort-Object) -join ",")
  $ns = (($new.stable_indices  | Sort-Object) -join ",")
  $bHex = $base.unan_union_hex; $nHex = $new.unan_union_hex
  Say "baseline unstable-union hex = $bHex"
  Say "stage6   unstable-union hex = $nHex"

  if ($bs -eq $ns -and $bHex -eq $nHex) {
    Say ">>> VERDICT: PASS -- stable-bit set and unstable-union are IDENTICAL to the frozen baseline."
    Say ">>> The rebuilt bitstream reproduces the same PUF fingerprint => freeze confirmed on hardware."
    exit 0
  } else {
    Say ">>> VERDICT: REVIEW -- stage6 differs from the baseline."
    $bSet = $base.stable_indices; $nSet = $new.stable_indices
    $onlyBase = @($bSet | Where-Object { $nSet -notcontains $_ })
    $onlyNew  = @($nSet | Where-Object { $bSet -notcontains $_ })
    Say ("  baseline-only stable bits: {0} of {1}" -f $onlyBase.Count, $bSet.Count)
    Say ("  stage6-only   stable bits: {0} of {1}" -f $onlyNew.Count, $nSet.Count)
    Say "  NOTE: a few bits near the flip-rate threshold are expected to cross it between runs."
    Say "        Cross-boot intrinsic variation is 12~16 bits, so do NOT fail on a small delta alone."
    Say "        Triage order: (1) confirm /lib/firmware sha256 == $Expect,"
    Say "                      (2) compare per-boot HD against the baseline,"
    Say "                      (3) reflash the archived 538CB36E... bin and re-sample to isolate."
    exit 2
  }
} finally {
  Pop-Location
}
