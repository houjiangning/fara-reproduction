# diag_ooc.tcl -- read-only probe: how is the GEMM module-reference synthesized?
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

set bd [get_files -quiet up_proj.bd]
puts "== BD: $bd"

catch { open_bd_design $bd }
catch { puts "== synth_flow_mode: [get_property synth_flow_mode [current_bd_design]]" }

puts "== runs:"
foreach r [get_runs -quiet] {
  puts "   [format %-44s $r] status=[get_property STATUS $r]"
}

puts "== ips:"
foreach i [get_ips -quiet] { puts "   $i" }

set mr [get_ips -quiet up_proj_gemm_up_proj_bd_0_0]
puts "== module-ref ip lookup: '$mr'"
if {[llength $mr] > 0} {
  foreach p {IPDEF IP_REVISION IS_MANAGED} {
    if {[catch { set v [get_property $p $mr] } e]} { set v "<?$e>" }
    puts "   $p = $v"
  }
  foreach p {SYNTHESISFLOW} {
    if {[catch { set v [get_property $p $mr] } e]} { set v "<?$e>" }
    puts "   $p = $v"
  }
}

puts "== run matching gemm: '[get_runs -quiet *gemm*]'"
puts "== iprun matching gemm: '[get_ips -quiet *gemm*]'"

if {[llength $mr] > 0} {
  if {[catch { create_ip_run $mr } e]} {
    puts "== create_ip_run REJECTED: $e"
  } else {
    puts "== create_ip_run OK"
  }
  puts "== runs after create_ip_run:"
  foreach r [get_runs -quiet] { puts "   $r" }
}

catch { close_bd_design }
close_project
puts "== DIAG_DONE"
