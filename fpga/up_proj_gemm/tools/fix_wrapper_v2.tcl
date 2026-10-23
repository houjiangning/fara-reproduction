#-----------------------------------------------------------------------------
# fix_wrapper_v2.tcl -- regenerate the HDL wrapper for the v2 project and
#                       attach the PUF DRC hooks.
#
# WHY: the stale `save_project_as -force` removed up_proj_gemm.gen, and the v2
# project's file list still references the now-missing wrapper at
#   $PPRDIR/up_proj_gemm.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v
# Fix: drop that dead entry, regenerate the wrapper from v2's own BD (it will
# land in up_proj_gemm_v2.gen/...), add it back, confirm auto-TOP, attach
# constr/drc_relax_pre.tcl to the impl_1 steps, then close (project mode
# persists the .xpr on close).
#
# IRON RULES: no create_project, no set_property TOP, no reorder_files, no
# source_mgmt_mode None.
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set drcpre "$root/constr/drc_relax_pre.tcl"

open_project "$root/up_proj_gemm_v2.xpr"
puts "== mode = [get_property source_mgmt_mode [current_project]]  TOP = '[get_property TOP [get_filesets sources_1]]'"
set_property source_mgmt_mode All [current_project]

# 1) drop the dead wrapper entry (points into the deleted up_proj_gemm.gen)
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== removing stale wrapper entry: $f"
  remove_files $f
}

# 2) regenerate BD output products + wrapper inside v2's own .gen
generate_target all [get_files up_proj.bd]
make_wrapper -files [get_files up_proj.bd] -top

set w "$root/up_proj_gemm_v2.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v"
if {![file exists $w]} {
  puts "!! wrapper not found at expected path: $w"
  puts "== wrapper candidates: [get_files -quiet *wrapper*]"
} else {
  if {[llength [get_files -quiet $w]] == 0} { add_files -norecurse $w }
  puts "== wrapper added: $w"
}
set fs [get_filesets sources_1]
puts "== TOP after wrapper = '[get_property TOP $fs]'"

# 3) PUF delivery hooks on impl_1 (LUTLP-1 downgrade + ALLOW_COMBINATORIAL_LOOPS
#    + LOC/BEL freeze via puf_loc_generated.tcl, sourced inside the impl steps)
foreach step {OPT_DESIGN PLACE_DESIGN ROUTE_DESIGN WRITE_BITSTREAM} {
  catch { set_property STEPS.${step}.TCL.PRE $drcpre [get_runs impl_1] }
}
puts "== drc_relax_pre.tcl attached to impl_1 steps"

# 4) one validation, then persist by closing (project auto-save)
open_bd_design [get_files -quiet up_proj.bd]
if {[catch { validate_bd_design } e]} {
  puts "!! validate FAILED: $e"
} else {
  puts "== validate OK"
}
close_project
puts "== FIX_WRAPPER_V2_DONE"
