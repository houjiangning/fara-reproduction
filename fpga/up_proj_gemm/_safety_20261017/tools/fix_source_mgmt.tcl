#-----------------------------------------------------------------------------
# fix_source_mgmt.tcl -- 修复 sources_1 文件集 / 编译顺序
#
# 症状（2026-10-16 全量构建失败）：
#   CRITICAL WARNING: [BD 41-1726] Unable to resolve module-source for block
#       '/gemm_up_proj_bd_0'  '/puf_bd_0'  '/puf_dec_bd_0'  '/axis_route2_0'
#   ERROR: [filemgmt 56-587] Failed to resolve reference. Nothing was found in
#       the project to match the name gemm_up_proj_bd / puf_bd / puf_dec_bd /
#       axis_route2
#   -> 这些"通过 BD module reference 被引用"的 .v 顶层不在（或被禁用）sources_1
#      的编译顺序里。注意连**原本好好的** gemm_up_proj_bd 也一起挂了，说明是
#      **文件集状态**回归（AutoDisabled / 手工编译顺序），不是 RTL 问题。
#
# 做法：确保这些文件在册且 IS_ENABLED=1，强制 source_mgmt_mode All，
#       重算编译顺序，然后**保存工程**（上一次 BD 集成脚本只 save_bd_design，
#       没有 save_project，文件集的这份状态没落盘）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"

puts "==== DIAG BEFORE ===="
puts "== source_mgmt_mode     = [get_property source_mgmt_mode [current_project]]"
puts "== sources_1 TOP        = [get_property TOP [get_filesets sources_1]]"
puts "== sources_1 file count = [llength [get_files -quiet -of_objects [get_filesets sources_1]]]"

# 通过 BD module reference 使用的顶层（**必须**是纯 Verilog .v）
set bd_tops [list \
  "$root/rtl/gemm_up_proj_bd.v" \
  "$root/rtl/puf_bd.v" \
  "$root/rtl/puf_dec_bd.v" \
  "$root/rtl/axis_route2.v" \
]

# 其余自有 RTL（一并确保在册）
set others [list \
  "$root/rtl/aes256_sbox.sv" "$root/rtl/aes256_core.sv" "$root/rtl/aes256_ctr.sv" \
  "$root/rtl/key_mgr.sv" "$root/rtl/fuzzy_extract.sv" "$root/rtl/sha256_kdf.sv" \
  "$root/rtl/wdec_stream.sv" "$root/rtl/puf_dec_axi_lite.sv" \
  "$root/rtl/bpuf_cell.sv" "$root/rtl/bpuf_array.sv" "$root/rtl/bpuf_ctrl.sv" \
  "$root/rtl/puf_axi_lite.sv" \
  "$root/rtl/gemm_up_proj_core.sv" "$root/rtl/gemm_up_proj_axi_lite.sv" \
  "$root/rtl/gemm_up_proj_top.sv" "$root/rtl/far_reroute.sv" \
]

foreach f [concat $bd_tops $others] {
  set ff [get_files -quiet $f]
  if {[llength $ff] == 0} {
    puts "== MISSING -> add_files [file tail $f]"
    if {[catch { add_files -norecurse $f } e]} { puts "!! add failed: $e" }
  } else {
    puts "== present  [file tail $f]  IS_ENABLED=[get_property IS_ENABLED $ff]  USED_IN=[get_property USED_IN $ff]"
  }
}

# 强制全量源管理，并把自有 RTL 全部显式启用（防 AutoDisabled）
set_property source_mgmt_mode All [current_project]
foreach f [concat $bd_tops $others] {
  set ff [get_files -quiet $f]
  if {[llength $ff] > 0} {
    catch { set_property IS_ENABLED 1 $ff }
  }
}
update_compile_order -fileset sources_1

puts "==== DIAG AFTER ===="
puts "== sources_1 TOP        = [get_property TOP [get_filesets sources_1]]"
foreach f $bd_tops {
  set ff [get_files -quiet $f]
  if {[llength $ff] > 0} {
    puts "== [file tail $f]  IS_ENABLED=[get_property IS_ENABLED $ff]"
  } else {
    puts "!! [file tail $f] STILL MISSING"
  }
}

# 说明：本工程没有可用的 save_project（会报 "Missing value for option 'name'"），
#       文件集状态由 close_project 落盘。
close_project
puts "== FIX_DONE"
