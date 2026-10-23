#=============================================================================
# stage6_isolation_verify.ps1 -- Stage 6 REVIEW triage, isolation test
#
# WHY
#   The rebuilt (Stage-5-fixed) bitstream 12659FED produced a PUF stable-bit
#   set differing from the frozen baseline by ~48 of ~95 bits (Jaccard 0.495),
#   and the unstable-union hex differs entirely. Per-bit analysis shows 48 bits
#   INVERTED their stuck value (e.g. bit 34 one_ratio 0.000 -> 1.000 with 0
#   flips in both campaigns), so this is more than 32-sample threshold jitter.
#   Two explanations remain:
#     H1 physical : re-implementation changed routing/parasitics -> cells
#                   re-resolved (LOC+BEL freeze does not preserve the response)
#     H2 session  : temperature/supply/session drift between the baseline
#                   session (2026-10-15) and the Stage 6 session (2026-10-16)
#
# WHAT THIS DOES
#   Reflash the ARCHIVED ORIGINAL bitstream (538CB36E...) and run a FRESH
#   32-boot campaign into a THIRD log (/opt/fara/puf/puf_samples_isolation.txt).
#     * isolation ~= baseline -> the original build IS reproducible across
#                               sessions => the rebuild really changed the PUF
#                               response at the routing level (H1)
#     * isolation != baseline -> the bit-exact 'stable set' criterion is too
#                               brittle for this PUF; drift dominates (H2),
#                               which validates the fuzzy-extractor route
#
# Run on the PC (board powered on and reachable):
#   powershell -ExecutionPolicy Bypass -File p0_out\stage6_isolation_verify.ps1
#=============================================================================
param(
  [int]$N = 31,
  [string]$Board = "ubuntu@192.168.1.200"
)
# "Continue", not "Stop": the post-reboot ssh timeout on stderr is benign and
# must not terminate the script (same fix as stage6_puf_board_verify.ps1).
$ErrorActionPreference = "Continue"

$Proj    = Split-Path $PSScriptRoot -Parent
$FW      = Join-Path $Proj "p0_out\stage6_backup_20261015\bit\up_proj_wrapper.bit.bin"
$OVR     = Join-Path $Proj "board_test\fara-puf-sample-isolation.override.conf"
$Expect  = "538CB36EAE9E9B383DC2BCFAF97831DFB3B5A9148BA38EEC848C3927053F7648"
$IsoLog  = "/opt/fara/puf/puf_samples_isolation.txt"
$BaseLog = "/opt/fara/puf/puf_samples.txt"
$S6Log   = "/opt/fara/puf/puf_samples_stage6.txt"
$Ip      = ($Board -split "@")[-1]
$SSHOPT  = @("-o","BatchMode=yes","-o","ConnectTimeout=5","-o","StrictHostKeyChecking=no")

function Say($m) { Write-Host "[iso] $m" }
function Die($m) { Write-Host "[iso] !! $m"; exit 1 }
function Rsh($cmd) { ssh @SSHOPT $Board $cmd }
function WaitSsh([int]$TimeoutSec) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
    $null = ssh @SSHOPT $Board "echo up" 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Start-Sleep -Seconds 3
  }
  return $false
}

# --- 0) local artifact guard ------------------------------------------------
$Got = (Get-FileHash $FW -Algorithm SHA256).Hash
Say "archived OLD bitstream SHA256 = $Got"
if ($Got -ne $Expect) { Die "SHA256 MISMATCH -- expected $Expect (refusing to flash the wrong build)" }
if (-not (Test-Path $OVR)) { Die "missing drop-in: $OVR" }
if (-not (Test-Connection $Ip -Count 2 -Quiet -ErrorAction SilentlyContinue)) { Die "board not responding to ping" }
Say "guards OK -- archived old bitstream + isolation drop-in present, board reachable"

# --- 1) pollution guard -> isolation log (BEFORE any reboot) -----------------
Say "installing isolation drop-in -> PUF_LOG=$IsoLog"
Rsh "sudo mkdir -p /etc/systemd/system/fara-puf-sample.service.d" | Out-Null
scp @SSHOPT $OVR "${Board}:/tmp/" | Out-Null
# remove any other drop-in so this one is the only PUF_LOG override
Rsh "sudo rm -f /etc/systemd/system/fara-puf-sample.service.d/*.conf" | Out-Null
Rsh "sudo install -m0644 /tmp/fara-puf-sample-isolation.override.conf /etc/systemd/system/fara-puf-sample.service.d/iso-puf-log.conf && sudo systemctl daemon-reload" | Out-Null
$envline = (Rsh "systemctl show fara-puf-sample.service -p Environment") -join " "
Say "service Environment: $envline"
if ($envline -notmatch "puf_samples_isolation") { Die "drop-in did not take effect -- abort before any reboot" }
Say "pollution guard live: new samples -> $IsoLog"

