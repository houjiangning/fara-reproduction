`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// bpuf_ctrl —— PUF 采样时序状态机
//
// 一次完整采样序列（由 start 触发）：
//
//   S_IDLE    参数校验（M 必须为奇数且在 [1, 2^CNT_W-1]、T_FORCE/T_SETTLE>=1）
//   S_CLR     array_clr 一拍，清零投票计数
//   S_FORCE   array_rst=1，保持 t_force 个周期
//   S_SETTLE  array_rst=0，等待 t_settle 个周期让电路收敛
//   S_SAMPLE  array_sample 一拍，把本轮结果累加进计数；round++
//             round < M → 回 S_FORCE 继续下一轮；否则 → S_DONE
//   S_DONE    锁存 q_maj / q_unan，统计稳定位数，done=1
//   S_ERR     参数非法，err=1
//
// 时序参数（T_FORCE / T_SETTLE）与采样次数 M 全部来自 AXI-Lite 寄存器，
// **必须用你自己的板子实测标定** —— 不要照抄默认值。标定方法见方案 B 文档 §3.4。
//
// 为什么 force/settle 用"周期数"而不是真实模拟延时：
//   本模块是数字逻辑，等的是"数字意义上的稳定"。真实收敛时间取决于物理实现，
//   用固定周期数作为可调参数、通过实测找到响应翻转率的拐点，是最实用的做法。
//=============================================================================
module bpuf_ctrl #(
  parameter integer N_BITS = 128,
  parameter integer CNT_W  = 5
) (
  input  wire clk,
  input  wire rst_n,

  // ---- 配置（来自 AXI-Lite）----
  input  wire        start,      // 电平：start=1 且 done=0 时启动一次
  input  wire        soft_rst,
  input  wire [31:0] t_force,
  input  wire [31:0] t_settle,
  input  wire [31:0] n_samp,     // M

  // ---- 到阵列 ----
  output reg         array_clr,
  output reg         array_rst,
  output reg         array_sample,
  input  wire [N_BITS-1:0] q_maj,
  input  wire [N_BITS-1:0] q_unan,
  input  wire [31:0]       n_samp_done,

  // ---- 状态 ----
  output reg  [N_BITS-1:0] resp_reg,   // 多数表决响应（锁存）
  output reg  [N_BITS-1:0] unan_reg,   // 非一致掩码（锁存）
  output reg  [31:0]       stable_cnt, // 稳定位数 = N_BITS - popcount(unan)
  output reg  [31:0]       nsamp_reg,  // 实际采样次数（锁存）
  output wire busy,
  output reg  done,
  output reg  err,
  output reg  [3:0] state
);

  localparam [3:0] S_IDLE   = 4'd0,
                   S_CLR    = 4'd1,
                   S_FORCE  = 4'd2,
                   S_SETTLE = 4'd3,
                   S_SAMPLE = 4'd4,
                   S_DONE   = 4'd5,
                   S_ERR    = 4'd6;

  localparam integer M_MAX = (1 << CNT_W) - 1;

  reg [31:0] timer;
  reg [31:0] round;

  assign busy = (state != S_IDLE) && (state != S_DONE) && (state != S_ERR);

  //-------------------------------------------------------------------
  // 参数校验：M 为奇数且落在 [1, M_MAX]
  //-------------------------------------------------------------------
  wire n_samp_ok  = (n_samp != 32'd0) && (n_samp <= M_MAX) && (n_samp[0] == 1'b1);
  wire t_force_ok = (t_force  != 32'd0);
  wire t_settl_ok = (t_settle != 32'd0);
  wire params_ok  = n_samp_ok && t_force_ok && t_settl_ok;

  //-------------------------------------------------------------------
  // 稳定位数：N_BITS 减去非一致位数
  //-------------------------------------------------------------------
  integer b;
  reg [31:0] unan_pop;

  always @(*) begin
    unan_pop = 32'd0;
    for (b = 0; b < N_BITS; b = b + 1)
      unan_pop = unan_pop + (q_unan[b] ? 32'd1 : 32'd0);
  end

  //-------------------------------------------------------------------
  // 主状态机
  //-------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      timer        <= 32'd0;
      round        <= 32'd0;
      array_clr    <= 1'b0;
      array_rst  <= 1'b0;
      array_sample <= 1'b0;
      resp_reg     <= {N_BITS{1'b0}};
      unan_reg     <= {N_BITS{1'b0}};
      stable_cnt   <= 32'd0;
      nsamp_reg    <= 32'd0;
      done         <= 1'b0;
      err          <= 1'b0;
    end else if (soft_rst) begin
      state        <= S_IDLE;
      timer        <= 32'd0;
      round        <= 32'd0;
      array_clr    <= 1'b0;
      array_rst  <= 1'b0;
      array_sample <= 1'b0;
      done         <= 1'b0;
      err          <= 1'b0;
    end else begin
      // 默认电平（每拍重置，需要时在下面的状态里拉高）
      array_clr    <= 1'b0;
      array_sample <= 1'b0;

      case (state)

        //--------------------------------------------------------------
        S_IDLE: begin
          array_rst <= 1'b0;
          if (start && !done) begin
            if (!params_ok) begin
              err   <= 1'b1;
              state <= S_ERR;
            end else begin
              err   <= 1'b0;
              timer <= 32'd0;
              round <= 32'd0;
              state <= S_CLR;
            end
          end
        end

        //--------------------------------------------------------------
        S_CLR: begin
          array_clr   <= 1'b1;      // 一拍
          array_rst <= 1'b1;      // 紧接着进入强制态，无空洞
          timer       <= 32'd0;
          state       <= S_FORCE;
        end

        //--------------------------------------------------------------
        S_FORCE: begin
          array_rst <= 1'b1;
          if (timer >= t_force - 32'd1) begin
            timer <= 32'd0;
            state <= S_SETTLE;
          end else begin
            timer <= timer + 32'd1;
          end
        end

        //--------------------------------------------------------------
        S_SETTLE: begin
          array_rst <= 1'b0;      // 放开，等待收敛
          if (timer >= t_settle - 32'd1) begin
            timer <= 32'd0;
            state <= S_SAMPLE;
          end else begin
            timer <= timer + 32'd1;
          end
        end

        //--------------------------------------------------------------
        S_SAMPLE: begin
          array_rst  <= 1'b0;
          array_sample <= 1'b1;     // 一拍，把本轮 q 累加进计数
          if (round >= n_samp - 32'd1) begin
            state <= S_DONE;
          end else begin
            round <= round + 32'd1;
            timer <= 32'd0;
            state <= S_FORCE;       // 下一轮：先强制
          end
        end

        //--------------------------------------------------------------
        S_DONE: begin
          array_rst <= 1'b0;
          // 与 GEMM 侧既有语义保持一致：done 置 1 后保持，软件把 start 写 0 才清 done。
          // （早期版本在 S_IDLE 里没清 done，导致第二次采样无法启动。）
          if (!start) begin
            done  <= 1'b0;
            state <= S_IDLE;
          end else begin
            resp_reg    <= q_maj;         // 此时计数已稳定，可安全锁存
            unan_reg    <= q_unan;
            stable_cnt  <= N_BITS - unan_pop;
            nsamp_reg   <= n_samp_done;
            done        <= 1'b1;
          end
        end

        //--------------------------------------------------------------
        S_ERR: begin
          array_rst <= 1'b0;
          err         <= 1'b1;
        end

        default: state <= S_IDLE;

      endcase
    end
  end

endmodule

`default_nettype wire