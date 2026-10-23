# diag_ooc2.tcl -- probe module-source resolution + OOC run creation
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

puts "== source_mgmt_mode (before): [get_property source_mgmt_mode [current_project]]"
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1
puts "== source_mgmt_mode (after) : [get_property source_mgmt_mode [current_project]]"

puts "== rtl files in sources_1:"
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
  if {[string match "*rtl*" $f]} { puts "   [file tail $f]" }
}

set bd [get_files -quiet up_proj.bd]
open_bd_design $bd
puts "== bd cells: [get_bd_cells -quiet]"
set c [get_bd_cells -quiet gemm_up_proj_bd_0]
puts "== gemm cell: $c"
if {[llength $c] > 0} {
  foreach p {REF_NAME VLNV} {
    if {[catch { set v [get_property $p $c] } e]} { set v "<?$e>" }
    puts "   $p = $v"
  }
}
puts "== synth_flow_mode: [get_property synth_flow_mode [current_bd_design]]"
catch { close_bd_design }

puts "== runs BEFORE generate:"
foreach r [get_runs -quiet] { puts "   $r" }

if {[catch { generate_target all $bd -force } e]} { puts "== generate_target -force FAILED: $e" }

puts "== runs AFTER generate -force:"
foreach r [get_runs -quiet] { puts "   $r" }

close_project
puts "== DIAG2_DONE"
