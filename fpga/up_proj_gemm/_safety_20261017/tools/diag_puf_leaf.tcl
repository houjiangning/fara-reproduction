#-----------------------------------------------------------------------------
# diag_puf_leaf.tcl -- leaf-level facts about the placed PUF array
#
# WHY: a Butterfly PUF's response is set by WHICH physical LUTs are used, not
#      just by the region they sit in. So the placement freeze must talk about
#      leaf primitives (LUTs with a real SLICE LOC), not about the module
#      instances g_cell[N].u_cell -- those are hierarchical wrappers whose LOC
#      property is empty (measured 2026-10-14).
#
# This dumps the counts and names needed to generate correct constraints.
#
# USAGE:  vivado -mode batch -source tools/diag_puf_leaf.tcl
#
# NOTE: prose avoids decorative square brackets -- in a Tcl double-quoted string
#       a bracket means COMMAND SUBSTITUTION and would be executed.
#-----------------------------------------------------------------------------

set root [file normalize [file join [file dirname [info script]] ..]]

if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
}
open_run impl_1

set arr [get_cells -quiet -hier -filter {REF_NAME =~ bpuf_array*}]
puts "== leaf: bpuf_array instances  = [llength $arr]"
foreach a $arr { puts "== leaf:   array = [get_property NAME $a]" }

set bpc [get_cells -quiet -hier -filter {REF_NAME =~ bpuf_cell*}]
puts "== leaf: bpuf_cell instances   = [llength $bpc]"

# every cell below the array; keep the ones with a real SLICE location
set all_under [get_cells -quiet -hier -filter {NAME =~ */puf_bd_0/inst/u_array/*}]
puts "== leaf: cells under the array = [llength $all_under]"

set placed {}
set refs  {}
set minx 999999
set maxx -1
set miny 999999
set maxy -1
foreach c $all_under {
  set loc [get_property LOC $c]
  if {[regexp {SLICE_X([0-9]+)Y([0-9]+)} $loc -> x y]} {
    lappend placed $c
    set r [get_property REF_NAME $c]
    if {[dict exists $refs $r]} {
      dict set refs $r [expr {[dict get $refs $r] + 1}]
    } else {
      dict set refs $r 1
    }
    if {$x < $minx} { set minx $x }
    if {$x > $maxx} { set maxx $x }
    if {$y < $miny} { set miny $y }
    if {$y > $maxy} { set maxy $y }
  }
}
puts "== leaf: placed leaf cells with SLICE LOC = [llength $placed]"
puts "== leaf: REF_NAME histogram:"
foreach r [lsort [dict keys $refs]] {
  puts "== leaf:   $r = [dict get $refs $r]"
}
puts "== leaf: bbox of placed leaf cells: X $minx..$maxx  Y $miny..$maxy"

puts "== leaf: first 12 placed leaf cells:"
set n 0
foreach c $placed {
  puts "== leaf:   [get_property NAME $c]  ->  [get_property LOC $c]  ([get_property REF_NAME $c])"
  incr n
  if {$n >= 12} { break }
}

puts "== leaf: DONE"
close_project
