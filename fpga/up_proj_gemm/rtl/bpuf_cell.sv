`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// bpuf_cell —— Butterfly PUF 单元（一位指纹，纯 LUT 实现）
//
// 原理（Kumar et al., "The Butterfly PUF: Protecting IP on Every FPGA", HOST 2008
//       的 LUT-only 实现）：
//   · 一对交叉耦合的 NOR（各综合成 1 个 LUT2）构成双稳态环
//   · puf_rst=1：两个节点都被拉到 0（已知态）
//   · puf_rst=0：放开环，电路自行收敛。**收敛到 (1,0) 还是 (0,1) 由两个
//     LUT 的制造偏差决定** —— 这就是这块芯片不可复制的指纹来源
//
//   命名说明：本端口曾想叫 force，但 force 是 SystemVerilog 关键字，
//   不能用作标识符（xvlog 会报 "keyword 'force' used in incorrect context"）。
//   因此统一命名为 puf_rst —— 语义就是"把单元打到已知态"。
//
// 为什么必须写 DONT_TOUCH + ALLOW_COMBINATORIAL_LOOPS：
//   交叉耦合 LUT 在功能上是一个**组合环**。Vivado 默认会报 LUTLP-1（combinational
//   loop）DRC，并可能断环或直接把整个环优化成常量 —— 那样读到的永远是个常数，
//   PUF 就废了。三件套缺一不可：
//     ① RTL：(* DONT_TOUCH = "TRUE" *) 钉住环上的网线与实例
//     ② RTL：模块级 (* ALLOW_COMBINATORIAL_LOOPS = "TRUE" *) 明确允许环存在
//     ③ XDC ：把 LUTLP-1 降级为 Warning（见 constr/puf_lock.xdc，仍然保留可见性）
//
// 布局锁定（P1 最关键的工程约束）：
//   PUF 响应取决于**综合/实现出来的物理结构**。同一份 bitstream 在同一块板子上
//   是稳定的；一旦重新综合/重新布局，响应就会变，之前加密的密文与 helper data
//   全部失效。因此必须用 Pblock/LOC 把本单元钉死（见 constr/puf_lock.xdc 与
//   tools/puf_lock_from_place.tcl）。
//
// IDX 参数：
//   仅用于**仿真行为模型**（sim/bpuf_cell_behav.sv）区分不同单元的响应。
//   真实综合里 IDX 不参与任何逻辑（会被忽略），加它只是为了让仿真与综合
//   共用同一份阵列例化代码。
//=============================================================================
(* ALLOW_COMBINATORIAL_LOOPS = "TRUE" *)
module bpuf_cell #(
  parameter integer IDX = 0
) (
  input  wire puf_rst,   // 1 = 强制到已知态（两节点同电平）
  output wire q          // 收敛结果（= 其中一个节点的电平）
);

  // 交叉耦合 NOR 对。必须 DONT_TOUCH，否则会被优化掉。
  (* DONT_TOUCH = "TRUE" *) wire a;
  (* DONT_TOUCH = "TRUE" *) wire b;

  (* DONT_TOUCH = "TRUE" *) assign a = ~(b | puf_rst);
  (* DONT_TOUCH = "TRUE" *) assign b = ~(a | puf_rst);

  assign q = a;

endmodule

`default_nettype wire