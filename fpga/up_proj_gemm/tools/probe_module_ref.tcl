#-----------------------------------------------------------------------------
# probe_module_ref.tcl -- 只读探针：把 update_module_reference 的用法与失败原因查清
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
open_bd_design [get_files -quiet up_proj.bd]

puts "==== PROBE ===="
set c [get_bd_cells -quiet puf_bd_0]
puts "CELL=$c"
puts "HAS_RESP_BEFORE=[llength [get_bd_pins -quiet puf_bd_0/resp_o]]"
puts "NPINS_BEFORE=[llength [get_bd_pins -quiet -of_objects $c]]"

set rc [catch { update_module_reference $c } e]
puts "RC=$rc"
puts "E=$e"
puts "ERRINFO=$::errorInfo"

puts "HAS_RESP_AFTER=[llength [get_bd_pins -quiet puf_bd_0/resp_o]]"
puts "NPINS_AFTER=[llength [get_bd_pins -quiet -of_objects $c]]"
puts "==== PROBE END ===="
