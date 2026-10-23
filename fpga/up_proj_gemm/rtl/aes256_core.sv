`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// aes256_core —— AES-256 加密核（全流水，吞吐 1 block/cycle）
//
// 为什么只做"加密"不做"解密"：
//   CTR 模式加解密是同一个运算（数据 XOR 密钥流），只需要加密方向。
//   所以本核只实现 FIPS-197 的加密路径 + 密钥扩展。
//
// 结构：
//   · 密钥扩展：一次性 FSM，60 个 32-bit word，1 word/cycle。
//               key_load 拉高后约 60 拍完成，之后 key_ready 置 1。
//   · 轮流水线：15 级寄存器
//               stage0..13 = 完整轮（SubBytes→ShiftRows→MixColumns→AddRoundKey）
//               stage14    = 末轮（SubBytes→ShiftRows→AddRoundKey，无 MixColumns）
//               吞吐 1 block/cycle，延迟 15 拍（输入有效 → 输出有效）
//   · ce 时钟使能：ce=0 时整条流水线保持不动。aes256_ctr 用它把
//                 "数据延迟线"与"密钥流"严格对齐 —— 这是本设计的关键技巧。
//
// 实现方式说明（重要，勿改成模块内 function）：
//   S-box 用**独立模块** aes256_sbox 实例化，共 14*16 + 16 + 4 = 244 个。
//   早期版本把 S-box 写成模块内 256 项 case 的 function，Vivado 的 elaborator
//   会把该 case 内联 228 次，表达式树规模爆炸 -> xelab EXCEPTION_ACCESS_VIOLATION
//   （已实测复现）。改成模块实例后 elaborator 只处理一份表体，问题消失。
//
// 字节序契约（必须与 tools/weight_encrypt.py 一致）：
//   128-bit 块的字节 j（j=0..15）位于 blk[8*j +: 8]
//   等价于 Python: blk = int.from_bytes(block_bytes, 'little')
//   流上的 16 个连续字节，按出现顺序构成块字节 0..15。
//
// 轮常量 Rcon：AES-256 只用 1..7（0x01,0x02,0x04,0x08,0x10,0x20,0x40）。
//=============================================================================
module aes256_core (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 密钥装载 / 扩展 ----
  input  wire         key_load,     // 单拍脉冲：锁存密钥并启动扩展
  input  wire [255:0] key_in,
  output reg          key_ready,    // 扩展完成（w[] 全部可用）

  // ---- 流水线时钟使能（0 = 整条流水线保持）----
  input  wire         ce,

  // ---- 数据通路 ----
  input  wire         in_valid,
  input  wire [127:0] in_blk,
  output wire         out_valid,
  output wire [127:0] out_blk
);

  localparam integer NR = 14;       // AES-256 轮数

  // 流水寄存器（必须在使用它的 generate 之前声明：xvlog 不允许前向引用）
  reg [127:0] pblk [0:14];
  reg         pvld [0:14];

  //===========================================================================
  // 1) 密钥扩展：w[0..59]，1 word/cycle
  //   i%8==0 → w[i] = w[i-8] ^ SubWord(RotWord(w[i-1])) ^ Rcon(i/8)
  //   i%8==4 → w[i] = w[i-8] ^ SubWord(w[i-1])
  //   其余   → w[i] = w[i-8] ^ w[i-1]
  //===========================================================================
  reg  [31:0] w [0:59];
  reg         busy;
  reg  [6:0]  kc;

  // 4 个 S-box 实例供 SubWord 使用（sub_word 一次处理 4 字节）
  wire [7:0] sw_in  [0:3];
  wire [7:0] sw_out [0:3];

  genvar gk;
  generate
    for (gk = 0; gk < 4; gk = gk + 1) begin : g_kexp_sb
      aes256_sbox u_kexp_sb (
        .x (sw_in[gk]),
        .y (sw_out[gk])
      );
    end
  endgenerate

  // w[kc-1] 的字节：b0=MSB .. b3=LSB
  wire [31:0] kprev = w[kc - 7'd1];
  assign sw_in[0] = kprev[31:24];       // b0
  assign sw_in[1] = kprev[23:16];       // b1
  assign sw_in[2] = kprev[15:8];        // b2
  assign sw_in[3] = kprev[7:0];         // b3

  // RotWord 后字节序 = [b1,b2,b3,b0] -> SubWord -> {S1,S2,S3,S0}
  wire [31:0] sub_rot = {sw_out[1], sw_out[2], sw_out[3], sw_out[0]};
  // 不做 RotWord 时 SubWord -> {S0,S1,S2,S3}
  wire [31:0] sub_plain = {sw_out[0], sw_out[1], sw_out[2], sw_out[3]};

  // Rcon 常量：FIPS-197 里 Rcon 是**单字节**，异或到 word 的**最高字节**上，
  //   即 0x01000000 / 0x02000000 / ...（不是 0x00000001！）
  //   实测踩坑：早期写成 {24'd0, rcon}，密钥扩展从 w[8] 起全部偏离
  //   （w[8] 期望 9ba35411 实得 9aa35410，差值恰为 0x01000001）。
  function automatic [31:0] rcon_word(input [6:0] i);
    case (i)
      7'd1: rcon_word = 32'h0100_0000;
      7'd2: rcon_word = 32'h0200_0000;
      7'd3: rcon_word = 32'h0400_0000;
      7'd4: rcon_word = 32'h0800_0000;
      7'd5: rcon_word = 32'h1000_0000;
      7'd6: rcon_word = 32'h2000_0000;
      7'd7: rcon_word = 32'h4000_0000;
      default: rcon_word = 32'h0000_0000;
    endcase
  endfunction

  wire [31:0] temp_w;
  assign temp_w = ((kc % 7'd8) == 7'd0) ? (sub_rot ^ rcon_word(kc / 7'd8)) :
                  ((kc % 7'd8) == 7'd4) ? sub_plain :
                                          kprev;

  integer wi;

  always @(posedge clk) begin
    if (!rst_n) begin
      busy      <= 1'b0;
      kc        <= 7'd0;
      key_ready <= 1'b0;
      for (wi = 0; wi < 60; wi = wi + 1) w[wi] <= 32'd0;
    end else begin
      if (key_load) begin
        w[0] <= key_in[255:224];
        w[1] <= key_in[223:192];
        w[2] <= key_in[191:160];
        w[3] <= key_in[159:128];
        w[4] <= key_in[127:96];
        w[5] <= key_in[95:64];
        w[6] <= key_in[63:32];
        w[7] <= key_in[31:0];
        kc        <= 7'd8;
        busy      <= 1'b1;
        key_ready <= 1'b0;
      end else if (busy) begin
        if (kc < 7'd60) begin
          w[kc] <= w[kc - 7'd8] ^ temp_w;
          kc    <= kc + 7'd1;
        end else begin
          busy      <= 1'b0;
          key_ready <= 1'b1;
        end
      end
    end
  end

  //===========================================================================
  // 2) 轮流水线的组合逻辑：每级的输入 / SubBytes / 轮变换
  //===========================================================================
  wire [127:0] st_in  [0:14];      // 各级输入状态
  wire [127:0] sb_out [0:14];      // SubBytes 之后
  wire [127:0] tr_out [0:14];      // ShiftRows(+MixColumns)+AddRoundKey 之后

  // 级 0 的输入是外部数据；其余各级输入是前一级的流水寄存器
  genvar gs, gb, gc;

  generate
    for (gs = 0; gs <= 14; gs = gs + 1) begin : g_stin
      if (gs == 0) assign st_in[gs] = in_blk;
      else         assign st_in[gs] = pblk[gs-1];
    end
  endgenerate

  // ---- SubBytes：级 1..14 各 16 个 S-box 实例；级 0 只做 AddRoundKey，不查表 ----
  generate
    for (gs = 0; gs <= 14; gs = gs + 1) begin : g_sb
      if (gs == 0) begin : g_bypass
        assign sb_out[0] = st_in[0];
      end else begin : g_real
        for (gb = 0; gb < 16; gb = gb + 1) begin : g_byte
          aes256_sbox u_sb (
            .x (st_in[gs][8*gb +: 8]),
            .y (sb_out[gs][8*gb +: 8])
          );
        end
      end
    end
  endgenerate

  // ---- ShiftRows + MixColumns + AddRoundKey ----
  //   扁平下标约定：i = 4*col + row，故 new[4c+r] = old[4*((c+r)%4)+r]
  //   三级结构（gs 是 genvar，三选一在综合期常量折叠）：
  //     gs == 0   → 纯 AddRoundKey（初始轮密钥加，不做任何字节变换）
  //     gs 1..13  → SubBytes → ShiftRows → MixColumns → AddRoundKey
  //     gs == 14  → SubBytes → ShiftRows → AddRoundKey（末轮无 MixColumns）
  generate
    for (gs = 0; gs <= 14; gs = gs + 1) begin : g_tr
      for (gc = 0; gc < 4; gc = gc + 1) begin : g_col
        // 本列原始输入字节（仅 gs==0 使用）
        wire [7:0] p0 = st_in[gs][8*(4*gc+0) +: 8];
        wire [7:0] p1 = st_in[gs][8*(4*gc+1) +: 8];
        wire [7:0] p2 = st_in[gs][8*(4*gc+2) +: 8];
        wire [7:0] p3 = st_in[gs][8*(4*gc+3) +: 8];

        // ShiftRows：取本轮第 gc 列的 4 个字节（已按行循环移位）
        wire [7:0] a0 = sb_out[gs][8*(4*((gc+0)%4)+0) +: 8];
        wire [7:0] a1 = sb_out[gs][8*(4*((gc+1)%4)+1) +: 8];
        wire [7:0] a2 = sb_out[gs][8*(4*((gc+2)%4)+2) +: 8];
        wire [7:0] a3 = sb_out[gs][8*(4*((gc+3)%4)+3) +: 8];

        // xtime：乘 2（模 AES 不可约多项式）
        wire [7:0] x0 = {a0[6:0], 1'b0} ^ (a0[7] ? 8'h1B : 8'h00);
        wire [7:0] x1 = {a1[6:0], 1'b0} ^ (a1[7] ? 8'h1B : 8'h00);
        wire [7:0] x2 = {a2[6:0], 1'b0} ^ (a2[7] ? 8'h1B : 8'h00);
        wire [7:0] x3 = {a3[6:0], 1'b0} ^ (a3[7] ? 8'h1B : 8'h00);

        // MixColumns（3*a = 2*a ^ a）
        wire [7:0] m0 = x0 ^ x1 ^ a1 ^ a2 ^ a3;
        wire [7:0] m1 = a0 ^ x1 ^ x2 ^ a2 ^ a3;
        wire [7:0] m2 = a0 ^ a1 ^ x2 ^ x3 ^ a3;
        wire [7:0] m3 = x0 ^ a0 ^ a1 ^ a2 ^ x3;

        wire [7:0] c0 = (gs == 0) ? p0 : ((gs == 14) ? a0 : m0);
        wire [7:0] c1 = (gs == 0) ? p1 : ((gs == 14) ? a1 : m1);
        wire [7:0] c2 = (gs == 0) ? p2 : ((gs == 14) ? a2 : m2);
        wire [7:0] c3 = (gs == 0) ? p3 : ((gs == 14) ? a3 : m3);

        // AddRoundKey：轮密钥 rk[gs] 的第 gc 个字 = w[4*gs + gc]
        //   FIPS-197 语境下字写成 [w0,w1,w2,w3]，w0 落第 0 行、
        //   在 32-bit 寄存器里 w0 位于**最高字节** [31:24]。
        //   实测踩坑：早期写成 [7:0] 给第 0 行（即整字打包反了），
        //   导致每个块只错 AddRoundKey 一项而全盘不一致。
        assign tr_out[gs][8*(4*gc+0) +: 8] = c0 ^ w[4*gs + gc][31:24];
        assign tr_out[gs][8*(4*gc+1) +: 8] = c1 ^ w[4*gs + gc][23:16];
        assign tr_out[gs][8*(4*gc+2) +: 8] = c2 ^ w[4*gs + gc][15:8];
        assign tr_out[gs][8*(4*gc+3) +: 8] = c3 ^ w[4*gs + gc][7:0];
      end
    end
  endgenerate

  //===========================================================================
  // 3) 流水寄存器：15 级（pblk[0..14] 已在模块开头声明）
  //===========================================================================
  always @(posedge clk) begin
    if (!rst_n) begin
      pvld[0] <= 1'b0;
      pblk[0] <= 128'd0;
    end else if (ce) begin
      pvld[0] <= in_valid;
      pblk[0] <= tr_out[0];
    end
  end

  generate
    for (gs = 1; gs <= 14; gs = gs + 1) begin : g_pipe
      always @(posedge clk) begin
        if (!rst_n) begin
          pvld[gs] <= 1'b0;
          pblk[gs] <= 128'd0;
        end else if (ce) begin
          pvld[gs] <= pvld[gs-1];
          pblk[gs] <= tr_out[gs];
        end
      end
    end
  endgenerate

  assign out_valid = pvld[14];
  assign out_blk   = pblk[14];

endmodule

`default_nettype wire