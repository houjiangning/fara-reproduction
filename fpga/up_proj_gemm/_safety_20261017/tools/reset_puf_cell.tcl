#-----------------------------------------------------------------------------
# reset_puf_cell.tcl -- 把 puf_bd_0 这个 module-reference cell 彻底拆掉并保存
#
# 为什么需要它：
#   rtl/puf_bd.v 新增端口后，BD 里既有的 puf_bd_0 **无法**通过
#   update_module_reference 刷新（该命令在本版本上静默失败 RC=1/E 空）。
#   module reference 的端口表在"打包成 IP"（up_proj_puf_bd_0_0.xci + 生成的 .v）
#   时就固化了；只在会话中途删 cell 重建仍会拿到旧表。
#   所以要：① 本项目会话内删 cell → 保存 → 关工程；② 由外部删掉生成 IP 目录；
#   ③ 之后再让 add_puf_dec_to_bd.tcl 全新创建该 cell。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
open_bd_design [get_files -quiet up_proj.bd]

puts "== RESET: puf_bd_0 before = [llength [get_bd_cells -quiet puf_bd_0]]"

foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet puf_bd_0/s_axi]] {
  puts "== RESET: deleting intf net $n"
  catch { delete_bd_objs $n }
}
if {[llength [get_bd_cells -quiet puf_bd_0]] > 0} {
  catch { delete_bd_objs [get_bd_cells puf_bd_0] }
  puts "== RESET: deleted puf_bd_0 cell"
}

save_bd_design
puts "== RESET: saved bd"
close_project
puts "== RESET: closed project"
puts "== RESET_DONE"
