#-----------------------------------------------------------------------------
# probe_compile_order.tcl -- 找出"编译顺序 manual 模式"是哪个属性控制的
#
#   背景：generate_target 报
#     [filemgmt 56-176] Module references are not supported in manual compile
#                       order mode and will be ignored.
#   -> 必须把编译顺序模式切回 automatic，module reference 才会被解析。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

puts "==== PROJECT props（含 compile/order/ref 关键字） ===="
foreach p [lsort [list_property [current_project]]] {
  if {[string match -nocase *compile* $p] || [string match -nocase *order* $p] || [string match -nocase *ref* $p]} {
    catch { puts "  $p = [get_property $p [current_project]]" }
  }
}

puts "==== sources_1 FILESET props（含 compile/order/ref 关键字） ===="
foreach p [lsort [list_property [get_filesets sources_1]]] {
  if {[string match -nocase *compile* $p] || [string match -nocase *order* $p] || [string match -nocase *ref* $p] || [string match -nocase *mgmt* $p]} {
    catch { puts "  $p = [get_property $p [get_filesets sources_1]]" }
  }
}

puts "==== 尝试已知候选 ===="
foreach cand {compile_order_mode CompileOrderMode compile_order CompileOrder \
              source_mgmt_mode CONFIG.CompileOrder CONFIG.CompileOrderMode} {
  foreach obj [list [current_project] [get_filesets sources_1]] {
    if {[catch { set v [get_property $cand $obj] } e]} { continue }
    if {$v ne ""} { puts "  candidate $cand on [lindex $obj 0-ish] = $v" }
    puts "  candidate '$cand' on $obj = '$v'"
  }
}
puts "==== PROBE_DONE ===="
close_project
