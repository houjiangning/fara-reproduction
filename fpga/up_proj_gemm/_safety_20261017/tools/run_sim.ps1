#=============================================================================
# run_sim.ps1 —— GEMM IP 自检一键跑：生成向量 → 编译 → 仿真 → 汇总
#
# 三个阶段：
#   Phase A 基线（gen_golden_vectors.py）：验证 GEMM 数据通路本身 bit-exact
#   Phase B FaR （gen_far_vectors.py）  ：验证 far_reroute 激活重路由 bit-exact
#                                        + FAR_HITS / FAR_PHASE 诊断寄存器
#   Phase AES （gen_aes_vectors.py）    ：验证 AES-256-CTR 加解密（NIST KAT +
#                                        随机向量 + 输出反压），PUF 方案 P0 阶段
#   Phase CRYPT（encrypt_vector_pack.py）：P2 空跑 —— X/b 明文直通 + W 段密文经
#                                        AES 解密后喂 GEMM，验证"加密对计算透明"
#   Phase PUF  （无向量生成）           ：P1 自检 —— Butterfly PUF 的采样 FSM / 多数
#                                        表决 / AXI-Lite 寄存器 / BD shim 端口
#
# 用法（PowerShell）：
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1            # GEMM 两阶段都跑
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only base # 只跑 GEMM 基线
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only far  # 只跑 GEMM FaR
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only aes  # 只跑 AES-CTR
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only crypt # P2 空跑验证
#   powershell -ExecutionPolicy Bypass -File tools\run_sim.ps1 -Only puf  # P1 PUF 自检
#
# 前置：python 与 numpy 可用；Vivado 2022.2 的 xvlog/xelab/xsim 存在。
#
# GEMM 编译集合（顺序无关）：
#   rtl/gemm_up_proj_core.sv   rtl/gemm_up_proj_axi_lite.sv
#   rtl/gemm_up_proj_top.sv    rtl/far_reroute.sv      <- FaR 引擎，缺了会 module not found
#   sim/fp32_ops_behav.sv      sim/tb_gemm_up_proj.sv
# **不加** rtl/fp32_mul.sv 与 rtl/fp32_add.sv —— 它们与行为模型同名，同时编译会冲突。
#
# AES 编译集合（与 GEMM 完全独立，另一套 TB）：
#   rtl/aes256_core.sv         rtl/aes256_ctr.sv       sim/tb_aes_ctr.sv
#=============================================================================
param(
  [ValidateSet("all", "base", "far", "aes", "crypt", "puf", "keymgr", "kdf", "fe", "wdec")]
  [string]$Only = "all"
)
$ErrorActionPreference = "Stop"

# ---- 按需修改：Vivado bin 目录 ----
$XilinxBin = "D:\Download\Xilinx_Vivado\Vivado\2022.2\bin"

$root = Split-Path -Parent $PSScriptRoot          # ...\up_proj_gemm
$rtl  = Join-Path $root "rtl"
$sim  = Join-Path $root "sim"
$work = Join-Path $root "sim_work"

# ---- Phase A 基线用例：K N M_TOTAL M_TILE G ADD_LAT MUL_LAT ----
# M_TOTAL/M_TILE/G/ADD_LAT/MUL_LAT 必须与 tb_gemm_up_proj.sv 的 localparam 一致。
$baseCases = @(
  @(16, 2, 64, 16, 8, 4, 8),   # 基线：K 被 G 整除
  @(13, 4, 64, 16, 8, 4, 8),   # K 不被 G 整除 + 多 token + 多趟
  @(5,  4, 64, 16, 8, 4, 8),   # K < G：尾部部分和链无乘积
  @(8,  1, 64, 16, 8, 4, 8)    # K == G：单 token
)

# ---- Phase B FaR 用例：K N M_TOTAL M_TILE G ADD_LAT MUL_LAT N_FAR DIV DEADZERO ----
# 硬约束：2*n_far <= K（dead 占 [0,n_far)，A 占 [K-n_far,K)，两者不能相交）。
# DEADZERO=1 时把 dead 通道激活压到 ~1e-7，用来把「输出守恒误差」做成有意义的数字。
$farCases = @(
  @(16, 2, 64, 16, 8, 4, 8, 4, 2, 0),   # 4 条条目，dead 稠密 → 只验数据通路 bit-exact
  @(32, 4, 64, 16, 8, 4, 8, 8, 2, 1),   # 8 条条目 + dead≈0 → 同时验守恒
  @(24, 3, 64, 16, 8, 4, 8, 6, 2, 0)    # 6 条条目，K 非 2 的幂
)

