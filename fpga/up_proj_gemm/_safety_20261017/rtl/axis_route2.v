`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// axis_route2 —— 运行期 / provisioning 两条数据流的 2:1 选路
//                （**必须是纯 Verilog .v**：BD module-reference 的顶层不接受 .sv）
//
//   mode = 0 : 运行期   AES -> GEMM,  GEMM -> S2MM
//   mode = 1 : 供板     AES -> S2MM（绕开 GEMM）
//
// 说明（plan-B §8.2）：
//   · 这是**纯组合最小版本**，不含 skid buffer。mode 由上层寄存器提供，
//     上电复位默认 0（运行期），避免"选路 bug 导致运行期数据走错路"。
//   · 若时序紧张，在两条路径上各加一级 axis_register_slice。
//   · GEMM 单元本身零改动：运行期 AES 解密结果原样送 GEMM s_axis，
//     GEMM 的 m_axis 结果原样送 DMA S2MM。
//
// aclk 只是给 BD 用的：Vivado 的 module-reference 流程要求 AXI4-Stream 接口
// 能关联到一个时钟引脚，否则 validate_bd_design 会报 "not associated to any
// clock pin"。本模块内部**不使用** aclk（无时序逻辑）。
//=============================================================================
module axis_route2 (
  input  wire        aclk,
  input  wire        mode,

  // ---- 来自 AES 解密/加密引擎 ----
  input  wire [63:0] aes_tdata,
  input  wire        aes_tvalid,
  output wire        aes_tready,
  input  wire        aes_tlast,

  // ---- 到 GEMM（s_axis）----
  output wire [63:0] gemm_tdata,
  output wire        gemm_tvalid,
  input  wire        gemm_tready,
  output wire        gemm_tlast,

  // ---- 来自 GEMM（m_axis）----
  input  wire [63:0] gout_tdata,
  input  wire        gout_tvalid,
  output wire        gout_tready,
  input  wire        gout_tlast,

  // ---- 到 DMA S2MM ----
  output wire [63:0] s2mm_tdata,
  output wire        s2mm_tvalid,
  input  wire        s2mm_tready,
  output wire        s2mm_tlast
);

  // AES -> GEMM 只在运行期导通；供板时把 GEMM 入口封死
  assign gemm_tdata  = aes_tdata;
  assign gemm_tvalid = aes_tvalid & ~mode;
  assign gemm_tlast  = aes_tlast;

  // AES 的 backpressure 二选一：运行期看 GEMM，供板看 S2MM
  assign aes_tready  = mode ? s2mm_tready : gemm_tready;

  // S2MM 入口二选一：运行期取 GEMM 结果，供板取 AES 输出
  assign s2mm_tdata  = mode ? aes_tdata  : gout_tdata;
  assign s2mm_tvalid = mode ? aes_tvalid : gout_tvalid;
  assign s2mm_tlast  = mode ? aes_tlast  : gout_tlast;

  // 供板时 GEMM 输出无人接收，必须把它的 tready 拉低，避免假握手
  assign gout_tready = mode ? 1'b0 : s2mm_tready;

endmodule

`default_nettype wire
