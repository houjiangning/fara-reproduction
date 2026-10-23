#-----------------------------------------------------------------------------
# add_gemm_to_bd.tcl -- insert the up_proj GEMM into the existing Block Design
#
# NOTE: keep this file ASCII-only. Vivado's Tcl on Windows decodes scripts with
# the system codepage (GBK); UTF-8 Chinese bytes can decode to 0x5C ('\') and
# break Tcl parsing.
#
# Steps:
#   1) generate the two Xilinx floating-point IPs (fp32_mul_ip / fp32_add_ip)
#   2) add the GEMM RTL to sources_1
#   3) delete axis_data_fifo_0 (the old loopback)
#   4) add gemm_up_proj_bd (plain-Verilog shim, see its file header)
#   5) connect:
#        axi_dma_0/M_AXIS_MM2S    -> gemm_up_proj_bd_0/s_axis
#        gemm_up_proj_bd_0/m_axis -> axi_dma_0/S_AXIS_S2MM
#        smartconnect_0/M01_AXI   -> gemm_up_proj_bd_0/s_axi  (NUM_MI 1->2)
#        pl_clk0 -> s_axi_aclk, peripheral_aresetn -> s_axi_aresetn
#        (also fixes the previously dangling smartconnect_1/aresetn)
#   6) assign base address 0xA0010000 / 64K to the GEMM S_AXI
#   7) validate_bd_design + save_bd_design
#
# Usage (project must not be open in the GUI):
#   vivado -mode batch -source tools/add_gemm_to_bd.tcl
# or from an open Vivado Tcl console:
#   source <path>/tools/add_gemm_to_bd.tcl
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set ADD_LAT 4
set MUL_LAT 8
set GEMM_BASE 0xA0010000
set GEMM_RANGE 64K

puts "== ROOT $root"

# Work both ways:
#   * batch mode  (vivado -mode batch -source add_gemm_to_bd.tcl): project closed -> open it
#   * GUI console (source .../add_gemm_to_bd.tcl while .xpr is open): reuse it, do not close
set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
  puts "== opened project (batch mode)"
} else {
  puts "== reusing already-open project: [current_project]"
}

#---------------------------------------------------------------------------
# 1) floating-point IPs
#    Idempotent: keep an existing IP whose C_Latency already matches, so a
#    re-run does not throw away the OOC synth/impl results.
#---------------------------------------------------------------------------
proc ensure_fp_ip {nm op lat extra} {
  if {[llength [get_ips -quiet $nm]] > 0} {
    set got [get_property CONFIG.C_Latency [get_ips $nm]]
    if {$got == $lat} {
      puts "== keep existing IP $nm (C_Latency=$got)"
      return
    }
    puts "== recreate $nm (C_Latency $got != $lat)"
    set xci [get_files -quiet "${nm}.xci"]
    if {[llength $xci] > 0} { remove_files $xci }
    if {[llength [get_ips -quiet $nm]] > 0} { delete_ip -quiet $nm }
  }
  create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $nm
  set_property -dict [concat [list \
    CONFIG.Operation_Type        $op \
    CONFIG.A_Precision_Type      {Single} \
    CONFIG.Result_Precision_Type {Single} \
    CONFIG.C_Rate                {1} \
    CONFIG.Maximum_Latency       {false} \
    CONFIG.C_Latency             $lat \
  ] $extra] [get_ips $nm]
  puts "== created IP $nm (C_Latency=$lat)"
}

ensure_fp_ip fp32_mul_ip Multiply   $MUL_LAT [list CONFIG.C_Mult_Usage {Full_Usage}]
ensure_fp_ip fp32_add_ip Add_Subtract $ADD_LAT {}

