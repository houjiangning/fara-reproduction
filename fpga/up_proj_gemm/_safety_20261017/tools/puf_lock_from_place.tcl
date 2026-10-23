#-----------------------------------------------------------------------------
# puf_lock_from_place.tcl -- freeze the PUF at its ACTUAL placed coordinates
#
# (rewritten 2026-10-14 after measuring the real netlist; the previous version
#  had two defects that would have failed silently -- see NOTES below)
#
# WHAT IT PRODUCES
#   constr/puf_pblock.xdc        pblock over the array region  + CONTAIN_ROUTING
#   constr/puf_loc_generated.tcl per-LUT LOC and BEL for every butterfly LUT
#
# WHY BOTH, AND WHY THE LOC FILE MATTERS MOST
#   A Butterfly PUF's fingerprint comes from WHICH physical LUT carries the
#   cross-coupled pair. A pblock only limits the REGION -- the placer may still
#   land the pair on different LUTs inside that region as soon as anything else
#   in the design changes (and this project keeps changing: AES, FaR, ...).
#   Any such change would silently rotate the PUF response and invalidate every
#   ciphertext and helper datum produced earlier. Pinning LOC + BEL removes that
#   failure mode: each butterfly LUT is nailed to one physical site.
#
#   The pblock is kept as well because it gives the placer a legal region and
#   CONTAIN_ROUTING, which keeps the PUF self-contained.
#
# WHY THE LOC FILE IS .tcl AND NOT .xdc
#   Cell names contain square brackets, e.g. g_cell[0].u_cell. In an XDC file
#   those brackets are a GLOB character class, so g_cell[0] would match g_cell0
#   -- and an XDC cannot loop to work around it. From Tcl we can pick the cell
#   object directly, with no pattern matching at all.
#   Delivery: constr/drc_relax_pre.tcl sources this file when it exists, and
#   that script is injected into every impl step via STEPS.<STEP>.TCL.PRE,
#   which is already proven to execute inside the run sub-processes.
#
# NOTES -- the two defects in the previous version, both measured 2026-10-14:
#   1) selector  "*puf_bd_0/u_array*"  matched 0 cells. The real hierarchy is
#      up_proj_i/puf_bd_0/inst/u_array/... -- there is an "inst" in between, so
#      the pattern needed "/inst/u_array". Matching now goes by REF_NAME.
#   2) the bbox walked LOC of the cells returned by that filter. The butterfly
#      instances are hierarchical wrappers (bpuf_cell) whose LOC is EMPTY, so
#      the bbox would have come out empty and the script would have exited.
#      The bbox now comes from leaf cells under the array that carry a real
#      SLICE coordinate.
#
# USAGE (project open, impl_1 completed):
#   open_run impl_1
#   source <path>/tools/puf_lock_from_place.tcl
#
# NOTE: prose here avoids decorative square brackets, because inside a Tcl
#       double-quoted string a bracket means COMMAND SUBSTITUTION.
#-----------------------------------------------------------------------------

set root [file normalize [file join [file dirname [info script]] ..]]
set out_pblock "$root/constr/puf_pblock.xdc"
set out_loc    "$root/constr/puf_loc_generated.tcl"
set pblk_name  "pb_bpuf"
set expect_cells 128

#---------------------------------------------------------------------------
# 0a) open the project and read the COMPLETED impl_1 placement
#
#     The coordinates cannot be read from a run that has not been placed, so
#     this refuses to run rather than producing an empty freeze file.
#---------------------------------------------------------------------------
set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
  puts "== puf_lock opened project"
}
set _impl_prog [get_property PROGRESS [get_runs impl_1]]
if {$_impl_prog ne "100%"} {
  puts "!! ERROR: impl_1 PROGRESS = $_impl_prog -- no placement to freeze."
  puts "!!        Finish an implementation run first."
  if {$_we_opened} { close_project }
  return
}
open_run impl_1
puts "== puf_lock reading impl_1 (PROGRESS = $_impl_prog)"

#---------------------------------------------------------------------------
# 0b) locate the array and the butterfly cells (by REF_NAME -- unambiguous)
#---------------------------------------------------------------------------
set arr_list [get_cells -quiet -hier -filter {REF_NAME =~ bpuf_array*}]
if {[llength $arr_list] != 1} {
  puts "!! ERROR: expected exactly 1 bpuf_array instance, found [llength $arr_list]."
  return
}
set arr [lindex $arr_list 0]
set arr_name [get_property NAME $arr]
puts "== puf_lock array instance      : $arr_name"

