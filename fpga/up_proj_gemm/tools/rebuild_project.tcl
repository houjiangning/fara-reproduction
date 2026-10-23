#-----------------------------------------------------------------------------
# rebuild_project.tcl -- 核武器：在**全新工程**里重建设计（不碰坏掉的 .xpr）
#
# 为什么：
#   旧 up_proj_gemm.xpr 的文件集状态被我自己的脚本连环改坏
#   （update_compile_order 偷换 TOP / 显式设 TOP 被自动模式拒绝 /
#     reorder_files -disable_unused 禁用了生成的 wrapper / remove_files 把
#     wrapper 条目摘没）。逐点修补只会打地鼠，所以整个换容器。
#
#   磁盘上的"设计"是完好的：rtl/ 全部 RTL、constr/ 全部约束、
#   up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd（含 9 个单元与全部连线）。
#
# 铁律（这次绝不再犯）：
#   * **不调用 update_compile_order**（它会把 TOP 偷换成 puf_dec_bd -> manual 模式）
#   * **不调用 reorder_files**（-disable_unused 会禁用生成的 wrapper）
#   * **不显式设置 TOP**（自动层次模式会拒绝；make_wrapper 加回 wrapper 后 TOP 自然正确）
#
# 本脚本只做到"验证点"就停：generate_target + make_wrapper 之后，
# 检查 56-176 / 41-1726 / 20-730 是否为 0、TOP 是否自动识别为 up_proj_wrapper。
# 干净通过才继续综合。
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set newdir "$root/rebuild_20261017"
set oldbd  "$root/up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd"

puts "== ROOT   $root"
puts "== NEWDIR $newdir"
if {![file exists $oldbd]} { puts "!! 找不到旧 .bd: $oldbd"; return }

file mkdir $newdir

#---------------------------------------------------------------------------
# 1) 建全新工程（器件/board 与旧工程一致）
#---------------------------------------------------------------------------
create_project up_proj_gemm_new $newdir -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
puts "== created new project"

#---------------------------------------------------------------------------
# 2) 加全部 RTL（自有源码）
#---------------------------------------------------------------------------
set rtl_files [concat [glob -nocomplain $root/rtl/*.sv] [glob -nocomplain $root/rtl/*.v]]
foreach f $rtl_files { add_files -norecurse $f }
puts "== added [llength $rtl_files] RTL files"
foreach f $rtl_files { puts "   [file tail $f]" }

#---------------------------------------------------------------------------
# 3) 加约束（只有这两个是 XDC；puf_loc_generated.tcl / drc_relax_pre.tcl 走 TCL.PRE 注入）
#---------------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse "$root/constr/puf_lock.xdc"
add_files -fileset constrs_1 -norecurse "$root/constr/puf_pblock.xdc"
puts "== added constraints"

#---------------------------------------------------------------------------
# 4) 加 Block Design
#    **不调用 update_compile_order**（它就是把 TOP 偷换成 puf_dec_bd 的元凶）
#---------------------------------------------------------------------------
add_files -norecurse $oldbd
puts "== added BD: $oldbd"

#---------------------------------------------------------------------------
# 5) 关键验证点：generate_target + make_wrapper（看 module reference 能否解析）
#---------------------------------------------------------------------------
puts ""
puts "==== 验证点开始 ===="
generate_target all [get_files up_proj.bd]
puts "==== generate_target 完成（上面若出现 41-1726 即为失败）===="
make_wrapper -files [get_files up_proj.bd] -top
puts "==== make_wrapper 完成 ===="

set fs [get_filesets sources_1]
puts "== sources_1 TOP (应为 up_proj_wrapper) = [get_property TOP $fs]"
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper IS_ENABLED=[get_property IS_ENABLED $f]"
}
puts "== REBUILD_STAGE1_DONE"
close_project
