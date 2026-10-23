`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// far_reroute —— FaR 激活重路由引擎（Forget-and-Rewire 里的 Rewire 半步）
//
// 作用对象：gemm_up_proj_core 里的 xbuf（X[n][k] @ n*k_cols + k）。
// 对每条 FaRMap 条目 e，逐 token 就地施加下列变换：
//
//     half      = X[n][A_e] * invdiv_e      // invdiv = 1/div，fp32
//     X[n][A_e] = half                       // 主 lane：激活规约到 1/div
//     X[n][d]   = X[n][d] + half             // 每条 dead lane 吃入 x[A]/div
//
// 这与软件端 far_defense.py 的 FaRLayer.forward 逐字对应：
//     act[..., A] = x[..., A] / div
//     act[..., d] = x[..., d] + x[..., A] / div
// 把权重列一起看就是：Y = (x[A]/div)·W[:,A] + (x[d]+x[A]/div)·W'[:,d]，
// 其中 W'[:,d] = W[:,A]（离线 shadow，已烘焙进 board_W）。因为 d 是"死通道"
// （x[d]≈0），所以 Y 与未加固时守恒：Y ≈ x[A]·W[:,A] + Σ_{k≠A} x[k]W[:,k]。
//
// 为什么用「乘 1/div」而不是除法：省一个 fp32 除法器。
//   div=2 时 1/2 精确可表示，x*0.5 与 x/2 逐位一致 → 与软件 golden bit-exact；
//   div=3 时 1/3 只能取最近邻 fp32，与真除法最多差 1 ulp（golden 按同一口径生成）。
//
// 为什么可以「就地」改写：far_defense.apply_rewire 保证各条目的 A 互不相同、
// dead 也不与任何 A 重合，所以逐条目顺序改写不会读到被别的条目污染的值。
//
// ------------------------------ 时序契约 -----------------------------------
// xbuf 读口是**寄存器输出**：本模块在 R_RD 拍给出 x_raddr，x_rdata 要到
// 再下一拍才有效（见 core 里 `x_rdata <= xbuf[x_raddr]`）。因此：
//     R_RD    : 发 x_raddr（cur_addr）
//     R_CALC  : lat_cnt=0 空等（x_rdata 还没出来）
//               lat_cnt=1 断言 in_valid（此时 x_rdata 已有效）
//               lat_cnt=1+LAT 结果有效 → 锁存
//     R_WR    : 写回 xbuf
//     R_ADV   : 推进索引
// 若把 in_valid 提前一拍（lat_cnt=0），乘法器会采到上一拍的旧 x_rdata，
// 结果会静默错一个元素 —— 这是本模块最容易被改坏的地方。
//=============================================================================
module far_reroute #(
  parameter integer K_MAX       = 768,   // 规约深度上限（xbuf 行宽）
  parameter integer N_MAX       = 32,    // token 数上限
  parameter integer N_ENTRY_MAX = 16,    // FaRMap 条目数上限
  parameter integer MAX_DEAD    = 2,     // div∈{2,3} → 每条目最多 2 条 dead lane
  parameter integer ADD_LAT     = 4,     // 与 fp32_add 的 LAT 一致
  parameter integer MUL_LAT     = 8      // 与 fp32_mul 的 LAT 一致
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        clr,          // 同步清零（接 core 的 cfg_soft_rst）

  // ---- 启动（单拍脉冲）----
  input  wire        start,
  input  wire [31:0] n_tokens,
  input  wire [31:0] k_cols,

  // ---- FaRMap（由 AXI-Lite 写入）----
  input  wire        far_en,
  input  wire [31:0] n_entries,
  input  wire [15:0] ent_a   [0:N_ENTRY_MAX-1],   // 敏感输入通道 A
  input  wire [31:0] ent_inv [0:N_ENTRY_MAX-1],   // fp32 1/div
  input  wire [1:0]  ent_nd  [0:N_ENTRY_MAX-1],   // dead 条数
  input  wire [15:0] ent_d0  [0:N_ENTRY_MAX-1],   // dead 通道 #0
  input  wire [15:0] ent_d1  [0:N_ENTRY_MAX-1],   // dead 通道 #1

  // ---- xbuf 读写口 ----
  output reg         x_we,
  output reg  [31:0] x_waddr,
  output reg  [31:0] x_wdata,
  output reg  [31:0] x_raddr,
  input  wire [31:0] x_rdata,

  // ---- 状态 ----
  output reg         busy,
  output reg         done,
  output reg  [31:0] st_hits,      // 本次重路由实际改写的元素个数（诊断）
  output reg  [2:0]  st_phase
);

  localparam [2:0] R_IDLE = 3'd0,
                   R_RD   = 3'd1,
                   R_CALC = 3'd2,
                   R_WR   = 3'd3,
                   R_ADV  = 3'd4,
                   R_DONE = 3'd5;

  reg [2:0]  rstate;
  reg [31:0] e_i, n_i, d_i;      // 条目 / token / dead 索引
  reg [31:0] base;               // n_i * k_cols
  reg [31:0] lat_cnt;
  reg [31:0] half_r;             // x[A]/div
  reg [31:0] res_r;              // x[d] + half
  reg        cur_dead;           // 0=正在处理 A，1=正在处理某条 dead
  reg [31:0] hits_r;

  assign st_phase = rstate;

  //------------------------------------------------------------------
  // 当前元素的地址与操作数
  //------------------------------------------------------------------
  wire [3:0]  ei = e_i[3:0];                      // N_ENTRY_MAX <= 16
  wire [31:0] cur_a    = {16'd0, ent_a[ei]};
  wire [31:0] cur_inv  = ent_inv[ei];
  wire [1:0]  cur_nd   = ent_nd[ei];
  wire [31:0] cur_d    = {16'd0, (d_i == 32'd0) ? ent_d0[ei] : ent_d1[ei]};
  wire [31:0] cur_addr = base + (cur_dead ? cur_d : cur_a);

  // in_valid 只在 R_CALC 的第 1 拍（lat_cnt==1）拉高；此时 x_rdata 才有效
  wire iv_tick = (rstate == R_CALC) && (lat_cnt == 32'd1);
  wire mul_iv  = iv_tick && !cur_dead;
  wire add_iv  = iv_tick &&  cur_dead;

  // 结果锁存拍：mul 走 MUL_LAT，add 走 ADD_LAT
  wire [31:0] lat_sel = cur_dead ? {28'd0, ADD_LAT[3:0]} : {28'd0, MUL_LAT[3:0]};
  wire        cap_tick = (rstate == R_CALC) && (lat_cnt == (32'd1 + lat_sel));

  wire [31:0] mul_y, add_y;
  wire        mul_v, add_v;

  fp32_mul #(.LAT(MUL_LAT)) u_mul (
    .clk      (clk),
    .rst_n    (rst_n),
    .in_valid (mul_iv),
    .a        (x_rdata),
    .b        (cur_inv),
    .out_valid(mul_v),
    .y        (mul_y)
  );

  fp32_add #(.LAT(ADD_LAT)) u_add (
    .clk      (clk),
    .rst_n    (rst_n),
    .in_valid (add_iv),
    .a        (x_rdata),
    .b        (half_r),
    .out_valid(add_v),
    .y        (add_y)
  );

  //------------------------------------------------------------------
  // 主状态机
  //------------------------------------------------------------------
  reg last_tok, last_ent;

  always @(posedge clk) begin
    if (!rst_n || clr) begin
      rstate   <= R_IDLE;
      busy     <= 1'b0;
      done     <= 1'b0;
      x_we     <= 1'b0;
      x_waddr  <= 32'd0;
      x_wdata  <= 32'd0;
      x_raddr  <= 32'd0;
      e_i      <= 32'd0;
      n_i      <= 32'd0;
      d_i      <= 32'd0;
      base     <= 32'd0;
      lat_cnt  <= 32'd0;
      half_r   <= 32'd0;
      res_r    <= 32'd0;
      cur_dead <= 1'b0;
      hits_r   <= 32'd0;
      st_hits  <= 32'd0;
    end else begin
      done <= 1'b0;        // done 是单拍脉冲
      x_we <= 1'b0;

      case (rstate)

        //--------------------------------------------------------------
        R_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            hits_r <= 32'd0;
            if (!far_en || (n_entries == 32'd0) ||
                (n_tokens == 32'd0) || (k_cols == 32'd0)) begin
              st_hits <= 32'd0;
              done    <= 1'b1;
            end else begin
              busy     <= 1'b1;
              e_i      <= 32'd0;
              n_i      <= 32'd0;
              d_i      <= 32'd0;
              base     <= 32'd0;
              cur_dead <= 1'b0;
              lat_cnt  <= 32'd0;
              rstate   <= R_RD;
            end
          end
        end

        //--------------------------------------------------------------
        // 发读地址；x_rdata 要到下一拍才有效
        R_RD: begin
          x_raddr <= cur_addr;
          lat_cnt <= 32'd0;
          rstate  <= R_CALC;
        end

        //--------------------------------------------------------------
        // 等流水线出结果
        R_CALC: begin
          if (cap_tick) begin
            if (cur_dead) res_r  <= add_y;
            else          half_r <= mul_y;
            rstate <= R_WR;
          end else begin
            lat_cnt <= lat_cnt + 32'd1;
          end
        end

        //--------------------------------------------------------------
        // 写回
        R_WR: begin
          x_we    <= 1'b1;
          x_waddr <= cur_addr;
          x_wdata <= cur_dead ? res_r : half_r;
          hits_r  <= hits_r + 32'd1;
          rstate  <= R_ADV;
        end

        //--------------------------------------------------------------
        // 推进：A → 各 dead → 下一 token → 下一条目
        R_ADV: begin
          last_tok = (n_i == n_tokens - 32'd1);
          last_ent = (e_i == n_entries - 32'd1);

          if (!cur_dead) begin
            if (cur_nd != 2'd0) begin
              cur_dead <= 1'b1;
              d_i      <= 32'd0;
              rstate   <= R_RD;
            end else begin
              if (last_tok) begin
                n_i  <= 32'd0;
                base <= 32'd0;
                if (last_ent) rstate <= R_DONE;
                else begin e_i <= e_i + 32'd1; rstate <= R_RD; end
              end else begin
                n_i    <= n_i + 32'd1;
                base   <= base + k_cols;
                rstate <= R_RD;
              end
            end
          end else begin
            if (d_i == {30'd0, cur_nd} - 32'd1) begin
              cur_dead <= 1'b0;
              d_i      <= 32'd0;
              if (last_tok) begin
                n_i  <= 32'd0;
                base <= 32'd0;
                if (last_ent) rstate <= R_DONE;
                else begin e_i <= e_i + 32'd1; rstate <= R_RD; end
              end else begin
                n_i    <= n_i + 32'd1;
                base   <= base + k_cols;
                rstate <= R_RD;
              end
            end else begin
              d_i    <= d_i + 32'd1;
              rstate <= R_RD;
            end
          end
        end

        //--------------------------------------------------------------
        R_DONE: begin
          busy    <= 1'b0;
          done    <= 1'b1;
          st_hits <= hits_r;
          rstate  <= R_IDLE;
        end

        default: rstate <= R_IDLE;
      endcase
    end
  end

  // synopsys translate_off
  initial begin
    if (MAX_DEAD > 2)
      $display("[far_reroute] WARNING: MAX_DEAD=%0d > 2，d1 端口只覆盖第 2 条 dead", MAX_DEAD);
    if (N_ENTRY_MAX > 16)
      $display("[far_reroute] WARNING: N_ENTRY_MAX=%0d > 16，e_i 索引被截到 4 位", N_ENTRY_MAX);
  end
  // synopsys translate_on

endmodule

`default_nettype wire
