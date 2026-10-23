`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_gemm_crypt —— P2 空跑验证：AES-256-CTR 解密块串在 GEMM 数据通路前面
//
// 目的（在还没改任何 BD 的情况下，提前把 P2 的风险降到最低）：
//   证明"把解密块插进 DMA→GEMM 之间，GEMM 的输出与既有 golden 逐 bit 一致"，
//   也就是**加密对计算透明**。
//
// 数据通路（严格镜像真实部署的流布局）：
//
//   [X 明文 | b 明文]  ────────────────────────────┐
//                                                 ├─→ gemm_up_proj_top ─→ 与 golden 比 Y
//   [W 密文] ──→ aes256_ctr(解密) ─────────────────┘
//
//   为什么 X/b 是明文：真实部署里 X 来自 PC 不加密，b 仅 12 KB 且 v1 不加密。
//   为什么只给 W 段喂 AES：counter 从 W 段起点 0 开始，与 tools/encrypt_vector_pack.py
//                          及方案 B 的契约完全一致。
//
// 两阶段驱动（阶段间不重叠，所以不需要并发 mux，只需一个二选一）：
//   phase 1：把 X|b 的明文 beat 直接驱动到 GEMM 的 s_axis
//   phase 2：把 W 的密文 beat 驱动到 aes256_ctr 的 s_axis，其 m_axis 接到 GEMM
//
// 向量来源：tools/encrypt_vector_pack.py 产出的 .mem（W 段已加密、期望输出不变）
//           +VEC=<path> 可覆盖，默认 crypt_vectors.mem
//
// AES 自身的正确性已由 tb_aes_ctr 覆盖（NIST KAT + 128 拍 bit-exact），
// 本 TB 只关心"端到端后 GEMM 结果是否不变"。
//
// 运行：tools/run_sim.ps1 -Only crypt
//=============================================================================
module tb_gemm_crypt;

  // ------------------------------------------------------------------
  // 被测配置（必须与向量头的编译期参数一致）
  // ------------------------------------------------------------------
  localparam integer M_TILE  = 16;
  localparam integer M_TOTAL = 64;
  localparam integer K_MAX   = 32;
  localparam integer N_MAX   = 4;
  localparam integer G       = 8;
  localparam integer ADD_LAT = 4;
  localparam integer MUL_LAT = 8;

  localparam integer MAX_IN_WORDS  = 8192;
  localparam integer MAX_BEATS     = MAX_IN_WORDS / 2;
  localparam integer MAX_OUT_WORDS = 8192;

  localparam integer PH_IDLE = 0, PH_PLAIN = 1, PH_CIPHER = 2, PH_DONE = 3;

  // ------------------------------------------------------------------
  // 时钟 / 复位
  // ------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  integer npass = 0;
  integer nfail = 0;

  // ------------------------------------------------------------------
  // 运行期参数 / 文件路径（必须在 initial 之前声明）
  // ------------------------------------------------------------------
  reg [1023:0] vec_path;
  reg [31:0]   ph;
  integer      fd, code, i, j;

  // ------------------------------------------------------------------
  // AXI4-Lite 主机（复用 tb_gemm_up_proj.sv 的任务写法）
  // ------------------------------------------------------------------
  reg  [7:0]  s_awaddr  = 8'd0;
  reg         s_awvalid = 1'b0;
  wire        s_awready;
  reg  [31:0] s_wdata   = 32'd0;
  reg  [3:0]  s_wstrb   = 4'h0;
  reg         s_wvalid  = 1'b0;
  wire        s_wready;
  wire [1:0]  s_bresp;
  wire        s_bvalid;
  reg         s_bready  = 1'b0;
  reg  [7:0]  s_araddr  = 8'd0;
  reg         s_arvalid = 1'b0;
  wire        s_arready;
  wire [31:0] s_rdata;
  wire [1:0]  s_rresp;
  wire        s_rvalid;
  reg         s_rready  = 1'b0;

  // ------------------------------------------------------------------
  // 阶段 / 源
  // ------------------------------------------------------------------
  wire        ph_cipher = (ph == PH_CIPHER);

  // ---- 明文源（X|b）：直接进 GEMM ----
  reg  [63:0] p_tdata = 64'd0;
  reg         p_tvalid = 1'b0;
  reg         p_tlast  = 1'b0;
  wire        p_tready;

  reg  [63:0] p_beats  [0:MAX_BEATS-1];
  integer     p_nbeats = 0;
  integer     p_idx    = 0;

  wire        p_consume = p_tvalid & p_tready;
  wire [31:0] p_nxt     = p_consume ? (p_idx + 1) : p_idx;
  wire        p_present = (ph == PH_PLAIN) && (p_nxt < p_nbeats);

  always @(posedge clk) begin
    if (!rst_n) begin
      p_idx    <= 0;
      p_tvalid <= 1'b0;
      p_tdata  <= 64'd0;
      p_tlast  <= 1'b0;
    end else begin
      // p_idx 只由本块驱动（initial 绝不直接写它）
      if (ph == PH_PLAIN) p_idx <= p_nxt;
      p_tvalid <= p_present;
      p_tdata  <= p_beats[p_nxt];
      p_tlast  <= (p_nxt == p_nbeats - 1);
    end
  end

  // ---- 密文源（W）：进 AES ----
  reg  [63:0] c_tdata = 64'd0;
  reg         c_tvalid = 1'b0;
  reg         c_tlast  = 1'b0;
  wire        c_tready;                 // = aes256_ctr.s_tready

  reg  [63:0] c_beats  [0:MAX_BEATS-1];
  integer     c_nbeats = 0;
  integer     c_idx    = 0;

  wire        c_consume = c_tvalid & c_tready;
  wire [31:0] c_nxt     = c_consume ? (c_idx + 1) : c_idx;
  wire        c_present = ph_cipher && (c_nxt < c_nbeats);

  always @(posedge clk) begin
    if (!rst_n) begin
      c_idx    <= 0;
      c_tvalid <= 1'b0;
      c_tdata  <= 64'd0;
      c_tlast  <= 1'b0;
    end else begin
      if (ph_cipher) c_idx <= c_nxt;
      c_tvalid <= c_present;
      c_tdata  <= c_beats[c_nxt];
      c_tlast  <= (c_nxt == c_nbeats - 1);
    end
  end

  // ------------------------------------------------------------------
  // AES-256-CTR 解密块
  // ------------------------------------------------------------------
  reg          a_key_load = 1'b0;
  reg  [255:0] a_key      = 256'd0;
  wire         a_key_ready;
  reg  [95:0]  a_nonce    = 96'd0;
  reg  [31:0]  a_ctr0     = 32'd0;
  reg          a_ctr_load = 1'b0;

  wire [63:0]  a_m_tdata;
  wire         a_m_tvalid;
  wire         a_m_tlast;
  wire         a_m_tready;           // 由下方的二选一连续赋值驱动，故必须是 wire
  wire [31:0]  a_blk_cnt;

  aes256_ctr #(
    .FIFO_DEPTH (32),
    .CTR_W      (32)
  ) u_aes (
    .clk        (clk),
    .rst_n      (rst_n),
    .key_load   (a_key_load),
    .key_in     (a_key),
    .key_ready  (a_key_ready),
    .nonce      (a_nonce),
    .ctr_init   (a_ctr0),
    .ctr_load   (a_ctr_load),
    .s_tdata    (c_tdata),
    .s_tvalid   (c_tvalid),
    .s_tready   (c_tready),
    .s_tlast    (c_tlast),
    .m_tdata    (a_m_tdata),
    .m_tvalid   (a_m_tvalid),
    .m_tready   (a_m_tready),
    .m_tlast    (a_m_tlast),
    .st_blk_cnt (a_blk_cnt)
  );

  // ------------------------------------------------------------------
  // GEMM 顶层（与被测上板的同一层）
  // ------------------------------------------------------------------
  reg  [63:0] g_tdata;
  reg         g_tvalid;
  reg         g_tlast;
  wire        g_tready;

  wire [63:0] g_m_tdata;
  wire        g_m_tvalid;
  wire        g_m_tready;
  wire        g_m_tlast;

  // 二选一：阶段 1 走明文源，阶段 2 走 AES 输出
  assign g_tdata  = ph_cipher ? a_m_tdata  : p_tdata;
  assign g_tvalid = ph_cipher ? a_m_tvalid : p_tvalid;
  assign g_tlast  = ph_cipher ? a_m_tlast  : p_tlast;

  assign p_tready   = ph_cipher ? 1'b0 : g_tready;
  assign a_m_tready = ph_cipher ? g_tready : 1'b0;

  gemm_up_proj_top #(
    .M_TILE  (M_TILE),
    .M_TOTAL (M_TOTAL),
    .K_MAX   (K_MAX),
    .N_MAX   (N_MAX),
    .G       (G),
    .ADD_LAT (ADD_LAT),
    .MUL_LAT (MUL_LAT),
    .C_S_AXI_DATA_WIDTH (32),
    .C_S_AXI_ADDR_WIDTH (8),
    .AXIS_TDATA_WIDTH   (64)
  ) u_dut (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (rst_n),
    .s_axi_awaddr  (s_awaddr),
    .s_axi_awprot  (3'd0),
    .s_axi_awvalid (s_awvalid),
    .s_axi_awready (s_awready),
    .s_axi_wdata   (s_wdata),
    .s_axi_wstrb   (s_wstrb),
    .s_axi_wvalid  (s_wvalid),
    .s_axi_wready  (s_wready),
    .s_axi_bresp   (s_bresp),
    .s_axi_bvalid  (s_bvalid),
    .s_axi_bready  (s_bready),
    .s_axi_araddr  (s_araddr),
    .s_axi_arprot  (3'd0),
    .s_axi_arvalid (s_arvalid),
    .s_axi_arready (s_arready),
    .s_axi_rdata   (s_rdata),
    .s_axi_rresp   (s_rresp),
    .s_axi_rvalid  (s_rvalid),
    .s_axi_rready  (s_rready),
    .s_axis_tdata  (g_tdata),
    .s_axis_tkeep  (8'hFF),
    .s_axis_tvalid (g_tvalid),
    .s_axis_tready (g_tready),
    .s_axis_tlast  (g_tlast),
    .m_axis_tdata  (g_m_tdata),
    .m_axis_tkeep  (),
    .m_axis_tvalid (g_m_tvalid),
    .m_axis_tready (g_m_tready),
    .m_axis_tlast  (g_m_tlast)
  );

  // GEMM 内部状态别名（仅仿真用层次引用）
  wire        c_done = u_dut.u_gemm.st_done;
  wire        c_err  = u_dut.u_gemm.st_err;
  wire [31:0] c_inw  = u_dut.u_gemm.st_in_words;
  wire [31:0] c_outw = u_dut.u_gemm.st_out_words;

  // ------------------------------------------------------------------
  // 向量存储
  // ------------------------------------------------------------------
  reg [31:0] in_words  [0:MAX_IN_WORDS-1];
  reg [31:0] exp_words [0:MAX_OUT_WORDS-1];
  reg [31:0] got_words [0:MAX_OUT_WORDS-1];

  integer    n_in, n_out;
  integer    h_k, h_n, h_mt, h_mtl, h_g, h_al, h_ml;
  integer    xw, bw, ww;                // X/b/W 三段字数
  integer    p_words, c_words;          // 明文段 / 密文段字数

  // ------------------------------------------------------------------
  // 输出收集
  // ------------------------------------------------------------------
  integer onum      = 0;
  reg     got_tlast = 1'b0;
  assign  g_m_tready = 1'b1;

  always @(posedge clk) begin
    if (rst_n && g_m_tvalid && g_m_tready) begin
      got_words[onum]   <= g_m_tdata[31:0];
      got_words[onum+1] <= g_m_tdata[63:32];
      onum <= onum + 2;
      if (g_m_tlast) got_tlast <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // AES 输出监视器：直接把 AES 吐出的 beat 收下来，
  // 与"明文向量里的 W 段"逐 beat 比对。
  // 作用：一旦端到端失败，立刻能区分是**解密错**还是 **GEMM 接线错**。
  // ------------------------------------------------------------------
  reg [1023:0] plain_path;
  reg [31:0]   plain_in   [0:MAX_IN_WORDS-1];
  reg [63:0]   w_plain_b  [0:MAX_BEATS-1];      // 明文 W 的期望 beat
  reg [63:0]   aes_out_b  [0:MAX_BEATS-1];      // AES 实际吐出的 beat
  integer      aes_out_n  = 0;
  integer      pf, pcode, pi;
  // 明文文件头部的独立接收变量（绝不与 h_*/n_in/n_out 复用）
  integer      ph_k, ph_n, ph_mt, ph_mtl, ph_g, ph_al, ph_ml, ph_in, ph_out;

  always @(posedge clk) begin
    if (rst_n && a_m_tvalid && a_m_tready && aes_out_n < MAX_BEATS) begin
      aes_out_b[aes_out_n] <= a_m_tdata;
      aes_out_n <= aes_out_n + 1;
    end
  end

  // ------------------------------------------------------------------
  // AXI4-Lite 任务
  // ------------------------------------------------------------------
  task automatic axi_write(input [7:0] a, input [31:0] d);
    begin
      @(posedge clk);
      s_awaddr  <= a;
      s_awvalid <= 1'b1;
      s_wdata   <= d;
      s_wstrb   <= 4'hF;
      s_wvalid  <= 1'b1;
      s_bready  <= 1'b1;
      do @(posedge clk);
      while (!(s_awready && s_awvalid && s_wready && s_wvalid));
      s_awvalid <= 1'b0;
      s_wvalid  <= 1'b0;
      do @(posedge clk);
      while (!s_bvalid);
      s_bready  <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // 主流程
  // ------------------------------------------------------------------
  integer tmo;
  reg [255:0] key;
  reg [95:0]  nonce;

  initial begin
    // ---- 载入向量 ----
    vec_path = "crypt_vectors.mem";
    code = $value$plusargs("VEC=%s", vec_path);
    fd = $fopen(vec_path, "r");
    if (fd == 0) begin
      $display("[FATAL] 打不开向量文件: %0s", vec_path);
      $finish;
    end

    code = $fscanf(fd, "%d %d %d %d %d %d %d %d %d",
                   h_k, h_n, h_mt, h_mtl, h_g, h_al, h_ml, n_in, n_out);
    if (code != 9) begin
      $display("[FATAL] 向量文件头解析失败 code=%0d", code);
      $finish;
    end
    $display("================================================================");
    $display("tb_gemm_crypt  P2 空跑：X/b 明文直通 + W 经 AES 解密 → GEMM");
    $display("  向量文件 : %0s", vec_path);
    $display("  向量头   : K=%0d N=%0d M_TOTAL=%0d M_TILE=%0d G=%0d ADD_LAT=%0d MUL_LAT=%0d N_IN=%0d N_OUT=%0d",
             h_k, h_n, h_mt, h_mtl, h_g, h_al, h_ml, n_in, n_out);
    $display("================================================================");

    if ((h_mt != M_TOTAL) || (h_mtl != M_TILE) ||
        (h_g != G)  || (h_al != ADD_LAT) || (h_ml != MUL_LAT)) begin
      $display("[FATAL] 向量头的编译期参数与 TB 不一致，请重新生成向量");
      $finish;
    end
    if ((h_k > K_MAX) || (h_k < 1) || (h_n > N_MAX) || (h_n < 1)) begin
      $display("[FATAL] K/N 超出 K_MAX/N_MAX 范围");
      $finish;
    end

    for (i = 0; i < n_in; i = i + 1) begin
      code = $fscanf(fd, "%h", in_words[i]);
      if (code != 1) begin
        $display("[FATAL] 输入字读短了 @%0d", i);
        $finish;
      end
    end
    for (i = 0; i < n_out; i = i + 1) begin
      code = $fscanf(fd, "%h", exp_words[i]);
      if (code != 1) begin
        $display("[FATAL] 期望输出字读短了 @%0d", i);
        $finish;
      end
    end
    $fclose(fd);

    // ---- 载入明文向量（用于给 AES 输出做独立比对）----
    plain_path = "golden_vectors.mem";
    code = $value$plusargs("PLAIN=%s", plain_path);
    pf = $fopen(plain_path, "r");
    if (pf == 0) begin
      $display("[FATAL] 打不开明文向量: %0s", plain_path);
      $finish;
    end
    pcode = $fscanf(pf, "%d %d %d %d %d %d %d %d %d",
                    ph_k, ph_n, ph_mt, ph_mtl, ph_g, ph_al, ph_ml, ph_in, ph_out);
    // 用**独立**变量接收明文文件的头部，绝不覆盖上面已解析好的 h_*/n_in/n_out ——
    // 实测踩坑：早期直接复用了 h_k/n_in 等，在共享 sim_work 里跑第二次时
    // 会被上一个分支留下的、K/N 不同的 golden_vectors.mem 污染，导致误判。
    if (ph_in != n_in) begin
      $display("[FATAL] 明文向量 N_IN=%0d 与密文向量 %0d 不一致", ph_in, n_in);
      $finish;
    end
    for (pi = 0; pi < MAX_IN_WORDS; pi = pi + 1) plain_in[pi] = 32'd0;
    for (pi = 0; pi < ph_in; pi = pi + 1)
      pcode = $fscanf(pf, "%h", plain_in[pi]);
    $fclose(pf);
    $display("  明文向量 : %0s  (K=%0d N=%0d N_IN=%0d)", plain_path, ph_k, ph_n, ph_in);

    // ---- 分段 ----
    xw = h_n * h_k;
    bw = M_TOTAL;
    ww = M_TOTAL * h_k;
    if (xw + bw + ww != n_in) begin
      $display("[FATAL] 分段不自洽: %0d + %0d + %0d != N_IN=%0d", xw, bw, ww, n_in);
      $finish;
    end
    if (((xw + bw) % 2) != 0) begin
      $display("[FATAL] X+b 段字数 %0d 非偶数，边界不在 beat 边界", xw + bw);
      $finish;
    end
    if ((ww % 4) != 0) begin
      $display("[FATAL] W 段字数 %0d 非 4 的倍数，无法整块加解密", ww);
      $finish;
    end

    p_words = xw + bw;
    c_words = ww;
    p_nbeats = p_words / 2;
    c_nbeats = c_words / 2;

    $display("  分段     : X=%0d b=%0d W=%0d 字   →  明文 %0d 字/%0d beat, 密文 %0d 字/%0d beat, W 块数 %0d",
             xw, bw, ww, p_words, p_nbeats, c_words, c_nbeats, ww / 4);

    if (p_nbeats > MAX_BEATS || c_nbeats > MAX_BEATS) begin
      $display("[FATAL] beat 数超出 MAX_BEATS=%0d", MAX_BEATS);
      $finish;
    end

    // 明文 beat（X|b，直通）
    for (i = 0; i < p_nbeats; i = i + 1)
      p_beats[i] = {in_words[2*i+1], in_words[2*i]};
    // 密文 beat（W，经 AES）
    for (i = 0; i < c_nbeats; i = i + 1)
      c_beats[i] = {in_words[p_words + 2*i + 1], in_words[p_words + 2*i]};

    // ---- 测试用固定 key/nonce（与 encrypt_vector_pack.py 默认值一致）----
    // AES-256 密钥：key_in[255:224] 是密钥字节 0..3，所以**直接按人读顺序**写
    //               （与 Python 的 int.from_bytes(key,'big') 一致）。
    // Nonce（96 bit）：契约是"nonce 字节 0 在最低位"（见 aes256_ctr.sv 文件头），
    //               所以要写成 **反转后的** 字面量。
    //               人读 nonce = a0a1a2a3a4a5a6a7a8a9aaab
    //               -> 字节0=a0 在最低位 -> 字面量 96'habaaa9a8a7a6a5a4a3a2a1a0
    //   实测踩坑：写成 96'ha0a1...ab 会让 12 个 nonce 字节整体反转，
    //             解密结果与 Python golden 完全不同（但 NIST KAT 仍能过，
    //             因为 KAT 的非正式向量是从 .mem 读入、已按小端编码）。
    key   = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
    nonce = 96'habaaa9a8a7a6a5a4a3a2a1a0;

    // ---- 复位 ----
    ph = PH_IDLE;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 配置 GEMM ----
    axi_write(8'h0C, h_k);        // K_COLS
    axi_write(8'h10, h_n);        // N_TOKENS
    axi_write(8'h30, 32'd0);      // FAR_CTRL=0（基线，不走 FaR）

    // ---- 装载 AES 密钥并等扩展完成 ----
    a_key = key;
    @(negedge clk); a_key_load = 1'b1;
    @(negedge clk); a_key_load = 1'b0;
    a_nonce = nonce;
    tmo = 0;
    while (!a_key_ready && tmo < 200) begin @(posedge clk); tmo = tmo + 1; end
    if (!a_key_ready) begin
      $display("  !! AES key_ready 超时");
      nfail = nfail + 1;
    end else begin
      $display("  AES key_ready 在 %0d 拍后拉高", tmo);
    end

    // ---- 启动 GEMM ----
    axi_write(8'h00, 32'h1);      // CTRL.start=1

    // ================= phase 1：X|b 明文直通 =================
    ph = PH_PLAIN;
    $display("");
    $display("---- phase 1：X|b 明文直通（%0d beat）----", p_nbeats);
    tmo = 0;
    while ((p_idx < p_nbeats) && tmo < 200000) begin @(posedge clk); tmo = tmo + 1; end
    $display("  完成：发 %0d beat，用 %0d 拍", p_nbeats, tmo);
    if (tmo >= 200000) begin
      $display("  !! phase 1 超时（p_idx=%0d）", p_idx);
      nfail = nfail + 1;
    end

    // ================= phase 2：W 密文经 AES 解密 =================
    // counter 从 W 段起点重新计 0
    @(negedge clk); a_ctr_load = 1'b1;
    @(negedge clk); a_ctr_load = 1'b0;

    ph = PH_CIPHER;
    $display("");
    $display("---- phase 2：W 密文 → AES 解密 → GEMM（%0d beat）----", c_nbeats);
    tmo = 0;
    while (!c_done && tmo < 500000) begin @(posedge clk); tmo = tmo + 1; end
    $display("  完成：用 %0d 拍；串上密文 beat=%0d，AES 出块=%0d（期望 %0d）",
             tmo, c_idx, a_blk_cnt, ww / 4);

    if (!c_done) begin
      $display("  !! GEMM 未 done（超时），err=%0d", c_err);
      nfail = nfail + 1;
    end
    repeat (10) @(posedge clk);
    ph = PH_DONE;
    axi_write(8'h00, 32'd0);      // CTRL.start=0 清 done

    // ================= 结果核对 =================
    $display("");
    $display("---- 核对 ----");
    $display("  GEMM: in_words=%0d (期望 %0d)  out_words=%0d (期望 %0d)  err=%0d",
             c_inw, (xw + bw + ww), c_outw, n_out, c_err);
    $display("  AES : 输出块数=%0d (期望 %0d)", a_blk_cnt, ww / 4);

    if (c_inw != (xw + bw + ww)) begin
      $display("  !! in_words 不符");
      nfail = nfail + 1;
    end
    if ((a_blk_cnt * 4) != ww) begin
      $display("  !! AES 块数不符");
      nfail = nfail + 1;
    end

    // ---- 独立比对：AES 输出 beat 是否等于明文 W ----
    // 这一步能把"解密错"和"GEMM 接线错"彻底分开
    $display("");
    $display("---- AES 解密正确性（与明文 W 逐 beat 比对）----");
    for (i = 0; i < c_nbeats; i = i + 1)
      w_plain_b[i] = {plain_in[p_words + 2*i + 1], plain_in[p_words + 2*i]};

    if (aes_out_n != c_nbeats) begin
      $display("  !! AES 输出 beat 数 %0d != 期望 %0d", aes_out_n, c_nbeats);
      nfail = nfail + 1;
    end
    j = 0;
    for (i = 0; i < c_nbeats; i = i + 1) begin
      if (aes_out_b[i] === w_plain_b[i]) j = j + 1;
      else if ((i < 4) || (i > c_nbeats - 3))
        $display("  W beat[%0d] BAD  got=%016x want=%016x", i, aes_out_b[i], w_plain_b[i]);
    end
    $display("  匹配 %0d / %0d beat", j, c_nbeats);
    if (j == c_nbeats) begin
      $display("  → AES 解密逐 beat 正确，问题若存在只可能在下游");
      npass = npass + 1;
    end else begin
      nfail = nfail + 1;
    end

    if (c_done && !c_err && (onum == n_out) && got_tlast) begin
      // 逐字比对
      for (j = 0; j < n_out; j = j + 1) begin
        if (got_words[j] === exp_words[j]) begin
          npass = npass + 1;
        end else begin
          nfail = nfail + 1;
          if (nfail <= 8)
            $display("  word[%0d] BAD  got=%08x want=%08x", j, got_words[j], exp_words[j]);
        end
      end
      if (nfail == 0)
        $display("  GEMM 输出 %0d 字全部 bit-exact（与明文向量跑出的 golden 完全一致）",
                 n_out);
    end else begin
      $display("  !! 输出流异常：done=%0d err=%0d onum=%0d/%0d tlast=%0d",
               c_done, c_err, onum, n_out, got_tlast);
      nfail = nfail + 1;
    end

    // ================= 汇总 =================
    $display("");
    $display("================================================================");
    if (nfail == 0 && npass > 0)
      $display("=== PASS ===  加密透明：%0d 项通过，0 项失败", npass);
    else
      $display("=== FAIL ===  %0d 项通过，%0d 项失败", npass, nfail);
    $display("================================================================");
    $finish;
  end

endmodule

`default_nettype wire