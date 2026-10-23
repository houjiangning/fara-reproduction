#-----------------------------------------------------------------------------
# diag2.tcl -- READ-ONLY-ish probe: can create_bd_cell resolve ALL FOUR module
#   references when we simply add all 22 RTL files (NO update_compile_order at
#   all), then open the BD?
#
# If all four resolve, the recipe is: add RTL -> open BD -> create cells ->
#   run the integration scripts (which then only do wiring, addressing and the
#   float IP creation). That avoids update_compile_order entirely, which is what
#   has been clearing the top ([filemgmt 20-730]).
# Does NOT save project or BD.
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]
puts "== mode = [get_property source_mgmt_mode [current_project]]  TOP = '[get_property TOP $fs]'"
set_property source_mgmt_mode All [current_project]

foreach f [concat [glob -nocomplain $root/rtl/*.sv] [glob -nocomplain $root/rtl/*.v]] {
  if {[llength [get_files -quiet $f]] == 0} { add_files -norecurse $f }
}
puts "== RTL in project: [llength [concat [get_files -quiet *.sv] [get_files -quiet *.v]]]"
puts "== TOP after add_files (NO update_compile_order) = '[get_property TOP $fs]'"

open_bd_design [get_files -quiet up_proj.bd]
foreach pair {gemm_up_proj_bd gemm_up_proj_bd_0 puf_bd puf_bd_0 axis_route2 axis_route2_0 puf_dec_bd puf_dec_bd_0} {
  set ref  [lindex $pair 0]
  set cell [lindex $pair 1]
  if {[catch { create_bd_cell -type module -reference $ref $cell } e]} {
    puts "!! $ref -> FAILED: $e"
  } else {
    puts "== $ref -> RESOLVED (cell $cell created)"
    catch { delete_bd_objs [get_bd_cells $cell] }
  }
}
puts "== DIAG2_DONE"
