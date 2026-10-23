#-----------------------------------------------------------------------------
# build_new.tcl -- 在**新工程** rebuild_20261017/up_proj_gemm_new.xpr 里跑完整构建
#
# 顺序依据 Vivado 自己的提示（20-742 Resolution）：
#   "要显式设 TOP，必须先把模式切到 manual：set_property source_mgmt_mode None"
#   而 module reference 的解析需要在 auto 模式 —— 但**已经在 stage1 里
#   generate_target 解析完了**（41-1726 = 0），所以现在切 manual 是安全的。
#
# 铁律：不调 update_compile_order、不调 reorder_files。
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set newdir "$root/rebuild_20261017"
set proj   "$newdir/up_proj_gemm_new.xpr"

open_project $proj
open_bd_design [get_files up_proj.bd]

# 1) 重新生成 wrapper，并显式把它加入 sources_1
make_wrapper -files [get_files up_proj.bd] -top
set cands [glob -nocomplain "$newdir/up_proj_gemm_new.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v"]
puts "== wrapper candidates: $cands"
foreach w $cands {
  if {[llength [get_files -quiet $w]] == 0} { add_files -norecurse $w; puts "== added wrapper entry" }
}
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper entry: [file tail $f]  IS_ENABLED=[get_property IS_ENABLED $f]"
}

# 2) 按官方要求：先切 manual 模式，再显式设 TOP
set fs [get_filesets sources_1]
if {[catch { set_property source_mgmt_mode None [current_project] } e0]} { puts "!! mode: $e0" }
if {[catch { set_property TOP up_proj_wrapper $fs } e1]} { puts "!! TOP: $e1" }
puts "== source_mgmt_mode = [get_property source_mgmt_mode [current_project]]"
puts "== sources_1 TOP = [get_property TOP $fs]"

# 3) DRC 放行钩子（PUF 组合环）+ 约束 USED_IN
foreach xf [list "$root/constr/puf_lock.xdc" "$root/constr/puf_pblock.xdc"] {
  set ff [get_files -quiet $xf]
  if {[llength $ff] > 0} { catch { set_property USED_IN {synthesis implementation} $ff } }
}
set drc_pre "$root/constr/drc_relax_pre.tcl"
puts "== drc_relax 存在: [file exists $drc_pre]"
foreach step {WRITE_BITSTREAM ROUTE_DESIGN PLACE_DESIGN OPT_DESIGN} {
  catch { set_property STEPS.${step}.TCL.PRE $drc_pre [get_runs impl_1] }
}

# 4) 全量重跑
foreach r [get_runs -quiet *] { catch { reset_run [get_property NAME $r] } }
puts "== launching synth_1"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS   [get_runs synth_1]]
puts "== synth_1 PROGRESS=$sp  STATUS=$ss"
if {$sp ne "100%" || ![string match "*Complete!*" $ss]} {
  puts "!! SYNTH FAILED -> 看 $newdir/up_proj_gemm_new.runs/synth_1/runme.log"
  puts "== BUILD_NEW_DONE"
  return
}

# 5) PUF 存在性检查（期望 128）
open_run synth_1
set cells [get_cells -quiet -hier -filter {NAME =~ *g_cell*}]
set idx {}
foreach c $cells { if {[regexp {g_cell\[([0-9]+)\]} [get_property NAME $c] -> n]} { lappend idx $n } }
puts "== distinct g_cell indices = [llength [lsort -integer -unique $idx]] (期望 128)"

# 6) 实现 + 比特流
puts "== launching impl_1"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "== impl_1 PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"
set bit "$newdir/up_proj_gemm_new.runs/impl_1/up_proj_wrapper.bit"
if {[file exists $bit]} { puts "== BITSTREAM $bit ([file size $bit] bytes)" } else { puts "!! 没生成 bitstream" }
puts "== BUILD_NEW_DONE"
