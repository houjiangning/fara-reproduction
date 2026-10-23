#-----------------------------------------------------------------------------
# repair_module_refs.tcl -- 干净会话里重建 BD module-reference 解析
#
# 背景（2026-10-16）：
#   连续两次全量构建都在 generate_target 阶段报
#     [BD 41-1726] Unable to resolve module-source for block '/gemm_up_proj_bd_0'
#                  '/puf_bd_0' '/puf_dec_bd_0' '/axis_route2_0'
#     [filemgmt 56-587] Failed to resolve reference ...
#   而**历史成功**的构建日志（puf_p1_rebuild_20261014.log）里 41-1726/56-587 是 0 条。
#   文件集本身是好的（4 个 .v 顶层都在册、IS_ENABLED=1、source_mgmt_mode=All、
#   TOP=up_proj_wrapper），所以问题在 Vivado 对 module reference 的**内部解析
#   缓存**与落盘的工程不同步 —— 很可能是我在集成脚本里对 puf_bd.v 做
#   remove_files/add_files、以及删掉生成的 IP 外壳所致。
#
# 本脚本：在**无其它 Vivado 进程**的干净会话里，对全部 4 个 module-reference
#   cell 逐个 update_module_reference，然后 validate + 保存 + 关闭，把状态落盘。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
open_bd_design [get_files -quiet up_proj.bd]

puts "==== cells in BD ===="
foreach c [get_bd_cells -quiet *] { puts "  $c" }

foreach name {gemm_up_proj_bd_0 puf_bd_0 puf_dec_bd_0 axis_route2_0} {
  set c [get_bd_cells -quiet $name]
  if {[llength $c] == 0} {
    puts "!! cell $name 不存在"
    continue
  }
  set rc [catch { update_module_reference $c } e]
  puts "== update_module_reference $name : rc=$rc  e=$e"
  puts "    pins = [llength [get_bd_pins -quiet -of_objects $c]]"
}

puts "==== validate ===="
if {[catch { validate_bd_design } e]} {
  puts "!! validate failed: $e"
} else {
  puts "== validate ok"
}

save_bd_design
puts "== save_bd_design ok"
close_project
puts "== REPAIR_DONE"
