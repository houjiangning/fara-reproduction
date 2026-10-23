#-----------------------------------------------------------------------------
# diag_bd_topology.tcl -- 只读诊断：打印当前 Block Design 的拓扑
#   * 不开 GUI 也能跑：vivado -mode batch -source tools/diag_bd_topology.tcl
#   * 只读，不修改、不保存
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
}

open_bd_design [get_files -quiet up_proj.bd]

puts "==== CELLS ===="
foreach c [get_bd_cells -quiet *] { puts "  $c" }

puts "==== SMARTConnect ===="
foreach p [list CONFIG.NUM_SI CONFIG.NUM_MI] {
  catch { puts "  smartconnect_0 $p = [get_property $p [get_bd_cells smartconnect_0]]" }
}

puts "==== INTF PINS ===="
foreach p [get_bd_intf_pins -quiet *] {
  set dir [get_property MODE $p]
  set proto [get_property VLNV $p]
  puts "  $p   [$dir]  $proto"
}

puts "==== INTF NETS ===="
foreach n [get_bd_intf_nets -quiet *] {
  set pins [get_bd_intf_pins -quiet -of_objects $n]
  puts "  $n : $pins"
}

puts "==== plain NETS on puf_bd_0 (resp/unan) ===="
foreach p [get_bd_pins -quiet -of_objects [get_bd_cells puf_bd_0]] {
  puts "  pin $p"
}

puts "==== ADDR SEGS ===="
foreach s [get_bd_addr_segs -quiet *] {
  catch { puts "  $s  offset=[get_property OFFSET $s] range=[get_property RANGE $s]" }
}

puts "==== DONE ===="
if {$_we_opened} { close_project }
