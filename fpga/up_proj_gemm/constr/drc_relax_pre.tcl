#=============================================================================
# drc_relax_pre.tcl -- suppress the Butterfly PUF's cross-coupled LUT loops
#
# STATIC FILE -- deliberately NOT generated at runtime.
#   Earlier versions of tools/puf_p1_synth.tcl generated this file with
#   `puts $fpp "..."` inside double quotes. That silently mangled the command,
#   because in Tcl a double-quoted string performs COMMAND SUBSTITUTION on
#   square brackets: an unescaped command in brackets was evaluated at WRITE
#   time and, returning nothing, vanished together with its brackets --
#   producing a malformed line.
#   Keeping this file static removes that entire class of bug.
#
# HOUSE RULE (learned the hard way, 4 separate failures):
#   NEVER put a square bracket inside a puts string for decoration.
#   In Tcl, "== [foo]" means "call the command foo", not "print [foo]".
#   This file uses plain text only; every computed value goes through a
#   variable. There is not one decorative bracket below.
#
# WHY A TCL SCRIPT AND NOT AN XDC FILE:
#   * Vivado's DRC message prescribes the bypass as a NET property, set with
#     set_property ALLOW_COMBINATORIAL_LOOPS TRUE on one net that is part of
#     the loop.
#   * Naming those nets with a pattern does NOT work. Measured 2026-10-13:
#       WARNING: Vivado 12-507  No nets matched
#                up_proj_i/puf_bd_0/inst/u_array/g_cell[*]/u_cell/a
#       ERROR:   Common 17-55  set_property expects at least one object
#     and that error aborted opt_design at 20%.
#   * An XDC file cannot use foreach to walk the real objects.
#   * A Tcl script CAN, and the run sub-processes DO execute it: the run log
#     shows "source .../constr/drc_relax_pre.tcl" inside each step.
#
# So: walk the REAL PUF cells, take the REAL nets off each of them, and set the
# property. No pattern matching, no name guessing.
#
# Delivery: attached as STEPS.<STEP>.TCL.PRE on impl_1 by tools/puf_p1_synth.tcl
#           (WRITE_BITSTREAM / ROUTE_DESIGN / PLACE_DESIGN / OPT_DESIGN).
#
# Safety: every set_property is wrapped in catch, so a net that refuses the
#         property cannot abort the run step.
#=============================================================================

#---------------------------------------------------------------------------
# Belt and braces, part 1 of 2: also downgrade the LUTLP-1 check's severity.
#
#   The XDC-level attempt at this was silently ignored inside the run
#   sub-processes (see the header of constr/puf_lock.xdc). But we are running
#   INSIDE those sub-processes here, via STEPS.<STEP>.TCL.PRE, so real Tcl
#   applies. The brackets below are GENUINE command substitution, which is why
#   they are legal here -- unlike the decorative brackets that broke this file.
#---------------------------------------------------------------------------
if {[catch { set_property SEVERITY {Warning} [get_drc_checks LUTLP-1] } drc_relax_sev_err]} {
  puts "== drc_relax: severity override refused: $drc_relax_sev_err"
} else {
  set drc_relax_sev [get_property SEVERITY [get_drc_checks LUTLP-1]]
  puts "== drc_relax: LUTLP-1 severity is now $drc_relax_sev"
}

#---------------------------------------------------------------------------
# Belt and braces, part 2 of 2: the property Vivado's own DRC text prescribes.
#---------------------------------------------------------------------------
set drc_relax_n_cells 0
set drc_relax_n_nets  0
set drc_relax_n_fail  0

foreach c [get_cells -quiet -hier -filter {NAME =~ *g_cell*}] {
  incr drc_relax_n_cells
  foreach nt [get_nets -quiet -of_objects $c] {
    if {[catch { set_property ALLOW_COMBINATORIAL_LOOPS TRUE $nt } e]} {
      incr drc_relax_n_fail
    } else {
      incr drc_relax_n_nets
    }
  }
}

set drc_relax_msg "== drc_relax: ALLOW_COMBINATORIAL_LOOPS set on $drc_relax_n_nets net(s) across $drc_relax_n_cells cell(s), refused $drc_relax_n_fail"

if {$drc_relax_n_nets > 0} {
  puts $drc_relax_msg
} else {
  puts $drc_relax_msg
  puts "== drc_relax: WARNING - no net accepted the property."
  puts "== drc_relax:   The cross-coupled loops stay un-suppressed, so bitgen"
  puts "== drc_relax:   will refuse with LUTLP-1 errors. Investigate first."
}

#---------------------------------------------------------------------------
# Placement freeze of the butterfly LUTs, when the coordinate file exists.
#
#   constr/puf_loc_generated.tcl is produced by tools/puf_lock_from_place.tcl
#   from the ACTUAL placement of a completed impl_1. It pins every butterfly
#   LUT to its physical SLICE coordinate and BEL, which is what actually keeps
#   the fingerprint from drifting -- a pblock only bounds the REGION.
#
#   This must be applied before place_design, and this file already runs in
#   that position inside every impl step sub-process.
#
#   Absent on the first pass (that pass is what produces the coordinates);
#   present on every pass afterwards.
#---------------------------------------------------------------------------
set drc_relax_locf [file join [file dirname [info script]] puf_loc_generated.tcl]
if {[file exists $drc_relax_locf]} {
  if {[catch { source $drc_relax_locf } drc_relax_loc_err]} {
    puts "== drc_relax: sourcing puf_loc_generated.tcl failed: $drc_relax_loc_err"
  }
} else {
  puts "== drc_relax: no puf_loc_generated.tcl yet -- placement NOT frozen"
}