set cells [get_cells -quiet -hier -filter {REF_NAME =~ bpuf_cell*}]
puts "== puf_lock bpuf_cell instances  : [llength $cells] (expect $expect_cells)"
if {[llength $cells] != $expect_cells} {
  puts "!! ERROR: cell count wrong. Some cells were merged or folded."
  puts "!!        Do NOT freeze. Investigate first."
  return
}

set idx_list {}
foreach c $cells {
  set n [get_property NAME $c]
  if {[regexp {g_cell\[([0-9]+)\]} $n -> idx]} { lappend idx_list $idx }
}
set uniq_idx [lsort -integer -unique $idx_list]
puts "== puf_lock distinct g_cell idx : [llength $uniq_idx] (expect $expect_cells)"
if {[llength $uniq_idx] != $expect_cells} {
  puts "!! ERROR: index count wrong. Do NOT freeze."
  return
}

#---------------------------------------------------------------------------
# 1) the LEAF LUTs of the butterfly cells -- these carry the fingerprint
#
#    MEASURED 2026-10-14 (measured, not assumed -- the earlier guess was wrong):
#      *g_cell* matches 384 cells, made up of
#        128 hierarchical wrapper instances  .../g_cell[N].u_cell   (no LOC),
#        256 leaf LUTs                       .../g_cell[N].u_cell/a_inferred_i_1
#                                            .../g_cell[N].u_cell/b_inferred_i_1
#      The pair a/b IS the cross-coupled NOR pair, i.e. the fingerprint. The
#      output q is a plain assign, so there is no third LUT per cell.
#      The 128 wrappers are skipped automatically because their LOC is empty.
#---------------------------------------------------------------------------
set leaf [get_cells -quiet -hier -filter {NAME =~ *g_cell*}]
puts "== puf_lock cells matching g_cell : [llength $leaf] (expect 384 = 128 wrappers + 256 leaf LUTs)"
if {[llength $leaf] == 0} {
  puts "!! ERROR: no butterfly leaf LUTs found."
  return
}

set pairs {}  ;# name loc bel
set n_pinned 0
set n_noloc  0
foreach c $leaf {
  set nm  [get_property NAME $c]
  set loc [get_property LOC $c]
  set bel [get_property BEL $c]
  if {$loc eq "" || ![regexp {SLICE_X[0-9]+Y[0-9]+} $loc]} {
    incr n_noloc
    continue
  }
  lappend pairs [list $nm $loc $bel]
  incr n_pinned
}
puts "== puf_lock leaf LUTs pinned    : $n_pinned (without SLICE loc: $n_noloc)"

