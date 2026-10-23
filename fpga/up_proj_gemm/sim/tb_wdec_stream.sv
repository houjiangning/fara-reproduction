`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_wdec_stream —— wdec_stream 自检：X/b 明文直通 + W 段 AES-CTR 解密 + 排空
//
// 向量由 tools/gen_wdec_vectors.py 生成（Python + gen_aes_vectors 为唯一可信源）：
//     wdec_in.mem  ：输入 beat（[X|b|W 密文]）
//     wdec_exp.mem ：期望输出 beat（[X|b|W 明文]）
//     wdec_cfg.mem ：key(64hex) nonce_rtl(24hex) ctr_init(8hex) plain_words(8hex)
//
// 覆盖点：
//   · 明文段（X|b）必须**逐位原样**通过（不被 AES 碰）
//   · 密文段（W）解密结果逐位等于明文
//   · tlast 只在最后一拍；输出 beat 总数 = 期望数
//   · 输出侧注入周期性反压（m_tready 间歇拉低），逼出排空逻辑的角落
//   · aes_active 排空：密文段最后一拍喂完后仍要等 AES 把剩余块吐完
//=============================================================================
module tb_wdec_stream;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;

  // ---- 配置 ----
  reg  [31:0] plain_words   = 32'd0;
  reg  [95:0] nonce         = 96'd0;
  reg  [31:0] ctr_init      = 32'd0;
  reg         ctr_load      = 1'b0;
  reg         key_load      = 1'b0;
  reg  [255:0] key_in       = 256'd0;
  wire        key_ready;

  // ---- 输入流 ----
  reg  [63:0] s_tdata  = 64'd0;
  reg         s_tvalid = 1'b0;
  wire        s_tready;
  reg         s_tlast  = 1'b0;

  // ---- 输出流 ----
  wire [63:0] m_tdata;
  wire        m_tvalid;
  reg         m_tready;
  wire        m_tlast;

  wire [31:0] st_blk_cnt;

  // ---- 输出反压：每 4 拍拉低 1 拍 ----
  reg [3:0] bp_cnt = 4'd0;
  always @(posedge clk) if (rst_n) bp_cnt <= bp_cnt + 4'd1;
  always @(*) m_tready = ~(bp_cnt[1:0] == 2'b10);

  wdec_stream #(
    .FIFO_DEPTH (32),
    .CTR_W      (32)
  ) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .plain_words (plain_words),
    .key_load    (key_load),
    .key_in      (key_in),
    .key_ready   (key_ready),
    .nonce       (nonce),
    .ctr_init    (ctr_init),
    .ctr_load    (ctr_load),
    .s_tdata     (s_tdata),
    .s_tvalid    (s_tvalid),
    .s_tready    (s_tready),
    .s_tlast     (s_tlast),
    .m_tdata     (m_tdata),
    .m_tvalid    (m_tvalid),
    .m_tready    (m_tready),
    .m_tlast     (m_tlast),
    .st_blk_cnt  (st_blk_cnt)
  );

  // ---- 向量存储 ----
  localparam MAXB = 4096;
  reg [63:0] in_mem  [0:MAXB-1];
  reg [63:0] exp_mem [0:MAXB-1];
  reg [63:0] got_mem [0:MAXB-1];

  integer n_in, n_exp, n_got, i, errors, guard;
  integer fdin, fdexp, fdcfg;
  reg [63:0] v;
  integer    rc;

  // ---- 输出侧收集 ----
  reg saw_last;
  always @(posedge clk) begin
    if (rst_n && m_tvalid && m_tready) begin
      if (n_got < MAXB) got_mem[n_got] <= m_tdata;
      n_got <= n_got + 1;
      if (m_tlast) saw_last <= 1'b1;
    end
  end

  initial begin
    n_in = 0; n_exp = 0; n_got = 0; saw_last = 1'b0; errors = 0;

    // ---- 读向量 ----
    fdin = $fopen("wdec_in.mem", "r");
    if (fdin == 0) begin $display("FATAL: 打不开 wdec_in.mem"); $display("=== FAIL ==="); $finish; end
    while (n_in < MAXB && $fscanf(fdin, "%h\n", v) == 1) begin
      in_mem[n_in] = v; n_in = n_in + 1;
    end
    $fclose(fdin);

    fdexp = $fopen("wdec_exp.mem", "r");
    if (fdexp == 0) begin $display("FATAL: 打不开 wdec_exp.mem"); $display("=== FAIL ==="); $finish; end
    while (n_exp < MAXB && $fscanf(fdexp, "%h\n", v) == 1) begin
      exp_mem[n_exp] = v; n_exp = n_exp + 1;
    end
    $fclose(fdexp);

    fdcfg = $fopen("wdec_cfg.mem", "r");
    if (fdcfg == 0) begin $display("FATAL: 打不开 wdec_cfg.mem"); $display("=== FAIL ==="); $finish; end
    rc = $fscanf(fdcfg, "%h %h %h %h\n", key_in, nonce, ctr_init, plain_words);
    $fclose(fdcfg);
    if (rc != 4) begin $display("FATAL: wdec_cfg.mem 解析失败 rc=%0d", rc); $display("=== FAIL ==="); $finish; end

    $display("向量：in=%0d exp=%0d  plain_words=%0d  ctr_init=%0d", n_in, n_exp, plain_words, ctr_init);

    // ---- reset ----
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 装密钥（约 60 拍后 key_ready）----
    @(negedge clk); key_load = 1'b1;
    @(negedge clk); key_load = 1'b0;
    guard = 0;
    while (!key_ready && guard < 500) begin @(posedge clk); guard = guard + 1; end
    if (!key_ready) begin $display("FAIL: key_ready 超时"); $display("=== FAIL ==="); $finish; end

    // ---- 装 counter ----
    @(negedge clk); ctr_load = 1'b1;
    @(negedge clk); ctr_load = 1'b0;

    // ---- 喂输入流 ----
    for (i = 0; i < n_in; i = i + 1) begin
      @(negedge clk);
      s_tdata  = in_mem[i];
      s_tvalid = 1'b1;
      s_tlast  = (i == n_in - 1);
      // 等到一拍上 valid&ready 同时成立（该拍完成握手）
      guard = 0;
      do begin
        @(posedge clk);
        guard = guard + 1;
      end while (!(s_tvalid && s_tready) && guard < 100000);
      if (guard >= 100000) begin
        $display("FAIL: 第 %0d 拍输入一直不被接受", i);
        errors = errors + 1;
        i = n_in;                      // 触发 for 结束条件，跳出
      end
    end
    @(negedge clk);
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;

    // ---- 等输出排空 ----
    guard = 0;
    while (n_got < n_exp && guard < 400000) begin
      @(posedge clk);
      guard = guard + 1;
    end
    // 再多给几拍，确认没有多余输出
    repeat (50) @(posedge clk);

    $display("");
    $display("输出 beat：收到 %0d，期望 %0d，tlast 见过=%0d", n_got, n_exp, saw_last);

    if (n_got != n_exp) begin
      $display("FAIL: beat 数不符"); errors = errors + 1;
    end

    for (i = 0; i < n_exp && i < n_got; i = i + 1) begin
      if (got_mem[i] !== exp_mem[i]) begin
        if (errors < 12)
          $display("  beat %0d 不符: got %016h exp %016h", i, got_mem[i], exp_mem[i]);
        errors = errors + 1;
      end
    end

    $display("");
    if (errors == 0 && n_got == n_exp && saw_last == 1'b1)
      $display("=== PASS ===");
    else
      $display("=== FAIL ===  errors=%0d", errors);

    $finish;
  end

  // 防跑飞
  initial begin
    #20_000_000;
    $display("FAIL: 全局超时");
    $display("=== FAIL ===");
    $finish;
  end

endmodule

`default_nettype wire
