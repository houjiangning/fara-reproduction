set rootdir [file normalize [file dirname [info script]]]
create_project -force fpchk "$rootdir/fpchk" -part xczu7ev-ffvc1156-2-e

foreach lat {4 5 6 8} {
  set name "fp_add_l${lat}"
  create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $name
  if {[catch {
    set_property -dict [list \
      CONFIG.Operation_Type {Add_Subtract} \
      CONFIG.A_Precision_Type {Single} \
      CONFIG.Result_Precision_Type {Single} \
      CONFIG.C_Rate {1} \
      CONFIG.Maximum_Latency {false} \
      CONFIG.C_Latency $lat \
    ] [get_ips $name]
    puts "LAT $lat -> C_Latency = [get_property CONFIG.C_Latency [get_ips $name]]  MaxLat=[get_property CONFIG.Maximum_Latency [get_ips $name]]"
  } e]} { puts "LAT $lat FAILED: $e" }
}

set name "fp_mul_l8"
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $name
if {[catch {
  set_property -dict [list \
    CONFIG.Operation_Type {Multiply} \
    CONFIG.A_Precision_Type {Single} \
    CONFIG.Result_Precision_Type {Single} \
    CONFIG.C_Rate {1} \
    CONFIG.Maximum_Latency {false} \
    CONFIG.C_Latency {8} \
  ] [get_ips $name]
  puts "MUL LAT 8 -> C_Latency = [get_property CONFIG.C_Latency [get_ips $name]]"
} e]} { puts "MUL LAT 8 FAILED: $e" }

close_project
