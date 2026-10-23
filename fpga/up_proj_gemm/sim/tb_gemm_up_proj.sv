`timescale 1ns / 1ps
//=============================================================================
// tb_gemm_up_proj —— GEMM IP 自检 testbench（bit-exact）
//
// 做什么：
//   1) 通过 gemm_up_proj_axi_lite 走真实 AXI4-Lite 事务配置 K/N 并启动；
//   2) 按 64-bit beat（低字先）把 [X | b | W] 输入流喂进 gemm_up_proj_core；
//   3) 收输出 beat，拆成 fp32 字，与 Python golden 逐位比对（!==）；
//   4) 同时核对 AXI-Lite 状态寄存器（done/err/in_words/out_words/tile_idx）；
//   5) 可选：+FARMAP=<path> 载入 FaRMap，写 0x30~0x4C 寄存器并打开 far_en，
//      再核对 FAR_HITS（重路由实际改写元素数）与 FAR_PHASE（结束后回 0）。
//
// 依赖：编译集合必须包含 sim/fp32_ops_behav.sv（行为模型），**不能**同时包含
//       rtl/fp32_mul.sv / rtl/fp32_add.sv（同名模块会冲突）。
//
// 运行：tools/run_sim.ps1  （先跑 gen_golden_vectors.py，再 xvlog/xelab/xsim）
//       手工跑 FaR 用例：
//         xsim tb_sim -runall -testplusarg "VEC=far_vectors.mem" \
//                          -testplusarg "FARMAP=far_vectors.fmap"
//=============================================================================
module tb_gemm_up_proj;

  // ------------------------------------------------------------------
  // 被测配置（必须与 tools/gen_golden_vectors.py 的参数一致）
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

  // ------------------------------------------------------------------
  // 时钟 / 复位
  // ------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;      // 100 MHz

  // ------------------------------------------------------------------
  // AXI4-Lite 主机
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
  // DUT = AXI 顶层封装（上板的同一层），内部例化 axi_lite + core
  // ------------------------------------------------------------------
  reg  [63:0] in_tdata;
  reg         in_tvalid, in_tlast;
  wire        in_tready;
  wire [63:0] out_tdata;
  wire        out_tvalid, out_tready, out_tlast;

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
    .s_axis_tdata  (in_tdata),
    .s_axis_tkeep  (8'hFF),
    .s_axis_tvalid (in_tvalid),
    .s_axis_tready (in_tready),
    .s_axis_tlast  (in_tlast),
    .m_axis_tdata  (out_tdata),
    .m_axis_tkeep  (),
    .m_axis_tvalid (out_tvalid),
    .m_axis_tready (out_tready),
    .m_axis_tlast  (out_tlast)
  );

  // 顶层内部状态别名（仅仿真用层次引用；不进综合）
  wire        c_busy  = u_dut.u_gemm.st_busy;
  wire        c_done  = u_dut.u_gemm.st_done;
  wire        c_err   = u_dut.u_gemm.st_err;
  wire [3:0]  c_state = u_dut.u_gemm.st_state;
  wire [31:0] c_inw   = u_dut.u_gemm.st_in_words;
  wire [31:0] c_outw  = u_dut.u_gemm.st_out_words;
  wire [31:0] c_tile  = u_dut.u_gemm.st_tile_idx;

  // ------------------------------------------------------------------
  // 向量存储
  // ------------------------------------------------------------------
  reg [31:0] in_words  [0:MAX_IN_WORDS-1];
  reg [63:0] beats     [0:MAX_BEATS-1];
  reg [31:0] exp_words [0:MAX_OUT_WORDS-1];
  reg [31:0] got_words [0:MAX_OUT_WORDS-1];

  integer    n_in, n_out, n_beats;
  integer    h_k, h_n, h_mt, h_mtl, h_g, h_al, h_ml;
  integer    fd, code, i;

  // ------------------------------------------------------------------
  // 输入流驱动（同步、按 tready 推进）
  // ------------------------------------------------------------------
  reg        drive_en = 1'b0;
  integer    didx     = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      in_tvalid <= 1'b0;
      in_tdata  <= 64'd0;
      in_tlast  <= 1'b0;
      didx      <= 0;
    end else if (in_tvalid && in_tready) begin
      if (didx == n_beats - 1) begin
        in_tvalid <= 1'b0;
        in_tlast  <= 1'b0;
      end else begin
        didx      <= didx + 1;
        in_tdata  <= beats[didx+1];
        in_tlast  <= (didx + 1 == n_beats - 1);
        in_tvalid <= 1'b1;
      end
    end else if (drive_en && !in_tvalid && (didx == 0)) begin
      in_tdata  <= beats[0];
      in_tlast  <= (n_beats == 1);
      in_tvalid <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // 输出流收集（tready 恒 1）
  // ------------------------------------------------------------------
  integer onum     = 0;
  reg     got_tlast = 1'b0;
  assign  out_tready = 1'b1;

  always @(posedge clk) begin
    if (rst_n && out_tvalid && out_tready) begin
      got_words[onum]   <= out_tdata[31:0];
      got_words[onum+1] <= out_tdata[63:32];
      onum <= onum + 2;
      if (out_tlast) got_tlast <= 1'b1;
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

  task automatic axi_read(input [7:0] a, output [31:0] d);
    begin
      @(posedge clk);
      s_araddr  <= a;
      s_arvalid <= 1'b1;
      s_rready  <= 1'b1;
      do @(posedge clk);
      while (!(s_arready && s_arvalid));
      s_arvalid <= 1'b0;
      do @(posedge clk);
      while (!s_rvalid);
      d = s_rdata;
      s_rready  <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // 主流程
  // ------------------------------------------------------------------
  reg [1023:0] vec_path;
  reg [31:0]   rd;
  integer      errors;
  integer      tmo;

  // ---- FaRMap ----
  localparam integer VERSION_EXPECT = 32'h0002_0000;   // FaR 版
  reg [1023:0] fmap_path;
  integer      n_far, far_on, far_hits_expect;
  reg [31:0]   fa   [0:15];     // A（敏感输入通道）
  reg [31:0]   finv [0:15];     // fp32 1/div 位模式
  reg [31:0]   fnd  [0:15];     // dead 条数
  reg [31:0]   fd0  [0:15];     // dead #0
  reg [31:0]   fd1  [0:15];     // dead #1
  integer      fd2, code2, j;

  initial begin
    errors = 0;

    // ---- 载入向量 ----
    // 默认在当前工作目录找 golden_vectors.mem（run_sim.ps1 会先拷进来）；
    // 也可用 +VEC=<path> 覆盖。
    vec_path = "golden_vectors.mem";
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
    $display("[TB] 向量头: K=%0d N=%0d M_TOTAL=%0d M_TILE=%0d G=%0d ADD_LAT=%0d MUL_LAT=%0d N_IN=%0d N_OUT=%0d",
             h_k, h_n, h_mt, h_mtl, h_g, h_al, h_ml, n_in, n_out);

    // K/N 是运行期配置，可随向量变化；M_TOTAL/M_TILE/G/ADD_LAT/MUL_LAT 是
    // 编译期参数，必须与向量头一致。
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

    n_beats = n_in / 2;
    for (i = 0; i < n_beats; i = i + 1)
      beats[i] = {in_words[2*i+1], in_words[2*i]};

    // ---- 可选：载入 FaRMap（+FARMAP=<path>）----
    // 不传该 plusarg 就是基线用例：FAR_CTRL 保持 0，far_reroute 一拍直通。
    far_on    = 0;
    n_far     = 0;
    far_hits_expect = 0;
    fmap_path = "";
    code2 = $value$plusargs("FARMAP=%s", fmap_path);
    if (code2 != 0) begin
      fd2 = $fopen(fmap_path, "r");
      if (fd2 == 0) begin
        $display("[FATAL] 打不开 FaRMap: %0s", fmap_path);
        $finish;
      end
      code2 = $fscanf(fd2, "%d", n_far);
      if (code2 != 1 || n_far < 0 || n_far > 16) begin
        $display("[FATAL] FaRMap 头解析失败 (n_far=%0d, code=%0d)", n_far, code2);
        $finish;
      end
      for (j = 0; j < n_far; j = j + 1) begin
        code2 = $fscanf(fd2, "%h %h %h %h %h",
                        fa[j], finv[j], fnd[j], fd0[j], fd1[j]);
        if (code2 != 5) begin
          $display("[FATAL] FaRMap 第 %0d 条解析失败 (code=%0d)", j, code2);
          $finish;
        end
      end
      $fclose(fd2);
      far_on = 1;
      $display("[TB] FaRMap 载入 %0d 条 <- %0s", n_far, fmap_path);
      for (j = 0; j < n_far; j = j + 1)
        far_hits_expect = far_hits_expect + h_n * (1 + fnd[j]);
      $display("[TB] 期望 FAR_HITS = %0d（= N * Σ(1+nd)）", far_hits_expect);
    end

    // ---- 复位 ----
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // ---- 配置 ----
    axi_write(8'h0C, h_k);            // K_COLS
    axi_write(8'h10, h_n);            // N_TOKENS
    axi_write(8'h14, 32'h0000_0000);  // LAYER_ID = 0

    axi_read(8'h0C, rd);
    if (rd !== h_k[31:0]) begin
      $display("[FAIL] K_COLS 回读 %0d != %0d", rd, h_k);
      errors = errors + 1;
    end
    axi_read(8'h10, rd);
    if (rd !== h_n[31:0]) begin
      $display("[FAIL] N_TOKENS 回读 %0d != %0d", rd, h_n);
      errors = errors + 1;
    end
    axi_read(8'h08, rd);
    if (rd !== M_TILE[31:0]) begin
      $display("[FAIL] M_ROWS 回读 %0d != %0d", rd, M_TILE);
      errors = errors + 1;
    end
    axi_read(8'h18, rd);
    if (rd !== VERSION_EXPECT) begin
      $display("[FAIL] VERSION 回读 %08x != %08x（FaR 版）", rd, VERSION_EXPECT);
      errors = errors + 1;
    end

    // ---- FaRMap 编程（必须在 CTRL.start 之前写完）----
    if (far_on) begin
      // 配置期间先关 far_en，避免半配置状态被 S_REWIRE 采到
      axi_write(8'h30, 32'h0000_0000);   // FAR_CTRL = 0
      axi_write(8'h34, n_far);           // FAR_NENT
      for (j = 0; j < n_far; j = j + 1) begin
        axi_write(8'h38, j);                            // FAR_IDX
        axi_write(8'h3C, {16'd0, fa[j][15:0]});         // FAR_A
        axi_write(8'h40, finv[j]);                      // FAR_INV
        axi_write(8'h44, {30'd0, fnd[j][1:0]});         // FAR_ND
        axi_write(8'h48, {16'd0, fd0[j][15:0]});        // FAR_D0
        axi_write(8'h4C, {16'd0, fd1[j][15:0]});        // FAR_D1
      end

      // 间接寻址通路抽查：回读第 0 条
      axi_write(8'h38, 32'd0);
      axi_read (8'h3C, rd);
      if (rd !== {16'd0, fa[0][15:0]}) begin
        $display("[FAIL] FAR_A[0] 回读 %08x != %08x", rd, {16'd0, fa[0][15:0]});
        errors = errors + 1;
      end
      axi_read (8'h40, rd);
      if (rd !== finv[0]) begin
        $display("[FAIL] FAR_INV[0] 回读 %08x != %08x", rd, finv[0]);
        errors = errors + 1;
      end
      axi_read (8'h34, rd);
      if (rd !== n_far) begin
        $display("[FAIL] FAR_NENT 回读 %0d != %0d", rd, n_far);
        errors = errors + 1;
      end

      axi_write(8'h30, 32'h0000_0001);   // FAR_CTRL.far_en = 1
      axi_read (8'h30, rd);
      if (rd[0] !== 1'b1) begin
        $display("[FAIL] FAR_CTRL.far_en 未置起 (rd=%08x)", rd);
        errors = errors + 1;
      end
    end

    // ---- 启动 + 灌流 ----
    drive_en = 1'b1;
    axi_write(8'h00, 32'h0000_0001);  // CTRL.start = 1

    // ---- 等 done ----
    tmo = 0;
    while (!c_done && (tmo < 2000000)) begin
      @(posedge clk);
      tmo = tmo + 1;
    end
    if (!c_done) begin
      $display("[FAIL] 超时未 done（state=%0d tile=%0d in=%0d）",
               c_state, c_tile, c_inw);
      errors = errors + 1;
    end

    axi_read(8'h04, rd);              // STATUS
    $display("[TB] STATUS = %08x (busy=%b done=%b err=%b state=%0d)",
             rd, rd[0], rd[1], rd[2], rd[7:4]);
    if (rd[1] !== 1'b1) begin $display("[FAIL] STATUS.done 未置起"); errors = errors + 1; end
    if (rd[2] !== 1'b0) begin $display("[FAIL] STATUS.err 置起");    errors = errors + 1; end

    axi_read(8'h20, rd);
    if (rd !== n_in[31:0]) begin
      $display("[FAIL] IN_WORDS 回读 %0d != %0d", rd, n_in);
      errors = errors + 1;
    end
    axi_read(8'h24, rd);
    if (rd !== n_out[31:0]) begin
      $display("[FAIL] OUT_WORDS 回读 %0d != %0d", rd, n_out);
      errors = errors + 1;
    end
    axi_read(8'h28, rd);
    if (rd !== (M_TOTAL / M_TILE - 1)) begin
      $display("[FAIL] TILE_IDX 回读 %0d != %0d", rd, M_TOTAL / M_TILE - 1);
      errors = errors + 1;
    end

    // ---- FaR 诊断寄存器 ----
    if (far_on) begin
      axi_read(8'h50, rd);              // FAR_HITS
      if (rd !== far_hits_expect) begin
        $display("[FAIL] FAR_HITS 回读 %0d != %0d（重路由没跑完/条目数不符）",
                 rd, far_hits_expect);
        errors = errors + 1;
      end else begin
        $display("[TB] FAR_HITS = %0d（期望 %0d）OK", rd, far_hits_expect);
      end
      axi_read(8'h54, rd);              // FAR_PHASE
      if (rd !== 32'd0) begin
        $display("[FAIL] FAR_PHASE 事务结束后 = %0d（应回 0 = R_IDLE）", rd);
        errors = errors + 1;
      end else begin
        $display("[TB] FAR_PHASE = 0 (R_IDLE) OK");
      end
    end

    // 清 done
    axi_write(8'h00, 32'h0000_0000);

    // ---- 比对 ----
    repeat (4) @(posedge clk);
    if (onum !== n_out) begin
      $display("[FAIL] 收到输出 %0d 字，期望 %0d 字", onum, n_out);
      errors = errors + 1;
    end
    if (got_tlast !== 1'b1) begin
      $display("[FAIL] 输出流未见到 tlast");
      errors = errors + 1;
    end

    begin
      integer nbad;
      real    rg, rw;
      nbad = 0;
      for (i = 0; i < n_out; i = i + 1) begin
        if (got_words[i] !== exp_words[i]) begin
          if (nbad < 16) begin
            rg = $bitstoshortreal(got_words[i]);
            rw = $bitstoshortreal(exp_words[i]);
            $display("  [%0d] got %08x (%e)  want %08x (%e)",
                     i, got_words[i], rg, exp_words[i], rw);
          end
          nbad = nbad + 1;
        end
      end
      if (nbad != 0) begin
        $display("[FAIL] 输出逐位比对：%0d/%0d 个字不一致", nbad, n_out);
        errors = errors + 1;
      end
    end

    if (errors == 0)
      $display("=== PASS ===  bit-exact，%0d 输出字全部一致，%0d 输入字全部消费%s",
               n_out, n_in, far_on ? "（FaR 重路由已启用）" : "（基线直通）");
    else
      $display("=== FAIL ===  共 %0d 项错误", errors);

    $finish;
  end

  // 全局看门狗
  initial begin
    #20_000_000;
    $display("[FATAL] 全局看门狗超时");
    $finish;
  end

endmodule
