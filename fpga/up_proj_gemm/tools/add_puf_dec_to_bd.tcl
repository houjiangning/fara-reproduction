#-----------------------------------------------------------------------------
# add_puf_dec_to_bd.tcl -- 方案B 阶段 7e：把 PUF+AES 解密块与选路插进数据通路
#
# 保持纯 ASCII；GUI / batch 两用；幂等可重跑。
#
# 目标拓扑（全部在一个 BD 里；PUF 仍留在静态区、不做 DPR 分区）：
#   axi_dma_0/M_AXIS_MM2S -> puf_dec_bd_0/s_axis
#   puf_dec_bd_0/m_axis     -> axis_route2_0/aes
#   axis_route2_0/gemm      -> gemm_up_proj_bd_0/s_axis
#   gemm_up_proj_bd_0/m_axis-> axis_route2_0/gout
#   axis_route2_0/s2mm      -> axi_dma_0/S_AXIS_S2MM
#   puf_bd_0/resp_o         -> puf_dec_bd_0/puf_resp_i   （同 PL 内 fabric 网线，非 AXI）
#   puf_bd_0/unan_o         -> puf_dec_bd_0/puf_unan_i
#   puf_dec_bd_0/route_mode_o-> axis_route2_0/mode
#   smartconnect_0 NUM_MI 3->4，新控制口 M03 -> puf_dec_bd_0/s_axi
#
# 地址：0xA0010000 GEMM（不动）、0xA0020000 puf_dec（新）、0xA0030000 PUF（不动）
#
# 关键纪律（照抄现有脚本已验证过的做法）：
#   * 连接判断比较两个 pin 的 NET，而不是"谁有 net"
#   * 拆流网时只删目标那两根，绝不碰 pl_clk0 / peripheral_aresetn 的扇出
#   * 建单元前先判存在；不改动已有单元的时钟/复位连接
#-----------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set DEC_BASE 0xA0020000
set DEC_RANGE 64K

puts "== ROOT $root"

set _we_opened 0
if {[llength [current_project -quiet]] == 0} {
  open_project "$root/up_proj_gemm.xpr"
  set _we_opened 1
  puts "== opened project (batch mode)"
} else {
  puts "== reusing already-open project: [current_project]"
}

#---------------------------------------------------------------------------
# 1) 加新 RTL
#---------------------------------------------------------------------------
set rtl_files [list \
  "$root/rtl/aes256_sbox.sv" \
  "$root/rtl/aes256_core.sv" \
  "$root/rtl/aes256_ctr.sv" \
  "$root/rtl/key_mgr.sv" \
  "$root/rtl/fuzzy_extract.sv" \
  "$root/rtl/sha256_kdf.sv" \
  "$root/rtl/wdec_stream.sv" \
  "$root/rtl/axis_route2.v" \
  "$root/rtl/puf_dec_axi_lite.sv" \
  "$root/rtl/puf_dec_bd.v" \
]

# 旧版把 axis_route2 写成了 .sv —— BD module-reference 顶层**不接受 SystemVerilog**，
# 必须 .v。若工程里还留着旧的 .sv，先移除，否则模块名重复会直接报冲突。
set stale "$root/rtl/axis_route2.sv"
if {[llength [get_files -quiet $stale]] > 0} {
  puts "== removing stale $stale (module-reference top must be .v)"
  remove_files -quiet $stale
}
foreach f $rtl_files {
  if {[llength [get_files -quiet $f]] == 0} {
    add_files -norecurse $f
    puts "== added $f"
  } else {
    puts "== already in project: [file tail $f]"
  }
}

# 默认 DisplayOnly 源管理会把"从顶层看不到"的源文件自动禁用（AutoDisabled），
# 导致 module reference 找不到模块名。强制全量源管理后再算编译顺序。
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

#---------------------------------------------------------------------------
# 2) 打开 BD
#---------------------------------------------------------------------------
open_bd_design [get_files -quiet up_proj.bd]

