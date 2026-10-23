set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm_v2.xpr"
puts "== mode = [get_property source_mgmt_mode [current_project]]"
puts "== TOP  = '[get_property TOP [get_filesets sources_1]]'"
puts "== RTL files in sources_1 = [llength [get_files -quiet $root/rtl/*.sv]] sv + [llength [get_files -quiet $root/rtl/*.v]] v"
puts "== constrs = [get_files -quiet -of_objects [get_filesets constrs_1]]"
open_bd_design [get_files -quiet up_proj.bd]
puts "== BD cells = [get_bd_cells -quiet *]"
puts "== NUM_MI smartconnect_0 = [get_property CONFIG.NUM_MI [get_bd_cells smartconnect_0]]"
foreach s [get_bd_addr_segs -quiet *] { catch { puts "== ADDR $s offset=[get_property OFFSET $s]" } }
if {[catch { validate_bd_design } e]} { puts "!! validate FAILED: $e" } else { puts "== validate OK" }
puts "== VERIFY_V2_DONE"
