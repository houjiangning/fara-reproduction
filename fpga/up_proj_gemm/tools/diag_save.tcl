set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
puts "== commands matching *save*: [info commands *save*]"
puts "== save_project exists: [llength [info commands save_project]]"
puts "== save_project_as exists: [llength [info commands save_project_as]]"
puts "== commands matching *proj*: [info commands *proj*]"
if {[catch { save_project } e1]} { puts "SAVE plain : $e1" } else { puts "SAVE plain OK" }
if {[catch { save_project -force } e2]} { puts "SAVE -force: $e2" } else { puts "SAVE -force OK" }
if {[catch { save_project_as -name up_proj_gemm } e3]} { puts "SAVEAS no -force: $e3" } else { puts "SAVEAS no -force OK" }
puts "== DIAG_SAVE_DONE"
