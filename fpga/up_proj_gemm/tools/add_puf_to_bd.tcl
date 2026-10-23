#-----------------------------------------------------------------------------
# add_puf_to_bd.tcl -- insert the Butterfly PUF into the existing Block Design
#
# NOTE: keep this file ASCII-only. Vivado's Tcl on Windows decodes scripts with
# the system codepage (GBK); UTF-8 Chinese bytes can decode to 0x5C ('\') and
# break Tcl parsing.
#
# WHY THIS IS SIMPLER THAN THE GEMM INSERTION:
#   The PUF is a pure CONTROL peripheral -- it has no AXI4-Stream interface and
#   is not part of the data path. So this script only ADDS a cell and hangs it
#   off smartconnect_0. It does NOT touch any existing stream net.
#
# Steps:
#   1) add the PUF RTL + constr/puf_lock.xdc to the project
#   2) create puf_bd_0 (module reference)
#   3) smartconnect_0: NUM_MI 2 -> 3 (M02 -> puf)
#   4) connect clock / reset
#   5) set ASSOCIATED_BUSIF and align FREQ_HZ with the peer
#   6) assign base address 0xA0030000 / 64K
#   7) validate_bd_design + save_bd_design
#
# ADDRESS MAP (keep this in sync as P2 adds the AES block):
#   0xA0010000 / 64K  gemm_up_proj_bd_0   (S_AXI,  smartconnect_0/M01_AXI)
#   0xA0020000 / 64K  (reserved for P2 AES decrypt block)
#   0xA0030000 / 64K  puf_bd_0            (S_AXI,  smartconnect_0/M02_AXI)
#   NOTE for P2: adding the AES block needs NUM_MI 3 -> 4 and should take
#   M03_AXI, keeping M02 for the PUF. Do not renumber M02.
#
# Usage (project must not be open in the GUI):
#   vivado -mode batch -source tools/add_puf_to_bd.tcl
# or from an open Vivado Tcl console:
#   source <path>/tools/add_puf_to_bd.tcl
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set PUF_BASE  0xA0030000
set PUF_RANGE 64K

puts "== ROOT $root"

# Work both ways:
#   * batch mode  : project closed -> open it
#   * GUI console : reuse the already-open project, do not close it
set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
  puts "== opened project (batch mode)"
} else {
  puts "== reusing already-open project: [current_project]"
}

#---------------------------------------------------------------------------
# 1) add RTL + constraints
#---------------------------------------------------------------------------
set rtl_files [list \
  "$root/rtl/bpuf_cell.sv" \
  "$root/rtl/bpuf_array.sv" \
  "$root/rtl/bpuf_ctrl.sv" \
  "$root/rtl/puf_axi_lite.sv" \
  "$root/rtl/puf_bd.v" \
]
foreach f $rtl_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -norecurse $f
    puts "== added $f"
  } else {
    puts "== already in project: [file tail $f]"
  }
}

# XDC files.
#   puf_lock.xdc    : ALWAYS. Downgrades the LUTLP-1 combinatorial-loop DRC.
#                     Written with plain constraint commands only -- XDC rejects
#                     control flow (if/catch/foreach/puts), and a version that
#                     used "if" was silently skipped, which blocked bitgen with
#                     128 DRC errors on 2026-10-13.
#   puf_pblock.xdc  : OPTIONAL. Only exists after tools/puf_lock_from_place.tcl
#                     has been run once, because it needs real SLICE coordinates.
set xdc_list [list "$root/constr/puf_lock.xdc"]
if {[file exists "$root/constr/puf_pblock.xdc"]} {
  lappend xdc_list "$root/constr/puf_pblock.xdc"
  puts "== found constr/puf_pblock.xdc -- will add it (placement freeze active)"
} else {
  puts "== constr/puf_pblock.xdc not present yet (placement not frozen)"
  puts "==   run tools/puf_lock_from_place.tcl after the first implementation"
}
foreach f $xdc_list {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -fileset constrs_1 -norecurse $f
    puts "== added $f"
  } else {
    puts "== already in project: [file tail $f]"
  }
}

# Module references resolve from the sources_1 compile order. With Vivado's
# default DisplayOnly source management, a module that is not reachable from the
# top hierarchy can be AutoDisabled and then "nothing found to match the name".
# Force full source management before computing the order.
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1
# 注意：**不要**对 constrs_1 调 update_compile_order —— 该命令只对源文件集有效。
# 上一版脚本里加了这一行，结果制造出无意义的红鲱鱼：
#   CRITICAL WARNING: [filemgmt 20-730] Could not find a top module in the fileset constrs_1
# constraints 文件集没有"top module"概念，这个警告纯属自找的。

#---------------------------------------------------------------------------
# 2~7) modify the BD
#---------------------------------------------------------------------------
open_bd_design [get_files -quiet up_proj.bd]

