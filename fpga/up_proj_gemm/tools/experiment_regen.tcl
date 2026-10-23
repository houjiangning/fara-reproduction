#-----------------------------------------------------------------------------
# experiment_regen.tcl -- 快速复现失败的 generate_target 步骤（只做诊断，不跑综合）
#
#   目的：在 ~3 分钟内回答两个问题
#     1) reset_target + generate_target 时还会不会报 [BD 41-1726]（模块源解析失败）
#     2) 该步骤之后，四个 module-reference 的"打包 IP"目录是否真的被重新生成
#        （目录不存在 => 解析失败是实锤，BD 对 run 就是 invalid reference）
#
#   另外试一个变量：source_mgmt_mode 从 All 改回工程默认 DisplayOnly，
#   只靠 IS_ENABLED=1 保证文件参与（这正是本工程历史上的正确做法）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
puts "== mode before = [get_property source_mgmt_mode [current_project]]"

set_property source_mgmt_mode DisplayOnly [current_project]
update_compile_order -fileset sources_1

foreach f {gemm_up_proj_bd.v puf_bd.v puf_dec_bd.v axis_route2.v} {
  set ff [get_files -quiet *$f]
  if {[llength $ff] > 0} {
    catch { set_property IS_ENABLED 1 $ff }
    puts "== $f  IS_ENABLED=[get_property IS_ENABLED $ff]  USED_IN=[get_property USED_IN $ff]"
  } else {
    puts "!! $f 不在工程里"
  }
}
puts "== mode after  = [get_property source_mgmt_mode [current_project]]"

foreach r [get_runs -quiet *] { catch { reset_run [get_property NAME $r] } }

puts "== reset_target"
reset_target all [get_files up_proj.bd]
puts "== generate_target"
generate_target all [get_files up_proj.bd]
puts "== make_wrapper"
make_wrapper -files [get_files up_proj.bd] -top

foreach d {up_proj_gemm_up_proj_bd_0_0 up_proj_puf_bd_0_0 up_proj_puf_dec_bd_0_0 up_proj_axis_route2_0_0} {
  set p "$root/up_proj_gemm.gen/sources_1/bd/up_proj/ip/$d"
  set q "$root/up_proj_gemm.srcs/sources_1/bd/up_proj/ip/$d"
  puts "== PACK $d : .gen=[file exists $p]  .srcs=[file exists $q]"
}
puts "== EXP_DONE"
close_project
