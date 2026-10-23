#-----------------------------------------------------------------------------
# probe2.tcl -- 完整 dump 工程/文件集属性，定位"manual compile order"开关
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

puts "==== PROJECT ALL PROPS ===="
foreach p [lsort [list_property [current_project]]] {
  if {[catch { set v [get_property $p [current_project]] } e]} { continue }
  set lv [string tolower $p]
  if {[string match *order* $lv] || [string match *compile* $lv] || [string match *manual* $lv] || [string match *sourceset* $lv] || [string match *mgmt* $lv]} {
    puts "  P: $p = $v"
  }
}

puts "==== FILESET sources_1 ALL PROPS ===="
foreach p [lsort [list_property [get_filesets sources_1]]] {
  if {[catch { set v [get_property $p [get_filesets sources_1]] } e]} { continue }
  puts "  F: $p = $v"
}
puts "==== PROBE2_DONE ===="
close_project
