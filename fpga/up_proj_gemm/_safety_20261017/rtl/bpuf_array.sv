`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// bpuf_array —— N_BITS 位 Butterfly PUF 阵列 + 多次采样多数表决
//
// 结构：N_BITS 个 bpuf_cell 并行，共享 force 控制。
//
// 降噪（PUF 的核心工程问题）：
//   单次采样的响应会有若干位不稳定（同一块芯片、不同上电或不同温度下翻转）。
//   本模块在一次采样序列内连续采 M 次（由 bpuf_ctrl 控制节奏），逐位累加 1 的
//   个数，最后：
//     · q_maj  = 多数表决结果（2*cnt > M）—— 用于生成稳定密钥材料
//     · q_unan = 非一致标记（cnt 既不是 0 也不是 M）—— 这些位**在整个序列内
//                都没能保持一致**，属于不可用位，必须被剔除
//
//   q_unan 是 P1 稳定性测量的关键输出：它直接告诉你"本次上电中哪些位是抖的"。
//   跨上电的翻转率则由 PC 侧 tools/puf_stability.py 汇总多次冷启动的响应来算。
//
// ── 关键约定 ──
//   · M（采样次数）应为**奇数**，否则 (2*cnt == M) 会出现多数表决平票；
//     bpuf_ctrl 会拒绝偶数 M（写进 ERR）。
//   · cnt 位宽 CNT_W=5 → M 最大 31。要更多次采样请调宽 CNT_W。
//   · clr 与 sample 都是单拍脉冲，由 ctrl 产生；clr 在新序列开始前清零计数。
//
// ── 仿真说明 ──
//   纯组合环在数字仿真里无法体现真实制造偏差（两个稳定点会被任意选中），
//   因此仿真走 sim/bpuf_cell_behav.sv（同名模块、行为模型），**不编译本目录的
//   rtl/bpuf_cell.sv** —— 与工程里 fp32_mul/fp32_add 的既有约定完全一致。
//=============================================================================
module bpuf_array #(
  parameter integer N_BITS = 128,
  parameter integer CNT_W  = 5          // 计数位宽；M 上限 = 2^CNT_W - 1
) (
  input  wire clk,
  input  wire rst_n,

  input  wire clr,                      // 单拍：清零投票计数
  input  wire puf_rst,                  // 电平：1 期间强制已知态
  input  wire sample,                   // 单拍：把当前 q 累加进计数

  output wire [N_BITS-1:0] q_raw,       // 当前原始输出（组合，调试用）
  output wire [N_BITS-1:0] q_maj,       // 多数表决结果
  output wire [N_BITS-1:0] q_unan,      // 非一致位标记（不可用位）
  output wire [31:0]       n_samp_done  // 实际完成的采样次数
);

  //-------------------------------------------------------------------
  // PUF 单元阵列
  //-------------------------------------------------------------------
  wire [N_BITS-1:0] q;

  genvar g;
  generate
    for (g = 0; g < N_BITS; g = g + 1) begin : g_cell
      bpuf_cell #(.IDX(g)) u_cell (
        .puf_rst (puf_rst),
        .q       (q[g])
      );
    end
  endgenerate

  assign q_raw = q;

  //-------------------------------------------------------------------
  // 逐位投票计数
  //-------------------------------------------------------------------
  reg  [CNT_W-1:0] cnt  [0:N_BITS-1];
  reg  [31:0]      nsamp;

  integer k;

  always @(posedge clk) begin
    if (!rst_n) begin
      nsamp <= 32'd0;
      for (k = 0; k < N_BITS; k = k + 1) cnt[k] <= {CNT_W{1'b0}};
    end else if (clr) begin
      nsamp <= 32'd0;
      for (k = 0; k < N_BITS; k = k + 1) cnt[k] <= {CNT_W{1'b0}};
    end else if (sample) begin
      nsamp <= nsamp + 32'd1;
      for (k = 0; k < N_BITS; k = k + 1)
        if (q[k]) cnt[k] <= cnt[k] + {{(CNT_W-1){1'b0}}, 1'b1};
    end
  end

  //-------------------------------------------------------------------
  // 表决结果（组合）
  //-------------------------------------------------------------------
  genvar h;
  generate
    for (h = 0; h < N_BITS; h = h + 1) begin : g_maj
      // 多数：2*cnt > nsamp。nsamp 应为奇数，故不会平票。
      assign q_maj[h]  = (cnt[h] * 2) > nsamp;
      // 非一致：既不是全 0 也不是全 1 → 该位整个序列内都抖
      assign q_unan[h] = (cnt[h] != {CNT_W{1'b0}}) && (cnt[h] != nsamp[CNT_W-1:0]);
    end
  endgenerate

  assign n_samp_done = nsamp;

endmodule

`default_nettype wire