#---------------------------------------------------------------------------
# 2b) 刷新 puf_bd_0 的 module reference
#
# rtl/puf_bd.v 新增了 resp_o / unan_o 两个输出端口，但 BD 里的 puf_bd_0 是
# module reference，**端口表在创建时就缓存了**。不刷新的话
#   get_bd_pins puf_bd_0/resp_o  ->  [BD 5-235] No pins matched
# 就会卡住整条连线。
# 优先用官方的刷新命令；万一该版本没有，才退化成"删掉重建"
# （重建会丢掉它参与的 net，所以必须把时钟/复位/s_axi 都重新连一遍 —— 见第 7 步）。
#---------------------------------------------------------------------------
# 先把 rtl/puf_bd.v 从源文件集里摘掉再加回来，逼 Vivado 重新解析 —— 单纯改磁盘上
# 的文件不够：module reference 的端口表缓存在工程里，刷新命令也没能撵走它。
set _pf "$root/rtl/puf_bd.v"
if {[llength [get_files -quiet $_pf]] > 0} {
  puts "== force re-parse: remove $_pf"
  remove_files -quiet $_pf
}
add_files -norecurse $_pf
update_compile_order -fileset sources_1
puts "== re-added $_pf"

set _need_recreate 0
if {[llength [get_bd_pins -quiet puf_bd_0/resp_o]] > 0} {
  puts "== puf_bd_0/resp_o 已存在（无需刷新）"
} else {
  if {[catch { update_module_reference -force [get_bd_cells puf_bd_0] } e]} {
    puts "!! update_module_reference -force failed: $e"
    set _need_recreate 1
  } elseif {[llength [get_bd_pins -quiet puf_bd_0/resp_o]] == 0} {
    puts "!! 刷新后仍无 resp_o -> 走重建"
    set _need_recreate 1
  } else {
    puts "== update_module_reference -force OK：resp_o 出现"
  }
}
if {$_need_recreate} {
  # module reference 在 BD 里会被"打包"成一个 IP：up_proj_puf_bd_0_0.xci +
  # 生成的 up_proj_puf_bd_0_0.v（在 .srcs 与 .gen 两处）。**端口表缓存在这里**，
  # 只删 BD cell 再重建仍会拿到旧端口表 —— 必须连生成的 IP 外壳一起删掉，
  # 逼 Vivado 从当前的 rtl/puf_bd.v 重新打包。
  foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet puf_bd_0/s_axi]] {
    catch { delete_bd_objs $n }
  }
  catch { delete_bd_objs [get_bd_cells puf_bd_0] }
  foreach d [list \
      "$root/up_proj_gemm.srcs/sources_1/bd/up_proj/ip/up_proj_puf_bd_0_0" \
      "$root/up_proj_gemm.gen/sources_1/bd/up_proj/ip/up_proj_puf_bd_0_0" ] {
    if {[file exists $d]} {
      puts "== deleting generated IP dir $d"
      catch { file delete -force $d }
    }
  }
  create_bd_cell -type module -reference puf_bd puf_bd_0
  puts "== recreated puf_bd_0 (repackaged from current rtl/puf_bd.v)"
}
if {[llength [get_bd_pins -quiet puf_bd_0/resp_o]] == 0} {
  puts "!! FATAL: puf_bd_0 仍无 resp_o —— 工程里 puf_bd 的模块定义不是磁盘那份"
  puts "!! 工程内 puf_bd 相关源文件: [get_files -quiet *puf_bd*]"
  error "puf_bd_0/resp_o missing"
}
puts "== puf_bd_0 pins: [llength [get_bd_pins -quiet -of_objects [get_bd_cells puf_bd_0]]]"

# --- 幂等连接助手（与 add_gemm_to_bd.tcl / add_puf_to_bd.tcl 同款）--------
proc _same_net {na nb} {
  return [expr {[llength $na] > 0 && [llength $nb] > 0 &&
                [lindex $na 0] eq [lindex $nb 0]}]
}
proc conn_net {a b} {
  set pa [get_bd_pins $a]
  set pb [get_bd_pins $b]
  set na [get_bd_nets -quiet -of_objects $pa]
  set nb [get_bd_nets -quiet -of_objects $pb]
  if {[_same_net $na $nb]} { puts "== already connected: $a <-> $b"; return }
  foreach n $nb { catch { delete_bd_objs $n } }
  connect_bd_net $pa $pb
  puts "== connected $a <-> $b"
}
proc conn_intf {a b} {
  set pa [get_bd_intf_pins $a]
  set pb [get_bd_intf_pins $b]
  set na [get_bd_intf_nets -quiet -of_objects $pa]
  set nb [get_bd_intf_nets -quiet -of_objects $pb]
  if {[_same_net $na $nb]} { puts "== already connected: $a <-> $b"; return }
  foreach n [lsort -unique [concat $na $nb]] { catch { delete_bd_objs $n } }
  connect_bd_intf_net $pa $pb
  puts "== connected $a <-> $b"
}