# --- 2) deploy ARCHIVED OLD bitstream + cold reboot --------------------------
Say "deploying ARCHIVED OLD bitstream into /lib/firmware"
Rsh "sudo rm -f $IsoLog" | Out-Null          # ensure the isolation log starts empty
scp @SSHOPT $FW "${Board}:/tmp/" | Out-Null
Rsh "sudo cp -f /tmp/up_proj_wrapper.bit.bin /lib/firmware/up_proj_wrapper.bit.bin" | Out-Null
$boardSha = (Rsh "sha256sum /lib/firmware/up_proj_wrapper.bit.bin") -join " "
Say "board firmware sha256: $boardSha"
if ($boardSha -notmatch $Expect) { Die "board firmware SHA mismatch after copy" }

Say "cold-booting to load the old bitstream"
Rsh "sync; sudo systemctl reboot" 2>$null | Out-Null
Start-Sleep -Seconds 3
if (-not (WaitSsh 180)) { Die "SSH did not come back within 180s" }
Start-Sleep -Seconds 15

# --- 3) L0 sanity -----------------------------------------------------------
$state = (Rsh "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown") -join " "
Say "fpga_manager state = $($state.Trim())"
if ($state -notmatch "operating") { Die "PL not configured (L0 FAIL)" }
Say "L0 OK (PL operating)"
$isoCnt = ((Rsh "grep -vc '^#' $IsoLog 2>/dev/null || echo 0") -join " ").Trim()
Say "isolation log holds $isoCnt sample(s) after deploy boot (expect 1)"

# --- 4) cold-boot sampling loop ---------------------------------------------
Say "running $N cold boots (samples -> $IsoLog)"
Push-Location $Proj
try {
  python tools\puf_coldboot_loop.py --host $Ip --user ubuntu --n $N --log $IsoLog --out p0_out\stage6_isolation_samples.txt
  if ($LASTEXITCODE -ne 0) { Say "!! cold-boot loop reported failures (rc=$LASTEXITCODE)" }

  Say "computing stability stats"
  python tools\puf_stability.py --in p0_out\stage6_isolation_samples.txt --out-dir p0_out\stage6_isolation_stability --no-plot --threshold 0.01
  if ($LASTEXITCODE -ne 0) { Die "puf_stability.py failed" }

  $iso  = Get-Content (Join-Path $Proj "p0_out\stage6_isolation_stability\puf_stability.json") -Raw | ConvertFrom-Json
  $base = Get-Content (Join-Path $Proj "puf_out\puf_stability.json") -Raw | ConvertFrom-Json
  $s6   = Get-Content (Join-Path $Proj "p0_out\stage6_stability\puf_stability.json") -Raw | ConvertFrom-Json

  function Row($tag,$j){ Say ("{0,-9}: samples={1} stable={2} flip={3:N4} hd={4:N2} unan={5}" -f `
      $tag,$j.n_samples,$j.stable_bits,$j.flip_rate_mean,$j.hd_cross_boot_mean,$j.unan_union_hex) }
  Row "baseline"  $base
  Row "stage6"    $s6
  Row "isolation" $iso

  function Jac($x,$y){ $a=@($x|Sort-Object -Unique); $b=@($y|Sort-Object -Unique);
    $i=@($a|Where-Object{$b -contains $_}); $u=$a.Count+$b.Count-$i.Count
    if ($u -eq 0) { return 1 } ; return [math]::Round($i.Count/$u,3) }
  $jBB = Jac $base.stable_indices $iso.stable_indices
  $jBS = Jac $base.stable_indices $s6.stable_indices
  $jIS = Jac $iso.stable_indices  $s6.stable_indices
  Say "Jaccard(stable set): baseline~isolation=$jBB  baseline~stage6=$jBS  isolation~stage6=$jIS"

  if ($iso.unan_union_hex -eq $base.unan_union_hex) {
    Say ">>> ISOLATION == BASELINE (unan identical): the OLD build is reproducible across sessions."
    Say ">>> => the rebuilt Stage-5 bitstream genuinely changed the PUF response (H1 physical/routing)."
    exit 0
  } elseif ($jBB -ge 0.9) {
    Say ">>> ISOLATION ~= BASELINE (Jaccard $jBB): the OLD build is largely reproducible."
    Say ">>> => rebuilt bitstream changed the PUF behaviour at the routing level (H1)."
    exit 0
  } else {
    Say ">>> ISOLATION != BASELINE (Jaccard $jBB, unan differs): same bitstream is NOT bit-exact reproducible."
    Say ">>> => criterion too brittle at n=32; cross-session/temperature drift dominates (H2)."
    Say ">>> => fuzzy extractor (Stage 7) is the correct route; do not require bit-exact stable-set identity."
    exit 3
  }
} finally { Pop-Location }