# --- idempotent connect helpers (same discipline as add_gemm_to_bd.tcl) -----
# Compare the two pins' NETS, not merely "does either pin have any net?" --
# pl_clk0 / peripheral_aresetn fan out to every cell, so the naive test always
# reports "already connected" and silently skips the new cell, leaving its
# clock/reset floating (validate then fails with BD 41-758).
proc _same_net {na nb} {
  return [expr {[llength $na] > 0 && [llength $nb] > 0 &&
                [lindex $na 0] eq [lindex $nb 0]}]
}
proc conn_net {a b} {
  set pa [get_bd_pins $a]
  set pb [get_bd_pins $b]
  set na [get_bd_nets -quiet -of_objects $pa]
  set nb [get_bd_nets -quiet -of_objects $pb]
  if {[_same_net $na $nb]} {
    puts "== already connected: $a <-> $b"
    return
  }
  # b is the fan-in pin: clear only ITS stale net. Never touch a's net -- a is
  # pl_clk0 / peripheral_aresetn, which fans out to the whole BD.
  foreach n $nb { catch { delete_bd_objs $n } }
  connect_bd_net $pa $pb
  puts "== connected $a <-> $b"
}
proc conn_intf {a b} {
  set pa [get_bd_intf_pins $a]
  set pb [get_bd_intf_pins $b]
  set na [get_bd_intf_nets -quiet -of_objects $pa]
  set nb [get_bd_intf_nets -quiet -of_objects $pb]
  if {[_same_net $na $nb]} {
    puts "== already connected: $a <-> $b"
    return
  }
  foreach n [lsort -unique [concat $na $nb]] { catch { delete_bd_objs $n } }
  connect_bd_intf_net $pa $pb
  puts "== connected $a <-> $b"
}

# 2) create the PUF cell only when actually missing (never delete an existing
#    cell -- that also drops every net it takes part in)
if {[llength [get_bd_cells -quiet puf_bd_0]] > 0} {
  puts "== puf_bd_0 already present, keeping it"
} else {
  create_bd_cell -type module -reference puf_bd puf_bd_0
  puts "== created puf_bd_0"
}

# 3) smartconnect_0: 2 slave ports (HPM0/HPM1), 3 master ports
#    (M00->DMA, M01->GEMM, M02->PUF)
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {3}] [get_bd_cells smartconnect_0]
puts "== smartconnect_0 NUM_SI=2 NUM_MI=3"

# 4) AXI-Lite control port
conn_intf smartconnect_0/M02_AXI puf_bd_0/s_axi

# 5) clock / reset (single clock domain, same as everything else)
conn_net zynq_ultra_ps_e_0/pl_clk0         puf_bd_0/s_axi_aclk
conn_net rst_ps8_0_99M/peripheral_aresetn  puf_bd_0/s_axi_aresetn

# 6a) tell the BD that s_axi_aclk clocks the S_AXI interface
#
# 实测：Vivado 会在 create_bd_cell 时**自动推断**出这些参数
#   INFO: [IP_Flow 19-4728] Bus Interface 's_axi_aclk': Added interface parameter
#                           'ASSOCIATED_BUSIF' with value 's_axi'
# 因此下面的显式 set_property 会报 "Cannot set ... It is read-only" 的
# CRITICAL WARNING —— 这是**好事**，说明已经设好了，不是错误。
# 所以这里先读回现值判断，只在确实缺失时才尝试写。
if {[catch {
  set cur [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins puf_bd_0/s_axi_aclk]]
  if {$cur eq "" } {
    set_property CONFIG.ASSOCIATED_BUSIF {s_axi} [get_bd_pins puf_bd_0/s_axi_aclk]
    set_property CONFIG.ASSOCIATED_RESET {s_axi_aresetn} [get_bd_pins puf_bd_0/s_axi_aclk]
    puts "== ASSOCIATED_BUSIF was empty -> set to s_axi"
  } else {
    puts "== ASSOCIATED_BUSIF already = $cur (auto-inferred; the read-only warning is expected/benign)"
  }
} e]} {
  puts "!! ASSOCIATED_BUSIF check failed (non-fatal): $e"
}

# 6b) match interface FREQ_HZ to the peer.
#     The ZCU106 board preset sets pl_clk0 to 99.999999 MHz, reported as
#     99990005 Hz. A BD module reference defaults every interface FREQ_HZ to
#     100000000 -> validate_bd_design then fails with BD 41-237.
set peer_f [get_property CONFIG.FREQ_HZ [get_bd_intf_pins smartconnect_0/M02_AXI]]
catch { set_property CONFIG.FREQ_HZ $peer_f [get_bd_intf_pins puf_bd_0/s_axi] }
puts "== FREQ_HZ puf_bd_0/s_axi <- smartconnect_0/M02_AXI ($peer_f)"

# 7) address assignment
set segs [get_bd_addr_segs -quiet -of_objects [get_bd_cells puf_bd_0]]
if {[llength $segs] == 0} {
  set segs [get_bd_addr_segs -quiet *puf_bd_0*]
}
if {[llength $segs] == 0} {
  puts "!! ERROR: no address segments found for puf_bd_0 -- check the module reference"
} else {
  assign_bd_address -offset $PUF_BASE -range $PUF_RANGE \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    $segs -force
  puts "== address assigned: $PUF_BASE / $PUF_RANGE"
}

validate_bd_design
save_bd_design
puts "== BD_SAVED"

foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_cells puf_bd_0]] {
  puts "== MAP $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
}

#---------------------------------------------------------------------------
# 8) sanity: is the PUF cell still in the source set?
#---------------------------------------------------------------------------
puts "== check: PUF RTL enabled in sources_1"
foreach f $rtl_files {
  set ff [get_files -quiet $f]
  if {[llength $ff] > 0} {
    catch { puts "==   [file tail $f] IS_ENABLED=[get_property IS_ENABLED $ff]" }
  }
}

puts "== ADD_PUF_DONE"
puts "== NEXT: synth_1 must be re-run from scratch (new OOC module reference)."
puts "==       Then constrain the PUF placement: see constr/puf_lock.xdc and"
puts "==       tools/puf_lock_from_place.tcl."

if {$_we_opened} { close_project }
