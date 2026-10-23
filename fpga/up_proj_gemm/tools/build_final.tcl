#-----------------------------------------------------------------------------
# build_final.tcl -- FINAL frozen-bitstream build.
#
# HISTORY / WHY THIS SHAPE:
#   Attempt A: reused rebuild_20261017/up_proj_gemm_new.xpr -> child process read
#     source_mgmt_mode=None from disk -> [filemgmt 56-176] module references
#     ignored -> [BD 41-1726] -> [56-587] -> [Runs 36-346].
#   Attempt B: fresh project in fbuild/, but the .bd was referenced from OUTSIDE
#     the project. make_wrapper therefore wrote the wrapper into the OLD
#     project's gen dir (up_proj_gemm.gen/...), not this project's, so Vivado did
#     not recognise it as a top -> [filemgmt 20-730] could not find a top ->
#     [Common 17-53] Top module not set.
#
#   The Oct-01 working project shows the right shape: its sources_1 lists the
#   wrapper as "$PGENDIR/sources_1/bd/up_proj/hdl/up_proj_wrapper.v" AND its
#   TopModule is up_proj_wrapper with TopAutoSet=TRUE. i.e. the BD must live
#   INSIDE the project so its generated wrapper lands under the project's own
#   gen dir and Vivado auto-selects it as top.
#
#   So: recreate the project at root, named up_proj_gemm, so that
#     <root>/up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd   (already there)
#     <root>/up_proj_gemm.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v
#   are project-relative. The corrupted root .xpr is deleted first; the .srcs
#   and .gen dirs are left in place.
#
# IRON RULES:
#   * no update_compile_order  (steals TOP -> puf_dec_bd -> manual mode)
#   * no reorder_files         (-disable_unused sets IS_ENABLED=0)
#   * no explicit set_property TOP  (auto mode rejects it: 20-742/20-730)
#   * no source_mgmt_mode None
#
# PUF delivery: constr/drc_relax_pre.tcl as STEPS.<STEP>.TCL.PRE on impl_1.
#   It downgrades DRC LUTLP-1, sets ALLOW_COMBINATORIAL_LOOPS on the real PUF
#   nets, and sources constr/puf_loc_generated.tcl to freeze each butterfly LUT
#   to its LOC+BEL. Must run inside the impl sub-processes (an XDC is ignored).
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set bd     "$root/up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd"
set drcpre "$root/constr/drc_relax_pre.tcl"
set oldxpr "$root/up_proj_gemm.xpr"

puts "== ROOT $root"
if {![file exists $bd]}     { puts "!! missing .bd: $bd"; return }
if {![file exists $drcpre]} { puts "!! missing $drcpre"; return }

#---------------------------------------------------------------------------
# 1) recreate the project in place (drop only the corrupted .xpr)
#---------------------------------------------------------------------------
if {[file exists $oldxpr]} { file delete -force $oldxpr }
create_project up_proj_gemm $root -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
puts "== recreated project; source_mgmt_mode=[get_property source_mgmt_mode [current_project]]"

#---------------------------------------------------------------------------
# 2) sources: all RTL + constraints + the in-place BD
#---------------------------------------------------------------------------
set rtl [concat [glob -nocomplain $root/rtl/*.sv] [glob -nocomplain $root/rtl/*.v]]
foreach f $rtl { add_files -norecurse $f }
puts "== added [llength $rtl] RTL files"

add_files -fileset constrs_1 -norecurse "$root/constr/puf_lock.xdc"
add_files -fileset constrs_1 -norecurse "$root/constr/puf_pblock.xdc"
add_files -norecurse $bd
puts "== added constraints + BD"

#---------------------------------------------------------------------------
# 3) regenerate BD targets + wrapper. reset_target forces fresh packaging of the
#    module-reference IP (puf_dec_bd changed in 7-1d; stale .dcp must not be
#    reused). make_wrapper writes the wrapper under THIS project's gen dir and
#    registers it with the BD, so Vivado can auto-select it as top.
#---------------------------------------------------------------------------
reset_target all [get_files up_proj.bd]
generate_target all [get_files up_proj.bd]
puts "== generate_target done (41-1726 above means failure)"
make_wrapper -files [get_files up_proj.bd] -top
puts "== make_wrapper done"

foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper entry: [get_property FILE_NAME $f] IS_ENABLED=[get_property IS_ENABLED $f]"
}
set top [get_property TOP [get_filesets sources_1]]
puts "== TOP after wrapper = '$top'"

#---------------------------------------------------------------------------
# 4) PUF delivery hooks on impl_1
#---------------------------------------------------------------------------
foreach step {OPT_DESIGN PLACE_DESIGN ROUTE_DESIGN WRITE_BITSTREAM} {
  catch { set_property STEPS.${step}.TCL.PRE $drcpre [get_runs impl_1] }
}
puts "== attached drc_relax_pre.tcl to impl_1 steps"

#---------------------------------------------------------------------------
# 5) synthesis
#---------------------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS   [get_runs synth_1]]
puts "== synth_1 PROGRESS=$sp  STATUS=$ss"
if {$sp ne "100%" || ![string match "*Complete!*" $ss]} {
  puts "!! SYNTH FAILED -> $root/up_proj_gemm.runs/synth_1/runme.log"
  puts "== BUILD_FINAL_DONE_FAIL"
  return
}

#---------------------------------------------------------------------------
# 6) PUF presence check (expect 128 distinct butterfly cells)
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
  puts "== BUILD_FINAL_DONE_FAIL"
  return
}

#---------------------------------------------------------------------------
# 7) implementation + bitstream
#---------------------------------------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "== impl_1 PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"

set bit "$root/up_proj_gemm.runs/impl_1/up_proj_wrapper.bit"
if {[file exists $bit]} {
  puts "== BITSTREAM $bit ([file size $bit] bytes)"
  puts "== BUILD_FINAL_DONE_OK"
} else {
  puts "!! no bitstream produced"
  puts "== BUILD_FINAL_DONE_FAIL"
}
