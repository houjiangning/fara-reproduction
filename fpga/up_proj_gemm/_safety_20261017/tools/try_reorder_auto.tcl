#-----------------------------------------------------------------------------
# try_reorder_auto.tcl -- 试 reorder_files -auto（GUI "Automatic Order" 的等价命令）
#
#   与 update_compile_order 的区别：
#     update_compile_order 只在"当前编译顺序模式"内重排序；
#     reorder_files -auto 才是把模式本身切回"自动"。
#   56-176 明确说 "manual compile order mode" —— 所以这才是对症的那一个。
#
#   判据：跑完后 generate_target 里 56-176 / 41-1726 是否消失。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

puts "== cmds matching *reorder* : [info commands *reorder*]"
puts "== cmds matching *compile_order* : [info commands *compile_order*]"

open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]

# 只有部分文件需要手动排；这里直接把模式拨回自动
foreach a [list \
  "reorder_files -auto -fileset sources_1" \
  "reorder_files -fileset sources_1 -auto" \
  "reorder_files -fileset sources_1 -enable_auto" \
  "reorder_files -fileset sources_1 -disable_auto {}" ] {
  if {[catch { eval $a } e]} {
    puts "== TRY '$a' -> FAIL: $e"
  } else {
    puts "== TRY '$a' -> OK"
  }
}

catch { update_compile_order -fileset sources_1 }
puts "== update_compile_order done"

puts "== reset_target"
reset_target all [get_files up_proj.bd]
puts "== generate_target (看 56-176 / 41-1726 还在不在)"
generate_target all [get_files up_proj.bd]
puts "== make_wrapper"
make_wrapper -files [get_files up_proj.bd] -top
puts "== REORDER_TEST_DONE"
close_project
