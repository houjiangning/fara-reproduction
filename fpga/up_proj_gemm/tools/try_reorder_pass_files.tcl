#-----------------------------------------------------------------------------
# try_reorder_pass_files.tcl -- reorder_files -auto 的正确用法（要传文件列表）
#
#   help 原文：
#     reorder_files [-fileset <arg>] ... [-auto] [-disable_unused] <files>...
#     [-auto] Automatically re-orders the given fileset
#     例: reorder_files -auto -disable_unused
#   我上次只给了 -fileset、没给 <files>，所以命令"通过但空转"。
#
#   本脚本依次试两种形态，每种后面立刻 generate_target，看 41-1726 是否消失：
#     A: reorder_files -auto -fileset sources_1 <全部源文件>
#     B: reorder_files -auto -disable_unused -fileset sources_1 <全部源文件>
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

set fs   [get_filesets sources_1]
set allf [get_files -quiet -of_objects $fs]
puts "== sources_1 文件数 = [llength $allf]"

puts "==== TRIAL A ===="
if {[catch { reorder_files -auto -fileset sources_1 {*}$allf } e]} {
  puts "  A-FAIL: $e"
} else {
  puts "  A-OK"
}
catch { update_compile_order -fileset sources_1 }
reset_target all [get_files up_proj.bd]
puts "  A: generate_target ..."
generate_target all [get_files up_proj.bd]
puts "==== TRIAL A done ===="

puts "==== TRIAL B ===="
if {[catch { reorder_files -auto -disable_unused -fileset sources_1 {*}$allf } e2]} {
  puts "  B-FAIL: $e2"
} else {
  puts "  B-OK"
}
catch { update_compile_order -fileset sources_1 }
reset_target all [get_files up_proj.bd]
puts "  B: generate_target ..."
generate_target all [get_files up_proj.bd]
puts "==== TRIAL B done ===="

puts "==== 4 个 BD 顶层的 IS_ENABLED（B 用了 -disable_unused，可能把它们禁掉）===="
foreach f {gemm_up_proj_bd.v puf_bd.v puf_dec_bd.v axis_route2.v} {
  set ff [get_files -quiet *$f]
  if {[llength $ff] > 0} {
    puts "== $f IS_ENABLED=[get_property IS_ENABLED $ff]"
  } else {
    puts "!! $f 没了"
  }
}
puts "==== PASSFILES_DONE ===="
close_project
