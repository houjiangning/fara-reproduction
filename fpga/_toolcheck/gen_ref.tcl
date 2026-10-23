set rootdir [file normalize [file dirname [info script]]]
create_project -force fp_ip_ref "$rootdir/fp_ip_ref" -part xczu7ev-ffvc1156-2-e
source "$rootdir/../up_proj_gemm/tools/gen_fp_ip.tcl"
puts "== VEO FILES =="
foreach f [glob -nocomplain "$rootdir/fp_ip_ref/fp_ip_ref.gen/sources_1/ip/*/*.veo"] { puts $f }
close_project
