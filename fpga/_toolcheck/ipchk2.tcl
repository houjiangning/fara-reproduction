# Probe 2: enumerate all CONFIG.* params of floating_point v7.1 (Vivado 2022.2)
set rootdir [file normalize [file dirname [info script]]]
create_project -force fpchk "$rootdir/fpchk" -part xczu7ev-ffvc1156-2-e

proc dump_params {ip} {
  puts "=== PARAMS OF $ip ==="
  foreach p [lsort [list_property [get_ips $ip]]] {
    if {[string match "CONFIG.*" $p]} {
      if {[catch {set v [get_property $p [get_ips $ip]]}]} { set v "<unreadable>" }
      puts "$p = $v"
    }
  }
}

if {[catch {
  create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp_add_chk
  set_property -dict [list \
    CONFIG.Operation_Type {Add_Subtract} \
    CONFIG.A_Precision_Type {Single} \
    CONFIG.Result_Precision_Type {Single} \
    CONFIG.C_Rate {1} \
  ] [get_ips fp_add_chk]
} e]} { puts "ADD CREATE ERR: $e" }
dump_params fp_add_chk

if {[catch {
  create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name fp_mul_chk
  set_property -dict [list \
    CONFIG.Operation_Type {Multiply} \
    CONFIG.A_Precision_Type {Single} \
    CONFIG.Result_Precision_Type {Single} \
    CONFIG.C_Rate {1} \
  ] [get_ips fp_mul_chk]
} e]} { puts "MUL CREATE ERR: $e" }
dump_params fp_mul_chk

close_project
