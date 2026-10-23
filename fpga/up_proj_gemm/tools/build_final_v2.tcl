#-----------------------------------------------------------------------------
# build_final_v2.tcl -- synth -> PUF check -> impl -> bitstream for v2.
#
# PRECONDITION: fix_wrapper_v2.tcl ran OK (wrapper regenerated in v2.gen, DRC
# hooks attached, BD validates).
#
# TOP NOTE: v2's sources_1 has TopAutoSet=TRUE with no stored TopModule. Now
# that all four module-ref RTLs are instantiated by BD cells, the ONLY
# uninstantiated candidate is up_proj_wrapper, so update_compile_order can
# resolve and STORE the top (this is how the original project got its stored
# TopModule). If it cannot, abort -- do NOT set_property TOP by hand.
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]

open_project "$root/up_proj_gemm_v2.xpr"
set_property source_mgmt_mode All [current_project]
set fs [get_filesets sources_1]
puts "== fileset TOP = '[get_property TOP $fs]'"
set topv [get_property TOP $fs]
if {$topv ne "up_proj_wrapper"} {
  puts "!! TOP is not up_proj_wrapper -> aborting"
  puts "== BUILD_DONE_FAIL_TOP"
  return
}

#---------------------------------------------------------------------------
# synthesis
#---------------------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS   [get_runs synth_1]]
puts "== synth_1 PROGRESS=$sp  STATUS=$ss"
if {$sp ne "100%" || ![string match "*Complete!*" $ss]} {
  puts "!! SYNTH FAILED -> $root/up_proj_gemm_v2.runs/synth_1/runme.log"
  puts "== BUILD_DONE_FAIL_SYNTH"
  return
}

#---------------------------------------------------------------------------
# PUF presence check (expect 128 distinct butterfly cells)
#---------------------------------------------------------------------------
open_run synth_1
set idxlist {}
foreach c [get_cells -quiet -hier -filter {NAME =~ *g_cell*}] {
  if {[regexp {g_cell\[([0-9]+)\]} [get_property NAME $c] -> n]} { lappend idxlist $n }
}
set uniq [lsort -integer -unique $idxlist]
puts "== distinct g_cell indices = [llength $uniq] (expect 128)"
if {[llength $uniq] != 128} {
  puts "!! PUF cells missing/merged -> netlist not trustworthy"
  puts "== BUILD_DONE_FAIL_PUF"
  return
}

#---------------------------------------------------------------------------
# implementation + bitstream
#---------------------------------------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "== impl_1 PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"

set bit "$root/up_proj_gemm_v2.runs/impl_1/up_proj_wrapper.bit"
if {[file exists $bit]} {
  puts "== BITSTREAM $bit ([file size $bit] bytes)"
  puts "== BUILD_DONE_OK"
} else {
  puts "!! no bitstream produced -> $root/up_proj_gemm_v2.runs/impl_1/runme.log"
  puts "== BUILD_DONE_FAIL_IMPL"
}
