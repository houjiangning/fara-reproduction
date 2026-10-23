#-----------------------------------------------------------------------------
# fix_wrapper_src.tcl -- 恢复被禁用的顶层 wrapper 源文件
#
#   实测：
#     up_proj_wrapper.v  IS_ENABLED=0  (USED_IN 正常)
#     set_property IS_ENABLED 1  ->  [filemgmt 20-1379] read-only，改不了
#   原因：它是我那次 reorder_files -auto -disable_unused 顺手禁掉的
#         （当时只核查了 4 个 BD 顶层，漏了 wrapper）。
#   IS_ENABLED=0 -> [filemgmt 20-730] Could not find a top module
#               -> [Common 17-53] Top module not set for synthesis run
#
#   做法：把该文件条目从工程移除，再用 make_wrapper 重新加入（新加入即启用）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]

set wf [get_files -quiet *up_proj_wrapper.v]
puts "== BEFORE: wrapper 条目数=[llength $wf]"
foreach f $wf { puts "   $f  IS_ENABLED=[get_property IS_ENABLED $f]" }

if {[llength $wf] > 0} {
  remove_files -quiet $wf
  puts "== removed wrapper file entry"
}

make_wrapper -files [get_files up_proj.bd] -top
puts "== make_wrapper 重新生成 wrapper"

set wf2 [get_files -quiet *up_proj_wrapper.v]
puts "== AFTER: wrapper 条目数=[llength $wf2]"
foreach f $wf2 { puts "   IS_ENABLED=[get_property IS_ENABLED $f]" }
puts "== TOP = [get_property TOP $fs]"
puts "== WRAPFIX_DONE"
close_project
