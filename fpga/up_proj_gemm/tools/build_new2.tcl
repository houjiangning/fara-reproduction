#-----------------------------------------------------------------------------
# build_new2.tcl -- 修正版：自动模式 + 把真实存在的 wrapper 加进来 + 不设 TOP
#
# 上一版错在**切到了 source_mgmt_mode None（manual）**——那正是 56-587 的开关；
# 而 20-742 的 Resolution 建议切 None 的前提是"没有 module reference"，本设计有 4 个。
#
# 正确组合（也是原始工程能跑的组合）：
#   * source_mgmt_mode = All（自动模式，module reference 才被解析）
#   * **不显式设 TOP**（自动模式会拒绝；让 Vivado 自己从 wrapper 推断）
#   * 只要 wrapper 文件真的在 sources_1 里 —— make_wrapper 很可能把它写到了
#     **旧 .bd 所在的 .gen 目录**（因为 add_files 的是旧路径的 .bd）
#   * 不调 update_compile_order、不调 reorder_files
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set newdir "$root/rebuild_20261017"
open_project "$newdir/up_proj_gemm_new.xpr"

# 1) 保持自动模式
set_property source_mgmt_mode All [current_project]
puts "== source_mgmt_mode = [get_property source_mgmt_mode [current_project]]"

# 2) 生成 wrapper，并把**实际存在**的那份加进 sources_1
make_wrapper -files [get_files up_proj.bd] -top
puts "== get_files *wrapper* = [get_files -quiet *wrapper*]"

set cands [list \
  "$root/up_proj_gemm.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v" \
  "$newdir/up_proj_gemm_new.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v" ]
foreach p $cands {
  if {[file exists $p]} {
    if {[llength [get_files -quiet $p]] == 0} {
      add_files -norecurse $p
      puts "== added wrapper: $p"
    } else {
      puts "== wrapper already in project: $p"
    }
  } else {
    puts "== not on disk: $p"
  }
}

set fs [get_filesets sources_1]
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper entry IS_ENABLED=[get_property IS_ENABLED $f]"
}
puts "== TOP (自动识别，不显式设置) = [get_property TOP $fs]"

# 3) DRC 放行钩子（PUF 组合环）
set drc_pre "$root/constr/drc_relax_pre.tcl"
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
  puts "== BUILD_NEW2_DONE"
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
puts "== BUILD_NEW2_DONE"
