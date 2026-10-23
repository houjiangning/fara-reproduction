#-----------------------------------------------------------------------------
# verify_freeze.tcl -- post-implementation provisioning gate:
#   1) compare every frozen PUF LUT's LOC+BEL against constr/puf_loc_generated.tcl
#   2) dump utilization + timing reports for the frozen build
# Run AFTER impl_1 write_bitstream completes. Read-only; no save.
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm_v2.xpr"
open_run impl_1
puts "== impl_1 design opened"

#---------------------------------------------------------------------------
# 1) freeze compliance: source the freeze list, then re-read actual placement
#---------------------------------------------------------------------------
source "$root/constr/puf_loc_generated.tcl"
set n_ok 0 ; set n_bad 0
foreach pair $puf_lock_pairs {
  set cellre [lindex $pair 0]
  set exploc [lindex $pair 1]
  set expbel [lindex $pair 2]
  set cells [get_cells -quiet -regexp $cellre]
  if {[llength $cells] == 0} {
    puts "!! MISSING cell: $cellre"
    incr n_bad
    continue
  }
  set c [lindex $cells 0]
  set aloc [get_property LOC $c]
  set abel [get_property BEL $c]
  if {$aloc eq $exploc && $abel eq $expbel} {
    incr n_ok
  } else {
    puts "!! MISMATCH $cellre : frozen=($exploc,$expbel) actual=($aloc,$abel)"
    incr n_bad
  }
}
puts "== FREEZE COMPLIANCE: $n_ok OK / $n_bad MISMATCH (of [llength $puf_lock_pairs])"

#---------------------------------------------------------------------------
# 2) reports
#---------------------------------------------------------------------------
report_utilization -file "$root/p0_out/util_final.rpt"
set wns "-"; set whs "-"
catch {
  set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -quiet]]
}
catch {
  set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -quiet]]
}
puts "== WNS=$wns  WHS=$whs"
report_timing_summary -file "$root/p0_out/timing_final.rpt"
puts "== summary of utilization:"
set stats {CLB_LUTS CLB_FFS BRAM_36K DSPS LUT_AS_MEMORY CARRY8}
foreach s $stats {
  catch { puts "  $s = [get_property STATS.$s [get_designs -filter {IS_CURRENT}]]" }
}
puts "== VERIFY_FREEZE_DONE"
