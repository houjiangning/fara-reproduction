#-----------------------------------------------------------------------------
# restore_bd.tcl -- step 3 (final): wire up the BD and persist the project.
#
# PRECONDITION: the four module-reference cells already exist (created by
#   tools/restore_group.tcl, one group per process).
#
# WHY THE INTERIM validate_bd_design IS MADE NON-FATAL:
#   Each integration script ends with validate_bd_design. Once all four cells are
#   pre-created, add_gemm_to_bd.tcl's validate fails with [BD 41-758] because the
#   PUF / route2 / puf_dec cells are not wired yet (add_puf / add_puf_dec wire
#   them later). In batch an uncaught error aborts the whole script, so the
#   remaining scripts would never run. We rename the real command and install a
#   wrapper that reports but does not throw; after all three scripts have done
#   their wiring we call the REAL validate once, at the end, and check it.
#
# The scripts still create the two fp32 IPs (that is why the cells were created
# earlier: each IP adds a top candidate and would have broken cell creation).
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm.xpr"
puts "== opened; mode = [get_property source_mgmt_mode [current_project]]  TOP = '[get_property TOP [get_filesets sources_1]]'"
set_property source_mgmt_mode All [current_project]

# --- make the scripts' interim validate non-fatal ---------------------------
# NOTE: validate_bd_design is only registered once a BD design is open in batch,
# so open the BD first, then rename the real command and install the wrapper.
open_bd_design [get_files -quiet up_proj.bd]
if {[catch { rename validate_bd_design _real_validate_bd_design } e]} {
  puts "!! cannot rename validate_bd_design: $e"
}
proc validate_bd_design {args} {
  if {[llength [info commands _real_validate_bd_design]] == 0} {
    puts "== interim validate skipped (real command unavailable)"
    return
  }
  if {[catch { _real_validate_bd_design {*}$args } e]} {
    puts "== interim validate_bd_design not clean yet (expected mid-integration): $e"
  } else {
    puts "== interim validate_bd_design OK"
  }
}

puts "==== sourcing add_gemm_to_bd.tcl ===="
source "$root/tools/add_gemm_to_bd.tcl"
puts "==== sourcing add_puf_to_bd.tcl ===="
source "$root/tools/add_puf_to_bd.tcl"
puts "==== sourcing add_puf_dec_to_bd.tcl ===="
source "$root/tools/add_puf_dec_to_bd.tcl"

# --- one real validation of the finished BD --------------------------------
if {[catch { _real_validate_bd_design } e]} {
  puts "!! FINAL validate_bd_design FAILED: $e"
} else {
  puts "== FINAL validate_bd_design OK"
}
save_bd_design

# persist the project. `save_project_as -force` on the SAME name is destructive
# (it rebuilt .srcs and dropped the BD), so save under a NEW name instead: that
# copies all sources (RTL, IPs, BD) into a fresh, self-consistent project.
if {[catch { save_project_as -name up_proj_gemm_v2 } e1]} {
  puts "!! save_project_as -name up_proj_gemm_final FAILED: $e1"
} else {
  puts "== project saved as up_proj_gemm_final"
}
puts "== RESTORE_BD_DONE"
