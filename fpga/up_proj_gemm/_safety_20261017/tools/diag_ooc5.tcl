# diag_ooc5.tcl -- repair test: re-add RTL to clear AutoDisabled, then re-resolve module ref
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
set_property source_mgmt_mode All [current_project]

set want [list \
  "$root/rtl/gemm_up_proj_bd.v" \
  "$root/rtl/gemm_up_proj_top.sv" \
  "$root/rtl/gemm_up_proj_core.sv" \
  "$root/rtl/gemm_up_proj_axi_lite.sv" \
  "$root/rtl/far_reroute.sv" \
  "$root/rtl/fp32_mul.sv" \
  "$root/rtl/fp32_add.sv"]

set rtl [get_files -quiet $want]
puts "== found [llength $rtl] rtl files"
if {[llength $rtl] > 0} {
  if {[catch { remove_files -quiet $rtl } e]} { puts "== remove_files failed: $e" } else { puts "== removed" }
}
if {[catch { add_files -norecurse $want } e]} { puts "== add_files failed: $e" } else { puts "== re-added" }
update_compile_order -fileset sources_1
report_compile_order -fileset sources_1 -used_in synthesis -file "$root/diag_compile_order3.rpt"
puts "== compile order written"

set bd [get_files -quiet up_proj.bd]
open_bd_design $bd
puts "== bd cells: [get_bd_cells -quiet]"
generate_target all $bd -force
puts "== runs after generate_target -force:"
foreach r [get_runs -quiet] { puts "   $r" }

close_project
puts "== DIAG5_DONE"
