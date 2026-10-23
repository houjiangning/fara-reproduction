# diag_ooc3.tcl -- why is the GEMM RTL disabled? does enabling fix resolution?
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
puts "== rtl files found: [llength $rtl]"
foreach f $rtl {
  set ad "?"; set en "?"; set li "?"
  catch { set ad [get_property AutoDisabled $f] }
  catch { set en [get_property IS_ENABLED $f] }
  catch { set li [get_property LIBRARY $f] }
  puts "   [format %-26s [file tail $f]] AutoDisabled=$ad IS_ENABLED=$en LIB=$li"
}

puts "== sources_1 compile order (used in synthesis):"
if {[catch { report_compile_order -fileset sources_1 -used_in synthesis -file "$root/diag_compile_order.rpt" } e]} {
  puts "   report_compile_order failed: $e"
} else {
  puts "   written $root/diag_compile_order.rpt"
}

# try to re-enable
foreach f $rtl { catch { set_property AutoDisabled 0 $f } ; catch { set_property IS_ENABLED 1 $f } }
update_compile_order -fileset sources_1

set bd [get_files -quiet up_proj.bd]
open_bd_design $bd
puts "== after enable+update: bd cells = [get_bd_cells -quiet]"
catch { close_bd_design }

puts "== runs:"
foreach r [get_runs -quiet] { puts "   $r" }

close_project
puts "== DIAG3_DONE"
