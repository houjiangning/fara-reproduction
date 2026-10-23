`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_fuzzy_extract —— fuzzy_extract 的 golden 向量自检
//
// 向量由 tools/gen_fe_vectors.py 生成（Python 为唯一可信源）：
//     fe_vectors.mem： <mask:32hex> <resp:32hex> <k:2hex> <seed:32hex>
//
// 覆盖：
//   · 边界：全 1 掩码 + k=42（3k=126，最大合法值）
//   · 单点翻转：在被取出的位里翻 1 位，seed 必须仍等于干净值（重复码纠错）
//   · 随机向量：掩码恰好留 3k 个位（最紧的选位）
//   · 反例：掩码为 0 + k=22 -> 必须置 err（选位不足）
//=============================================================================
module tb_fuzzy_extract;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg          rst_n = 1'b0;
  reg  [127:0] mask = 128'd0;
  reg  [127:0] helper = 128'd0;
  reg  [7:0]   kcfg = 8'd0;
  reg  [127:0] resp = 128'd0;
  reg          start = 1'b0;
  wire         busy, done, err;
  wire [127:0] seed;
  wire [7:0]   k_used;

  fuzzy_extract #(.NBITS(128)) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .cfg_mask (mask),
    .cfg_helper(helper),
    .cfg_k    (kcfg),
    .puf_resp (resp),
    .start    (start),
    .busy     (busy),
    .done     (done),
    .err      (err),
    .seed     (seed),
    .k_used   (k_used)
  );

  integer     fd, i, npass, nfail, guard, rc;
  reg [127:0] vm, vr, vh, vs;
  reg [7:0]   vk;

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    fd = $fopen("fe_vectors.mem", "r");
    if (fd == 0) begin $display("FATAL: 打不开 fe_vectors.mem"); $display("=== FAIL ==="); $finish; end

    npass = 0; nfail = 0; i = 0;

    while ($fscanf(fd, "%h %h %h %h %h\n", vm, vr, vh, vk, vs) == 5) begin
      // 关键：在 **negedge** 上装向量，给 posedge 半周期建立时间。
      // 若在 posedge 同一 delta 里改配置再拉 start，DUT 到底看到"旧 cfg_k + 新 start"
      // 还是"新 cfg_k + 新 start"取决于进程调度顺序 —— 实测会随机跑出 S_ERR。
      @(negedge clk);
      mask = vm; resp = vr; helper = vh; kcfg = vk;
      start = 1'b1;

      guard = 0;
      while (!(done || err) && guard < 5000) begin @(posedge clk); guard = guard + 1; end

      if (err) begin
        $display("FAIL vec %0d : 意外置 err  (k=%0d need=%0d)", i, vk, vk * 3);
        $display("   dbg state=%0d bidx=%0d sel_cnt=%0d gidx=%0d tri_pos=%0d k_used=%0d",
                 dut.state, dut.bidx, dut.sel_cnt, dut.gidx, dut.tri_pos, k_used);
        $display("   dbg dut.cfg_k=%0d dut.k_ok=%b dut.need=%0d dut.kcfg_seen=?", dut.cfg_k, dut.k_ok, dut.need);
        nfail = nfail + 1;
      end else if (seed === vs && k_used === vk) begin
        $display("PASS vec %0d : k=%0d seed=%032h", i, vk, seed);
        npass = npass + 1;
      end else begin
        $display("FAIL vec %0d : got %032h exp %032h (k_used=%0d)", i, seed, vs, k_used);
        nfail = nfail + 1;
      end

      @(negedge clk);
      start = 1'b0;
      guard = 0;
      while ((done || err) && guard < 200) begin @(posedge clk); guard = guard + 1; end
      i = i + 1;
    end
    $fclose(fd);

    // ---- 反例：掩码为 0 + k=22 -> 必须 err ----
    $display("");
    $display("反例：掩码全 0 + k=22 -> 期望 err");
    @(negedge clk);
    mask = 128'd0; resp = 128'd0; kcfg = 8'd22;
    start = 1'b1;
    guard = 0;
    while (!(done || err) && guard < 5000) begin @(posedge clk); guard = guard + 1; end
    if (err === 1'b1) begin
      $display("PASS 反例：正确置 err");
    end else begin
      $display("FAIL 反例：未置 err (done=%0d)", done);
      nfail = nfail + 1;
    end
    start = 1'b0;
    repeat (20) @(posedge clk);

    $display("");
    $display("FE 向量：%0d 通过 / %0d 失败（共 %0d 条）", npass, nfail, i);
    if (nfail == 0 && npass > 0) $display("=== PASS ===");
    else                         $display("=== FAIL ===");
    $finish;
  end

endmodule

`default_nettype wire
