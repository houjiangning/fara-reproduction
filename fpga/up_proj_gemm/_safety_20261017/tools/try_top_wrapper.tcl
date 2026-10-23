#-----------------------------------------------------------------------------
# try_top_wrapper.tcl -- 关键假设验证：sources_1 的 TOP 被误设成了 puf_dec_bd
#
#   证据：fix_source_mgmt.tcl 的 DIAG BEFORE/AFTER 显示
#     update_compile_order -fileset sources_1 把 TOP 从 up_proj_wrapper
#     改成了 puf_dec_bd（puf_dec_bd 也是个没有任何人例化的顶层模块，
#     所以自动识别会误选）。
#   TOP 错了 -> Vivado 无法从层次推导编译顺序 -> 退化成 manual
#           -> [filemgmt 56-176] module reference 被忽略 -> [BD 41-1726]。
#
#   本脚本：把 TOP 钉回 up_proj_wrapper，然后 generate_target，看 41-1726 是否消失。
#   **故意不再调用 update_compile_order**（它正是把 TOP 改错的元凶）。
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
open_project "$root/up_proj_gemm.xpr"
set fs [get_filesets sources_1]

puts "== TOP before = [get_property TOP $fs]"
catch { puts "== TOP_FILE before = [get_property TOP_FILE $fs]" }

set wrapper "$root/up_proj_gemm.gen/sources_1/bd/up_proj/hdl/up_proj_wrapper.v"
if {[catch { set_property TOP up_proj_wrapper $fs } e]} {
  puts "!! set TOP failed: $e"
} else {
  puts "== TOP set to up_proj_wrapper"
}
if {[file exists $wrapper]} {
  catch { set_property TOP_FILE $wrapper $fs }
  puts "== TOP_FILE = $wrapper"
} else {
  puts "!! wrapper 文件不存在: $wrapper"
}
puts "== TOP after  = [get_property TOP $fs]"

puts "== reset_target"
reset_target all [get_files up_proj.bd]
puts "== generate_target   <-- 看 41-1726"
generate_target all [get_files up_proj.bd]
puts "== make_wrapper"
make_wrapper -files [get_files up_proj.bd] -top
puts "== TOP final = [get_property TOP $fs]"

save_bd_design
puts "== TOPTEST_DONE"
close_project
