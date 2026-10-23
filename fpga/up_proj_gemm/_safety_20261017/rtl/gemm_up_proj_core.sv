`timescale 1ns / 1ps
//=============================================================================
// gemm_up_proj_core —— up_proj 层 GEMM 计算核心
//
// 计算式（与 board_export/board_cfg_transformer_h_0_mlp_c_fc.json 一致）：
//     Y[m][n] = sum_{k=0}^{K-1} X[n][k] * W[m][k] + b[m]
//     M_TOTAL=3072 (out_features)  K=768 (in_features)  N=token 数
//
// ------------------------------ 数据布局契约 -------------------------------
// 输入流 (s_axis_in, 64-bit/beat, 低 32 位先发, 即 word0 = TDATA[31:0])：
//     [ X : N*K 字 ]      X[n][k]  @ 偏移 n*K + k
//     [ b : M_TOTAL 字 ]  b[m]     @ 偏移 N*K + m
//     [ W : M_TOTAL*K 字 ] W[m][k] @ 偏移 N*K + M_TOTAL + m*K + k
//   一次事务总字数 = N*K + M_TOTAL + M_TOTAL*K（必须为偶数）。
//   W 部分按趟消费：第 t 趟取 W[t*M_TILE .. t*M_TILE+M_TILE-1][*]。
//
// 输出流 (m_axis_out, 64-bit/beat, word0 = 低 32 位)：
//     for t in 0..N_TILES-1:            // N_TILES = M_TOTAL/M_TILE
//       for n in 0..N-1:
//         for m in 0..M_TILE-1:
//           Y[t*M_TILE + m][n]
//
// ------------------------------ 浮点累加顺序契约 ---------------------------
// 这是 bit-exact 的唯一依据，Python golden（tools/gen_golden_vectors.py）逐条复刻：
//   1) 每条 lane 负责一个输出行 m；K 个乘积分摊到 G 条部分和链：
//        acc[g] 累加所有 (k mod G)==g 的乘积，k 由小到大；
//   2) acc[0] **预置为 bias[m]**（不是最后再加），acc[1..G-1] 预置 0；
//   3) 归约从 acc[0] 起**串行左折**：red = (((acc0+acc1)+acc2)+...+acc[G-1])；
//   4) red 即最终 Y，直接写出。
//
// ------------------------------ 流水线约束 ---------------------------------
//   * MUL_LAT / ADD_LAT 必须与 tools/gen_fp_ip.tcl 生成的 IP 的 C_Latency 一致；
//   * **G >= ADD_LAT + 1**（硬约束，见下）；
//   * K 无需被 G 整除（余数自然落进 acc[k mod G]）。
//
//   为什么是 G >= ADD_LAT+1 而不是 >= ADD_LAT：
//     Xilinx FP 加法 IP 在时钟沿对输入采样。设乘积 k 在周期 A_k 送进加法器：
//       回写  acc[g] 在沿 A_k+ADD_LAT+1 发生 → 新值从周期 A_k+ADD_LAT+1 起可见；
//       同链下一个乘积 k+G 在周期 A_k+G 采样 acc[g]（沿 A_k+G+1 采样）。
//     要读到回写值，必须 A_k+ADD_LAT+1 <= A_k+G，即 G >= ADD_LAT+1。
//     取 G=ADD_LAT 会少读一次回写（静默丢一项），故默认 G=8 > ADD_LAT=4。
//=============================================================================
module gemm_up_proj_core #(
  parameter integer M_TILE  = 16,     // 并行输出行数 = MAC lane 数
  parameter integer M_TOTAL = 3072,   // 输出总行数
  parameter integer K_MAX   = 768,    // 规约深度上限
  parameter integer N_MAX   = 32,     // 单次事务 token 数上限
  parameter integer G       = 8,      // 部分和链数，硬约束 G >= ADD_LAT+1
  parameter integer ADD_LAT = 4,      // 与 fp32_add_ip 的 C_Latency 一致
  parameter integer MUL_LAT = 8,      // 与 fp32_mul_ip 的 C_Latency 一致
  parameter integer N_ENTRY_MAX = 16, // FaRMap 条目数上限
  parameter integer MAX_DEAD    = 2,  // 每条目 dead lane 上限（div∈{2,3}）
  parameter integer AXIS_TDATA_WIDTH = 64
) (
  input  wire clk,
  input  wire rst_n,

  // ---- 配置（来自 AXI-Lite）----
  input  wire [31:0] cfg_k_cols,
  input  wire [31:0] cfg_n_tokens,
  input  wire        cfg_start,
  input  wire        cfg_soft_rst,

  // ---- FaRMap 配置（来自 AXI-Lite，逐条目间接写）----
  input  wire        cfg_far_en,
  input  wire [31:0] cfg_far_n,
  input  wire [15:0] cfg_ent_a   [0:N_ENTRY_MAX-1],
  input  wire [31:0] cfg_ent_inv [0:N_ENTRY_MAX-1],
  input  wire [1:0]  cfg_ent_nd  [0:N_ENTRY_MAX-1],
  input  wire [15:0] cfg_ent_d0  [0:N_ENTRY_MAX-1],
  input  wire [15:0] cfg_ent_d1  [0:N_ENTRY_MAX-1],

  // ---- 状态回读 ----
  output wire [31:0] st_in_words,
  output wire [31:0] st_out_words,
  output wire [31:0] st_tile_idx,
  output wire [3:0]  st_state,
  output wire        st_busy,
  output reg         st_done,
  output reg         st_err,
  output wire [31:0] st_far_hits,
  output wire [2:0]  st_far_phase,

  // ---- 输入流 ----
  input  wire [AXIS_TDATA_WIDTH-1:0] s_axis_in_tdata,
  input  wire                        s_axis_in_tvalid,
  output wire                        s_axis_in_tready,
  input  wire                        s_axis_in_tlast,

  // ---- 输出流 ----
  output wire [AXIS_TDATA_WIDTH-1:0] m_axis_out_tdata,
  output wire                        m_axis_out_tvalid,
  input  wire                        m_axis_out_tready,
  output wire                        m_axis_out_tlast
);

  localparam integer N_TILES        = M_TOTAL / M_TILE;
  localparam integer XBUF_DEPTH     = N_MAX * K_MAX;
  localparam integer BEATS_PER_TOKEN = M_TILE / 2;   // 每 token 输出的 64-bit 拍数

  localparam [3:0] S_IDLE   = 4'd0,
                   S_LOAD_X = 4'd1,
                   S_LOAD_B = 4'd2,
                   S_LOAD_W = 4'd3,
                   S_MAC    = 4'd4,
                   S_RED    = 4'd5,
                   S_OUT    = 4'd6,
                   S_DONE   = 4'd7,
                   S_ERR    = 4'd8,
                   S_REWIRE = 4'd9;

  //===========================================================================
  // 输入流拆包：64-bit beat -> 2 个 32-bit word（低字先）
  //===========================================================================
  reg        beat_vld;
  reg [63:0] beat_d;
  reg        sel;                      // 0=低字, 1=高字

  reg  [3:0] state;

  wire [31:0] in_word   = sel ? beat_d[63:32] : beat_d[31:0];
  wire        in_word_v = beat_vld;
  wire        in_word_rdy = (state == S_LOAD_X) || (state == S_LOAD_B) || (state == S_LOAD_W);
  wire        word_ack    = in_word_v && in_word_rdy;

  assign s_axis_in_tready = (!beat_vld) || (sel && in_word_rdy);

  reg in_tlast_seen;

  always @(posedge clk) begin
    if (!rst_n) begin
      beat_vld <= 1'b0; beat_d <= 64'd0; sel <= 1'b0;
    end else begin
      if (word_ack) begin
        if (sel) beat_vld <= 1'b0;
        else     sel     <= 1'b1;
      end
      if (s_axis_in_tvalid && s_axis_in_tready) begin
        beat_d <= s_axis_in_tdata;
        beat_vld <= 1'b1;
        sel <= 1'b0;
      end
    end
  end

  //===========================================================================
  // 配置/计数寄存器
  //===========================================================================
  reg [31:0] k_cols, n_tok;
  reg [31:0] x_total, in_total;
  reg [31:0] in_cnt, out_cnt, tile_idx, n_idx, x_base;
  reg [31:0] x_cnt, b_cnt, w_k, w_m, bpre_i;
  reg [31:0] t_cnt, wb_cnt, g_add_cnt, g_wb_cnt;
  reg [31:0] red_ph, red_c;
  reg [15:0] out_idx;
  reg        mac_rd_done;

  assign st_in_words  = in_cnt;
  assign st_out_words = out_cnt;
  assign st_tile_idx  = tile_idx;
  assign st_state     = state;
  assign st_busy      = (state != S_IDLE) && (state != S_DONE);

  //===========================================================================
  // 缓冲
  //===========================================================================
  // ---- W：M_TILE 个独立 bank，提供 M_TILE 个并行读口 ----
  reg [31:0] w_rdata [0:M_TILE-1];
  wire        w_we    = word_ack && (state == S_LOAD_W);
  wire [31:0] w_waddr = w_k;
  wire [31:0] w_wbank = w_m;
  wire [31:0] w_wdata = in_word;
  wire [31:0] w_raddr = (state == S_MAC && t_cnt < k_cols) ? t_cnt : 32'd0;

  genvar gw;
  generate
    for (gw = 0; gw < M_TILE; gw = gw + 1) begin : g_wbuf
      reg [31:0] mem [0:K_MAX-1];
      always @(posedge clk) begin
        if (w_we && (w_wbank == gw)) mem[w_waddr] <= w_wdata;
        w_rdata[gw] <= mem[w_raddr];
      end
    end
  endgenerate

  // ---- X：单读口，广播给所有 lane ----
  // S_REWIRE 期间读写口交给 far_reroute（就地改写激活）；其余状态归本核。
  // 两者不会同时有效：S_REWIRE 时 in_word_rdy=0，本核 x_we 必为 0。
  reg [31:0] xbuf [0:XBUF_DEPTH-1];
  reg [31:0] x_rdata;

  wire        far_active = (state == S_REWIRE);

  wire        x_we_core    = word_ack && (state == S_LOAD_X);
  wire [31:0] x_waddr_core = x_cnt;
  wire [31:0] x_wdata_core = in_word;
  wire [31:0] x_raddr_core = (state == S_MAC && t_cnt < k_cols) ? (x_base + t_cnt) : 32'd0;

  wire        far_x_we;
  wire [31:0] far_x_waddr, far_x_wdata, far_x_raddr;

  wire        x_we_eff    = far_active ? far_x_we    : x_we_core;
  wire [31:0] x_waddr_eff = far_active ? far_x_waddr : x_waddr_core;
  wire [31:0] x_wdata_eff = far_active ? far_x_wdata : x_wdata_core;
  wire [31:0] x_raddr_eff = far_active ? far_x_raddr : x_raddr_core;

  always @(posedge clk) begin
    if (x_we_eff) xbuf[x_waddr_eff] <= x_wdata_eff;
    x_rdata <= xbuf[x_raddr_eff];
  end

  // ---- FaR 激活重路由（在 S_LOAD_X 结束后跑一次，之后 X 保持不变）----
  wire        far_done;
  wire        far_start = (state == S_LOAD_X) && word_ack && (x_cnt == x_total - 32'd1);

  far_reroute #(
    .K_MAX       (K_MAX),
    .N_MAX       (N_MAX),
    .N_ENTRY_MAX (N_ENTRY_MAX),
    .MAX_DEAD    (MAX_DEAD),
    .ADD_LAT     (ADD_LAT),
    .MUL_LAT     (MUL_LAT)
  ) u_far (
    .clk       (clk),
    .rst_n     (rst_n),
    .clr       (cfg_soft_rst),
    .start     (far_start),
    .n_tokens  (n_tok),
    .k_cols    (k_cols),
    .far_en    (cfg_far_en),
    .n_entries (cfg_far_n),
    .ent_a     (cfg_ent_a),
    .ent_inv   (cfg_ent_inv),
    .ent_nd    (cfg_ent_nd),
    .ent_d0    (cfg_ent_d0),
    .ent_d1    (cfg_ent_d1),
    .x_we      (far_x_we),
    .x_waddr   (far_x_waddr),
    .x_wdata   (far_x_wdata),
    .x_raddr   (far_x_raddr),
    .x_rdata   (x_rdata),
    .busy      (),
    .done      (far_done),
    .st_hits   (st_far_hits),
    .st_phase  (st_far_phase)
  );

  // ---- bias：单读口，每趟开头把 M_TILE 个值搬进 breg ----
  reg [31:0] bbuf [0:M_TOTAL-1];
  reg [31:0] b_rdata;
  reg [31:0] breg [0:M_TILE-1];
  wire        b_we    = word_ack && (state == S_LOAD_B);
  wire [31:0] b_raddr = (state == S_LOAD_W && bpre_i < M_TILE)
                        ? (tile_idx * M_TILE + bpre_i) : 32'd0;
  always @(posedge clk) begin
    if (b_we) bbuf[b_cnt] <= in_word;
    b_rdata <= bbuf[b_raddr];
  end

  //===========================================================================
  // MAC 阵列
  //===========================================================================
  // 时序：t_cnt==0 发 raddr=0；数据在 t_cnt==1 出现在乘法器输入（对应 k=0）；
  //       最后一个地址 k_cols-1 在 t_cnt==k_cols-1 发出，在 t_cnt==k_cols 使用。
  //       故 mul_iv 在 t_cnt ∈ [1, k_cols] 为 1，且 mac_rd_done 拉高后立刻归零。
  wire mul_iv = (state == S_MAC) && (t_cnt >= 32'd1) && !mac_rd_done;

  wire [31:0] mul_y [0:M_TILE-1];
  wire        mul_v [0:M_TILE-1];

  genvar gl;
  generate
    for (gl = 0; gl < M_TILE; gl = gl + 1) begin : g_mul
      fp32_mul #(.LAT(MUL_LAT)) u_mul (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (mul_iv),
        .a        (x_rdata),
        .b        (w_rdata[gl]),
        .out_valid(mul_v[gl]),
        .y        (mul_y[gl])
      );
    end
  endgenerate

  // 累加器：M_TILE 条 lane，每条 G 个部分和（二维数组，内层索引 G:1 选一，省 mux）
  reg [31:0] acc [0:M_TILE-1][0:G-1];

  wire [31:0] add_a [0:M_TILE-1];
  wire [31:0] add_y [0:M_TILE-1];
  wire        add_v [0:M_TILE-1];

  generate
    for (gl = 0; gl < M_TILE; gl = gl + 1) begin : g_acc
      assign add_a[gl] = acc[gl][g_add_cnt];
      fp32_add #(.LAT(ADD_LAT)) u_acc (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (mul_v[gl]),
        .a        (add_a[gl]),
        .b        (mul_y[gl]),
        .out_valid(add_v[gl]),
        .y        (add_y[gl])
      );
    end
  endgenerate

  //===========================================================================
  // 归约：每 lane 一个加法器，从 acc0 起串行左折
  //===========================================================================
  wire [31:0] red_b_idx = (red_ph < G-1) ? (red_ph + 32'd1) : (G-1);
  wire        red_iv    = (state == S_RED) && (red_c == 32'd0) && (red_ph <= G-2);

  wire [31:0] red_a [0:M_TILE-1];
  wire [31:0] red_y [0:M_TILE-1];
  wire        red_v [0:M_TILE-1];
  reg  [31:0] red_acc [0:M_TILE-1];

  generate
    for (gl = 0; gl < M_TILE; gl = gl + 1) begin : g_red
      assign red_a[gl] = (red_ph == 0) ? acc[gl][0] : red_acc[gl];
      fp32_add #(.LAT(ADD_LAT)) u_red (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (red_iv),
        .a        (red_a[gl]),
        .b        (acc[gl][red_b_idx]),
        .out_valid(red_v[gl]),
        .y        (red_y[gl])
      );
    end
  endgenerate

  //===========================================================================
  // 输出打包
  //===========================================================================
  reg [31:0] yreg [0:M_TILE-1];

  assign m_axis_out_tdata  = {yreg[2*out_idx+1], yreg[2*out_idx]};
  assign m_axis_out_tvalid = (state == S_OUT);
  assign m_axis_out_tlast  = (tile_idx == N_TILES-1) && (n_idx == n_tok-1) &&
                             (out_idx == BEATS_PER_TOKEN-1);

  //===========================================================================
  // 主状态机
  //===========================================================================
  integer li, gi;

  always @(posedge clk) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      st_done     <= 1'b0;
      st_err      <= 1'b0;
      in_tlast_seen <= 1'b0;
      k_cols      <= 32'd768;
      n_tok       <= 32'd1;
      x_total     <= 32'd0;
      in_total    <= 32'd0;
      in_cnt      <= 32'd0;
      out_cnt     <= 32'd0;
      tile_idx    <= 32'd0;
      n_idx       <= 32'd0;
      x_base      <= 32'd0;
      x_cnt       <= 32'd0;
      b_cnt       <= 32'd0;
      w_k         <= 32'd0;
      w_m         <= 32'd0;
      bpre_i      <= 32'd0;
      t_cnt       <= 32'd0;
      wb_cnt      <= 32'd0;
      g_add_cnt   <= 32'd0;
      g_wb_cnt    <= 32'd0;
      red_ph      <= 32'd0;
      red_c       <= 32'd0;
      out_idx     <= 16'd0;
      mac_rd_done <= 1'b0;
      for (li = 0; li < M_TILE; li = li + 1) begin
        for (gi = 0; gi < G; gi = gi + 1) acc[li][gi] <= 32'd0;
        breg[li] <= 32'd0; red_acc[li] <= 32'd0; yreg[li] <= 32'd0;
      end
    end else if (cfg_soft_rst) begin
      state       <= S_IDLE;
      st_done     <= 1'b0;
      st_err      <= 1'b0;
      in_tlast_seen <= 1'b0;
      in_cnt      <= 32'd0;
      out_cnt     <= 32'd0;
      tile_idx    <= 32'd0;
      n_idx       <= 32'd0;
      x_base      <= 32'd0;
      mac_rd_done <= 1'b0;
    end else begin
      // in_tlast_seen 必须只由本块驱动：它同时要在 reset / soft_rst / start 时清零。
      // 若放到 beat 采集块里去置 1，就成了多驱动网 —— 仿真两个驱动都能写、
      // 结果是对的，但综合会判定冲突并把该寄存器折叠成常量 0，
      // 于是 in_cnt 完全正确、S_OUT 却报 err=1（tlast 从未被看到）。
      if (s_axis_in_tvalid && s_axis_in_tready && s_axis_in_tlast)
        in_tlast_seen <= 1'b1;

      case (state)

        //------------------------------------------------------------------
        S_IDLE: begin
          if (cfg_start && !st_done) begin
            if ((cfg_k_cols == 0) || (cfg_k_cols > K_MAX) ||
                (cfg_n_tokens == 0) || (cfg_n_tokens > N_MAX)) begin
              st_err <= 1'b1;
              state  <= S_ERR;
            end else begin
              k_cols     <= cfg_k_cols;
              n_tok      <= cfg_n_tokens;
              x_total    <= cfg_n_tokens * cfg_k_cols;
              in_total   <= cfg_n_tokens*cfg_k_cols + M_TOTAL + M_TOTAL*cfg_k_cols;
              in_cnt     <= 32'd0;
              out_cnt    <= 32'd0;
              tile_idx   <= 32'd0;
              n_idx      <= 32'd0;
              x_base     <= 32'd0;
              x_cnt      <= 32'd0;
              b_cnt      <= 32'd0;
              w_k        <= 32'd0;
              w_m        <= 32'd0;
              bpre_i     <= 32'd0;
              t_cnt      <= 32'd0;
              wb_cnt     <= 32'd0;
              g_add_cnt  <= 32'd0;
              g_wb_cnt   <= 32'd0;
              red_ph     <= 32'd0;
              red_c      <= 32'd0;
              out_idx    <= 16'd0;
              mac_rd_done<= 1'b0;
              st_err     <= 1'b0;
              in_tlast_seen <= 1'b0;
              state      <= S_LOAD_X;
            end
          end
        end

        //------------------------------------------------------------------
        S_LOAD_X: begin
          if (word_ack) begin
            in_cnt <= in_cnt + 32'd1;
            x_cnt  <= x_cnt + 32'd1;
            // X 全部进 xbuf 后先做一次 FaR 激活重路由（far_en=0 时 1 拍直通）
            if (x_cnt == x_total - 32'd1) state <= S_REWIRE;
          end
        end

        //------------------------------------------------------------------
        // FaR 激活重路由：far_reroute 就地改写 xbuf 里的 X
        // 只跑一次（X 在整笔事务里不变，各趟只换 W tile）
        //------------------------------------------------------------------
        S_REWIRE: begin
          if (far_done) state <= S_LOAD_B;
        end

        //------------------------------------------------------------------
        S_LOAD_B: begin
          if (word_ack) begin
            in_cnt <= in_cnt + 32'd1;
            b_cnt  <= b_cnt + 32'd1;
            if (b_cnt == M_TOTAL - 1) state <= S_LOAD_W;
          end
        end

        //------------------------------------------------------------------
        S_LOAD_W: begin
          if (word_ack) begin
            in_cnt <= in_cnt + 32'd1;
            if (w_k == k_cols - 32'd1) begin
              w_k <= 32'd0;
              if (w_m == M_TILE - 1) begin
                w_m <= 32'd0;
                if (bpre_i >= M_TILE) begin
                  t_cnt       <= 32'd0;
                  wb_cnt      <= 32'd0;
                  g_add_cnt   <= 32'd0;
                  g_wb_cnt    <= 32'd0;
                  mac_rd_done <= 1'b0;
                  state       <= S_MAC;
                end
              end else begin
                w_m <= w_m + 32'd1;
              end
            end else begin
              w_k <= w_k + 32'd1;
            end
          end
          if (bpre_i <= M_TILE) bpre_i <= bpre_i + 32'd1;
          if ((bpre_i >= 32'd1) && (bpre_i <= M_TILE)) breg[bpre_i-32'd1] <= b_rdata;
        end

        //------------------------------------------------------------------
        S_MAC: begin
          // 预置部分和：acc[0]=bias，其余=0
          if (t_cnt == 32'd0) begin
            for (li = 0; li < M_TILE; li = li + 1) begin
              acc[li][0] <= breg[li];
              for (gi = 1; gi < G; gi = gi + 1) acc[li][gi] <= 32'd0;
            end
          end
          // 部分和回写
          if (add_v[0]) begin
            for (li = 0; li < M_TILE; li = li + 1)
              acc[li][g_wb_cnt] <= add_y[li];
          end
          if (t_cnt < k_cols) t_cnt <= t_cnt + 32'd1;
          else                mac_rd_done <= 1'b1;

          if (mul_v[0]) g_add_cnt <= (g_add_cnt == G-1) ? 32'd0 : g_add_cnt + 32'd1;
          if (add_v[0]) begin
            g_wb_cnt <= (g_wb_cnt == G-1) ? 32'd0 : g_wb_cnt + 32'd1;
            wb_cnt   <= wb_cnt + 32'd1;
            if (wb_cnt == k_cols - 32'd1) begin
              red_ph <= 32'd0;
              red_c  <= 32'd0;
              state  <= S_RED;
            end
          end
        end

        //------------------------------------------------------------------
        S_RED: begin
          // 每阶段占 ADD_LAT+1 拍：red_c==0 发脉冲 → red_c==ADD_LAT 取结果，
          // 再留 1 拍使 red_acc 回写对下一次读可见（避免同链 RAW，见文件头约束）。
          if (red_c == ADD_LAT) red_c <= 32'd0;
          else                  red_c <= red_c + 32'd1;

          if (red_v[0]) begin
            for (li = 0; li < M_TILE; li = li + 1) red_acc[li] <= red_y[li];
            if (red_ph == G-2) begin
              for (li = 0; li < M_TILE; li = li + 1) yreg[li] <= red_y[li];
              out_idx <= 16'd0;
              state   <= S_OUT;
            end else begin
              red_ph <= red_ph + 32'd1;
            end
          end
        end

        //------------------------------------------------------------------
        S_OUT: begin
          if (m_axis_out_tvalid && m_axis_out_tready) begin
            out_cnt <= out_cnt + 32'd2;   // 每拍 64-bit = 2 个 fp32 字
            if (out_idx == BEATS_PER_TOKEN-1) begin
              if (n_idx == n_tok - 32'd1) begin
                n_idx  <= 32'd0;
                x_base <= 32'd0;
                if (tile_idx == N_TILES-1) begin
                  if ((in_cnt != in_total) || !in_tlast_seen) st_err <= 1'b1;
                  st_done <= 1'b1;
                  state   <= S_DONE;
                end else begin
                  tile_idx <= tile_idx + 32'd1;
                  w_k      <= 32'd0;
                  w_m      <= 32'd0;
                  bpre_i   <= 32'd0;
                  state    <= S_LOAD_W;
                end
              end else begin
                n_idx       <= n_idx + 32'd1;
                x_base      <= x_base + k_cols;
                t_cnt       <= 32'd0;
                wb_cnt      <= 32'd0;
                g_add_cnt   <= 32'd0;
                g_wb_cnt    <= 32'd0;
                mac_rd_done <= 1'b0;
                state       <= S_MAC;
              end
            end else begin
              out_idx <= out_idx + 16'd1;
            end
          end
        end

        //------------------------------------------------------------------
        S_DONE: begin
          if (!cfg_start) begin
            st_done <= 1'b0;
            state   <= S_IDLE;
          end
        end

        //------------------------------------------------------------------
        S_ERR: begin
          st_err <= 1'b1;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
