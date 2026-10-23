#-----------------------------------------------------------------------------
# diag_puf_cells.tcl -- read the REAL PUF cell hierarchy from the placed netlist
#
# WHY: the pblock generator (tools/puf_lock_from_place.tcl) has to name cells
#      exactly. A guessed path such as *puf_bd_0/u_array* was measured to be
#      unreliable, so print the real names first and code against those.
#
# USAGE:
#   vivado -mode batch -source tools/diag_puf_cells.tcl
#
# NOTE: prose below avoids decorative square brackets on purpose -- inside a
#       Tcl double-quoted string a bracket means COMMAND SUBSTITUTION.
#-----------------------------------------------------------------------------

set root [file normalize [file join [file dirname [info script]] ..]]

if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  puts "== diag: opened project"
}
open_run impl_1
puts "== diag: design = [current_design]"

foreach pat {*g_cell* *u_array* *puf_bd_0* *puf_bd_0/u_array* *inst/u_array*} {
  set cs [get_cells -quiet -hier -filter [format {NAME =~ %s} $pat]]
  puts "== diag: pattern $pat -> [llength $cs] cells"
  set n 0
  foreach c $cs {
    puts "== diag:     name = [get_property NAME $c]"
    puts "== diag:     LOC  = [get_property LOC $c]  TYPE = [get_property PRIMITIVE_TYPE $c]  REF = [get_property REF_NAME $c]"
    incr n
    if {$n >= 3} { break }
  }
}

puts "== diag: DONE"
close_project
