`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_bpuf —— Butterfly PUF 自检 testbench（P1）
//
// 测什么（注意边界）：本 TB 验证的是**采样时序状态机、投票逻辑、AXI-Lite
// 寄存器、以及 BD shim 的端口连线**。它**不能**验证真实 PUF 的物理统计特性
// （仿真里没有制造偏差），真实翻转率必须上板实测。
//
// DUT：直接例化 rtl/puf_bd.v —— 也就是将来要放进 Block Design 的同一层，
//      这样连端口名写错都能在仿真阶段抓到。
//
// 依赖 sim/bpuf_cell_behav.sv（行为模型）；
// **不编译** rtl/bpuf_cell.sv（同名模块会冲突）。
//
// 测试项：
//   T1 只读常量：VERSION / NBITS / NWORDS
//   T2 未映射偏移读回 0xDEADBEEF
//   T3 读写回环：N_SAMP / T_FORCE / T_SETTLE / IDX
//   T4 参数校验：偶数 M 必须被拒（err=1）
//   T5 完整采样：done/NSAMP_DONE/STABLE_CNT 正确
//   T6 UNAN 掩码精确匹配"每轮翻转"的那些位（IDX % 17 == 0）
//   T7 所有稳定位的 DATA 必须等于 PBS 模型给出的基底值
//   T8 IDX 间接寻址真的在切换字
//   T9 第二次采样可重复启动，且稳定位结果一致
//   T10 AXI-Lite 读通道 R 数据锁存：背靠背读不同地址不得改写前一笔读数据
//
// 运行：tools/run_sim.ps1 -Only puf
//=============================================================================
module tb_bpuf;

  localparam integer N_BITS = 128;
  localparam integer CNT_W  = 5;
  localparam integer N_WORD = N_BITS / 32;

  localparam [31:0] VERSION_EXPECT = 32'h0001_0000;
  localparam integer UNSTABLE_STRIDE = 17;      // 与 bpuf_cell_behav.sv 一致
  localparam integer M_EXPECT        = 9;       // 本次用的采样次数（奇数）

  // ------------------------------------------------------------------
  // 时钟 / 复位
  // ------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  integer npass = 0;
  integer nfail = 0;

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
  // DUT = 将来进 BD 的同一层
  // ------------------------------------------------------------------
  puf_bd #(
    .N_BITS (N_BITS),
    .CNT_W  (CNT_W)
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
    .s_axi_rready  (s_rready)
  );

  // ------------------------------------------------------------------
  // 寄存器偏移（与 rtl/puf_axi_lite.sv 一致）
  // ------------------------------------------------------------------
  localparam [7:0] R_CTRL       = 8'h00;
  localparam [7:0] R_STATUS     = 8'h04;
  localparam [7:0] R_NBITS      = 8'h08;
  localparam [7:0] R_NWORDS     = 8'h0C;
  localparam [7:0] R_N_SAMP     = 8'h10;
  localparam [7:0] R_T_FORCE    = 8'h14;
  localparam [7:0] R_T_SETTLE   = 8'h18;
  localparam [7:0] R_VERSION    = 8'h1C;
  localparam [7:0] R_NSAMP_DONE = 8'h20;
  localparam [7:0] R_STABLE_CNT = 8'h24;
  localparam [7:0] R_IDX        = 8'h28;
  localparam [7:0] R_DATA       = 8'h2C;
  localparam [7:0] R_UNAN       = 8'h30;

  // ------------------------------------------------------------------
  // AXI 任务
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
  // 与 bpuf_cell_behav.sv 相同的基底函数（用于独立算出期望值）
  // ------------------------------------------------------------------
  function automatic logic base_of(input integer idx);
    return ((idx * 7 + 3 + (idx >> 2)) & 1) != 0;
  endfunction

  // ------------------------------------------------------------------
  // 主流程
  // ------------------------------------------------------------------
  reg [31:0] rd, st;
  reg [31:0] dword [0:N_WORD-1];
  reg [31:0] uword [0:N_WORD-1];
  reg [31:0] exp_unan [0:N_WORD-1];

  integer i, w, bit_i, tmo;
  reg [31:0] exp_stable;
  reg [31:0] pop;

  // 期望的 UNAN 掩码：IDX % 17 == 0 的位
  task automatic build_expected_unan;
    begin
      for (w = 0; w < N_WORD; w = w + 1) exp_unan[w] = 32'd0;
      for (bit_i = 0; bit_i < N_BITS; bit_i = bit_i + 1)
        if ((bit_i % UNSTABLE_STRIDE) == 0)
          exp_unan[bit_i / 32] = exp_unan[bit_i / 32] | (32'd1 << (bit_i % 32));

      // exp_stable = N_BITS - popcount(exp_unan)（直白算法，避免位运算写错）
      exp_stable = N_BITS;
      for (w = 0; w < N_WORD; w = w + 1)
        for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1)
          if (exp_unan[w][bit_i]) exp_stable = exp_stable - 32'd1;
    end
  endtask

  initial begin
    $display("================================================================");
    $display("tb_bpuf  Butterfly PUF 自检（FSM / 表决 / 寄存器 / BD shim）");
    $display("  N_BITS=%0d  CNT_W=%0d  N_WORD=%0d  M=%0d", N_BITS, CNT_W, N_WORD, M_EXPECT);
    $display("  注意：本 TB 不含制造偏差模型，验证的是逻辑而非物理统计特性");
    $display("================================================================");

    // ---- 复位 ----
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    //=================================================================
    // T1 只读常量
    //=================================================================
    $display("");
    $display("---- T1 只读常量 ----");
    axi_read(R_VERSION, rd);
    if (rd === VERSION_EXPECT) begin
      $display("  VERSION  = 0x%08x  OK", rd); npass = npass + 1;
    end else begin
      $display("  VERSION  = 0x%08x  BAD (want 0x%08x)", rd, VERSION_EXPECT); nfail = nfail + 1;
    end
    axi_read(R_NBITS, rd);
    if (rd === N_BITS) begin
      $display("  NBITS    = %0d  OK", rd); npass = npass + 1;
    end else begin
      $display("  NBITS    = %0d  BAD (want %0d)", rd, N_BITS); nfail = nfail + 1;
    end
    axi_read(R_NWORDS, rd);
    if (rd === N_WORD) begin
      $display("  NWORDS   = %0d  OK", rd); npass = npass + 1;
    end else begin
      $display("  NWORDS   = %0d  BAD (want %0d)", rd, N_WORD); nfail = nfail + 1;
    end

    //=================================================================
    // T2 未映射偏移
    //=================================================================
    $display("");
    $display("---- T2 未映射偏移应读回 0xDEADBEEF ----");
    axi_read(8'h60, rd);
    if (rd === 32'hDEAD_BEEF) begin
      $display("  0x60 -> 0x%08x  OK", rd); npass = npass + 1;
    end else begin
      $display("  0x60 -> 0x%08x  BAD", rd); nfail = nfail + 1;
    end

    //=================================================================
    // T3 读写回环
    //=================================================================
    $display("");
    $display("---- T3 读写回环 ----");
    axi_write(R_N_SAMP,   32'd9);
    axi_read (R_N_SAMP,   rd);
    if (rd === 32'd9) begin $display("  N_SAMP   = %0d  OK", rd); npass = npass + 1;
    end else begin $display("  N_SAMP   = %0d  BAD", rd); nfail = nfail + 1; end

    axi_write(R_T_FORCE,  32'd8);
    axi_read (R_T_FORCE,  rd);
    if (rd === 32'd8) begin $display("  T_FORCE  = %0d  OK", rd); npass = npass + 1;
    end else begin $display("  T_FORCE  = %0d  BAD", rd); nfail = nfail + 1; end

    axi_write(R_T_SETTLE, 32'd16);
    axi_read (R_T_SETTLE, rd);
    if (rd === 32'd16) begin $display("  T_SETTLE = %0d  OK", rd); npass = npass + 1;
    end else begin $display("  T_SETTLE = %0d  BAD", rd); nfail = nfail + 1; end

    //=================================================================
    // T4 参数校验：偶数 M 必须被拒
    //=================================================================
    $display("");
    $display("---- T4 偶数 M 必须被拒 ----");
    axi_write(R_N_SAMP, 32'd8);            // 偶数
    axi_write(R_CTRL,   32'h1);            // start=1
    tmo = 0;
    while (tmo < 200) begin @(posedge clk); tmo = tmo + 1;
      if (u_dut.u_ctrl.err) break; end
    axi_read(R_STATUS, st);
    if ((st >> 2) & 1) begin
      $display("  偶数 M 被拒，STATUS.err=1  OK"); npass = npass + 1;
    end else begin
      $display("  偶数 M 未被拒  BAD (STATUS=0x%08x)", st); nfail = nfail + 1;
    end
    axi_write(R_CTRL, 32'h2);              // soft_rst 清 err
    repeat (4) @(posedge clk);

    //=================================================================
    // T5~T8 完整采样
    //=================================================================
    $display("");
    $display("---- T5 完整采样（M=%0d, T_FORCE=8, T_SETTLE=16）----", M_EXPECT);
    axi_write(R_N_SAMP,   M_EXPECT);
    axi_write(R_T_FORCE,  32'd8);
    axi_write(R_T_SETTLE, 32'd16);
    axi_write(R_CTRL,     32'h1);          // start=1

    tmo = 0;
    while (!u_dut.u_ctrl.done && tmo < 20000) begin @(posedge clk); tmo = tmo + 1; end
    $display("  采样完成：用 %0d 拍", tmo);
    if (!u_dut.u_ctrl.done) begin
      $display("  !! done 超时（state=%0d err=%0d）", u_dut.u_ctrl.state, u_dut.u_ctrl.err);
      nfail = nfail + 1;
    end

    axi_read(R_STATUS, st);
    $display("  STATUS = 0x%08x  busy=%0d done=%0d err=%0d state=%0d",
             st, st & 1, (st >> 1) & 1, (st >> 2) & 1, (st >> 4) & 15);
    if ((st & 1) == 0 && ((st >> 1) & 1) == 1 && ((st >> 2) & 1) == 0) begin
      npass = npass + 1;
    end else begin
      $display("  !! STATUS 不符合 done 语义"); nfail = nfail + 1;
    end

    axi_read(R_NSAMP_DONE, rd);
    if (rd === M_EXPECT) begin
      $display("  NSAMP_DONE = %0d  OK", rd); npass = npass + 1;
    end else begin
      $display("  NSAMP_DONE = %0d  BAD (want %0d)", rd, M_EXPECT); nfail = nfail + 1;
    end

    build_expected_unan;
    axi_read(R_STABLE_CNT, rd);
    if (rd === exp_stable) begin
      $display("  STABLE_CNT = %0d  OK (期望 %0d)", rd, exp_stable); npass = npass + 1;
    end else begin
      $display("  STABLE_CNT = %0d  BAD (期望 %0d)", rd, exp_stable); nfail = nfail + 1;
    end

    // ---- 逐字读回 DATA / UNAN ----
    for (w = 0; w < N_WORD; w = w + 1) begin
      axi_write(R_IDX, w);
      axi_read (R_DATA, dword[w]);
      axi_read (R_UNAN, uword[w]);
    end

    $display("");
    $display("---- T6 UNAN 掩码精确匹配 ----");
    for (w = 0; w < N_WORD; w = w + 1) begin
      if (uword[w] === exp_unan[w]) begin
        $display("  UNAN[%0d] = 0x%08x  OK", w, uword[w]); npass = npass + 1;
      end else begin
        $display("  UNAN[%0d] = 0x%08x  BAD (want 0x%08x)", w, uword[w], exp_unan[w]);
        nfail = nfail + 1;
      end
    end
    pop = 0;
    for (w = 0; w < N_WORD; w = w + 1)
      for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1)
        if (uword[w][bit_i]) pop = pop + 1;
    $display("  UNAN 置位数 = %0d（期望 %0d）", pop, N_BITS - exp_stable);

    $display("");
    $display("---- T7 稳定位 DATA 必须等于行为模型基底值 ----");
    begin
      integer bad;
      bad = 0;
      for (w = 0; w < N_WORD; w = w + 1)
        for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1) begin
          if (uword[w][bit_i]) continue;       // 不稳定位不检查（多数表决结果是噪声）
          if (dword[w][bit_i] !== base_of(w * 32 + bit_i)) begin
            bad = bad + 1;
            if (bad <= 5)
              $display("    bit %0d BAD got=%0d want=%0d",
                       w * 32 + bit_i, dword[w][bit_i], base_of(w * 32 + bit_i));
          end
        end
      if (bad == 0) begin
        $display("  所有稳定位 DATA 与模型一致  OK (检查了 %0d 位)", exp_stable);
        npass = npass + 1;
      end else begin
        $display("  !! %0d 个稳定位不匹配", bad); nfail = nfail + 1;
      end
    end

    $display("");
    $display("---- T8 IDX 间接寻址确实在切换字 ----");
    axi_write(R_IDX, 0);
    axi_read (R_DATA, rd);
    axi_write(R_IDX, 3);
    begin
      reg [31:0] d3;
      axi_read(R_DATA, d3);
      axi_write(R_IDX, 0);
      begin
        reg [31:0] d0_again;
        axi_read(R_DATA, d0_again);
        if (d0_again === rd && d3 === dword[3]) begin
          $display("  IDX=0 复读一致(0x%08x)，IDX=3 读到 0x%08x  OK", d0_again, d3);
          npass = npass + 1;
        end else begin
          $display("  !! IDX 切换异常: d0=0x%08x d0_again=0x%08x d3=0x%08x want3=0x%08x",
                   rd, d0_again, d3, dword[3]);
          nfail = nfail + 1;
        end
      end
    end

    //=================================================================
    // T9 第二次采样：清 start -> 再启动 -> 稳定位结果一致
    //=================================================================
    $display("");
    $display("---- T9 第二次采样可重复启动 ----");
    axi_write(R_CTRL, 32'h0);              // 清 done
    repeat (4) @(posedge clk);
    axi_read(R_STATUS, st);
    if (((st >> 1) & 1) == 0) begin
      $display("  写 start=0 后 done 已清  OK"); npass = npass + 1;
    end else begin
      $display("  !! done 未被清 (STATUS=0x%08x)", st); nfail = nfail + 1;
    end

    axi_write(R_CTRL, 32'h1);              // 再次启动
    tmo = 0;
    while (!u_dut.u_ctrl.done && tmo < 20000) begin @(posedge clk); tmo = tmo + 1; end
    $display("  第二次采样：用 %0d 拍，done=%0d", tmo, u_dut.u_ctrl.done);

    begin
      integer bad2;
      bad2 = 0;
      for (w = 0; w < N_WORD; w = w + 1) begin
        axi_write(R_IDX, w);
        axi_read (R_DATA, rd);
        axi_read (R_UNAN, uword[w]);
        // 稳定位两次应完全一致；不稳定位允许不同
        for (bit_i = 0; bit_i < 32; bit_i = bit_i + 1) begin
          if (uword[w][bit_i]) continue;
          if (rd[bit_i] !== dword[w][bit_i]) bad2 = bad2 + 1;
        end
        // UNAN 掩码本身也必须一致（模型里固定是那些位）
        if (uword[w] !== exp_unan[w]) bad2 = bad2 + 1;
      end
      if (bad2 == 0) begin
        $display("  二次采样与首次在一处稳定位上完全一致  OK"); npass = npass + 1;
      end else begin
        $display("  !! 二次采样有 %0d 处不一致", bad2); nfail = nfail + 1;
      end
    end

    axi_write(R_CTRL, 32'h0);              // 收尾：清 done

    //=================================================================
    // T10 AXI-Lite 读通道：R 数据必须寄存器锁存
    //   场景：发 AR(A) 后**刻意不取走** R 数据，此时再发 AR(B)。
    //   要求：随后取走的第一笔 R 数据必须是 A 的值。
    //   旧实现（rdata 组合于读地址）：AR(B) 一被接受就把 R 数据改成 B，
    //   本用例会读到 B 的值 -> FAIL。寄存器锁存后必须读到 A。
    //   A=VERSION(0x00010000)，B=NBITS(128)，两者取值已知且必不相同。
    //=================================================================
    $display("");
    $display("---- T10 读通道 R 数据锁存（背靠背读不同地址）----");
    begin
      reg [31:0] da, db;
      // 起始先冲掉可能残留的 R 通道，确保 rvalid=0
      s_rready <= 1'b1; repeat (2) @(posedge clk); s_rready <= 1'b0;

      @(posedge clk);
      s_araddr  <= R_VERSION;
      s_arvalid <= 1'b1;
      s_rready  <= 1'b0;                                     // 刻意不取走
      do @(posedge clk); while (!(s_arready && s_arvalid));  // A 的 AR 握手
      s_arvalid <= 1'b0;
      do @(posedge clk); while (!s_rvalid);                  // A 的 R 数据有效

      // 在 A 的 R 数据仍未取走时，发 B 的 AR（DUT 应因 rvalid=1 而保持 arready=0）
      s_araddr  <= R_NBITS;
      s_arvalid <= 1'b1;
      repeat (3) @(posedge clk);

      // 现在才取走第一笔 R 数据 —— 必须仍是 A 的值
      s_rready  <= 1'b1;
      do @(posedge clk); while (!(s_rvalid && s_rready));
      da = s_rdata;
      s_rready  <= 1'b0;

      // B 的 AR 此时才应被接受
      do @(posedge clk); while (!(s_arready && s_arvalid));
      s_arvalid <= 1'b0;
      do @(posedge clk); while (!s_rvalid);
      db = s_rdata;
      s_rready  <= 1'b1;
      @(posedge clk); s_rready <= 1'b0; @(posedge clk);

      if (da === VERSION_EXPECT && db === N_BITS) begin
        $display("  第一笔 = 0x%08x (VERSION) OK；第二笔 = %0d (NBITS) OK", da, db);
        npass = npass + 1;
      end else begin
        $display("  !! R 数据被改写：first=0x%08x (want 0x%08x) second=%0d (want %0d)",
                 da, VERSION_EXPECT, db, N_BITS);
        nfail = nfail + 1;
      end
    end

    //=================================================================
    // 汇总
    //=================================================================
    $display("");
    $display("================================================================");
    if (nfail == 0 && npass > 0)
      $display("=== PASS ===  %0d 项通过，0 项失败", npass);
    else
      $display("=== FAIL ===  %0d 项通过，%0d 项失败", npass, nfail);
    $display("================================================================");
    $finish;
  end

endmodule

`default_nettype wire