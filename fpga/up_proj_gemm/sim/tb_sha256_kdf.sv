`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_sha256_kdf —— sha256_kdf 的 golden 向量自检
//
// 向量由 tools/gen_kdf_vectors.py 生成（Python hashlib 为唯一可信源）：
//     block = seed(16B) || salt(16B) || purpose(16B) = 48 B，单块 SHA-256
// 文件名固定 kdf_vectors.mem，须与本 TB 同目录（sim_work）。
//
// 覆盖：全零锚点、真实 22 位 seed 形态、随机向量。
// 退出：=== PASS === / === FAIL ===
//=============================================================================
module tb_sha256_kdf;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg          rst_n = 1'b0;
  reg          start = 1'b0;
  reg  [127:0] seed_v, salt_v, purpose_v;
  wire         busy, done;
  wire [255:0] digest;

  sha256_kdf dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .start   (start),
    .seed    (seed_v),
    .salt    (salt_v),
    .purpose (purpose_v),
    .busy    (busy),
    .done    (done),
    .digest  (digest)
  );

  integer      fd;
  integer      i, npass, nfail, guard;
  reg [127:0]  vs, vl, vp;
  reg [255:0]  vd;

  initial begin
    // ---- reset ----
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    fd = $fopen("kdf_vectors.mem", "r");
    if (fd == 0) begin
      $display("FATAL: 打不开 kdf_vectors.mem（须与本 TB 同目录）");
      $display("=== FAIL ===");
      $finish;
    end

    npass = 0; nfail = 0; i = 0;

    while ($fscanf(fd, "%h %h %h %h\n", vs, vl, vp, vd) == 4) begin
      seed_v    = vs;
      salt_v    = vl;
      purpose_v = vp;

      // ---- 启动（start 是电平，done 保持到 start 清零）----
      start = 1'b1;
      guard = 0;
      while (!done && guard < 5000) begin
        @(posedge clk);
        guard = guard + 1;
      end

      if (!done) begin
        $display("FAIL vec %0d : KDF 超时未 done", i);
        nfail = nfail + 1;
      end else if (digest === vd) begin
        $display("PASS vec %0d : seed=%032h digest=%064h", i, seed_v, digest);
        npass = npass + 1;
      end else begin
        $display("FAIL vec %0d : got %064h exp %064h", i, digest, vd);
        nfail = nfail + 1;
      end

      // ---- 清 done，回到 IDLE 准备下一条 ----
      start = 1'b0;
      guard = 0;
      while (done && guard < 200) begin
        @(posedge clk);
        guard = guard + 1;
      end
      i = i + 1;
    end

    $fclose(fd);
    $display("");
    $display("KDF 向量：%0d 通过 / %0d 失败（共 %0d 条）", npass, nfail, i);
    if (nfail == 0 && npass > 0) $display("=== PASS ===");
    else                         $display("=== FAIL ===");
    $finish;
  end

endmodule

`default_nettype wire
