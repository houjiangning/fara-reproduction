`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// key_mgr —— AES-256 密钥寄存器（只写不可读 + 一次性锁定）
//
// 与 plan-B §6.2 一致的"三重保险"：
//   ① 密钥寄存器**不进 AXI-Lite 的 read case** —— 软件读 key 寄存器只会读到
//      puf_dec_axi_lite 默认分支的 0xDEADBEEF；
//   ② locked 置位后软件写失效（密钥一旦由 KDF 写入即锁死，防调试口覆盖）；
//   ③ aes_key 只在 PL 内部直连 aes256_core 的 key_in，不经过任何 AXI 通道。
//
// 两个加载来源：
//   · kdf_valid 单拍脉冲 + kdf_key：正常路径（PUF -> FE -> KDF -> 这里）
//   · sw_write  单拍脉冲 + sw_key ：调试路径（仅 locked==0 时有效）
//
// key_new 输出**单拍脉冲**，给 aes256_core.key_load 用（触发 60 拍密钥扩展）。
//=============================================================================
module key_mgr (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 正常路径：来自 sha256_kdf ----
  input  wire         kdf_valid,
  input  wire [255:0] kdf_key,

  // ---- 调试路径：来自 AXI-Lite 软件写入 ----
  input  wire         sw_write,
  input  wire [255:0] sw_key,

  // ---- 输出 ----
  output wire [255:0] aes_key,     // 直连 aes256_core.key_in，不出 PL
  output reg          locked,      // 密钥已装载并锁定
  output reg          key_new      // 单拍：驱动 aes256_core.key_load
);

  reg [255:0] key_r;

  always @(posedge clk) begin
    if (!rst_n) begin
      key_r   <= 256'd0;
      locked  <= 1'b0;
      key_new <= 1'b0;
    end else begin
      // key_new 默认回零，只有下面两个加载事件才置 1（单拍脉冲）
      key_new <= 1'b0;

      if (kdf_valid) begin
        key_r   <= kdf_key;
        locked  <= 1'b1;
        key_new <= 1'b1;
      end else if (sw_write && !locked) begin
        key_r   <= sw_key;
        key_new <= 1'b1;
      end
    end
  end

  // 密钥只在 PL 内部走线，不经过 AXI
  assign aes_key = key_r;

endmodule

`default_nettype wire
