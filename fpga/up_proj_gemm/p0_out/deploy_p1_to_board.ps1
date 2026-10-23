#=============================================================================
# deploy_p1_to_board.ps1 -- Stage 2 tail: push the FROZEN P1 bitstream + board
# test files to the ZCU106, install into /lib/firmware, then run
# board_test/p1_deploy_and_verify.sh (L0 -> L3 + PUF checks).
#
# Run on the PC:
#   powershell -ExecutionPolicy Bypass -File p0_out\deploy_p1_to_board.ps1
#
# Requires SSH access to ubuntu@192.168.1.200. Key auth + passwordless sudo
# are configured on this board, so everything runs non-interactively
# (no "ssh -t", which only added "Connection closed" noise).
#
# Artifact under test (Stage 6 rebuilt bitstream, includes the Stage 5
# puf_axi_lite AXI read-channel latch fix):
#   p0_out/up_proj_wrapper.bit.bin   19321332 B
#   SHA256 12659FEDB176E932B9D932CE7A77EA52B793F10738B96DB94788369C03D52C3B
# Previous frozen build (Stage 2/3, kept for reference):
#   SHA256 538CB36EAE9E9B383DC2BCFAF97831DFB3B5A9148BA38EEC848C3927053F7648
#   (backed up under p0_out/stage6_backup_20261015/bit/)
#=============================================================================
$ErrorActionPreference = "Stop"

$Board  = "ubuntu@192.168.1.200"
$Remote = "/tmp/p1b"
$Proj   = Split-Path $PSScriptRoot -Parent
$FW     = Join-Path $Proj "p0_out\up_proj_wrapper.bit.bin"
$BT     = Join-Path $Proj "board_test"

$Expect = "12659FEDB176E932B9D932CE7A77EA52B793F10738B96DB94788369C03D52C3B"
$Got = (Get-FileHash $FW -Algorithm SHA256).Hash
Write-Host "[pc] local bitstream SHA256 = $Got"
if ($Got -ne $Expect) {
    Write-Host "[pc] !! SHA256 MISMATCH -- expected $Expect"
    Write-Host "[pc] !! aborting: the file under test is not the frozen build"
    exit 1
}
Write-Host "[pc] SHA256 OK -- matches the frozen build"

Write-Host "[pc] reachability"
if (-not (Test-Connection 192.168.1.200 -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
    Write-Host "[pc] !! board not responding to ping"; exit 1
}

Write-Host "[pc] prep remote dir"
ssh $Board "mkdir -p $Remote"

Write-Host "[pc] scp bitstream"
scp $FW "${Board}:/tmp/"

Write-Host "[pc] scp board test files"
scp "$BT\p1_deploy_and_verify.sh" "$BT\puf_sample.c" "$BT\run_l3.sh" `
    "$BT\dma_probe.c" "$BT\gemm_probe.c" "$BT\gemm_dma_test.c" `
    "$BT\gemm_vectors_k8n1.bin" "$BT\gemm_vectors_k16n1.bin" `
    "$BT\gemm_vectors_k768n1.bin" "${Board}:$Remote/"

Write-Host "[pc] install into /lib/firmware, then run L0 -> L3 + PUF"
ssh $Board "sudo cp -f /tmp/up_proj_wrapper.bit.bin /lib/firmware/ && sudo sh $Remote/p1_deploy_and_verify.sh"
$rc = $LASTEXITCODE
Write-Host "[pc] board script exit = $rc  (0=PASS, 1=env, 3=L3 mismatch)"
exit $rc
