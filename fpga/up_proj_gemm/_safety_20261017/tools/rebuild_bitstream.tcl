#-----------------------------------------------------------------------------
# rebuild_bitstream.tcl -- synthesis + implementation + write_bitstream.
#
# Keep this file ASCII-only. Vivado's Tcl on Windows decodes scripts with the
# system codepage (GBK); UTF-8 bytes can decode to 0x5C ('\') and break parsing.
#
# WHY THIS SCRIPT CHANGED (2026-10-06)
# ---------------------------------------------------------------------------
# Previous versions assumed the GEMM was synthesized OUT OF CONTEXT through the
# BD module reference and hard-gated the build on
#     .../ip/up_proj_gemm_up_proj_bd_0_0/up_proj_gemm_up_proj_bd_0_0.dcp
# That gate was WRONG and blocked every build:
#   * generate_target only ever writes the module-ref STUB
#       .../ip/up_proj_gemm_up_proj_bd_0_0/synth/up_proj_gemm_up_proj_bd_0_0.v
#     which itself instantiates gemm_up_proj_bd; it never writes a .dcp.
#   * the .dcp only appears if a separate OOC synthesis run exists, and in this
#     project that run had been destroyed by the diag_ooc*.tcl attempts.
#
# tools/fix_enable_rtl.tcl now switches the BD to GLOBAL synthesis
# (synth_checkpoint_mode none), so the module reference is synthesized
# IN-CONTEXT inside synth_1 and no OOC checkpoint exists at all. The whole
# "stale checkpoint -> old VERSION=0x0001_0000 bitstream" failure mode is
# therefore impossible by construction.
#
# The replacement gate verifies the opposite thing: that the current FaR RTL
# really was synthesized into synth_1, by looking for the GEMM wrapper cell in
# the synthesized netlist. A stale/black-box GEMM would not appear there.
#
# Prereq: tools/fix_enable_rtl.tcl has been run once.
#
# Usage (project must NOT be open in the GUI):
#   vivado -mode batch -source tools/rebuild_bitstream.tcl
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set jobs 8

puts "== ROOT $root"
open_project "$root/up_proj_gemm.xpr"

set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

set bd [get_files -quiet up_proj.bd]
if {[llength $bd] == 0} { error "up_proj.bd not found in the project" }
if {[catch {
  puts "== synth_checkpoint_mode = [get_property synth_checkpoint_mode $bd]"
} e]} { puts "== synth_checkpoint_mode not readable: $e" }

# newest RTL edit, reported for the record
set rtl_mtime 0
foreach f [glob -nocomplain "$root/rtl/*.v" "$root/rtl/*.sv"] {
  if {[file mtime $f] > $rtl_mtime} { set rtl_mtime [file mtime $f] }
}
puts "== newest RTL edit: [clock format $rtl_mtime -format {%Y-%m-%d %H:%M:%S}]"

#---------------------------------------------------------------------------
# [1] synth_1
#---------------------------------------------------------------------------
# synth_1: reuse it when it is already complete AND newer than the newest RTL
set synth_dcp "$root/up_proj_gemm.runs/synth_1/up_proj_wrapper.dcp"
set need_synth 1
if {[file exists $synth_dcp] && ([file mtime $synth_dcp] >= $rtl_mtime) \
    && ([get_property PROGRESS [get_runs synth_1]] eq "100%")} {
  set need_synth 0
  puts "== synth_1 already current (dcp newer than RTL) -- reusing it"
}

reset_run impl_1

if {$need_synth} {
  reset_run synth_1
  puts "== launch synth_1"
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  set st [get_property STATUS [get_runs synth_1]]
  puts "== synth_1 STATUS: $st"
  if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synth_1 did not complete: $st"
  }
} else {
  puts "== synth_1 STATUS (reused): [get_property STATUS [get_runs synth_1]]"
}

#---------------------------------------------------------------------------
# [2] GATE: the GEMM + FaR RTL must have been synthesized IN-CONTEXT
#
#     Two independent checks, because the obvious one is wrong:
#       (a) synth log must show far_reroute / gemm_up_proj_bd being compiled
#       (b) synthesized netlist must contain the GEMM hierarchy
#
#     NOTE on the cell name: Vivado flattens the module-ref wrapper, so the
#     netlist hierarchy is
#         up_proj_i/gemm_up_proj_bd_0/inst/u_top/u_gemm/...
#     i.e. it uses the BD cell name 'gemm_up_proj_bd_0'. Filtering on the
#     generated wrapper name 'up_proj_gemm_up_proj_bd_0_0' finds nothing and
#     produces a false failure.
#
#     Expected black boxes in synth are ONLY the Xilinx FP IPs
#     (fp32_add_ip / fp32_mul_ip), which are linked from their own .dcp at
#     implementation time. gemm_up_proj_bd must NOT be a black box.
#---------------------------------------------------------------------------
set synth_log "$root/up_proj_gemm.runs/synth_1/runme.log"
if {![file exists $synth_log]} {
  set cand [glob -nocomplain "$root/up_proj_gemm.runs/synth_1/*.log"]
  if {[llength $cand] > 0} { set synth_log [lindex $cand 0] }
}
puts "== synth log: $synth_log"

set log_ok 0
if {[catch {
  set fh [open $synth_log r]; set txt [read $fh]; close $fh
  foreach mod {far_reroute gemm_up_proj_bd} {
    if {[string first "synthesizing module '$mod'" $txt] >= 0} {
      puts "== log gate OK: '$mod' was synthesized"
      incr log_ok
    } else {
      puts "!! log gate FAIL: '$mod' not found in $synth_log"
    }
  }
} e]} {
  puts "!! log gate could not run: $e"
}

set cell_ok 0
if {[catch {
  open_run synth_1
  set cells [get_cells -hier -quiet -filter {NAME =~ "*gemm_up_proj_bd_0*"}]
  puts "== GEMM cells in synthesized netlist: [llength $cells]"
  if {[llength $cells] > 0} { set cell_ok 1 }
  close_design
} e]} {
  puts "!! netlist gate could not run: $e"
}

if {!($log_ok == 2 && $cell_ok)} {
  error "GEMM/FaR was NOT synthesized in-context (log gate=$log_ok/2, netlist gate=$cell_ok).\
 Run tools/fix_enable_rtl.tcl (it sets synth_checkpoint_mode none) and retry.\
 Refusing to build a bitstream that may not contain the FaR RTL."
}
puts "== in-context gate OK: GEMM + FaR RTL are part of synth_1"

#---------------------------------------------------------------------------
# [3] impl + bitstream
#---------------------------------------------------------------------------
puts "== launch impl_1 -to_step write_bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "== impl_1 STATUS: $st"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "impl_1 did not complete: $st"
}
puts "== impl_1 WNS: [get_property STATS.WNS [get_runs impl_1]] ns"

set bit [file join [get_property DIRECTORY [get_runs impl_1]] up_proj_wrapper.bit]
if {![file exists $bit]} { error "bitstream not found: $bit" }
puts "== BITSTREAM: $bit"
puts "== BITSTREAM mtime: [clock format [file mtime $bit] -format {%Y-%m-%d %H:%M:%S}]"
puts "== REBUILD_DONE"
close_project
