#-----------------------------------------------------------------------------
# diag_modref.tcl -- one-shot, READ-ONLY-ish diagnostic for why
#   create_bd_cell -type module -reference gemm_up_proj_bd cannot resolve the
#   module ("Nothing was found in the project to match the name gemm_up_proj_bd").
#
# It prints, at the exact point where add_gemm_to_bd.tcl fails:
#   * source_mgmt_mode (manual vs automatic)
#   * fileset top before/after update_compile_order
#   * the gemm_up_proj_bd.v file object: IS_ENABLED / USED_IN / TYPE
# It does NOT save the project or the BD.
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]
set p  [current_project]
puts "== mode at open        = [get_property source_mgmt_mode $p]"
puts "== TOP at open         = '[get_property TOP $fs]'"

# add the gemm RTL the same way add_gemm_to_bd.tcl does
foreach n {gemm_up_proj_core.sv gemm_up_proj_axi_lite.sv gemm_up_proj_top.sv \
           far_reroute.sv gemm_up_proj_bd.v fp32_mul.sv fp32_add.sv} {
  if {[llength [get_files -quiet "$root/rtl/$n"]] == 0} { add_files -norecurse "$root/rtl/$n" }
}
set gf [get_files -quiet *gemm_up_proj_bd.v]
puts "== gemm_up_proj_bd.v   = $gf"
if {[llength $gf] > 0} {
  puts "==   TYPE              = [get_property FILE_TYPE $gf]"
  puts "==   IS_ENABLED        = [get_property IS_ENABLED $gf]"
  puts "==   USED_IN           = [get_property USED_IN $gf]"
  puts "==   USED_IN_SYNTHESIS = [get_property USED_IN_SYNTHESIS $gf]"
}

puts "== mode before update = [get_property source_mgmt_mode $p]"
set_property source_mgmt_mode All $p
puts "== mode after  set All= [get_property source_mgmt_mode $p]"

if {[catch { update_compile_order -fileset sources_1 } e]} {
  puts "!! update_compile_order threw: $e"
}
puts "== mode after update   = [get_property source_mgmt_mode $p]"
puts "== TOP after update    = '[get_property TOP $fs]'"

# probe the exact call that fails, but inside catch, and report
open_bd_design [get_files -quiet up_proj.bd]
if {[catch { create_bd_cell -type module -reference gemm_up_proj_bd DIAG_gemm_tmp } e]} {
  puts "!! create_bd_cell probe failed: $e"
} else {
  puts "== create_bd_cell probe SUCCEEDED (module resolves)"
  catch { delete_bd_objs [get_bd_cells DIAG_gemm_tmp] }
}
puts "== DIAG_DONE"