New-Item -ItemType Directory -Force -Path $work | Out-Null
Push-Location $work

try {
  #=========================================================================
  # AES-CTR 自检分支（与 GEMM 流程完全独立，编译集合不同）
  #   退出码：0=全过  非0=失败
  #=========================================================================
  if ($Only -eq "aes") {
    Write-Host "== [AES/3] 生成向量（NIST KAT + 随机）" -ForegroundColor Cyan
    & python "$root\tools\gen_aes_vectors.py" --mode all `
        --n-blk 64 `
        --out "$sim\aes_vectors.mem" `
        --kat-out "$sim\aes_kat.mem" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gen_aes_vectors.py 失败（见上方输出）" }

    Copy-Item "$sim\aes_kat.mem"     "$work\aes_kat.mem"     -Force
    Copy-Item "$sim\aes_vectors.mem" "$work\aes_vectors.mem" -Force

    Write-Host ""
    Write-Host "== [AES/3] 编译 RTL + TB (xvlog)" -ForegroundColor Cyan
    & "$XilinxBin\xvlog.bat" -sv `
        "$rtl\aes256_sbox.sv" `
        "$rtl\aes256_core.sv" `
        "$rtl\aes256_ctr.sv" `
        "$sim\tb_aes_ctr.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }

    & "$XilinxBin\xelab.bat" tb_aes_ctr -s tb_aes | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }

    Write-Host ""
    Write-Host "== [AES/3] 仿真 (xsim)" -ForegroundColor Cyan
    $out = & "$XilinxBin\xsim.bat" tb_aes -runall 2>&1 | Out-String
    $out -split "`r?`n" |
      Where-Object { $_ -match "Test |keystream|BAD|PASS|FAIL|超时|tlast|n_blk|key_ready|bit-exact|发完|====" } |
      ForEach-Object { Write-Host $_ }

    Write-Host ""
    if ($out -match "=== PASS ===") {
      Write-Host "==== AES-256-CTR 全部通过 ====" -ForegroundColor Green
    } else {
      Write-Host "==== AES-256-CTR 失败 ====" -ForegroundColor Red
      exit 1
    }
    return
  }

  if ($Only -eq "keymgr") {
    Write-Host "== [KEYMGR] 编译 RTL + TB (xvlog)" -ForegroundColor Cyan
    & "$XilinxBin\xvlog.bat" -sv "$rtl\key_mgr.sv" "$sim\tb_key_mgr.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }
    & "$XilinxBin\xelab.bat" tb_key_mgr -s tb_keymgr | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }
    $out = & "$XilinxBin\xsim.bat" tb_keymgr -runall 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match "PASS|FAIL|====" } | ForEach-Object { Write-Host $_ }
    if ($out -match "=== PASS ===") { Write-Host "==== key_mgr 通过 ====" -ForegroundColor Green }
    else { Write-Host "==== key_mgr 失败 ====" -ForegroundColor Red; exit 1 }
    return
  }

  if ($Only -eq "kdf") {
    Write-Host "== [KDF] 生成 golden 向量" -ForegroundColor Cyan
    & python "$root\tools\gen_kdf_vectors.py" --out "$sim\kdf_vectors.mem" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gen_kdf_vectors.py 失败" }
    Copy-Item "$sim\kdf_vectors.mem" "$work\kdf_vectors.mem" -Force
    & "$XilinxBin\xvlog.bat" -sv "$rtl\sha256_kdf.sv" "$sim\tb_sha256_kdf.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }
    & "$XilinxBin\xelab.bat" tb_sha256_kdf -s tb_kdf | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }
    $out = & "$XilinxBin\xsim.bat" tb_kdf -runall 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match "PASS|FAIL|向量|====" } | ForEach-Object { Write-Host $_ }
    if ($out -match "=== PASS ===") { Write-Host "==== sha256_kdf 通过 ====" -ForegroundColor Green }
    else { Write-Host "==== sha256_kdf 失败 ====" -ForegroundColor Red; exit 1 }
    return
  }

  if ($Only -eq "fe") {
    Write-Host "== [FE] 生成 golden 向量" -ForegroundColor Cyan
    & python "$root\tools\gen_fe_vectors.py" --out "$sim\fe_vectors.mem" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gen_fe_vectors.py 失败" }
    Copy-Item "$sim\fe_vectors.mem" "$work\fe_vectors.mem" -Force
    & "$XilinxBin\xvlog.bat" -sv "$rtl\fuzzy_extract.sv" "$sim\tb_fuzzy_extract.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }
    & "$XilinxBin\xelab.bat" tb_fuzzy_extract -s tb_fe | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }
    $out = & "$XilinxBin\xsim.bat" tb_fe -runall 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match "PASS|FAIL|vec |反例|====" } | ForEach-Object { Write-Host $_ }
    if ($out -match "=== PASS ===") { Write-Host "==== fuzzy_extract 通过 ====" -ForegroundColor Green }
    else { Write-Host "==== fuzzy_extract 失败 ====" -ForegroundColor Red; exit 1 }
    return
  }

  if ($Only -eq "wdec") {
    Write-Host "== [WDEC] 生成输入/期望向量" -ForegroundColor Cyan
    & python "$root\tools\gen_wdec_vectors.py" --outdir "$sim" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gen_wdec_vectors.py 失败" }
    Copy-Item "$sim\wdec_in.mem","$sim\wdec_exp.mem","$sim\wdec_cfg.mem" "$work\" -Force
    & "$XilinxBin\xvlog.bat" -sv "$rtl\aes256_sbox.sv" "$rtl\aes256_core.sv" "$rtl\aes256_ctr.sv" "$rtl\wdec_stream.sv" "$sim\tb_wdec_stream.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }
    & "$XilinxBin\xelab.bat" tb_wdec_stream -s tb_wdec | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }
    $out = & "$XilinxBin\xsim.bat" tb_wdec -runall 2>&1 | Out-String
    $out -split "`r?`n" | Where-Object { $_ -match "PASS|FAIL|beat|====" } | ForEach-Object { Write-Host $_ }
    if ($out -match "=== PASS ===") { Write-Host "==== wdec_stream 通过 ====" -ForegroundColor Green }
    else { Write-Host "==== wdec_stream 失败 ====" -ForegroundColor Red; exit 1 }
    return
  }

  if ($Only -eq "puf") {
    #-----------------------------------------------------------------------
    # P1 自检：Butterfly PUF 的 FSM / 多数表决 / 寄存器 / BD shim
    # 编译集合 = rtl 的 PUF 模块 + **sim/bpuf_cell_behav.sv**（行为模型）
    # **不含** rtl/bpuf_cell.sv（同名模块会冲突）—— 与 fp32 的既有约定一致。
    #-----------------------------------------------------------------------
    Write-Host "== [PUF/2] 编译 RTL + 行为模型 + TB (xvlog)" -ForegroundColor Cyan
    & "$XilinxBin\xvlog.bat" -sv `
        "$sim\bpuf_cell_behav.sv" `
        "$rtl\bpuf_array.sv" `
        "$rtl\bpuf_ctrl.sv" `
        "$rtl\puf_axi_lite.sv" `
        "$rtl\puf_bd.v" `
        "$sim\tb_bpuf.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }

    & "$XilinxBin\xelab.bat" tb_bpuf -s tb_puf | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }

    Write-Host ""
    Write-Host "== [PUF/2] 仿真 (xsim)" -ForegroundColor Cyan
    $out = & "$XilinxBin\xsim.bat" tb_puf -runall 2>&1 | Out-String
    $out -split "`r?`n" |
      Where-Object { $_ -match "T\d |PASS|FAIL|OK|BAD|VERSION|NBITS|NWORDS|STATUS|STABLE|UNAN|采样|超时|====" } |
      ForEach-Object { Write-Host $_ }

    Write-Host ""
    if ($out -match "=== PASS ===") {
      Write-Host "==== PUF 自检通过 ====" -ForegroundColor Green
    } else {
      Write-Host "==== PUF 自检失败 ====" -ForegroundColor Red
      exit 1
    }
    return
  }

  if ($Only -eq "crypt") {
    #-----------------------------------------------------------------------
    # P2 空跑：X/b 明文直通 + W 段密文经 AES 解密 → GEMM，比对原 golden
    #   1) 先生成明文向量（与 base 用例同参数，保证 golden 一致）
    #   2) 只加密 W 段 → crypt_vectors.mem
    #   3) 编译 aes256_* + gemm_* + tb_gemm_crypt，跑仿真
    # 注意：编译集合**不含** fp32_mul/fp32_add（与行为模型冲突），
    #       但要含 sim/fp32_ops_behav.sv 给 GEMM 用。
    #-----------------------------------------------------------------------
    Write-Host "== [CRYPT/4] 生成明文向量（与 base 用例同参数）" -ForegroundColor Cyan
    & python "$root\tools\gen_golden_vectors.py" `
        --k 16 --n 2 --m-total 64 --m-tile 16 --g 8 --add-lat 4 --mul-lat 8 `
        --out "$sim\golden_vectors.mem" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gen_golden_vectors.py 失败" }

    Write-Host ""
    Write-Host "== [CRYPT/4] 加密 W 段" -ForegroundColor Cyan
    & python "$root\tools\encrypt_vector_pack.py" `
        --in "$sim\golden_vectors.mem" `
        --out "$sim\crypt_vectors.mem" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "encrypt_vector_pack.py 失败" }

    Copy-Item "$sim\crypt_vectors.mem"  "$work\crypt_vectors.mem"  -Force
    # TB 会读明文向量做 AES 输出的独立比对，必须一并刷新到 sim_work。
    # （sim_work 在各分支间共享；不刷新会被上一个分支留下的、K/N 不同的
    #   golden_vectors.mem 污染 —— 实测踩过。）
    Copy-Item "$sim\golden_vectors.mem" "$work\golden_vectors.mem" -Force

    Write-Host ""
    Write-Host "== [CRYPT/4] 编译 RTL + TB (xvlog)" -ForegroundColor Cyan
    & "$XilinxBin\xvlog.bat" -sv `
        "$rtl\aes256_sbox.sv" `
        "$rtl\aes256_core.sv" `
        "$rtl\aes256_ctr.sv" `
        "$rtl\gemm_up_proj_core.sv" `
        "$rtl\gemm_up_proj_axi_lite.sv" `
        "$rtl\gemm_up_proj_top.sv" `
        "$rtl\far_reroute.sv" `
        "$sim\fp32_ops_behav.sv" `
        "$sim\tb_gemm_crypt.sv" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }

    & "$XilinxBin\xelab.bat" tb_gemm_crypt -s tb_crypt | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }

    Write-Host ""
    Write-Host "== [CRYPT/4] 仿真 (xsim)" -ForegroundColor Cyan
    $out = & "$XilinxBin\xsim.bat" tb_crypt -runall 2>&1 | Out-String
    $out -split "`r?`n" |
      Where-Object { $_ -match "PASS|FAIL|FATAL|phase |分段|核对|GEMM|AES |bit-exact|完成|BAD|====" } |
      ForEach-Object { Write-Host $_ }

    Write-Host ""
    if ($out -match "=== PASS ===") {
      Write-Host "==== P2 空跑通过：加密对 GEMM 计算透明 ====" -ForegroundColor Green
    } else {
      Write-Host "==== P2 空跑失败 ====" -ForegroundColor Red
      exit 1
    }
    return
  }

  #=========================================================================
  # [1/3] 编译：RTL + 行为模型 + TB
  #=========================================================================
  Write-Host "== [1/3] 编译 RTL + TB (xvlog)" -ForegroundColor Cyan
  & "$XilinxBin\xvlog.bat" -sv `
      "$rtl\gemm_up_proj_core.sv" `
      "$rtl\gemm_up_proj_axi_lite.sv" `
      "$rtl\gemm_up_proj_top.sv" `
      "$rtl\far_reroute.sv" `
      "$sim\fp32_ops_behav.sv" `
      "$sim\tb_gemm_up_proj.sv" | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "xvlog 失败" }

  & "$XilinxBin\xelab.bat" tb_gemm_up_proj -s tb_sim | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "xelab 失败" }

  $npass = 0
  $nfail = 0
  $failNames = @()

  #=========================================================================
  # [2/3] Phase A：基线用例
  #=========================================================================
  if ($Only -ne "far") {
    foreach ($c in $baseCases) {
      $k, $n, $mt, $mtl, $g, $al, $ml = $c
      Write-Host ""
      Write-Host "== [2/3] 基线 K=$k N=$n M_TOTAL=$mt M_TILE=$mtl G=$g" -ForegroundColor Cyan

      & python "$root\tools\gen_golden_vectors.py" `
          --k $k --n $n --m-total $mt --m-tile $mtl --g $g --add-lat $al --mul-lat $ml | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "gen_golden_vectors.py 失败" }

      Copy-Item "$sim\golden_vectors.mem" "$work\golden_vectors.mem" -Force

      Write-Host "== [3/3] 仿真 (xsim)" -ForegroundColor Cyan
      $out = & "$XilinxBin\xsim.bat" tb_sim -runall 2>&1 | Out-String
      $out -split "`r?`n" |
        Where-Object { $_ -match "PASS|FAIL|FATAL|向量头|STATUS" } |
        ForEach-Object { Write-Host $_ }

      if ($out -match "=== PASS ===") { $npass++ }
      else { $nfail++; $failNames += "base K=$k N=$n" }
    }
  }

  #=========================================================================
  # [3/3] Phase B：FaR 用例（+FARMAP 打开激活重路由）
  #=========================================================================
  if ($Only -ne "base") {
    foreach ($c in $farCases) {
      $k, $n, $mt, $mtl, $g, $al, $ml, $nf, $dv, $dz = $c
      Write-Host ""
      Write-Host "== [2/3] FaR  K=$k N=$n n_far=$nf div=$dv deadzero=$dz" -ForegroundColor Cyan

      # 直接写进 sim_work，.fmap 与 .json 会自动落在同目录同名位置
      $gargs = @("$root\tools\gen_far_vectors.py",
                 "--k", $k, "--n", $n, "--m-total", $mt, "--m-tile", $mtl,
                 "--g", $g, "--add-lat", $al, "--mul-lat", $ml,
                 "--n-far", $nf, "--div", $dv,
                 "--out", "$work\far_vectors.mem")
      if ($dz -eq 1) { $gargs += "--dead-zero" }
      & python @gargs | Out-Host
      if ($LASTEXITCODE -ne 0) { throw "gen_far_vectors.py 失败" }

      Write-Host "== [3/3] 仿真 (xsim, FARMAP 已开)" -ForegroundColor Cyan
      # Windows 关键坑：xsim.bat 经 loader.bat 转发时会按 '=' 拆分命令行参数，
      # 直接写 `-testplusarg "VEC=far_vectors.mem"` 会被拆成 VEC / far_vectors.mem
      # 两个 token，xsim 报 "Expected a switch but found f"。
      # 解法：把 plusarg 写进 -f 响应文件，由 xsim 自己解析，'=' 得以保留。
      Set-Content -Path "$work\xsim_args.txt" -Encoding ascii -Value @(
        '-testplusarg "VEC=far_vectors.mem"',
        '-testplusarg "FARMAP=far_vectors.fmap"'
      )
      $out = & "$XilinxBin\xsim.bat" tb_sim -f xsim_args.txt -runall 2>&1 | Out-String
      $out -split "`r?`n" |
        Where-Object { $_ -match "PASS|FAIL|FATAL|向量头|STATUS|FAR_HITS|FAR_PHASE|FaRMap" } |
        ForEach-Object { Write-Host $_ }

      if ($out -match "=== PASS ===") { $npass++ }
      else { $nfail++; $failNames += "far K=$k N=$n n_far=$nf" }
    }
  }

  #=========================================================================
  # 汇总
  #=========================================================================
  Write-Host ""
  if ($nfail -eq 0) {
    Write-Host "==== 全部通过：$npass 组 bit-exact ====" -ForegroundColor Green
  } else {
    Write-Host "==== 失败 $nfail 组（通过 $npass 组）====" -ForegroundColor Red
    foreach ($fn in $failNames) { Write-Host "     - $fn" -ForegroundColor Red }
    exit 1
  }
}
finally {
  Pop-Location
}
