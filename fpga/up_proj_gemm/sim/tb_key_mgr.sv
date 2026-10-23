`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// tb_key_mgr —— 密钥寄存器"只写/锁定"行为自检
//
// 覆盖三条安全属性：
//   1) 未锁定时 sw_write 可以装载密钥并出 key_new 单拍脉冲
//   2) kdf_valid 装载后 locked=1，并以 KDF 密钥为准
//   3) locked 之后 sw_write **不再生效**（密钥不被软件覆盖），key_new 不再脉冲
//=============================================================================
module tb_key_mgr;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg          rst_n = 1'b0;
  reg          kdf_valid = 1'b0;
  reg  [255:0] kdf_key = 256'd0;
  reg          sw_write = 1'b0;
  reg  [255:0] sw_key = 256'd0;
  wire [255:0] aes_key;
  wire         locked;
  wire         key_new;

  key_mgr dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .kdf_valid (kdf_valid),
    .kdf_key   (kdf_key),
    .sw_write  (sw_write),
    .sw_key    (sw_key),
    .aes_key   (aes_key),
    .locked    (locked),
    .key_new   (key_new)
  );

  integer npass, nfail;
  reg [255:0] KEYA, KEYB, KEYC, KEYD;
  integer pulse_cnt;

  // key_new 脉冲计数
  always @(posedge clk) if (rst_n && key_new) pulse_cnt = pulse_cnt + 1;

  task chk;
    input        cond;
    input [255:0] got;
    input [255:0] exp;
    input [127:0] name;
    begin
      if (cond) begin
        $display("PASS %0s", name);
        npass = npass + 1;
      end else begin
        $display("FAIL %0s : got %064h exp %064h", name, got, exp);
        nfail = nfail + 1;
      end
    end
  endtask

  initial begin
    npass = 0; nfail = 0; pulse_cnt = 0;
    KEYA = 256'h1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111;
    KEYB = 256'h2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222_2222;
    KEYC = 256'h3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333_3333;
    KEYD = 256'h4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444_4444;

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 1) 未锁定：sw 写 KEYA ----
    @(negedge clk); sw_key = KEYA; sw_write = 1'b1;
    @(negedge clk); sw_write = 1'b0;
    @(posedge clk);
    chk(aes_key === KEYA, aes_key, KEYA, "sw_write(未锁)装载 KEYA");
    chk(locked === 1'b0, {255'd0, locked}, 256'd0, "未锁定 locked=0");
    chk(pulse_cnt === 1, {255'd0, pulse_cnt[0]}, 256'd1, "key_new 出 1 个脉冲");

    // ---- 2) 未锁定：sw 写 KEYB（应生效）----
    @(negedge clk); sw_key = KEYB; sw_write = 1'b1;
    @(negedge clk); sw_write = 1'b0;
    @(posedge clk);
    chk(aes_key === KEYB, aes_key, KEYB, "未锁定时可被再次覆盖");

    // ---- 3) kdf_valid 装载 KEYC -> lock ----
    @(negedge clk); kdf_key = KEYC; kdf_valid = 1'b1;
    @(negedge clk); kdf_valid = 1'b0;
    @(posedge clk);
    chk(aes_key === KEYC, aes_key, KEYC, "kdf_valid 装载 KEYC");
    chk(locked === 1'b1, {255'd0, locked}, 256'd1, "KDF 后 locked=1");

    // ---- 4) 锁定后 sw 写 KEYD 应无效 ----
    pulse_cnt = 0;
    @(negedge clk); sw_key = KEYD; sw_write = 1'b1;
    @(negedge clk); sw_write = 1'b0;
    repeat (3) @(posedge clk);
    chk(aes_key === KEYC, aes_key, KEYC, "locked 后 sw_write 无效（密钥仍是 KEYC）");
    chk(pulse_cnt === 0, {255'd0, pulse_cnt[0]}, 256'd0, "locked 后 key_new 不脉冲");

    $display("");
    $display("key_mgr：%0d 通过 / %0d 失败", npass, nfail);
    if (nfail == 0) $display("=== PASS ===");
    else            $display("=== FAIL ===");
    $finish;
  end

endmodule

`default_nettype wire
