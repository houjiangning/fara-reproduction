`timescale 1ns / 1ps
//=============================================================================
// fp32_mul —— 单精度乘法流水线（综合版，例化 Xilinx floating_point v7.1）
//
// 端口约定（全工程统一）：
//   * 上游恒 tvalid=1、下游恒 tready=1，IP 当纯流水线用；
//   * out_valid 比 in_valid 晚 LAT 拍，y 与 out_valid 同拍有效；
//   * IP 无 aresetn（生成时未使能复位端口），rst_n 只用于清 valid 移位链。
//
// 仿真时请改用 sim/fp32_ops_behav.sv（同名模块，shortreal 精确复刻 IEEE-754
// binary32 舍入，已用 1200 组随机向量与 numpy 比对零误差）。
// 两个文件模块名相同，**不可同时加入同一编译集合**。
//
// 依赖：tools/gen_fp_ip.tcl 生成的 IP "fp32_mul_ip"，其 C_Latency 必须 == LAT。
//=============================================================================
module fp32_mul #(
  parameter integer LAT = 8
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        in_valid,
  input  wire [31:0] a,
  input  wire [31:0] b,
  output wire        out_valid,
  output wire [31:0] y
);

  // ---- valid 延迟链（与 IP 延迟一致）----
  reg [LAT-1:0] vld;
  always @(posedge clk) begin
    if (!rst_n) vld <= {LAT{1'b0}};
    else        vld <= {vld[LAT-2:0], in_valid};
  end
  assign out_valid = vld[LAT-1];

  // ---- 乘法 IP ----
  fp32_mul_ip u_fp32_mul_ip (
    .aclk                 (clk),
    .s_axis_a_tvalid      (1'b1),
    .s_axis_a_tready      (),
    .s_axis_a_tdata       (a),
    .s_axis_b_tvalid      (1'b1),
    .s_axis_b_tready      (),
    .s_axis_b_tdata       (b),
    .m_axis_result_tvalid (),
    .m_axis_result_tready (1'b1),
    .m_axis_result_tdata  (y)
  );

endmodule