generate_target all [get_ips fp32_mul_ip fp32_add_ip]
set got_mul [get_property CONFIG.C_Latency [get_ips fp32_mul_ip]]
set got_add [get_property CONFIG.C_Latency [get_ips fp32_add_ip]]
puts "== FP_IP_LATENCY mul=$got_mul (want $MUL_LAT)  add=$got_add (want $ADD_LAT)"
if {$got_mul != $MUL_LAT || $got_add != $ADD_LAT} {
  error "FP IP latency mismatch: RTL params must match IP C_Latency"
}

#---------------------------------------------------------------------------
# 2) add RTL
#---------------------------------------------------------------------------
# 顺序无关，但 far_reroute.sv 必须在编译集合里，否则 core 里 u_far 例化会报
# "module not found"。far_reroute 与 core/top 同为 SystemVerilog，可一起交给
# sources_1；只有 BD 的 module-reference 顶层必须是纯 Verilog（gemm_up_proj_bd.v）。
set rtl_files [list \
  "$root/rtl/gemm_up_proj_core.sv" \
  "$root/rtl/gemm_up_proj_axi_lite.sv" \
  "$root/rtl/gemm_up_proj_top.sv" \
  "$root/rtl/far_reroute.sv" \
  "$root/rtl/gemm_up_proj_bd.v" \
  "$root/rtl/fp32_mul.sv" \
  "$root/rtl/fp32_add.sv" \
]
foreach f $rtl_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -norecurse $f
    puts "== added $f"
  } else {
    puts "== already in project: [file tail $f]"
  }
}
# Module references (BD "Add Module") resolve from the sources_1 compile order.
# With the default DisplayOnly source management Vivado can report "Could not
# find a top module in the fileset sources_1" and then fail with "Nothing was
# found in the project to match the name gemm_up_proj_bd". Force full source
# management before computing the order.
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

#---------------------------------------------------------------------------
# 3~6) modify the BD
#---------------------------------------------------------------------------
open_bd_design [get_files -quiet up_proj.bd]

# --- connect helpers -------------------------------------------------------
# Idempotent: re-running must not fail. The "already connected" test compares
# the two pins' NETS, not merely "does either pin have any net?". pl_clk0 and
# peripheral_aresetn fan out to every cell in the BD, so the naive test always
# reported them as connected and silently skipped the freshly re-created GEMM
# cell -- leaving s_axi_aclk / s_axi_aresetn floating and failing validate with
# "BD 41-758 ... not connected to a valid clock source".
proc _same_net {na nb} {
  return [expr {[llength $na] > 0 && [llength $nb] > 0 &&
                [lindex $na 0] eq [lindex $nb 0]}]
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
  # point-to-point: drop any stale net the cell delete left on either pin
  foreach n [lsort -unique [concat $na $nb]] { catch { delete_bd_objs $n } }
  connect_bd_intf_net $pa $pb
  puts "== connected $a <-> $b"
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

# 3) drop the loopback FIFO
if {[llength [get_bd_cells -quiet axis_data_fifo_0]] > 0} {
  delete_bd_objs [get_bd_cells axis_data_fifo_0]
  puts "== deleted axis_data_fifo_0"
}

# 4) add the GEMM
#    Keep an existing cell. Deleting it also drops every net it takes part in
#    (the two stream nets and the pl_clk0 / peripheral_aresetn fan-out taps), and
#    the reconnect that follows is exactly what produced the
#    "BD 41-758 /gemm_up_proj_bd_0/s_axi_aclk not connected to a valid clock
#    source" failure. Only create the cell when it is actually missing.
if {[llength [get_bd_cells -quiet gemm_up_proj_bd_0]] > 0} {
  puts "== gemm_up_proj_bd_0 already present, keeping it"
} else {
  create_bd_cell -type module -reference gemm_up_proj_bd gemm_up_proj_bd_0
  puts "== created gemm_up_proj_bd_0"
}

# 5) smartconnect_0: 2 slave ports (HPM0/HPM1), 2 master ports (M00->DMA, M01->GEMM)
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells smartconnect_0]
puts "== smartconnect_0 NUM_SI=2 NUM_MI=2"