#---------------------------------------------------------------------------
# 3) 建两个新单元（幂等；绝不删除既有单元）
#---------------------------------------------------------------------------
if {[llength [get_bd_cells -quiet puf_dec_bd_0]] > 0} {
  puts "== puf_dec_bd_0 already present, keeping it"
} else {
  create_bd_cell -type module -reference puf_dec_bd puf_dec_bd_0
  puts "== created puf_dec_bd_0"
}

if {[llength [get_bd_cells -quiet axis_route2_0]] > 0} {
  puts "== axis_route2_0 already present, keeping it"
} else {
  create_bd_cell -type module -reference axis_route2 axis_route2_0
  puts "== created axis_route2_0"
}

#---------------------------------------------------------------------------
# 4) smartconnect_0: 3 主口 -> 4 主口（M03 -> puf_dec 控制口；M00/M01/M02 不动）
#---------------------------------------------------------------------------
set cur_mi [get_property CONFIG.NUM_MI [get_bd_cells smartconnect_0]]
puts "== smartconnect_0 NUM_MI before: $cur_mi"
if {$cur_mi < 4} {
  set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {4}] [get_bd_cells smartconnect_0]
  puts "== smartconnect_0 NUM_SI=2 NUM_MI=4"
} else {
  puts "== smartconnect_0 NUM_MI already >= 4, keeping it"
}

#---------------------------------------------------------------------------
# 5) 拆掉旧的 DMA<->GEMM 两条直连流网（只删这两根，不碰时钟/复位扇出）
#---------------------------------------------------------------------------
foreach p [list axi_dma_0/M_AXIS_MM2S gemm_up_proj_bd_0/m_axis] {
  foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $p]] {
    puts "== deleting old stream net $n (from $p)"
    catch { delete_bd_objs $n }
  }
}

#---------------------------------------------------------------------------
# 6) 重新布线
#---------------------------------------------------------------------------
conn_intf axi_dma_0/M_AXIS_MM2S      puf_dec_bd_0/s_axis
conn_intf puf_dec_bd_0/m_axis         axis_route2_0/aes
conn_intf axis_route2_0/gemm          gemm_up_proj_bd_0/s_axis
conn_intf gemm_up_proj_bd_0/m_axis    axis_route2_0/gout
conn_intf axis_route2_0/s2mm          axi_dma_0/S_AXIS_S2MM

# PUF 侧：若上面的刷新走了"删除重建"分支，这些连接需要重新建立；
# 若一切正常，这里是幂等 no-op。
conn_intf smartconnect_0/M02_AXI   puf_bd_0/s_axi
conn_net  zynq_ultra_ps_e_0/pl_clk0        puf_bd_0/s_axi_aclk
conn_net  rst_ps8_0_99M/peripheral_aresetn puf_bd_0/s_axi_aresetn

# PUF 响应硬件网线（fabric，非 AXI）与选路模式
conn_net puf_bd_0/resp_o     puf_dec_bd_0/puf_resp_i
conn_net puf_bd_0/unan_o     puf_dec_bd_0/puf_unan_i
conn_net puf_dec_bd_0/route_mode_o axis_route2_0/mode

# 控制口
conn_intf smartconnect_0/M03_AXI   puf_dec_bd_0/s_axi

#---------------------------------------------------------------------------
# 7) 时钟 / 复位（单时钟域）
#---------------------------------------------------------------------------
conn_net zynq_ultra_ps_e_0/pl_clk0        puf_dec_bd_0/s_axi_aclk
conn_net rst_ps8_0_99M/peripheral_aresetn puf_dec_bd_0/s_axi_aresetn
conn_net zynq_ultra_ps_e_0/pl_clk0        axis_route2_0/aclk

#---------------------------------------------------------------------------
# 8) 接口元数据：ASSOCIATED_BUSIF + FREQ_HZ 对齐（照抄 GEMM/PUF 的做法）
#---------------------------------------------------------------------------
if {[catch {
  set cur_ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins puf_dec_bd_0/s_axi_aclk]]
  if {$cur_ab eq ""} {
    set_property CONFIG.ASSOCIATED_BUSIF {s_axi:s_axis:m_axis} [get_bd_pins puf_dec_bd_0/s_axi_aclk]
    set_property CONFIG.ASSOCIATED_RESET {s_axi_aresetn}        [get_bd_pins puf_dec_bd_0/s_axi_aclk]
    puts "== puf_dec_bd_0/s_axi_aclk ASSOCIATED_BUSIF set"
  } else {
    puts "== puf_dec_bd_0/s_axi_aclk ASSOCIATED_BUSIF already = $cur_ab"
  }
} e]} {
  puts "!! ASSOCIATED_BUSIF (puf_dec) check failed (non-fatal): $e"
}

