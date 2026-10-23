`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// sha256_kdf —— 单次 SHA-256 的密钥派生函数（KDF）
//
// plan-B §6.1：key = SHA-256( FE_output ‖ salt ‖ purpose )
//   · FE_output : fuzzy_extract 的 seed（128 位，低位 cfg_k 位有效，其余补 0）
//   · salt      : 公开随机数，与 helper data 一起存（enrollment 时生成）
//   · purpose   : 用途标签，如 "fara-weight-aes"，避免同一 PUF 派生出的不同
//                 密钥互相牵连
//
// 为什么用 SHA-256 而不是 AES 做 KDF：
//   SHA-256 是哈希/PRF，天生就是"把任意长、可能有偏的输入压成定长均匀输出"
//   （conditioning）。AES 是**需要密钥**的分组密码 —— 而我们正要"从 PUF 派生
//   密钥"，用 AES 会撞上先有鸡还是先有蛋（只能用一把固定公开密钥当 PRF，属非
//   标准构造）。所有标准 KDF（HKDF、SP 800-108）都是"哈希/PRF 在前、密钥在后"。
//   所以分工是：SHA-256 负责**派生**，AES-256-CTR 负责**使用**，两者都用。
//
// ---------------------------------------------------------------------------
// 消息格式：三者拼成**恰好一个 SHA-256 块**（48 字节 = 384 bit 消息）
//   W0..W3  = seed[127:96], seed[95:64], seed[63:32], seed[31:0]
//   W4..W7  = salt  (同上四段)
//   W8..W11 = purpose (同上四段)
//   W12     = 32'h8000_0000 ；W13 = W14 = 0 ；W15 = 384（消息比特长度）
// 固定单块、无长度歧义 —— RTL 与 Python golden 逐位可比。
//
// 字节序契约（与 aes256_core 对齐）：
//   SHA-256 消息字是大端；digest[255:224] = H0 = 哈希结果的**前 4 字节**。
//   aes256_core 的密钥扩展 w[0] = key_in[255:224]（= 密钥前 4 字节），
//   所以 digest[255:0] 直接接 key_mgr -> aes256_core.key_in 即可。
//   Python golden：bytes(hashlib.sha256(seed_bytes + salt_bytes + purpose_bytes).digest())
// ---------------------------------------------------------------------------
//
// 实现：64 轮迭代（1 轮/拍）+ 16 字滚动 W 窗口。只有 32 位模加 / 循环移位 /
// 异或 / 与或非 —— 没有 S 盒表，是这几个密码块里最简单、最容易用 NIST KAT
// 逐位验证的一个（AES 的 S 盒才是复杂度热点，故它单独拆成 aes256_sbox.sv）。
//=============================================================================
module sha256_kdf (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 输入 ----
  input  wire         start,      // 电平：start=1 且 done=0 启动；写 0 清 done
  input  wire [127:0] seed,
  input  wire [127:0] salt,
  input  wire [127:0] purpose,

  // ---- 状态 / 输出 ----
  output reg          busy,
  output reg          done,
  output reg  [255:0] digest    // = AES-256 密钥（前向 32 字节，大端字节序）
);

  localparam [1:0] S_IDLE = 2'd0,
                   S_RUN  = 2'd1,
                   S_DONE = 2'd2;

  reg [1:0]  state;
  reg [5:0]  t;                       // 轮计数 0..63

  reg [31:0] W [0:15];                // 16 字滚动窗口
  reg [31:0] a, b, c, d, e, f, g, h;  // 工作变量
  reg [31:0] H0, H1, H2, H3, H4, H5, H6, H7;   // 链接变量（= IV，本轮结束后叠加）

  // ---- 轮常量 K[0..63]（FIPS-180-4 §4.2.2）----
  (* rom_style = "distributed" *)
  reg [31:0] K [0:63];
  initial begin
    K[ 0]=32'h428a2f98; K[ 1]=32'h71374491; K[ 2]=32'hb5c0fbcf; K[ 3]=32'he9b5dba5;
    K[ 4]=32'h3956c25b; K[ 5]=32'h59f111f1; K[ 6]=32'h923f82a4; K[ 7]=32'hab1c5ed5;
    K[ 8]=32'hd807aa98; K[ 9]=32'h12835b01; K[10]=32'h243185be; K[11]=32'h550c7dc3;
    K[12]=32'h72be5d74; K[13]=32'h80deb1fe; K[14]=32'h9bdc06a7; K[15]=32'hc19bf174;
    K[16]=32'he49b69c1; K[17]=32'hefbe4786; K[18]=32'h0fc19dc6; K[19]=32'h240ca1cc;
    K[20]=32'h2de92c6f; K[21]=32'h4a7484aa; K[22]=32'h5cb0a9dc; K[23]=32'h76f988da;
    K[24]=32'h983e5152; K[25]=32'ha831c66d; K[26]=32'hb00327c8; K[27]=32'hbf597fc7;
    K[28]=32'hc6e00bf3; K[29]=32'hd5a79147; K[30]=32'h06ca6351; K[31]=32'h14292967;
    K[32]=32'h27b70a85; K[33]=32'h2e1b2138; K[34]=32'h4d2c6dfc; K[35]=32'h53380d13;
    K[36]=32'h650a7354; K[37]=32'h766a0abb; K[38]=32'h81c2c92e; K[39]=32'h92722c85;
    K[40]=32'ha2bfe8a1; K[41]=32'ha81a664b; K[42]=32'hc24b8b70; K[43]=32'hc76c51a3;
    K[44]=32'hd192e819; K[45]=32'hd6990624; K[46]=32'hf40e3585; K[47]=32'h106aa070;
    K[48]=32'h19a4c116; K[49]=32'h1e376c08; K[50]=32'h2748774c; K[51]=32'h34b0bcb5;
    K[52]=32'h391c0cb3; K[53]=32'h4ed8aa4a; K[54]=32'h5b9cca4f; K[55]=32'h682e6ff3;
    K[56]=32'h748f82ee; K[57]=32'h78a5636f; K[58]=32'h84c87814; K[59]=32'h8cc70208;
    K[60]=32'h90befffa; K[61]=32'ha4506ceb; K[62]=32'hbef9a3f7; K[63]=32'hc67178f2;
  end

  // ---- 循环右移 ----
  function automatic [31:0] rotr(input [31:0] x, input integer n);
    rotr = (x >> n) | (x << (32 - n));
  endfunction

  // ---- 消息扩展（16 字滚动窗口）----
  //   4 位下标做减法的自然回绕即 mod 16，无需显式取模。
  wire [3:0] i2  = t[3:0] - 4'd2;
  wire [3:0] i7  = t[3:0] - 4'd7;
  wire [3:0] i15 = t[3:0] - 4'd15;

  wire [31:0] w_t  = W[t[3:0]];       // 本轮 W[t]
  wire [31:0] w_2  = W[i2];           // W[t-2]
  wire [31:0] w_15 = W[i15];          // W[t-15]

  wire [31:0] sig1 = rotr(w_2, 17) ^ rotr(w_2, 19) ^ (w_2 >> 10);   // sigma1
  wire [31:0] sig0 = rotr(w_15, 7) ^ rotr(w_15, 18) ^ (w_15 >> 3);  // sigma0
  // W[t+16] = sigma1(W[t+14]) + W[t+9] + sigma0(W[t+1]) + W[t]
  wire [31:0] w_next = sig1 + W[i7] + sig0 + w_t;

  // ---- 压缩函数一轮 ----
  wire [31:0] S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);   // Sigma1(e)
  wire [31:0] ch = (e & f) ^ (~e & g);                        // Ch(e,f,g)
  wire [31:0] T1 = h + S1 + ch + K[t] + w_t;

  wire [31:0] S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);    // Sigma0(a)
  wire [31:0] mj = (a & b) ^ (a & c) ^ (b & c);               // Maj(a,b,c)
  wire [31:0] T2 = S0 + mj;

  wire [31:0] na = T1 + T2;
  wire [31:0] nb = a;
  wire [31:0] nc = b;
  wire [31:0] nd = c;
  wire [31:0] ne = d + T1;
  wire [31:0] nf = e;
  wire [31:0] ng = f;
  wire [31:0] nh = g;

  integer wi;

  always @(posedge clk) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      t      <= 6'd0;
      busy   <= 1'b0;
      done   <= 1'b0;
      digest <= 256'd0;
      a <= 32'd0; b <= 32'd0; c <= 32'd0; d <= 32'd0;
      e <= 32'd0; f <= 32'd0; g <= 32'd0; h <= 32'd0;
      H0 <= 32'd0; H1 <= 32'd0; H2 <= 32'd0; H3 <= 32'd0;
      H4 <= 32'd0; H5 <= 32'd0; H6 <= 32'd0; H7 <= 32'd0;
      for (wi = 0; wi < 16; wi = wi + 1) W[wi] <= 32'd0;
    end else begin
      case (state)

        //------------------------------------------------------------------
        S_IDLE: begin
          busy <= 1'b0;
          if (start && !done) begin
            // 装载**固定单块**消息（大端字序）
            W[ 0] <= seed[127:96];    W[ 1] <= seed[95:64];
            W[ 2] <= seed[63:32];     W[ 3] <= seed[31:0];
            W[ 4] <= salt[127:96];    W[ 5] <= salt[95:64];
            W[ 6] <= salt[63:32];     W[ 7] <= salt[31:0];
            W[ 8] <= purpose[127:96]; W[ 9] <= purpose[95:64];
            W[10] <= purpose[63:32];  W[11] <= purpose[31:0];
            W[12] <= 32'h8000_0000;
            W[13] <= 32'd0;
            W[14] <= 32'd0;
            W[15] <= 32'd384;         // 消息比特长度 = 48 B * 8

            // SHA-256 初始链接值
            H0 <= 32'h6a09e667; H1 <= 32'hbb67ae85;
            H2 <= 32'h3c6ef372; H3 <= 32'ha54ff53a;
            H4 <= 32'h510e527f; H5 <= 32'h9b05688c;
            H6 <= 32'h1f83d9ab; H7 <= 32'h5be0cd19;

            a <= 32'h6a09e667; b <= 32'hbb67ae85;
            c <= 32'h3c6ef372; d <= 32'ha54ff53a;
            e <= 32'h510e527f; f <= 32'h9b05688c;
            g <= 32'h1f83d9ab; h <= 32'h5be0cd19;

            t     <= 6'd0;
            busy  <= 1'b1;
            done  <= 1'b0;
            state <= S_RUN;
          end
        end

        //------------------------------------------------------------------
        // 第 t 轮：用 W[t]（旧值）算 T1/T2，同时算出 W[t+16] 覆盖该槽位。
        // t<16 时覆盖 message word 也安全 —— 该字只在"本轮 + 本轮算 W[t+16]"
        // 被用到，之后才被再次读回。
        S_RUN: begin
          a <= na; b <= nb; c <= nc; d <= nd;
          e <= ne; f <= nf; g <= ng; h <= nh;
          W[t[3:0]] <= w_next;

          if (t == 6'd63) begin
            // 末轮：H + 末轮工作变量 = 摘要。H0..H7 仍是 IV，从未被改写。
            digest <= {H0 + na, H1 + nb, H2 + nc, H3 + nd,
                       H4 + ne, H5 + nf, H6 + ng, H7 + nh};
            busy  <= 1'b0;
            done  <= 1'b1;
            state <= S_DONE;
          end else begin
            t <= t + 6'd1;
          end
        end

        //------------------------------------------------------------------
        S_DONE: begin
          busy <= 1'b0;
          if (!start) begin
            done  <= 1'b0;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;

      endcase
    end
  end

endmodule

`default_nettype wire
