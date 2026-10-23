#-----------------------------------------------------------------------------
# probe_reorder.tcl -- 看清 reorder_files 的真实选项 & compile order 报告
#   reorder_files -auto 被接受但无效；-disable_auto 又不存在 -> 用法不对。
#   这里把 -help 文本打出来，找"切回自动"的正确写法。只读。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

puts "==== reorder_files -help ===="
set rc [catch { reorder_files -help } h]
puts "rc=$rc"
puts "$h"

puts "==== report_compile_order -help ===="
set rc2 [catch { report_compile_order -help } h2]
puts "rc2=$rc2"
puts "$h2"

puts "==== report_compile_order 实际输出（前 1500 字符）===="
if {[catch { set r [report_compile_order -fileset sources_1] } e3]} {
  puts "report failed: $e3"
} else {
  puts [string range $r 0 1500]
}
puts "==== PROBE_END ===="
close_project
