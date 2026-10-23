#-----------------------------------------------------------------------------
# fix_enable_rtl.tcl -- repair the GEMM module-reference state and switch the
#                       block design to GLOBAL (in-context) synthesis.
#
# Keep this file ASCII-only. Vivado's Tcl on Windows decodes scripts with the
# system codepage (GBK); UTF-8 bytes can decode to 0x5C ('\') and break parsing.
#
# WHAT WAS WRONG (established 2026-10-06)
# ---------------------------------------------------------------------------
#  (1) The GEMM RTL files were DISABLED in sources_1 (<Attr AutoDisabled="1"/>),
#      so the BD module reference could not resolve 'gemm_up_proj_bd':
#        ERROR: [filemgmt 56-587] Failed to resolve reference ...
#        CRITICAL WARNING: [BD 41-1726] Unable to resolve module-source ...
#  (2) The BD is set to 'synth_flow_mode: Hierarchical', i.e. the module
#      reference is expected to be synthesized OUT OF CONTEXT into a checkpoint
#        .../ip/up_proj_gemm_up_proj_bd_0_0/up_proj_gemm_up_proj_bd_0_0.dcp
#      That checkpoint had been destroyed by the earlier diag_ooc*.tcl attempts
#      and is NOT recreated by generate_target (which only writes the stub).
#      A missing/stale OOC checkpoint is exactly what made the 2026-10-05
#      bitstream keep reporting VERSION=0x0001_0000 after the FaR RTL edit.
#
# THE FIX
# ---------------------------------------------------------------------------
#  (1) full source management + re-enable the 7 GEMM RTL files
#  (2) switch the BD to GLOBAL synthesis:
#          set_property synth_checkpoint_mode none [get_files up_proj.bd]
#      With no hierarchical checkpoints the module reference is synthesized
#      IN-CONTEXT inside synth_1, so there is no separate netlist that can lag
#      behind the RTL. The stale-bitstream failure mode disappears by design.
#      (This is the same remedy used by non-project-mode flows, where
#       "synth_flow_mode" in the .bd MUST be "None".)
#  (3) regenerate BD output products
#  (4) report, and assert the OOC run is GONE (its absence is now correct)
#
# Usage (Vivado must NOT have this project open):
#   vivado -mode batch -source tools/fix_enable_rtl.tcl
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
puts "== ROOT $root"

open_project "$root/up_proj_gemm.xpr"

set rtl_files [list \
  "$root/rtl/gemm_up_proj_bd.v" \
  "$root/rtl/gemm_up_proj_top.sv" \
  "$root/rtl/gemm_up_proj_core.sv" \
  "$root/rtl/gemm_up_proj_axi_lite.sv" \
  "$root/rtl/far_reroute.sv" \
  "$root/rtl/fp32_mul.sv" \
  "$root/rtl/fp32_add.sv" \
]

#--- [1] full source management + enable every GEMM RTL file ----------------
set_property source_mgmt_mode All [current_project]
puts "== source_mgmt_mode = [get_property source_mgmt_mode [current_project]]"

foreach f $rtl_files {
  set fs [get_files -quiet $f]
  if {[llength $fs] == 0} {
    add_files -norecurse $f
    set fs [get_files -quiet $f]
    puts "== added   [file tail $f]"
  }
  set_property IS_ENABLED 1 $fs
  puts "== enabled [file tail $f]  (IS_ENABLED=[get_property IS_ENABLED $fs])"
}
update_compile_order -fileset sources_1

#--- [2] switch the BD to global (in-context) synthesis ---------------------
set bd [get_files -quiet up_proj.bd]
if {[llength $bd] == 0} { error "up_proj.bd not found in the project" }

if {[catch {
  puts "== synth_checkpoint_mode before: [get_property synth_checkpoint_mode $bd]"
} e]} { puts "== synth_checkpoint_mode not readable: $e" }

if {[catch { set_property synth_checkpoint_mode none $bd } e]} {
  puts "!! set_property synth_checkpoint_mode none failed: $e"
} else {
  puts "== set_property synth_checkpoint_mode none  -> OK"
}
if {[catch {
  puts "== synth_checkpoint_mode after : [get_property synth_checkpoint_mode $bd]"
} e]} { puts "== synth_checkpoint_mode not readable: $e" }

#--- [3] regenerate BD output products --------------------------------------
open_bd_design $bd
# belt-and-braces: also push the flow mode onto the open design if settable
catch { set_property synth_flow_mode None [current_bd_design] }
if {[catch { validate_bd_design } e]} { puts "!! validate_bd_design reported: $e" }
save_bd_design
puts "== BD re-saved"
if {[catch { reset_target all $bd } e]} { puts "== reset_target all rejected: $e" }
generate_target all $bd
puts "== BD targets regenerated"

#--- [4] report -------------------------------------------------------------
puts "== runs in project:"
set has_gemm_ooc 0
foreach r [get_runs -quiet] {
  puts "     $r"
  if {[string match "*gemm_up_proj_bd_0_0*" $r]} { set has_gemm_ooc 1 }
}
if {$has_gemm_ooc} {
  puts "!! a GEMM OOC run still exists -- global synthesis did NOT take effect."
  puts "!! Re-check synth_checkpoint_mode above."
} else {
  puts "== no GEMM OOC run (EXPECTED with global synthesis)"
}

puts "== source_mgmt_mode = [get_property source_mgmt_mode [current_project]]"
puts "== FIX_ENABLE_RTL_DONE"
close_project