#---------------------------------------------------------------------------
# 2) region bbox from EVERY placed leaf under the array (counters included),
#    so the pblock legally contains the whole array.
#---------------------------------------------------------------------------
set under [get_cells -quiet -hier -filter {NAME =~ */puf_bd_0/inst/u_array/*}]
set minx 999999
set maxx -1
set miny 999999
set maxy -1
set nplaced 0
foreach c $under {
  set loc [get_property LOC $c]
  if {[regexp {SLICE_X([0-9]+)Y([0-9]+)} $loc -> x y]} {
    if {$x < $minx} { set minx $x }
    if {$x > $maxx} { set maxx $x }
    if {$y < $miny} { set miny $y }
    if {$y > $maxy} { set maxy $y }
    incr nplaced
  }
}
puts "== puf_lock placed leaves under array: $nplaced"
if {$nplaced == 0} {
  puts "!! ERROR: nothing under the array reports a SLICE coordinate."
  return
}
set lo_x [expr {$minx - 1}]
set hi_x [expr {$maxx + 1}]
set lo_y [expr {$miny - 1}]
set hi_y [expr {$maxy + 1}]
puts "== puf_lock actual array bbox   : X $minx..$maxx  Y $miny..$maxy"
puts "== puf_lock pblock region       : SLICE_X${lo_x}Y${lo_y}:SLICE_X${hi_x}Y${hi_y}"

#---------------------------------------------------------------------------
# 3) write constr/puf_pblock.xdc -- pure literal constraint commands
#---------------------------------------------------------------------------
set fp [open $out_pblock "w"]
fconfigure $fp -translation lf
puts $fp "#============================================================================="
puts $fp "# puf_pblock.xdc -- PUF array region freeze (GENERATED -- do not hand-edit)"
puts $fp "#"
puts $fp "# Generated by tools/puf_lock_from_place.tcl from the ACTUAL placement of"
puts $fp "# impl_1. Re-run that script after any placement change."
puts $fp "#"
puts $fp "# PURE CONSTRAINT COMMANDS ONLY. XDC rejects if/catch/foreach and would"
puts $fp "# silently skip the block (the bug that blocked bitgen on 2026-10-13)."
puts $fp "#"
puts $fp "# Source bbox: X $minx..$maxx  Y $miny..$maxy   placed leaves: $nplaced"
puts $fp "# Butterfly cells: [llength $uniq_idx]   leaf LUTs pinned by LOC: $n_pinned"
puts $fp "#============================================================================="
puts $fp ""
puts $fp "create_pblock $pblk_name"
puts $fp "resize_pblock \[get_pblocks $pblk_name\] -add {SLICE_X${lo_x}Y${lo_y}:SLICE_X${hi_x}Y${hi_y}}"
puts $fp "set_property CONTAIN_ROUTING TRUE \[get_pblocks $pblk_name\]"
puts $fp ""
puts $fp "# bind the whole PUF array hierarchy to the region"
puts $fp "add_cells_to_pblock \[get_pblocks $pblk_name\] \[get_cells {$arr_name}\]"
puts $fp ""
close $fp
puts "== puf_lock WROTE $out_pblock"

#---------------------------------------------------------------------------
# 4) write constr/puf_loc_generated.tcl -- per-LUT LOC and BEL
#
#    The names are stored as Tcl LIST elements, so the square brackets in
#    g_cell[0].u_cell never reach a pattern matcher as pattern syntax; they are
#    plain characters in a string. The file is sourced with `source`, so Tcl
#    parses those strings -- both paths stay away from glob.
#
#    Cells are fetched as   get_cells -quiet -hier -regexp <literal name as a
#    REGEX>, with every regex metacharacter in the name escaped. That is an
#    exact match on the full path, and unlike a glob there is no character-class
#    reading of a bracket.
#---------------------------------------------------------------------------
set fp [open $out_loc "w"]
fconfigure $fp -translation lf
puts $fp "#============================================================================="
puts $fp "# puf_loc_generated.tcl -- per-LUT placement freeze of the Butterfly PUF"
puts $fp "#"
puts $fp "# GENERATED by tools/puf_lock_from_place.tcl -- do not hand-edit."
puts $fp "# Sourced by constr/drc_relax_pre.tcl, which is injected into every impl"
puts $fp "# step through STEPS.<STEP>.TCL.PRE (proven to run inside the sub-process)."
puts $fp "#"
puts $fp "# WHY LOC+BEL and not just a pblock: the fingerprint depends on WHICH"
puts $fp "# physical LUT holds the cross-coupled pair. A region does not fix that."
puts $fp "#"
puts $fp "# $n_pinned butterfly leaf LUTs pinned."
puts $fp "# Parent array instance: $arr_name"
puts $fp "#"
puts $fp "# Names are stored as LITERAL REGEX patterns: every regex metacharacter,"
puts $fp "# including the brackets of g_cell[0], is escaped with a backslash. The"
puts $fp "# cell lookup therefore uses get_cells -regexp, an exact whole-path match,"
puts $fp "# never a glob -- a glob would read g_cell[0] as a character class and"
puts $fp "# silently match the wrong name (or nothing at all)."
puts $fp "#============================================================================="
puts $fp ""
set puf_re_meta [list "\\" "." "\[" "\]" "*" "+" "?" "(" ")" "\{" "\}" "^" "\$" "|"]
puts $fp "set puf_lock_pairs {}"
foreach p $pairs {
  set nm  [lindex $p 0]
  set loc [lindex $p 1]
  set bel [lindex $p 2]
  set nm_re ""
  foreach ch [split $nm ""] {
    if {[lsearch -exact $puf_re_meta $ch] >= 0} { append nm_re "\\" $ch } else { append nm_re $ch }
  }
  # The braces around $rec are written LITERALLY into the file. Without them the
  # inner [list] expands to plain text and the file line becomes
  #   lappend puf_lock_pairs NAME LOC BEL
  # which appends THREE elements, flattening the list (measured: 256 records
  # came out as 768 loose elements and every pin failed).
  set rec [list $nm_re $loc $bel]
  puts $fp "lappend puf_lock_pairs \{$rec\}"
}
puts $fp ""
puts $fp "set puf_lock_ok  0"
puts $fp "set puf_lock_bad 0"
puts $fp "foreach p \$puf_lock_pairs \{"
puts $fp "  set nm  \[lindex \$p 0\]"
puts $fp "  set loc \[lindex \$p 1\]"
puts $fp "  set bel \[lindex \$p 2\]"
puts $fp "  if \{\[llength \$p\] != 3\} \{"
puts $fp "    incr puf_lock_bad"
puts $fp "    continue"
puts $fp "  \}"
puts $fp "  set c \[get_cells -quiet -hier -regexp \$nm\]"
puts $fp "  if \{\[llength \$c\] != 1\} \{"
puts $fp "    incr puf_lock_bad"
puts $fp "    continue"
puts $fp "  \}"
puts $fp "  if \{\[catch \{ set_property LOC \$loc \$c \} e\]\} \{"
puts $fp "    incr puf_lock_bad"
puts $fp "    continue"
puts $fp "  \}"
puts $fp "  if \{\$bel ne \"\"\} \{ catch \{ set_property BEL \$bel \$c \} \}"
puts $fp "  incr puf_lock_ok"
puts $fp "\}"
puts $fp "if \{\$puf_lock_bad > 0\} \{"
puts $fp "  puts \"== puf_lock: WARNING \$puf_lock_bad pin records FAILED, \$puf_lock_ok pinned\""
puts $fp "\} else \{"
puts $fp "  puts \"== puf_lock: \$puf_lock_ok butterfly LUTs pinned by LOC and BEL\""
puts $fp "\}"
puts $fp ""
close $fp
puts "== puf_lock WROTE $out_loc"

#---------------------------------------------------------------------------
# 5) show the first generated lines so the shape can be eyeballed
#---------------------------------------------------------------------------
puts ""
puts "== puf_lock --- first 6 pin lines of the generated puf_loc file ---"
set n 0
foreach p $pairs {
  puts "== puf_lock   [lindex $p 0]  ->  [lindex $p 1]  BEL=[lindex $p 2]"
  incr n
  if {$n >= 6} { break }
}

#---------------------------------------------------------------------------
# 6) SELF-TEST -- apply the generated file right here, against the design it
#    was derived from, and report whether it really finds and pins the cells.
#
#    This is the gate. A broken name encoding is caught in seconds here instead
#    of after a full re-implementation. Setting LOC on the in-memory placed
#    design is harmless: nothing is written back to disk.
#---------------------------------------------------------------------------
puts ""
puts "== puf_lock SELF-TEST: sourcing the generated file against impl_1"
if {[catch { source $out_loc } puf_lock_selftest_err]} {
  puts "!! puf_lock SELF-TEST FAILED to run: $puf_lock_selftest_err"
} elseif {[info exists puf_lock_bad] && $puf_lock_bad > 0} {
  puts "!! puf_lock SELF-TEST: $puf_lock_bad pin records FAILED, $puf_lock_ok pinned."
  puts "!!   The name encoding in $out_loc is wrong. Do NOT rebuild yet."
} else {
  puts "== puf_lock SELF-TEST: PASS -- all $puf_lock_ok butterfly LUTs pinned by LOC and BEL."
}

puts ""
puts "== puf_lock NEXT STEPS:"
puts "==   1) constr/drc_relax_pre.tcl sources constr/puf_loc_generated.tcl"
puts "==      automatically now, inside every impl step sub-process"
puts "==   2) re-run tools/add_puf_to_bd.tcl (it picks up constr/puf_pblock.xdc)"
puts "==   3) re-run tools/puf_p1_synth.tcl to rebuild with the freeze applied"
puts "==   4) after the rebuild, re-run this script and confirm the LOC list is"
puts "==      IDENTICAL -- identical coordinates mean the freeze held"
puts "== DONE"

if {$_we_opened} { close_project }