# 5a) stream nets
conn_intf axi_dma_0/M_AXIS_MM2S    gemm_up_proj_bd_0/s_axis
conn_intf gemm_up_proj_bd_0/m_axis axi_dma_0/S_AXIS_S2MM

# 5b) AXI-Lite control port
conn_intf smartconnect_0/M01_AXI gemm_up_proj_bd_0/s_axi

# 5c) clock / reset
conn_net zynq_ultra_ps_e_0/pl_clk0              gemm_up_proj_bd_0/s_axi_aclk
conn_net rst_ps8_0_99M/peripheral_aresetn       gemm_up_proj_bd_0/s_axi_aresetn
if {[get_bd_nets -quiet -of_objects [get_bd_pins smartconnect_1/aresetn]] eq ""} {
  connect_bd_net [get_bd_pins rst_ps8_0_99M/peripheral_aresetn] \
                 [get_bd_pins smartconnect_1/aresetn]
  puts "== fixed unconnected smartconnect_1/aresetn"
}

# 5d) tell the BD that s_axi_aclk is the clock of all three interfaces
if {[catch {
  set_property CONFIG.ASSOCIATED_BUSIF {s_axi:s_axis:m_axis} \
               [get_bd_pins gemm_up_proj_bd_0/s_axi_aclk]
  set_property CONFIG.ASSOCIATED_RESET {s_axi_aresetn} \
               [get_bd_pins gemm_up_proj_bd_0/s_axi_aclk]
  puts "== ASSOCIATED_BUSIF set"
} e]} {
  puts "!! ASSOCIATED_BUSIF failed (non-fatal): $e"
}

# 5e) match interface FREQ_HZ to the PL clock domain.
#     The ZCU106 board preset sets pl_clk0 to 99.999999 MHz, which Vivado
#     reports as 99990005 Hz. A BD module reference, however, defaults every
#     interface FREQ_HZ to 100000000 -- validate_bd_design then fails with
#     "BD 41-237 FREQ_HZ does not match". Force each GEMM interface to the
#     value its peer already carries.
foreach pr [list \
    [list gemm_up_proj_bd_0/s_axi  smartconnect_0/M01_AXI] \
    [list gemm_up_proj_bd_0/s_axis axi_dma_0/M_AXIS_MM2S] \
    [list gemm_up_proj_bd_0/m_axis axi_dma_0/S_AXIS_S2MM]] {
  set mine [lindex $pr 0]
  set peer [lindex $pr 1]
  set f [get_property CONFIG.FREQ_HZ [get_bd_intf_pins $peer]]
  set_property CONFIG.FREQ_HZ $f [get_bd_intf_pins $mine]
  catch {
    set d [get_property CONFIG.CLK_DOMAIN [get_bd_intf_pins $peer]]
    if {$d ne ""} { set_property CONFIG.CLK_DOMAIN $d [get_bd_intf_pins $mine] }
  }
  puts "== FREQ_HZ $mine <- $peer ($f)"
}

# 6) address assignment
set segs [get_bd_addr_segs -quiet -of_objects [get_bd_cells gemm_up_proj_bd_0]]
puts "== GEM_ADDR_SEGS: $segs"
if {[llength $segs] == 0} {
  set segs [get_bd_addr_segs -quiet *gemm_up_proj_bd_0*]
  puts "== GEM_ADDR_SEGS(fallback): $segs"
}
assign_bd_address -offset $GEMM_BASE -range $GEMM_RANGE \
  -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
  $segs -force
puts "== address assigned: $GEMM_BASE / $GEMM_RANGE"

# 7) validate + save
validate_bd_design
save_bd_design
puts "== BD_SAVED"

foreach s [get_bd_addr_segs -quiet -of_objects [get_bd_cells gemm_up_proj_bd_0]] {
  puts "== MAP $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]"
}
puts "== ADD_GEMM_DONE"
if {$_we_opened} { close_project }
