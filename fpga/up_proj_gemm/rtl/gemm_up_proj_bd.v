`timescale 1ns / 1ps
//=============================================================================
// gemm_up_proj_bd —— 供 Block Design「Add Module」使用的纯 Verilog 薄封装
//
// 为什么需要这一层：
//   Vivado 2022.2 的 module-reference（BD 里的 Add Module）**不允许
//   SystemVerilog 文件作为引用的顶层文件**，会报
//       ERROR: [filemgmt 56-195] ... type SystemVerilog. This type is not
//       allowed as the top file in the reference.
//   因此用一个 Verilog-2001 文件承载端口，内部原样例化 SV 实现
//   （gemm_up_proj_top）。子模块是 .sv 不受该限制影响。
//
// 注意：本文件只是端口透传，不含任何逻辑。
//   **端口名/位宽/参数必须与 rtl/gemm_up_proj_top.sv 严格一致**；
//   一旦不一致，例化处会直接编译报错（这本身就是一致性检查）。
//
// 端口协议推断：
//   s_axi_*  -> S_AXI  (AXI4-Lite, 时钟 s_axi_aclk)
//   s_axis_* -> S_AXIS (AXI4-Stream, 时钟 s_axis_aclk)
//   m_axis_* -> M_AXIS (AXI4-Stream, 时钟 m_axis_aclk)
//   三条接口时钟在 BD 中必须接同一路 pl_clk0（本设计为单时钟域）。
//=============================================================================
module gemm_up_proj_bd #(
  parameter integer M_TILE  = 16,     // 并行输出行数 = MAC lane 数
  parameter integer M_TOTAL = 3072,   // 输出总行数（GPT-2 small c_fc out_features）
  parameter integer K_MAX   = 768,    // 规约深度上限（c_fc in_features）
  parameter integer N_MAX   = 32,     // 单次事务 token 数上限
  parameter integer G       = 8,      // 部分和链数，硬约束 G >= ADD_LAT+1
  parameter integer ADD_LAT = 4,      // 与 fp32_add_ip 的 C_Latency 一致
  parameter integer MUL_LAT = 8,      // 与 fp32_mul_ip 的 C_Latency 一致
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 8,
  parameter integer AXIS_TDATA_WIDTH   = 64
) (
  // 时钟 / 复位
  input  wire                          s_axi_aclk,
  input  wire                          s_axi_aresetn,

  // AXI4-Lite 从机（控制/状态）
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [2:0]                    s_axi_awprot,
  input  wire                          s_axi_awvalid,
  output wire                          s_axi_awready,
  input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
  input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  wire                          s_axi_wvalid,
  output wire                          s_axi_wready,
  output wire [1:0]                    s_axi_bresp,
  output wire                          s_axi_bvalid,
  input  wire                          s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [2:0]                    s_axi_arprot,
  input  wire                          s_axi_arvalid,
  output wire                          s_axi_arready,
  output wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
  output wire [1:0]                    s_axi_rresp,
  output wire                          s_axi_rvalid,
  input  wire                          s_axi_rready,

  // AXI4-Stream 从机：输入 [X | b | W]
  input  wire [AXIS_TDATA_WIDTH-1:0]   s_axis_tdata,
  input  wire [AXIS_TDATA_WIDTH/8-1:0] s_axis_tkeep,
  input  wire                          s_axis_tvalid,
  output wire                          s_axis_tready,
  input  wire                          s_axis_tlast,

  // AXI4-Stream 主机：输出 Y
  output wire [AXIS_TDATA_WIDTH-1:0]   m_axis_tdata,
  output wire [AXIS_TDATA_WIDTH/8-1:0] m_axis_tkeep,
  output wire                          m_axis_tvalid,
  input  wire                          m_axis_tready,
  output wire                          m_axis_tlast
);

  gemm_up_proj_top #(
    .M_TILE              (M_TILE),
    .M_TOTAL             (M_TOTAL),
    .K_MAX               (K_MAX),
    .N_MAX               (N_MAX),
    .G                   (G),
    .ADD_LAT             (ADD_LAT),
    .MUL_LAT             (MUL_LAT),
    .C_S_AXI_DATA_WIDTH  (C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH  (C_S_AXI_ADDR_WIDTH),
    .AXIS_TDATA_WIDTH    (AXIS_TDATA_WIDTH)
  ) u_top (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .s_axis_tlast  (s_axis_tlast),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tlast  (m_axis_tlast)
  );

endmodule
