#-----------------------------------------------------------------------------
# gen_fp_ip.tcl —— 生成 GEMM 所需的两个 Xilinx 浮点 IP (floating_point v7.1)
#
# 用法(在 up_proj_gemm 工程内):
#   vivado -mode batch -source gen_fp_ip.tcl -tclargs <path/to/up_proj_gemm.xpr>
# 若省略参数，则在当前已打开的工程内执行。
#
# 生成两个 IP:
#   fp32_mul_ip  : Multiply,     Single, C_Rate=1, Latency = $MUL_LAT
#   fp32_add_ip  : Add_Subtract, Single, C_Rate=1, Latency = $ADD_LAT
#
# 注意: ADD_LAT / MUL_LAT 必须与 rtl/gemm_up_proj_core.sv 顶层参数 ADD_LAT / MUL_LAT
#       以及 rtl/fp32_add.sv / rtl/fp32_mul.sv 的 LAT 一致，否则硬件累加顺序与
#       流水线对齐会错位（本脚本末尾会回读实际 C_Latency 并告警）。
#-----------------------------------------------------------------------------
set ADD_LAT 4
set MUL_LAT 8

if {[llength $argv] > 0} {
  set xpr [lindex $argv 0]
  puts "== open_project $xpr"
  open_project $xpr
}

if {[catch {current_project} p] || $p eq ""} {
  error "gen_fp_ip.tcl: no project open. Pass the .xpr path as -tclargs argument."
}

# ---- 删除旧的同名 IP，避免参数不一致 ----
foreach nm {fp32_mul_ip fp32_add_ip} {
  if {[llength [get_ips -quiet $nm]] > 0} {
    puts "== remove old IP $nm"
    remove_files [get_files -quiet "${nm}.xci"]
    if {[llength [get_ips -quiet $nm]] > 0} { delete_ip -quiet $nm }
  }
}

# ---- fp32_mul_ip ----
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp32_mul_ip
set_property -dict [list \
  CONFIG.Operation_Type      {Multiply} \
  CONFIG.A_Precision_Type    {Single} \
  CONFIG.Result_Precision_Type {Single} \
  CONFIG.C_Rate              {1} \
  CONFIG.Maximum_Latency     {false} \
  CONFIG.C_Latency           $MUL_LAT \
  CONFIG.C_Mult_Usage        {Full_Usage} \
] [get_ips fp32_mul_ip]

# ---- fp32_add_ip ----
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp32_add_ip
set_property -dict [list \
  CONFIG.Operation_Type      {Add_Subtract} \
  CONFIG.A_Precision_Type    {Single} \
  CONFIG.Result_Precision_Type {Single} \
  CONFIG.C_Rate              {1} \
  CONFIG.Maximum_Latency     {false} \
  CONFIG.C_Latency           $ADD_LAT \
] [get_ips fp32_add_ip]

generate_target all [get_ips fp32_mul_ip fp32_add_ip]

# ---- 回读实际 C_Latency 并与 RTL 参数比对 ----
set got_mul [get_property CONFIG.C_Latency [get_ips fp32_mul_ip]]
set got_add [get_property CONFIG.C_Latency [get_ips fp32_add_ip]]
puts "== fp32_mul_ip  C_Latency = $got_mul  (RTL 期望 $MUL_LAT)"
puts "== fp32_add_ip  C_Latency = $got_add  (RTL 期望 $ADD_LAT)"

if {$got_mul != $MUL_LAT} {
  puts "!! WARNING: fp32_mul_ip 实际 C_Latency=$got_mul != 期望 $MUL_LAT"
  puts "!!          请把 rtl/gemm_up_proj_core.sv 的 MUL_LAT 改为 $got_mul，"
  puts "!!          并同步 rtl/fp32_mul.sv 与 sim/fp32_ops_behav.sv 的 LAT 默认值。"
}
if {$got_add != $ADD_LAT} {
  puts "!! WARNING: fp32_add_ip 实际 C_Latency=$got_add != 期望 $ADD_LAT"
  puts "!!          请把 rtl/gemm_up_proj_core.sv 的 ADD_LAT 改为 $got_add，"
  puts "!!          并同步 rtl/fp32_add.sv 与 sim/fp32_ops_behav.sv 的 LAT 默认值；"
  puts "!!          同时确认仍满足硬约束 G >= ADD_LAT+1。"
}
puts "== GEN_FP_IP_DONE"
