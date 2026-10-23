#=============================================================================
# rebuild_bitstream.ps1 -- rebuild after an RTL edit
#
#   vivado batch:  reset synth/impl -> synth -> impl -> write_bitstream
#   bootgen:       .bit -> .bit.bin (fpga_manager only accepts .bit.bin)
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File tools\rebuild_bitstream.ps1
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 decodes .ps1 using the
#       system codepage (GBK) when no UTF-8 BOM is present, so non-ASCII comments
#       get mis-decoded and can swallow newlines / break the parse. run_sim.ps1
#       happens to carry a BOM; this script must not depend on that.
#
# Prereq: the Vivado project must NOT be open in the GUI (batch mode locks it).
# Output: up_proj_gemm.runs\impl_1\up_proj_wrapper.bit / .bit.bin
#=============================================================================
$ErrorActionPreference = "Stop"

# ---- edit if needed: Vivado bin directory ----
$XilinxBin = "D:\Download\Xilinx_Vivado\Vivado\2022.2\bin"

$root = Split-Path -Parent $PSScriptRoot          # ...\up_proj_gemm
$impl = Join-Path $root "up_proj_gemm.runs\impl_1"

Write-Host "== [1/2] vivado: synth + impl + write_bitstream" -ForegroundColor Cyan
& "$XilinxBin\vivado.bat" -mode batch -nojournal `
    -source "$root\tools\rebuild_bitstream.tcl" `
    -log "$root\rebuild_bitstream.log"
if ($LASTEXITCODE -ne 0) { throw "vivado failed, see $root\rebuild_bitstream.log" }

Write-Host ""
Write-Host "== [2/2] bootgen: .bit -> .bit.bin" -ForegroundColor Cyan
Push-Location $impl
try {
  # bootgen -image takes a relative name, so the bif must live in impl_1 and be
  # invoked from there. Rewrite it every run so a missing up_proj.bif cannot fail
  # the build. Single-quoted here-string: no interpolation, no brace parsing.
  $bif = @'
// up_proj GEMM full bitstream -> .bit.bin for Linux fpga_manager (flags=0, full config)
all:
{
    up_proj_wrapper.bit
}
'@
  Set-Content -Path "up_proj.bif" -Value $bif -Encoding ASCII
  & "$XilinxBin\bootgen.bat" -image up_proj.bif -arch zynqmp `
      -o up_proj_wrapper.bit.bin -w
  if ($LASTEXITCODE -ne 0) { throw "bootgen failed" }
} finally {
  Pop-Location
}

Write-Host ""
Get-ChildItem (Join-Path $impl "up_proj_wrapper.bit"), (Join-Path $impl "up_proj_wrapper.bit.bin") |
  Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize

# ---- verification -----------------------------------------------------------
# NOTE: with the BD on GLOBAL synthesis (synth_checkpoint_mode none, set by
# tools\fix_enable_rtl.tcl) the GEMM is synthesized IN-CONTEXT inside synth_1.
# There is deliberately NO module-reference OOC checkpoint any more, so a
# missing .dcp is the EXPECTED state -- not a failure. The authoritative
# in-context gate runs inside rebuild_bitstream.tcl ([2] GEMM wrapper cells).
Write-Host "== [verify] in-context synthesis (no OOC checkpoint expected)" -ForegroundColor Cyan
$dcp = Join-Path $root "up_proj_gemm.gen\sources_1\bd\up_proj\ip\up_proj_gemm_up_proj_bd_0_0\up_proj_gemm_up_proj_bd_0_0.dcp"
if (Test-Path $dcp) {
  Write-Host "   OOC dcp : present (unexpected -- global synthesis did not take effect)" -ForegroundColor Yellow
} else {
  Write-Host "   OOC dcp : absent (expected with global synthesis)"
}
$log = Join-Path $root "rebuild_bitstream.log"
if (Test-Path $log) {
  if (Select-String -Path $log -Pattern "in-context gate OK" -Quiet) {
    Write-Host "   in-context gate: OK" -ForegroundColor Green
  } else {
    Write-Host "   in-context gate: NOT CONFIRMED -- check $log" -ForegroundColor Red
  }
}

Write-Host "== [verify] new .bit / .bit.bin" -ForegroundColor Cyan
$bin = Join-Path $impl "up_proj_wrapper.bit.bin"
if (Test-Path $bin) {
  $f = Get-Item $bin
  Write-Host ("   .bit.bin: {0} bytes  {1}" -f $f.Length, $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
  (Get-FileHash $bin -Algorithm SHA256).Hash
  Write-Host "   (previous pre-FaR bitstream was 19,321,332 bytes / B429EDCF...EB06)"
  Write-Host "   A DIFFERENT SHA256 means the FaR RTL is really in this bitstream."
}
