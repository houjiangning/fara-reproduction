#-----------------------------------------------------------------------------
# restore_group.tcl -- create ONE integration group's module-reference cell,
#   in its own batch process.
#
# WHY ONE GROUP PER PROCESS:
#   * update_compile_order MUST run with the BD CLOSED and with few top
#     candidates, otherwise Vivado clears the top ([filemgmt 20-730]) and
#     create_bd_cell cannot resolve the module (56-587 / BD 41-1690). Proven:
#     diag_modref (BD closed, 2 candidates) SUCCEEDED; every attempt with more
#     candidates or with the BD open FAILED.
#   * A fresh process starts with the BD closed.
#   * We accumulate the RTL of all groups up to the current one, so the cells
#     already saved in the BD stay resolvable. Modules already turned into BD
#     cells are excluded from top candidates, so each update sees at most
#     {up_proj_wrapper + this group's module} = 2 candidates.
#   * The project file is NOT saved here (save_project is unavailable in this
#     build -- it errors "Missing value for option 'name'"); only save_bd_design
#     is used, which is what persists the new cell. RTL is re-added each run.
#
# Usage: vivado -mode batch -source tools/restore_group.tcl \
#          -nojournal -log <f> -tclargs <gemm|puf|route2|dec>
#-----------------------------------------------------------------------------
set root  [file normalize [file join [file dirname [info script]] ..]]
set group [lindex $argv 0]
if {$group eq ""} { puts "!! no group given"; return }

set gemmf {gemm_up_proj_core.sv gemm_up_proj_axi_lite.sv gemm_up_proj_top.sv \
           far_reroute.sv gemm_up_proj_bd.v fp32_mul.sv fp32_add.sv}
set puff  {bpuf_cell.sv bpuf_array.sv bpuf_ctrl.sv puf_axi_lite.sv puf_bd.v}
set r2f   {axis_route2.v}
set decf  {aes256_sbox.sv aes256_core.sv aes256_ctr.sv key_mgr.sv fuzzy_extract.sv \
           sha256_kdf.sv wdec_stream.sv puf_dec_axi_lite.sv puf_dec_bd.v}

switch -- $group {
  gemm   { set files $gemmf;                    set cellpairs {gemm_up_proj_bd:gemm_up_proj_bd_0} }
  puf    { set files [concat $gemmf $puff];     set cellpairs {puf_bd:puf_bd_0} }
  route2 { set files [concat $gemmf $puff $r2f]; set cellpairs {axis_route2:axis_route2_0} }
  dec    { set files [concat $gemmf $puff $r2f $decf]; set cellpairs {puf_dec_bd:puf_dec_bd_0} }
  default { puts "!! unknown group '$group'"; return }
}

open_project "$root/up_proj_gemm.xpr"
puts "== GROUP $group opened; mode = [get_property source_mgmt_mode [current_project]]  TOP = '[get_property TOP [get_filesets sources_1]]'"
set_property source_mgmt_mode All [current_project]

foreach n $files {
  if {[llength [get_files -quiet "$root/rtl/$n"]] == 0} { add_files -norecurse "$root/rtl/$n" }
}
puts "== GROUP $group: RTL added ([llength $files] files)"

update_compile_order -fileset sources_1
puts "== GROUP $group: TOP after update_compile_order = '[get_property TOP [get_filesets sources_1]]'"

open_bd_design [get_files -quiet up_proj.bd]
foreach pair $cellpairs {
  set ref  [lindex [split $pair :] 0]
  set cell [lindex [split $pair :] 1]
  if {[llength [get_bd_cells -quiet $cell]] > 0} {
    puts "== GROUP $group: $cell already present"
  } elseif {[catch { create_bd_cell -type module -reference $ref $cell } e]} {
    puts "!! GROUP $group: create_bd_cell $ref FAILED: $e"
  } else {
    puts "== GROUP $group: created $cell"
  }
}
save_bd_design
puts "== GROUP_${group}_DONE"
close_project
