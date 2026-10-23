# Scratch check: confirm floating_point v7.1 parameter names / legal latencies (Vivado 2022.2)
set rootdir [file normalize [file dirname [info script]]]
create_project -force fpchk "$rootdir/fpchk" -part xczu7ev-ffvc1156-2-e

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp_add_chk
set_property -dict [list \
  CONFIG.Operation_Type {Add_Subtract} \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.Result_Precision_Type {Single} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.C_Latency {4} \
  CONFIG.C_Rate {1} \
] [get_ips fp_add_chk]
puts "=== ADD IP PARAMS ==="
foreach p [lsort [list_property [get_ips fp_add_chk]]] {
  if {[string match "CONFIG.*" $p]} { puts "$p = [get_property $p [get_ips fp_add_chk]]" }
}

create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp_mul_chk
set_property -dict [list \
  CONFIG.Operation_Type {Multiply} \
  CONFIG.A_Precision_Type {Single} \
  CONFIG.C_A_Exponent_Width {8} \
  CONFIG.C_A_Fraction_Width {24} \
  CONFIG.B_Precision_Type {Single} \
  CONFIG.C_B_Exponent_Width {8} \
  CONFIG.C_B_Fraction_Width {24} \
  CONFIG.Result_Precision_Type {Single} \
  CONFIG.C_Result_Exponent_Width {8} \
  CONFIG.C_Result_Fraction_Width {24} \
  CONFIG.C_Latency {4} \
  CONFIG.C_Rate {1} \
] [get_ips fp_mul_chk]
puts "=== MUL IP PARAMS ==="
foreach p [lsort [list_property [get_ips fp_mul_chk]]] {
  if {[string match "CONFIG.*" $p]} { puts "$p = [get_property $p [get_ips fp_mul_chk]]" }
}

generate_target all [get_ips fp_add_chk fp_mul_chk]
puts "=== GENERATE OK ==="
report_utilization -file "$rootdir/fpchk_util.txt"
close_project
