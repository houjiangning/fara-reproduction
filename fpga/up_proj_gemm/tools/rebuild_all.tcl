#-----------------------------------------------------------------------------
# rebuild_all.tcl -- recover the lost integrated BD and produce the FINAL
#                    frozen bitstream.
#
# CONTEXT:
#   An earlier attempt ran create_project -force IN THE SOURCE DIRECTORY, which
#   deleted <root>/up_proj_gemm.srcs/ (holding the integrated up_proj.bd) plus
#   .gen/.runs. Only the Oct-01 loopback BD survives (in _backup_bd_20261001).
#   So we rebuild the integration deterministically from that seed:
#     Oct-01 loopback BD
#       -> tools/add_gemm_to_bd.tcl      (GEMM + fp32 IPs, 0xA0010000)
#       -> tools/add_puf_to_bd.tcl       (Butterfly PUF,  0xA0030000)
#       -> tools/add_puf_dec_to_bd.tcl   (AES decrypt + route2, 0xA0020000, MI 3->4)
#   Those scripts ARE what built the original integrated BD; they are idempotent.
#
# WHY THE PROJECT IS RECREATED AT ROOT, NAMED up_proj_gemm:
#   The seeded .bd carries an internal expectation that its generated products
#   live in a gen dir named "up_proj_gemm.gen". A project named differently (e.g.
#   up_proj_gemm_final in an isolated dir) made make_wrapper write the wrapper to
#   a mismatched gen dir, so Vivado did not treat it as the BD wrapper and
#   auto-TOP failed (20-730). Recreating the ORIGINAL layout
#     project dir = root, name = up_proj_gemm,
#     .srcs = root/up_proj_gemm.srcs, .gen = root/up_proj_gemm.gen
#   makes the seeded BD, its gen dir and the wrapper all consistent -> auto-TOP
#   works, exactly as in the Oct-01 project.
#   create_project -force only removes <name>.* entries (.srcs/.gen/.runs/.sim/
#   .cache/.hw/.ip_user_files/.xpr); rtl/, constr/, tools/ are untouched (verified
#   on the previous run). A paranoia copy lives in _safety_20261017/.
#
# IRON RULES: no explicit set_property TOP; no reorder_files;
#   no source_mgmt_mode None; never create_project in-place *before* a backup.
#
# PUF delivery: constr/drc_relax_pre.tcl as STEPS.<STEP>.TCL.PRE on impl_1; it
#   downgrades LUTLP-1, sets ALLOW_COMBINATORIAL_LOOPS on the real PUF nets, and
#   sources constr/puf_loc_generated.tcl to freeze each butterfly LUT at LOC+BEL.
#-----------------------------------------------------------------------------
set root   [file normalize [file join [file dirname [info script]] ..]]
set proj   "$root/up_proj_gemm.xpr"
set bakbd  "$root/_backup_bd_20261001/up_proj.bd"
set srcbd  "$root/up_proj_gemm.srcs/sources_1/bd/up_proj/up_proj.bd"
set wrap   "$root/up_proj_gemm.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v"
set drcpre "$root/constr/drc_relax_pre.tcl"

puts "== ROOT $root"
if {![file exists $bakbd]}  { puts "!! missing seed BD: $bakbd"; return }
if {![file exists $drcpre]} { puts "!! missing $drcpre"; return }

#---------------------------------------------------------------------------
# 1) recreate the ORIGINAL project layout at root (safe: only <name>.* removed)
#---------------------------------------------------------------------------
if {[file exists $proj]} { file delete -force $proj }
create_project up_proj_gemm $root -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu106:part0:2.6 [current_project]
puts "== recreated project at root; source_mgmt_mode=[get_property source_mgmt_mode [current_project]]"

#---------------------------------------------------------------------------
# 2) seed the BD INSIDE the project (project-relative)
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
# 3b) ORDERING: make the SEED BD wrapper FIRST so sources_1 has a top, which the
#     integration scripts need to resolve their module references.
#---------------------------------------------------------------------------
generate_target all [get_files up_proj.bd]
make_wrapper -files [get_files up_proj.bd] -top
if {[file exists $wrap] && [llength [get_files -quiet $wrap]] == 0} { add_files -norecurse $wrap }
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== seed wrapper [file tail $f] IS_ENABLED=[get_property IS_ENABLED $f]"
}
puts "== seed TOP = '[get_property TOP [get_filesets sources_1]]'"

#---------------------------------------------------------------------------
# 4) re-integrate (scripts see an open project and reuse it)
#---------------------------------------------------------------------------
puts "==== sourcing add_gemm_to_bd.tcl ===="
source "$root/tools/add_gemm_to_bd.tcl"
puts "==== sourcing add_puf_to_bd.tcl ===="
source "$root/tools/add_puf_to_bd.tcl"
puts "==== sourcing add_puf_dec_to_bd.tcl ===="
source "$root/tools/add_puf_dec_to_bd.tcl"

#---------------------------------------------------------------------------
# 5) regenerate targets + wrapper; confirm auto-TOP
#---------------------------------------------------------------------------
generate_target all [get_files up_proj.bd]
make_wrapper -files [get_files up_proj.bd] -top
if {[file exists $wrap] && [llength [get_files -quiet $wrap]] == 0} { add_files -norecurse $wrap }
foreach f [get_files -quiet *up_proj_wrapper.v] {
  puts "== wrapper [file tail $f] IS_ENABLED=[get_property IS_ENABLED $f]"
}
set top [get_property TOP [get_filesets sources_1]]
puts "== TOP = '$top'"

#---------------------------------------------------------------------------
# 6) PUF delivery hooks + persist BEFORE launch (child reads disk)
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
  puts "!! SYNTH FAILED -> $root/up_proj_gemm.runs/synth_1/runme.log"
  puts "== BUILD_FINAL_DONE_FAIL"
  return
}

#---------------------------------------------------------------------------
# 8) PUF presence check (expect 128)
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

set bit "$root/up_proj_gemm.runs/impl_1/up_proj_wrapper.bit"
if {[file exists $bit]} {
  puts "== BITSTREAM $bit ([file size $bit] bytes)"
  puts "== BUILD_FINAL_DONE_OK"
} else {
  puts "!! no bitstream produced"
  puts "== BUILD_FINAL_DONE_FAIL"
}
