`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// wdec_stream —— 权重解密流包装：明文段直通、密文段经 AES-256-CTR
//
// 真实流布局（严格镜像 P2 空跑已验证过的布局，见 p2_dryrun_evidence.json）：
//     [ X 明文 | b 明文 | W 密文 ]        顺序拼接在同一条 64-bit AXI4-Stream 上
// 只有 W 段需要解密；X/b 段**直通**（v1 里 b 仅 12 KB 且不加密，X 来自 PC 明文）。
//
// 计数器规则（与 tools/weight_encrypt.py 的 counter_block() 及加密端一致）：
//     counter 从 **W 段起点** 归零，即 aes256_ctr 的 ctr_init 只在 W 段开头装载。
//     所以本模块只要在 W 段起点之前不往 AES 送数，AES 内部的块计数自然从 0 开始。
//
// 段边界为何天然对齐：K=768 偶、N*K 恒偶、M_TOTAL=3072 偶，
// 所以 X/b/W 每个字段边界都落在 64-bit beat 边界上，不会撕裂 beat。
//   明文段字数 plain_words = X_words + b_words（X_words = N*K，b_words = M_TOTAL）
// 由软件按本次推理的 N 写入（N 可变），拆成 beat 数 = plain_words/2。
//
// ── 相位 / 排空（本模块最容易写错的地方）──────────────────────────────
//   输入解复用用一个信号 feed_aes = (已收 beat 数 >= 明文段 beat 数)；
//   输出复用不能只看输入拍数 —— AES 有 15 拍流水延迟 + 输出 FIFO，
//   密文段最后一拍喂进去后，那些密文还要十几拍才排出来。
//   所以输出侧另设 aes_active 标志：进入密文段时置位，
//   **AES 吐出带 tlast 的那一拍**才清除。aes_active 未清期间拒绝新的明文输入，
//   保证"新的传输不会插到尚未排空的 AES 输出前面"。
//
//   本模块内部例化 aes256_ctr；密钥只从 key_mgr 内部直连进来。
//=============================================================================
module wdec_stream #(
  parameter integer FIFO_DEPTH = 32,
  parameter integer CTR_W      = 32
) (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 配置（软件按本次推理写）----
  input  wire [31:0]  plain_words,   // X_words + b_words（明文段 32-bit 字数）

  // ---- 密钥（来自 key_mgr，内部直连；密钥不出 PL）----
  input  wire         key_load,
  input  wire [255:0] key_in,
  output wire         key_ready,

  // ---- CTR 参数 ----
  input  wire [95:0]      nonce,
  input  wire [CTR_W-1:0] ctr_init,
  input  wire             ctr_load,   // 单拍：装载 ctr_init（每次传输前）

  // ---- AXI4-Stream 从机（输入：DMA MM2S）----
  input  wire [63:0]  s_tdata,
  input  wire         s_tvalid,
  output wire         s_tready,
  input  wire         s_tlast,

  // ---- AXI4-Stream 主机（输出：到 GEMM s_axis）----
  output wire [63:0]  m_tdata,
  output wire         m_tvalid,
  input  wire         m_tready,
  output wire         m_tlast,

  // ---- 状态 ----
  output wire [31:0]  st_blk_cnt
);

  //-------------------------------------------------------------------
  // 输入侧相位：按已接收的 beat 数判断是否已进入密文段
  //-------------------------------------------------------------------
  reg [31:0] beat_cnt;

  wire [31:0] plain_beats = plain_words >> 1;         // 明文段 beat 数
  wire        feed_aes    = (beat_cnt >= plain_beats); // 1 = 当前拍属于密文段

  //-------------------------------------------------------------------
  // 输出侧相位：aes_active
  //-------------------------------------------------------------------
  reg  aes_active;

  // AES 输出的握手（仅在 AES 相位下才排空 AES FIFO）
  wire aes_m_take;
  wire aes_out_last;

  wire accept_plain = s_tvalid & s_tready & ~feed_aes;

  always @(posedge clk) begin
    if (!rst_n) begin
      beat_cnt   <= 32'd0;
      aes_active <= 1'b0;
    end else begin
      // ---- beat 计数：明文段/密文段共用一个连续计数 ----
      if (s_tvalid & s_tready) begin
        if (s_tlast) beat_cnt <= 32'd0;               // 一次传输结束，回零
        else         beat_cnt <= beat_cnt + 32'd1;
      end

      // ---- aes_active：进入密文段置位；AES 吐出 tlast 清除 ----
      if (s_tvalid & s_tready & feed_aes) aes_active <= 1'b1;
      if (aes_out_last)                   aes_active <= 1'b0;
    end
  end

  //-------------------------------------------------------------------
  // 内部 AES-256-CTR 引擎
  //-------------------------------------------------------------------
  wire [63:0] aes_m_tdata;
  wire        aes_m_tvalid;
  wire        aes_m_tlast;
  wire        aes_s_tready;
  wire        aes_m_tready;

  aes256_ctr #(
    .FIFO_DEPTH (FIFO_DEPTH),
    .CTR_W      (CTR_W)
  ) u_aes (
    .clk        (clk),
    .rst_n      (rst_n),
    .key_load   (key_load),
    .key_in     (key_in),
    .key_ready  (key_ready),
    .nonce      (nonce),
    .ctr_init   (ctr_init),
    .ctr_load   (ctr_load),
    .s_tdata    (s_tdata),                 // 只喂密文段
    .s_tvalid   (s_tvalid & feed_aes),
    .s_tready   (aes_s_tready),
    .s_tlast    (s_tlast  & feed_aes),
    .m_tdata    (aes_m_tdata),
    .m_tvalid   (aes_m_tvalid),
    .m_tready   (aes_m_tready),
    .m_tlast    (aes_m_tlast),
    .st_blk_cnt (st_blk_cnt)
  );

  assign aes_m_tready = m_tready & aes_active;

  assign aes_m_take    = aes_m_tvalid & aes_m_tready;
  assign aes_out_last  = aes_m_take & aes_m_tlast;

  //-------------------------------------------------------------------
  // 输入握手：明文段直通下游；密文段交给 AES。
  // AES 尚未排空时（aes_active=1）**拒绝**新的明文段输入，
  // 防止新传输的明文插到还在排空的密文输出前面，破坏顺序。
  //-------------------------------------------------------------------
  assign s_tready = feed_aes ? aes_s_tready : (m_tready & ~aes_active);

  //-------------------------------------------------------------------
  // 输出复用：AES 相位取 AES 输出；否则直通明文。
  // 注意非 AES 相位必须用 (s_tvalid & ~feed_aes) ——
  // 否则密文段第一拍在 aes_active 还没置位的那个周期会被当成明文吐出。
  //-------------------------------------------------------------------
  assign m_tdata  = aes_active ? aes_m_tdata  : s_tdata;
  assign m_tvalid = aes_active ? aes_m_tvalid : (s_tvalid & ~feed_aes);
  assign m_tlast  = aes_active ? aes_m_tlast  : (s_tlast  & ~feed_aes);

endmodule

`default_nettype wire
