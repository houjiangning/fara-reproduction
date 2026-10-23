`timescale 1ns / 1ps
//=============================================================================
// fp32_add —— 单精度加法流水线（综合版，例化 Xilinx floating_point v7.1）
//
// 端口约定同 fp32_mul。IP 为 Add_Subtract 型，s_axis_operation_tdata 恒接 0
// （0 = 加，1 = 减），本设计只做加法。
//
// 依赖：tools/gen_fp_ip.tcl 生成的 IP "fp32_add_ip"，其 C_Latency 必须 == LAT。
//
// 仿真时请改用 sim/fp32_ops_behav.sv 中的同名模块。
//=============================================================================
module fp32_add #(
  parameter integer LAT = 4
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        in_valid,
  input  wire [31:0] a,
  input  wire [31:0] b,
  output wire        out_valid,
  output wire [31:0] y
);

  reg [LAT-1:0] vld;
  always @(posedge clk) begin
    if (!rst_n) vld <= {LAT{1'b0}};
    else        vld <= {vld[LAT-2:0], in_valid};
  end
  assign out_valid = vld[LAT-1];

  fp32_add_ip u_fp32_add_ip (
    .aclk                        (clk),
    .s_axis_a_tvalid             (1'b1),
    .s_axis_a_tready             (),
    .s_axis_a_tdata              (a),
    .s_axis_b_tvalid             (1'b1),
    .s_axis_b_tready             (),
    .s_axis_b_tdata              (b),
    .s_axis_operation_tvalid     (1'b1),
    .s_axis_operation_tready     (),
    .s_axis_operation_tdata      (8'd0),
    .m_axis_result_tvalid        (),
    .m_axis_result_tready        (1'b1),
    .m_axis_result_tdata         (y)
  );

endmodule
