#-----------------------------------------------------------------------------
# enable_all_src.tcl -- 把所有设计源强制启用，并清掉存着的 TOP 让自动模式重认
#
#   线索链：
#     [filemgmt 20-742] 显式/存着的 TOP "up_proj_wrapper" 无法校验 -> 改自动挑顶层
#     [filemgmt 20-730] Could not find a top module in the fileset sources_1
#     ERROR 17-53       Top module not set for synthesis run
#   wrapper 文件其实**存在**，所以"找不到顶层"只能解释为：**该源文件被禁用了**
#   （我那次 reorder_files -disable_unused 干的好事，当时只核查了 4 个 BD 顶层）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]

puts "==== BEFORE ===="
puts "== TOP = [get_property TOP $fs]"
set wf [get_files -quiet *up_proj_wrapper.v]
puts "== wrapper files: $wf"
foreach f $wf {
  puts "   IS_ENABLED=[get_property IS_ENABLED $f]  USED_IN=[get_property USED_IN $f]"
}

# 1) 把 sources_1 里所有源文件强制启用
set n 0
foreach f [get_files -quiet -of_objects $fs] {
  if {[catch { set_property IS_ENABLED 1 $f } e]} { } else { incr n }
}
puts "== IS_ENABLED=1 已设置 $n 个文件"

# 2) 清掉存着的 TOP（自动层次模式会自行重新识别）
if {[catch { set_property TOP {} $fs } e2]} {
  puts "== 清 TOP 失败(可忽略): $e2"
} else {
  puts "== TOP 已清空，交给自动识别"
}

puts "==== AFTER ===="
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper IS_ENABLED=[get_property IS_ENABLED $f]"
}
puts "== TOP = [get_property TOP $fs]"
puts "== ENABLE_DONE"
close_project