# AXI-Lite 侧：从 peer 抄（与既有 PUF/GEMM 做法一致）
foreach pr [list \
    [list puf_dec_bd_0/s_axi smartconnect_0/M03_AXI] \
    [list puf_bd_0/s_axi     smartconnect_0/M02_AXI] ] {
  set mine [lindex $pr 0]
  set peer [lindex $pr 1]
  if {[catch {
    set f [get_property CONFIG.FREQ_HZ [get_bd_intf_pins $peer]]
    set_property CONFIG.FREQ_HZ $f [get_bd_intf_pins $mine]
    puts "== FREQ_HZ $mine <- $peer ($f)"
  } e]} {
    puts "!! FREQ_HZ $mine failed (non-fatal): $e"
  }
}

# 流链：**整条链必须同一个 FREQ_HZ**（取 DMA MM2S 的 99990005）。
# 不能逐个"从对端抄"：axis_route2 是直通模块，Vivado 会把 GEMM 侧的 99990005
# 自动回灌到 aes 侧，而 puf_dec_bd_0/m_axis 又停在默认的 100000000，
# 于是 validate 报 FREQ_HZ mismatch。统一显式赋值即可根治。
set STREAM_F [get_property CONFIG.FREQ_HZ [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S]]
foreach p [list puf_dec_bd_0/s_axis puf_dec_bd_0/m_axis \
                axis_route2_0/aes axis_route2_0/gemm \
                axis_route2_0/gout axis_route2_0/s2mm] {
  if {[catch {
    set_property CONFIG.FREQ_HZ $STREAM_F [get_bd_intf_pins $p]
    puts "== FREQ_HZ $p <- $STREAM_F (stream chain)"
  } e]} {
    puts "!! FREQ_HZ $p failed (non-fatal): $e"
  }
}

#---------------------------------------------------------------------------
# 9) 地址分配
#   · puf_bd_0 若在本轮被重建，它的 0xA0030000 段会丢，这里一并重挂（幂等）
#   · puf_dec_bd_0 新挂 0xA0020000
#---------------------------------------------------------------------------
set puf_segs [get_bd_addr_segs -quiet -of_objects [get_bd_cells puf_bd_0]]
if {[llength $puf_segs] > 0} {
  assign_bd_address -offset 0xA0030000 -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] $puf_segs -force
  puts "== address assigned: puf_bd_0 0xA0030000 / 64K"
}

set segs [get_bd_addr_segs -quiet -of_objects [get_bd_cells puf_dec_bd_0]]
if {[llength $segs] == 0} { set segs [get_bd_addr_segs -quiet *puf_dec_bd_0*] }
if {[llength $segs] == 0} {
  puts "!! ERROR: no address segments for puf_dec_bd_0"
} else {
  assign_bd_address -offset $DEC_BASE -range $DEC_RANGE \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] $segs -force
  puts "== address assigned: $DEC_BASE / $DEC_RANGE"
}

#---------------------------------------------------------------------------
# 10) 校验 + 保存
#---------------------------------------------------------------------------
validate_bd_design
save_bd_design
puts "== BD_SAVED"

#---------------------------------------------------------------------------
# 11) 保存后拓扑dump（写进日志，便于人工核对）
#---------------------------------------------------------------------------
puts "==== INTF NETS (after) ===="
foreach n [get_bd_intf_nets -quiet *] {
  puts "  $n : [get_bd_intf_pins -quiet -of_objects $n]"
}
puts "==== PLAIN NETS touching puf_dec/route2 ===="
foreach p [concat [get_bd_pins -quiet -of_objects [get_bd_cells puf_dec_bd_0]] \
                  [get_bd_pins -quiet -of_objects [get_bd_cells axis_route2_0]]] {
  catch { puts "  $p  net=[get_bd_nets -quiet -of_objects $p]" }
}
puts "==== ADDR (after) ===="
foreach s [get_bd_addr_segs -quiet *] {
  catch { puts "  $s offset=[get_property OFFSET $s] range=[get_property RANGE $s]" }
}

puts "== ADD_PUF_DEC_DONE"
puts "== NEXT: synth_1 必须整条重跑（新增 OOC module reference）"
if {$_we_opened} { close_project }
