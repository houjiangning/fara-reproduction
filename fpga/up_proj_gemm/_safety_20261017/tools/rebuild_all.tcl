#-----------------------------------------------------------------------------
# rebuild_all.tcl -- recover the lost integrated BD and produce the FINAL
#                    frozen bitstream, in one pass.
#
# CONTEXT (why this exists):
#   A previous attempt ran create_project -force IN THE SOURCE DIRECTORY, which
#   deleted <root>/up_proj_gemm.srcs/ (holding the integrated up_proj.bd) plus
#   .gen/.runs. The integrated BD is gone; the recycle bin only has the Oct-01
#   loopback BD. So we rebuild the integration deterministically:
#     Oct-01 backup BD (loopback)
#       -> tools/add_gemm_to_bd.tcl      (GEMM + fp32 IPs, 0xA0010000)
#       -> tools/add_puf_to_bd.tcl       (Butterfly PUF,  0xA0030000)
#       -> tools/add_puf_dec_to_bd.tcl   (AES decrypt + route2, 0xA0020000, MI 3->4)
#   Those three scripts ARE what built the original integrated BD, and they are
#   written to be idempotent, so re-running them reproduces the same topology.
#
# KEY LAYOUT FIX (this is what finally makes auto-TOP work):
#   The fresh project lives in an ISOLATED dir (final_build), and the seed BD is
#   copied INSIDE the project's own .srcs. Therefore make_wrapper writes the
#   wrapper to THIS project's .gen, and Vivado recognises it as the BD wrapper
#   and auto-selects it as top (the Oct-01 project proves this works). The earlier
#   failure (20-730 "could not find a top") happened because the BD was
#   referenced from OUTSIDE the project, so the wrapper landed in a foreign .gen.
#
# IRON RULES: no in-place create_project; no explicit set_property TOP; no
#   reorder_files; no source_mgmt_mode None.
#
# PUF delivery: constr/drc_relax_pre.tcl as STEPS.<STEP>.TCL.PRE on impl_1, which
#   sources constr/puf_loc_generated.tcl to freeze each butterfly LUT at its
#   LOC+BEL. Must run inside the impl sub-processes.
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set fb     "$root/final_build"
set proj   "$fb/up_proj_gemm_final.xpr"
set bakbd  "$root/_backup_bd_20261001/up_proj.bd"
set srcbd  "$fb/up_proj_gemm_final.srcs/sources_1/bd/up_proj/up_proj.bd"
set drcpre "$root/constr/drc_relax_pre.tcl"

puts "== ROOT $root"
if {![file exists $bakbd]}  { puts "!! missing seed BD: $bakbd"; return }
if {![file exists $drcpre]} { puts "!! missing $drcpre"; return }

#---------------------------------------------------------------------------
# 1) fresh project in an ISOLATED directory (never in-place)
#---------------------------------------------------------------------------
if {[file exists $fb]} { file delete -force $fb }
create_project up_proj_gemm_final $fb -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
puts "== created fresh project in isolated dir; source_mgmt_mode=[get_property source_mgmt_mode [current_project]]"

#---------------------------------------------------------------------------
# 2) seed the BD INSIDE the project (project-relative -> wrapper lands here)
#---------------------------------------------------------------------------
file mkdir [file dirname $srcbd]
file copy -force $bakbd $srcbd
add_files -norecurse $srcbd
puts "== seeded BD: $srcbd"

#---------------------------------------------------------------------------
# 3) all RTL + constraints
#---------------------------------------------------------------------------
set rtl [concat [glob -nocomplain $root/rtl/*.sv] [glob -nocomplain $root/rtl/*.v]]
foreach f $rtl { add_files -norecurse $f }
puts "== added [llength $rtl] RTL files"
add_files -fileset constrs_1 -norecurse "$root/constr/puf_lock.xdc"
add_files -fileset constrs_1 -norecurse "$root/constr/puf_pblock.xdc"

#---------------------------------------------------------------------------
# 3b) CRITICAL ORDERING: make the SEED BD's wrapper FIRST, so sources_1 has a
#     top module. The integration scripts create BD cells with module references
#     (create_bd_cell -type module -reference gemm_up_proj_bd ...); that only
#     resolves when the fileset has a top to build the hierarchy from. Without
#     it you get [filemgmt 20-730] + [56-587] + [BD 41-1690] and the cell
#     creation fails. In the original project the loopback wrapper already
#     existed when these scripts ran -- that is why they worked there.
#---------------------------------------------------------------------------
generate_target all [get_files up_proj.bd]
make_wrapper -files [get_files up_proj.bd] -top
set _w "$fb/up_proj_gemm_final.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v"
if {[llength [get_files -quiet $_w]] == 0} { add_files -norecurse $_w }
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== seed wrapper [get_property FILE_NAME $f] IS_ENABLED=[get_property IS_ENABLED $f]"
}
puts "== seed TOP = '[get_property TOP [get_filesets sources_1]]'"

#---------------------------------------------------------------------------
# 4) re-integrate by REUSING the proven scripts (they see an open project and
#    reuse it, so they will not close ours)
#---------------------------------------------------------------------------
puts "==== sourcing add_gemm_to_bd.tcl ===="
source "$root/tools/add_gemm_to_bd.tcl"
puts "==== sourcing add_puf_to_bd.tcl ===="
source "$root/tools/add_puf_to_bd.tcl"
puts "==== sourcing add_puf_dec_to_bd.tcl ===="
source "$root/tools/add_puf_dec_to_bd.tcl"

#---------------------------------------------------------------------------
# 5) generate targets + wrapper; confirm auto-TOP
#---------------------------------------------------------------------------
generate_target all [get_files up_proj.bd]
make_wrapper -files [get_files up_proj.bd] -top
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper [get_property FILE_NAME $f] IS_ENABLED=[get_property IS_ENABLED $f]"
}
set top [get_property TOP [get_filesets sources_1]]
puts "== TOP = '$top'"

#---------------------------------------------------------------------------
# 6) PUF delivery hooks + persist BEFORE launch (launch_runs child reads disk)
#---------------------------------------------------------------------------
foreach step {OPT_DESIGN PLACE_DESIGN ROUTE_DESIGN WRITE_BITSTREAM} {
  catch { set_property STEPS.${step}.TCL.PRE $drcpre [get_runs impl_1] }
}
puts "== attached drc_relax_pre.tcl to impl_1 steps"
save_project
puts "== project saved"

#---------------------------------------------------------------------------
# 7) synthesis
#---------------------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set sp [get_property PROGRESS [get_runs synth_1]]
set ss [get_property STATUS   [get_runs synth_1]]
puts "== synth_1 PROGRESS=$sp  STATUS=$ss"
if {$sp ne "100%" || ![string match "*Complete!*" $ss]} {
  puts "!! SYNTH FAILED -> $fb/up_proj_gemm_final.runs/synth_1/runme.log"
  puts "== BUILD_FINAL_DONE_FAIL"
  return
}

#---------------------------------------------------------------------------
# 8) PUF presence check (expect 128 distinct butterfly cells)
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
# 9) implementation + bitstream
#---------------------------------------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "== impl_1 PROGRESS=[get_property PROGRESS [get_runs impl_1]]  STATUS=[get_property STATUS [get_runs impl_1]]"

set bit "$fb/up_proj_gemm_final.runs/impl_1/up_proj_wrapper.bit"
if {[file exists $bit]} {
  puts "== BITSTREAM $bit ([file size $bit] bytes)"
  puts "== BUILD_FINAL_DONE_OK"
} else {
  puts "!! no bitstream produced"
  puts "== BUILD_FINAL_DONE_FAIL"
}
