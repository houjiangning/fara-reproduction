`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// bpuf_cell_behav —— bpuf_cell 的**仿真行为模型**（同名模块，仅供仿真）
//
// 为什么需要它：
//   真实的交叉耦合 LUT 环在数字仿真里没有意义 —— 没有制造偏差可依赖，
//   两个稳定点会被仿真器任意选中，结果与物理无关。所以仿真时用一个行为模型
//   替代它，专门用来验证**采样时序状态机与表决逻辑**是否正确。
//
// 与工程既有约定一致：
//   rtl/fp32_mul.sv / rtl/fp32_add.sv 在仿真里由 sim/fp32_ops_behav.sv 替代，
//   编译时**不加入** RTL 版本。本文件同理：仿真编译集合含 sim/bpuf_cell_behav.sv，
//   且**不含** rtl/bpuf_cell.sv（同名模块会冲突）。
//
// 建模行为（确定性、可复现）：
//   · puf_rst=1  → q=0（与真实单元"强制到已知态"一致）
//   · puf_rst=0  → q 由 IDX 与"第几轮释放"共同决定：
//       - 大多数位（IDX % 17 != 0）：**稳定**，每次释放都给出同一个值
//         → 应被表决为一致，不出现在 q_unan 里
//       - 少数位（IDX % 17 == 0）    ：**每轮翻转**（交替 0/1）
//         → 应被标记为 q_unan（不可用位）
//     这样 tb 才能精确断言 STABLE_CNT 与 UNAN 的位数。
//
//   为 N_BITS=128 时，IDX%17==0 的位是 0,17,34,51,68,85,102,119 —— 共 8 位，
//   故期望 STABLE_CNT = 128 - 8 = 120。
//
// 注意：本模型**不代表真实 PUF 的统计特性**，只保证 FSM/表决路径可验证。
//       真实翻转率必须上板实测（board_test/puf_sample.c + tools/puf_stability.py）。
//=============================================================================
module bpuf_cell #(
  parameter integer IDX = 0
) (
  input  wire puf_rst,
  output reg  q
);

  // 每位一个固定的"制造偏差"基底值（由 IDX 决定，确定性）
  function automatic logic base_of(input integer idx);
    // 用 IDX 做位混合，保证不同 IDX 的基底各不相同且分布不单调
    return (idx * 7 + 3 + (idx >> 2)) & 1;
  endfunction

  // 该位是否为"不稳定位"（每轮翻转）
  localparam integer UNSTABLE = (IDX % 17 == 0) ? 1 : 0;

  // 释放次数计数器：每次 puf_rst 由 1→0 视为一次"释放"
  integer rel_cnt;

  initial begin
    rel_cnt = 0;
    q       = 1'b0;
  end

  always @(negedge puf_rst) begin
    rel_cnt = rel_cnt + 1;
  end

  always @(*) begin
    if (puf_rst) q = 1'b0;                                   // 强制态
    else if (UNSTABLE) q = base_of(IDX) ^ rel_cnt[0];        // 每轮翻转
    else               q = base_of(IDX);                     // 稳定
  end

endmodule

`default_nettype wire