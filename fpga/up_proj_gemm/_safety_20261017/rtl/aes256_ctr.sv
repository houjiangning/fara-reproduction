`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// aes256_ctr —— AES-256-CTR 流式加解密（AXI4-Stream 64-bit）
//
// CTR 关键性质：加密与解密是同一个运算（数据 XOR 密钥流）。
//   运行期      ：输入密文 → 输出明文 → 送 GEMM
//   provisioning：输入明文 → 输出密文 → 送 DMA S2MM
// 本模块不区分方向，方向由数据流决定。
//
// ---------------------------------------------------------------------------
// 流契约
// ---------------------------------------------------------------------------
//   · 64-bit/beat，每 2 个 beat 组成 1 个 128-bit AES 块（低字/低字节先）
//   · 块字节序：块字节 j 位于 blk[8*j +: 8]（见 aes256_core.sv 文件头）
//   · tlast 在流的最后一个 beat 上；本模块把它透传到对应块的第二拍
//
// ---------------------------------------------------------------------------
// 时序对齐技巧（本模块的核心）
// ---------------------------------------------------------------------------
//   AES 核的流水线由 ce 门控：ce=0 时整条流水线保持不动。
//   本模块用**同一个 ce** 驱动一条 15 级"数据延迟线"(dpipe)。
//   由于两者步进完全一致，无论 ce 的占空比如何变化，
//   第 N 个被发射的块，其密钥流与原始数据**必然在同一拍出现在输出级**，
//   于是 XOR 天然对齐，不需要任何额外的对齐 FIFO 或握手。
//
// ---------------------------------------------------------------------------
// 计数器块布局（必须与 tools/weight_encrypt.py 的 counter_block() 一致）
// ---------------------------------------------------------------------------
//   counter block 的 16 字节 = [ nonce(12B) | ctr 大端(4B) ]
//   在 128-bit 小端表示下即：
//     blk[95:0]  = nonce            （nonce 字节 0 在最低位）
//     blk[127:96]= {ctr[7:0], ctr[15:8], ctr[23:16], ctr[31:24]}
//   等价于 Python：
//     int.from_bytes(nonce_bytes + ctr.to_bytes(4,'big'), 'little')
//
// ---------------------------------------------------------------------------
// 吞吐
// ---------------------------------------------------------------------------
//   流每 2 拍供应 1 个块 → 需要 0.5 block/cycle (=800 MB/s @100MHz)
//   AES 核能力 1 block/cycle → 2 倍余量
//=============================================================================
module aes256_ctr #(
  parameter integer FIFO_DEPTH = 32,     // 输出缓冲深度（块数，须为 2 的幂）
  parameter integer CTR_W      = 32      // 计数器位宽
) (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 密钥（来自 key_mgr，只写不可读）----
  input  wire         key_load,
  input  wire [255:0] key_in,
  output wire         key_ready,

  // ---- CTR 参数 ----
  input  wire [95:0]  nonce,
  input  wire [CTR_W-1:0] ctr_init,      // 起始块号（v1 用 0）
  input  wire         ctr_load,          // 单拍脉冲：装载 ctr_init

  // ---- AXI4-Stream 从机（输入）----
  input  wire [63:0]  s_tdata,
  input  wire         s_tvalid,
  output wire         s_tready,
  input  wire         s_tlast,

  // ---- AXI4-Stream 主机（输出）----
  output wire [63:0]  m_tdata,
  output wire         m_tvalid,
  input  wire         m_tready,
  output wire         m_tlast,

  // ---- 状态 ----
  output wire [31:0]  st_blk_cnt       // 已处理块数（诊断）
);

  localparam integer LAT = 15;           // 与 aes256_core 的流水级数一致

  // FIFO 内部索引宽度（要求 FIFO_DEPTH 为 2 的幂）
  localparam integer IW  = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);

  //===========================================================================
  // 1) 输入组装：2 个 beat → 1 个 128-bit 块
  //===========================================================================
  reg  [63:0] lo_beat;
  reg         lo_last;
  reg         lo_valid;

  wire [127:0] in_blk_now = {s_tdata, lo_beat};

  wire         take   = s_tvalid & s_tready;
  wire         issue  = take & lo_valid;   // 第二个 beat 到达 → 发射一个块

  //===========================================================================
  // 2) 流控：inflight 计数 + 输出 FIFO 余量
  //===========================================================================
  reg  [7:0]  inflight;                    // 已发射但尚未出现在输出级的块数
  reg  [7:0]  fifo_cnt;

  wire        can_issue = ((fifo_cnt + inflight) < FIFO_DEPTH[7:0]);

  assign      s_tready  = (~lo_valid) | can_issue;

  always @(posedge clk) begin
    if (!rst_n) begin
      lo_beat  <= 64'd0;
      lo_last  <= 1'b0;
      lo_valid <= 1'b0;
    end else if (take) begin
      if (!lo_valid) begin
        lo_beat  <= s_tdata;
        lo_last  <= s_tlast;
        lo_valid <= 1'b1;
      end else begin
        lo_valid <= 1'b0;                  // 该块已发射
      end
    end
  end

  //===========================================================================
  // 3) CTR 计数器
  //===========================================================================
  reg  [CTR_W-1:0] ctr;
  reg  [31:0]      blk_cnt;

  // 计数器块：nonce 在低 96 位，ctr 大端在 [127:96]
  wire [127:0] ctr_blk = {ctr[7:0], ctr[15:8], ctr[23:16], ctr[31:24], nonce};

  always @(posedge clk) begin
    if (!rst_n) begin
      ctr     <= {CTR_W{1'b0}};
      blk_cnt <= 32'd0;
    end else begin
      if (ctr_load) begin
        ctr     <= ctr_init;
        blk_cnt <= 32'd0;
      end else if (issue) begin
        ctr     <= ctr + {{(CTR_W-1){1'b0}}, 1'b1};
        blk_cnt <= blk_cnt + 32'd1;
      end
    end
  end

  //===========================================================================
  // 4) AES 核 + 数据延迟线（两者步进一致 → 天然对齐）
  //
  //   ce 固定为 1：不门控流水线。
  //   早期版本把 ce 接成 issue（即"只在发射时步进"），实测有两个致命问题：
  //     ① ks_vld(=pvld[14]) 在 ce=0 期间会**保持**多个周期，同一个块被重复
  //        推入输出 FIFO（实测 64 块推出 141 拍）；
  //     ② 输入结束后不再有 issue，流水线永久冻结，尾部十几个块永不排出。
  //   ce≡1 时流水线每拍步进，ks_vld 每块恰好是**单周期脉冲**，
  //   且固定延迟 15 拍即可对齐 dpipe 与密钥流，逻辑最简单也最可证。
  //   （若将来要省功耗，需另做"inflight 排空"机制，不能简单门控。）
  //===========================================================================
  wire         ce = 1'b1;
  wire [127:0] ks_blk;
  wire         ks_vld;

  aes256_core u_aes (
    .clk       (clk),
    .rst_n     (rst_n),
    .key_load  (key_load),
    .key_in    (key_in),
    .key_ready (key_ready),
    .ce        (ce),
    .in_valid  (issue),
    .in_blk    (ctr_blk),
    .out_valid (ks_vld),
    .out_blk   (ks_blk)
  );

  // 数据延迟线：深度 = LAT，与 AES 流水线同步步进
  reg  [127:0] dpipe [0:LAT-1];
  reg          lpipe [0:LAT-1];

  integer di;

  always @(posedge clk) begin
    if (!rst_n) begin
      for (di = 0; di < LAT; di = di + 1) begin
        dpipe[di] <= 128'd0;
        lpipe[di] <= 1'b0;
      end
    end else if (ce) begin
      dpipe[0] <= in_blk_now;
      lpipe[0] <= s_tlast;                 // 第二拍的 tlast 就是该块的末拍标记
      for (di = 1; di < LAT; di = di + 1) begin
        dpipe[di] <= dpipe[di-1];
        lpipe[di] <= lpipe[di-1];
      end
    end
  end

  // 输出级：数据 ^ 密钥流（加密与解密同一式子）
  wire [127:0] xor_blk  = dpipe[LAT-1] ^ ks_blk;
  wire         xor_last = lpipe[LAT-1];

  //===========================================================================
  // 5) 输出缓冲 FIFO（吸收 m_tready 抖动）
  //    注：输出寄存器的声明放在本块之前，避免前向引用。
  //===========================================================================
  reg  [127:0] fifo_mem  [0:FIFO_DEPTH-1];
  reg          fifo_last [0:FIFO_DEPTH-1];
  reg  [IW:0]  fifo_wp, fifo_rp;           // 多 1 位便于回绕比较（深度为 2 的幂时低位即索引）

  reg  [127:0] out_blk_r;
  reg          out_last_r;
  reg          out_ovld;
  reg          out_sel;                    // 0=低 64 位（第一拍）, 1=高 64 位

  wire fifo_empty = (fifo_cnt == 8'd0);
  wire fifo_push  = ks_vld;                // ks_vld 高时 xor_blk 有效
  wire out_take   = (!out_ovld) && (!fifo_empty);

  always @(posedge clk) begin
    if (!rst_n) begin
      fifo_wp   <= {(IW+1){1'b0}};
      fifo_rp   <= {(IW+1){1'b0}};
      fifo_cnt  <= 8'd0;
      inflight  <= 8'd0;
    end else begin
      // ---- 写侧 ----
      if (fifo_push) begin
        fifo_mem [fifo_wp[IW-1:0]] <= xor_blk;
        fifo_last[fifo_wp[IW-1:0]] <= xor_last;
        fifo_wp <= fifo_wp + {{IW{1'b0}}, 1'b1};
      end

      // ---- 读侧：把一个块搬进输出寄存器 ----
      if (out_take)
        fifo_rp <= fifo_rp + {{IW{1'b0}}, 1'b1};

      // ---- 计数 ----
      case ({fifo_push, out_take})
        2'b10: fifo_cnt <= fifo_cnt + 8'd1;
        2'b01: fifo_cnt <= fifo_cnt - 8'd1;
        default: fifo_cnt <= fifo_cnt;
      endcase

      // ---- inflight：发射 +1，出流水线 -1 ----
      case ({issue, ks_vld})
        2'b10: inflight <= inflight + 8'd1;
        2'b01: inflight <= inflight - 8'd1;
        default: inflight <= inflight;
      endcase
    end
  end

  //===========================================================================
  // 6) 输出寄存器：一个块 = 2 个 beat
  //===========================================================================
  always @(posedge clk) begin
    if (!rst_n) begin
      out_blk_r  <= 128'd0;
      out_last_r <= 1'b0;
      out_ovld   <= 1'b0;
      out_sel    <= 1'b0;
    end else begin
      if (out_take) begin
        out_blk_r  <= fifo_mem [fifo_rp[IW-1:0]];
        out_last_r <= fifo_last[fifo_rp[IW-1:0]];
        out_ovld   <= 1'b1;
        out_sel    <= 1'b0;
      end else if (out_ovld && m_tready) begin
        if (out_sel == 1'b0) out_sel  <= 1'b1;
        else                 out_ovld <= 1'b0;
      end
    end
  end

  assign m_tdata  = out_sel ? out_blk_r[127:64] : out_blk_r[63:0];
  assign m_tvalid = out_ovld;
  assign m_tlast  = out_ovld & out_sel & out_last_r;

  assign st_blk_cnt = blk_cnt;

endmodule

`default_nettype wire