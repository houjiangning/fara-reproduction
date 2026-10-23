# diag_ooc4.tcl -- test: does synth_flow_mode change pull GEMM RTL into the compile order?
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
set_property source_mgmt_mode All [current_project]

set bd [get_files -quiet up_proj.bd]
open_bd_design $bd
puts "== synth_flow_mode now: '[get_property synth_flow_mode [current_bd_design]]'"
foreach cand {Global None} {
  if {[catch { set_property synth_flow_mode $cand [current_bd_design] } e]} {
    puts "== set synth_flow_mode $cand -> REJECTED: $e"
  } else {
    puts "== set synth_flow_mode $cand -> OK (now '[get_property synth_flow_mode [current_bd_design]]')"
    break
  }
}
save_bd_design
close_bd_design

update_compile_order -fileset sources_1
report_compile_order -fileset sources_1 -used_in synthesis -file "$root/diag_compile_order2.rpt"
puts "== compile order written"

open_bd_design $bd
puts "== bd cells: [get_bd_cells -quiet]"
catch { close_bd_design }

puts "== runs:"
foreach r [get_runs -quiet] { puts "   $r" }

close_project
puts "== DIAG4_DONE"
