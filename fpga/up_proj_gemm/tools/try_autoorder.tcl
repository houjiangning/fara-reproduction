#-----------------------------------------------------------------------------
# try_autoorder.tcl -- 试着把 sources_1 的编译顺序模式设回 Automatic，并当场验证
#   验证方式：设完之后立刻跑 reset_target + generate_target，
#   看 [BD 41-1726] / [filemgmt 56-176] 是否消失（消失即修好）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"

set fs [get_filesets sources_1]
puts "== BEFORE: CompileOrderMode = '[get_property CompileOrderMode $fs]'"

foreach cand {Automatic Auto automatic} {
  if {[catch { set_property CompileOrderMode $cand $fs } e]} {
    puts "== set CompileOrderMode $cand -> FAIL: $e"
  } else {
    puts "== set CompileOrderMode $cand -> OK (now '[get_property CompileOrderMode $fs]')"
  }
}

catch { update_compile_order -fileset sources_1 }
puts "== after update_compile_order"

puts "== reset_target"
reset_target all [get_files up_proj.bd]
puts "== generate_target  (看这里还报不报 41-1726 / 56-176)"
generate_target all [get_files up_proj.bd]
puts "== make_wrapper"
make_wrapper -files [get_files up_proj.bd] -top

save_bd_design
puts "== TRY_DONE"
close_project
