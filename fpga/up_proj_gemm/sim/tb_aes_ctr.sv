`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_aes_ctr —— AES-256-CTR 自检 testbench
//
// 两个独立测试：
//
//   Test 1  aes256_core 直连 NIST KAT
//     从 aes_kat.mem 读入官方向量，直接对 aes256_core 喂计数器块，
//     比对输出密钥流。这一项**只验证 AES 轮函数本身**（S-box/ShiftRows/
//     MixColumns/密钥扩展），与流控无关。
//       mem[0] key[255:128]   mem[1] key[127:0]
//       mem[2..5] 4 个计数器块    mem[6..9] 4 个期望密钥流
//
//   Test 2  aes256_ctr 流式端到端 + 反压
//     从 aes_vectors.mem 读入随机向量，按 64-bit beat 喂入，
//     输出侧施加**随机 m_tready 反压**，比对每个块的密文。
//       mem[0] key[255:128]  mem[1] key[127:0]
//       mem[2] {32'h0,nonce}  mem[3] ctr_init  mem[4] n_blk
//       mem[5..] 明文块   随后 n_blk 个期望密文块
//
// 运行：tools/run_sim.ps1 -Only aes
//=============================================================================
module tb_aes_ctr;

  localparam integer LAT     = 15;
  localparam integer MAX_BLK = 256;

  // ------------------------------------------------------------------
  // 运行期参数 / 文件路径（必须在 initial 之前声明）
  // ------------------------------------------------------------------
  reg [1023:0] kat_file;
  reg [1023:0] vec_file;
  reg [31:0]   n_blk_v;

  // ------------------------------------------------------------------
  // 时钟 / 复位
  // ------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  integer npass = 0;
  integer nfail = 0;

  // ------------------------------------------------------------------
  // 向量存储器
  // ------------------------------------------------------------------
  reg [127:0] kat_mem [0:15];
  reg [127:0] vec_mem [0:8191];

  // ==================================================================
  // Test 1 : aes256_core 直连 KAT
  // ==================================================================
  reg          c_key_load = 1'b0;
  reg  [255:0] c_key      = 256'd0;
  wire         c_key_ready;
  reg          c_ce       = 1'b0;
  reg          c_iv       = 1'b0;
  reg  [127:0] c_ib       = 128'd0;
  wire         c_ov;
  wire [127:0] c_ob;

  aes256_core u_core (
    .clk       (clk),
    .rst_n     (rst_n),
    .key_load  (c_key_load),
    .key_in    (c_key),
    .key_ready (c_key_ready),
    .ce        (c_ce),
    .in_valid  (c_iv),
    .in_blk    (c_ib),
    .out_valid (c_ov),
    .out_blk   (c_ob)
  );

  // 输出收集器
  integer      c_ncol;
  reg [127:0]  c_col [0:15];

  always @(posedge clk) begin
    if (c_ov && c_ncol < 16) begin
      c_col[c_ncol] <= c_ob;
      c_ncol        <= c_ncol + 1;
    end
  end

  // ==================================================================
  // Test 2 : aes256_ctr 流式
  // ==================================================================
  reg          s_key_load = 1'b0;
  reg  [255:0] s_key      = 256'd0;
  wire         s_key_ready;
  reg  [95:0]  s_nonce    = 96'd0;
  reg  [31:0]  s_ctr0     = 32'd0;
  reg          s_ctr_load = 1'b0;

  reg  [63:0]  s_tdata  = 64'd0;
  reg          s_tvalid = 1'b0;
  wire         s_tready;
  reg          s_tlast  = 1'b0;

  wire [63:0]  m_tdata;
  wire         m_tvalid;
  reg          m_tready = 1'b0;
  wire         m_tlast;
  wire [31:0]  s_blk_cnt;

  aes256_ctr #(
    .FIFO_DEPTH (32),
    .CTR_W      (32)
  ) u_ctr (
    .clk        (clk),
    .rst_n      (rst_n),
    .key_load   (s_key_load),
    .key_in     (s_key),
    .key_ready  (s_key_ready),
    .nonce      (s_nonce),
    .ctr_init   (s_ctr0),
    .ctr_load   (s_ctr_load),
    .s_tdata    (s_tdata),
    .s_tvalid   (s_tvalid),
    .s_tready   (s_tready),
    .s_tlast    (s_tlast),
    .m_tdata    (m_tdata),
    .m_tvalid   (m_tvalid),
    .m_tready   (m_tready),
    .m_tlast    (m_tlast),
    .st_blk_cnt (s_blk_cnt)
  );

  // ---- 输入激励源 ----
  //   src_idx / s_tvalid / s_tdata / s_tlast 只由本 always 块驱动。
  //   初始块**绝不**直接写 src_idx —— 曾因 initial(阻塞) 与 always(NBA)
  //   同时写它，xsim 把 src_idx 解析成 X，导致整个 Test 2 空转。
  //   启动只用 src_run（初始块独占）+ reset 已把 src_idx 清零。
  reg  [63:0] src_beats [0:2*MAX_BLK-1];
  integer     n_beats;
  integer     src_idx;
  reg         src_run = 1'b0;

  wire        consume = s_tvalid & s_tready & src_run;
  wire [31:0] nxt     = consume ? (src_idx + 1) : src_idx;
  wire        present = src_run & (nxt < n_beats);

  always @(posedge clk) begin
    if (!rst_n) begin
      src_idx  <= 0;
      s_tvalid <= 1'b0;
      s_tdata  <= 64'd0;
      s_tlast  <= 1'b0;
    end else begin
      src_idx  <= nxt;
      s_tvalid <= present;
      s_tdata  <= src_beats[nxt];
      s_tlast  <= (nxt == n_beats - 1);
    end
  end

  // ---- 输出侧：随机反压（约 30% 概率不 ready，用来压测输出 FIFO）----
  reg [31:0] rnd = 32'h1234_5678;

  always @(posedge clk) begin
    if (!rst_n) begin
      m_tready <= 1'b0;
      rnd      <= 32'h1234_5678;
    end else begin
      rnd      <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1]};   // LFSR
      m_tready <= ~(rnd[3:0] == 4'h0) | (rnd[7:4] != 4'h5);  // 伪随机，大部分为 1
    end
  end

  // ---- 输出收集 ----
  reg [63:0] out_beats [0:2*MAX_BLK-1];
  integer    out_n;
  integer    out_last_idx;

  always @(posedge clk) begin
    if (!rst_n) begin
      out_n        <= 0;
      out_last_idx <= -1;
    end else if (m_tvalid && m_tready) begin
      out_beats[out_n] <= m_tdata;
      if (m_tlast) out_last_idx <= out_n;
      out_n <= out_n + 1;
    end
  end

  // ==================================================================
  // 主流程
  // ==================================================================
  integer i, blk;
  reg [127:0] exp_blk, got_beats;
  reg [63:0]  b0, b1;

  initial begin
    if (!$value$plusargs("KAT=%s", kat_file)) kat_file = "aes_kat.mem";
    if (!$value$plusargs("VEC=%s", vec_file)) vec_file = "aes_vectors.mem";

    $display("================================================================");
    $display("tb_aes_ctr  AES-256-CTR 自检");
    $display("  KAT 向量 : %0s", kat_file);
    $display("  随机向量 : %0s", vec_file);
    $display("================================================================");

    // ---------------------------------------------------------------
    // Test 1
    // ---------------------------------------------------------------
    $readmemh(kat_file, kat_mem);
    $display("");
    $display("---- Test 1: aes256_core vs NIST KAT ----");

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    c_ncol = 0;
    repeat (2) @(posedge clk);

    // 装载密钥（mem[0] 是 key 高 128 位）
    c_key = {kat_mem[0], kat_mem[1]};
    @(negedge clk); c_key_load = 1'b1;
    @(negedge clk); c_key_load = 1'b0;

    // 等密钥扩展完成
    i = 0;
    while (!c_key_ready && i < 200) begin
      @(posedge clk); i = i + 1;
    end
    if (!c_key_ready) begin
      $display("  !! key_ready 超时（%0d 拍未见）", i);
      nfail = nfail + 1;
    end else begin
      $display("  key_ready 在 %0d 拍后拉高", i);
    end

    // ce 常开，连发 4 个计数器块（mem[2..5]）
    c_ce = 1'b1;
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk);
      c_iv = 1'b1;
      c_ib = kat_mem[2 + i];
    end
    @(negedge clk);
    c_iv = 1'b0;

    repeat (LAT + 8) @(posedge clk);
    c_ce = 1'b0;

    for (i = 0; i < 4; i = i + 1) begin
      if (c_col[i] === kat_mem[6 + i]) begin
        $display("  blk%0d keystream OK   %032h", i, c_col[i]);
        npass = npass + 1;
      end else begin
        $display("  blk%0d keystream BAD  got %032h want %032h", i, c_col[i], kat_mem[6 + i]);
        nfail = nfail + 1;
      end
    end

    // ---------------------------------------------------------------
    // Test 2
    // ---------------------------------------------------------------
    $readmemh(vec_file, vec_mem);
    $display("");
    $display("---- Test 2: aes256_ctr 流式 + 反压 ----");

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    n_blk_v = vec_mem[4][31:0];
    $display("  n_blk = %0d", n_blk_v);

    // 组装 beat 序列：每块 2 拍，低 64 位先发
    for (i = 0; i < n_blk_v && i < MAX_BLK; i = i + 1) begin
      src_beats[2*i]     = vec_mem[5 + i][63:0];
      src_beats[2*i + 1] = vec_mem[5 + i][127:64];
    end
    n_beats = 2 * ((n_blk_v < MAX_BLK) ? n_blk_v : MAX_BLK);

    // 装载 key / nonce / ctr
    s_key   = {vec_mem[0], vec_mem[1]};
    s_nonce = vec_mem[2][95:0];
    s_ctr0  = vec_mem[3][31:0];

    @(negedge clk); s_key_load = 1'b1; s_ctr_load = 1'b1;
    @(negedge clk); s_key_load = 1'b0; s_ctr_load = 1'b0;

    i = 0;
    while (!s_key_ready && i < 200) begin
      @(posedge clk); i = i + 1;
    end
    if (!s_key_ready) begin
      $display("  !! s_key_ready 超时");
      nfail = nfail + 1;
    end

    src_run = 1'b1;                      // 唯一启动方式（src_idx 由 always 块独占）
    $display("  激励启动: n_beats=%0d", n_beats);

    // 等所有 beat 发完 + 流水线排空
    i = 0;
    while ((out_n < n_beats) && i < 200000) begin
      @(posedge clk); i = i + 1;
    end
    src_run = 1'b0;
    repeat (20) @(posedge clk);

    $display("  发完 %0d 拍，等待 %0d 拍；收到 %0d 拍；st_blk_cnt=%0d",
             n_beats, i, out_n, s_blk_cnt);
    $display("  诊断: src_idx=%0d  s_tvalid=%b  m_tvalid=%b",
             src_idx, s_tvalid, m_tvalid);

    if (i >= 200000) begin
      $display("  !! 超时：流未排空（src_idx=%0d out_n=%0d）", src_idx, out_n);
      nfail = nfail + 1;
    end

    // 逐块比对
    for (blk = 0; blk < n_blk_v && blk < MAX_BLK; blk = blk + 1) begin
      exp_blk = vec_mem[5 + n_blk_v + blk];
      b0 = out_beats[2*blk];
      b1 = out_beats[2*blk + 1];
      got_beats = {b1, b0};
      if (got_beats === exp_blk) begin
        npass = npass + 1;
      end else begin
        nfail = nfail + 1;
        if (nfail <= 5)
          $display("  blk%0d BAD  got %032h want %032h", blk, got_beats, exp_blk);
      end
    end

    if (nfail == 0)
      $display("  全部 %0d 块密文 bit-exact", n_blk_v);

    // 检查 tlast
    if (out_n > 0) begin
      if (out_last_idx == n_beats - 1)
        $display("  tlast 位置正确（第 %0d 拍）", out_last_idx);
      else begin
        $display("  !! tlast 位置错误: 在第 %0d 拍，期望第 %0d 拍", out_last_idx, n_beats - 1);
        nfail = nfail + 1;
      end
    end

    // ---------------------------------------------------------------
    // 汇总
    // ---------------------------------------------------------------
    $display("");
    $display("================================================================");
    if (nfail == 0 && npass > 0)
      $display("=== PASS ===   %0d 项通过，0 项失败", npass);
    else
      $display("=== FAIL ===   %0d 项通过，%0d 项失败", npass, nfail);
    $display("================================================================");
    $finish;
  end

endmodule

`default_nettype wire