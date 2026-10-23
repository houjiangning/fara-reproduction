`timescale 1ns / 1ps
//=============================================================================
// fp32_ops_behav —— fp32 乘/加的**仿真行为模型**（仅仿真使用，不可综合）
//
// 用 SystemVerilog shortreal 实现。shortreal 就是 IEEE-754 binary32，
// xsim 的 shortreal 算术按 binary32 正确舍入（round-to-nearest-even），
// 与 Xilinx floating_point IP 默认的舍入模式一致。
// 已用 1200 组随机向量（含宽指数跨度、相消情形）与 numpy.float32 逐位比对，
// 零误差。
//
// 本文件与 rtl/fp32_mul.sv、rtl/fp32_add.sv 提供**同名模块**：
//   * 仿真编译集合只加本文件（tools/run_sim.ps1 已按此配置）；
//   * Vivado 综合工程只加 rtl/ 下的 IP 封装版。
//   两者切勿同时加入同一编译集合。
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
  reg [31:0] aq [0:LAT-1];
  reg [31:0] bq [0:LAT-1];
  reg [LAT-1:0] vld;
  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      vld <= {LAT{1'b0}};
      for (i = 0; i < LAT; i = i + 1) begin aq[i] <= 32'd0; bq[i] <= 32'd0; end
    end else begin
      aq[0] <= a;
      bq[0] <= b;
      for (i = 1; i < LAT; i = i + 1) begin aq[i] <= aq[i-1]; bq[i] <= bq[i-1]; end
      vld   <= {vld[LAT-2:0], in_valid};
    end
  end

  function automatic [31:0] f_mul(input [31:0] x, input [31:0] z);
    shortreal rx, rz, ry;
    begin
      rx = $bitstoshortreal(x);
      rz = $bitstoshortreal(z);
      ry = rx * rz;
      f_mul = $shortrealtobits(ry);
    end
  endfunction

  assign y         = f_mul(aq[LAT-1], bq[LAT-1]);
  assign out_valid = vld[LAT-1];
endmodule


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
  reg [31:0] aq [0:LAT-1];
  reg [31:0] bq [0:LAT-1];
  reg [LAT-1:0] vld;
  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      vld <= {LAT{1'b0}};
      for (i = 0; i < LAT; i = i + 1) begin aq[i] <= 32'd0; bq[i] <= 32'd0; end
    end else begin
      aq[0] <= a;
      bq[0] <= b;
      for (i = 1; i < LAT; i = i + 1) begin aq[i] <= aq[i-1]; bq[i] <= bq[i-1]; end
      vld   <= {vld[LAT-2:0], in_valid};
    end
  end

  function automatic [31:0] f_add(input [31:0] x, input [31:0] z);
    shortreal rx, rz, ry;
    begin
      rx = $bitstoshortreal(x);
      rz = $bitstoshortreal(z);
      ry = rx + rz;
      f_add = $shortrealtobits(ry);
    end
  endfunction

  assign y         = f_add(aq[LAT-1], bq[LAT-1]);
  assign out_valid = vld[LAT-1];
endmodule
