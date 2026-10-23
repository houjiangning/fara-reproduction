`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// puf_dec_axi_lite —— 方案 B 加解密/密钥派生块的 AXI4-Lite 控制/状态寄存器组
//                     基址 0xA0020000 / 64 KB（与 plan-B §9.2 一致）
//
// 寄存器映射（字节偏移，32-bit）：
//   0x00 CTRL        W   [0] fe_start(电平,写0清 done) [2] soft_rst(自清)
//                        [3] ctr_load(自清脉冲)        [4] dbg_use_sw_resp
//                        （[1] 保留）
//   0x04 STATUS      R   [0] fe_busy  [1] fe_done  [2] fe_err  [3] kdf_busy
//                        [4] kdf_done [5] key_locked [6] aes_key_ready
//                        [7] route_mode  [15:8] fe_k_used
//   0x08 VERSION     R   0x0003_0000
//   0x0C CTRL2       RW  [0] route_mode  [1] sw_key_load(自清脉冲)
//   0x10..0x1C MASK  RW  稳定位掩码（helper data，公开）
//   0x20 FE_K        RW  输出组数 k（1..42）
//   0x24..0x30 SALT  RW  KDF 盐（公开随机数）
//   0x34..0x40 PURPOSE RW KDF 用途标签（如 "fara-weight-aes"）
//   0x44..0x4C NONCE RW  CTR nonce（96-bit；字节 0 在最低位）
//   0x50 CTR_INIT    RW  起始块号（v1 用 0）
//   0x54 PLAIN_WORDS RW  明文段字数 X_words+b_words
//   0x58..0x64 RESP_SW RW 调试用"合成 PUF 响应"（配合 CTRL[4]）
//   0x68..0x84 SWKEY  W  调试用软件密钥（**只写**，读回 0xDEADBEEF）
//
// ── 刻意不做的事（安全约束）────────────────────────────────────────────
//   本模块**不提供任何密钥/seed 回读**。派生出的密钥与 FE seed 都是密钥材料，
//   一旦能被 AXI 读走，就等于把密钥送进 PS 内存，且低熵下可被离线暴力破解。
//   冻结前的上板自测因此走**不泄露**的等价路径：
//     软件写 RESP_SW + MASK/SALT/PURPOSE -> FE -> KDF -> key，
//     然后核对下游"解密 + GEMM"是否仍与 golden 逐 bit 一致 ——
//     若 FE/KDF 与 Python 有半点偏差，密文解错，GEMM 立刻不匹配。
//   唯一写密钥的软件口 SWKEY 只在 key_mgr.locked==0 时有效，且只写不可读。
//
// 未映射偏移读回 0xDEADBEEF —— 沿用工程既有"默认安全"约定。
//=============================================================================
module puf_dec_axi_lite #(
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 8,
  parameter integer N_BITS             = 128
) (
  input  wire s_axi_aclk,
  input  wire s_axi_aresetn,

  input  wire [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr,
  input  wire [2:0]                      s_axi_awprot,
  input  wire                            s_axi_awvalid,
  output reg                             s_axi_awready,
  input  wire [C_S_AXI_DATA_WIDTH-1:0]   s_axi_wdata,
  input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  wire                            s_axi_wvalid,
  output reg                             s_axi_wready,
  output reg  [1:0]                      s_axi_bresp,
  output reg                             s_axi_bvalid,
  input  wire                            s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
  input  wire [2:0]                      s_axi_arprot,
  input  wire                            s_axi_arvalid,
  output reg                             s_axi_arready,
  output wire [C_S_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
  output reg  [1:0]                      s_axi_rresp,
  output reg                             s_axi_rvalid,
  input  wire                            s_axi_rready,

  // ---- 配置输出 ----
  output reg  [31:0]    cfg_ctrl,
  output reg  [31:0]    cfg_ctrl2,
  output reg  [N_BITS-1:0] cfg_mask,
  output reg  [N_BITS-1:0] cfg_helper,
  output reg  [7:0]     cfg_k,
  output reg  [127:0]   cfg_salt,
  output reg  [127:0]   cfg_purpose,
  output reg  [95:0]    cfg_nonce,
  output reg  [31:0]    cfg_ctr_init,
  output reg  [31:0]    cfg_plain_words,
  output reg  [N_BITS-1:0] cfg_resp_sw,
  output reg  [255:0]   cfg_sw_key,

  // ---- 状态输入 ----
  input  wire        st_fe_busy,
  input  wire        st_fe_done,
  input  wire        st_fe_err,
  input  wire        st_kdf_busy,
  input  wire        st_kdf_done,
  input  wire        st_key_locked,
  input  wire        st_aes_key_ready,
  input  wire        st_route_mode,
  input  wire [7:0]  st_fe_k_used,

  // ---- 常量 ----
  input  wire [31:0] const_version
);

  localparam integer AW = C_S_AXI_ADDR_WIDTH;

  localparam [7:0] A_CTRL        = 8'h00;
  localparam [7:0] A_STATUS      = 8'h04;
  localparam [7:0] A_VERSION     = 8'h08;
  localparam [7:0] A_CTRL2       = 8'h0C;
  localparam [7:0] A_MASK0       = 8'h10;
  localparam [7:0] A_MASK1       = 8'h14;
  localparam [7:0] A_MASK2       = 8'h18;
  localparam [7:0] A_MASK3       = 8'h1C;
  localparam [7:0] A_FE_K        = 8'h20;
  localparam [7:0] A_SALT0       = 8'h24;
  localparam [7:0] A_SALT1       = 8'h28;
  localparam [7:0] A_SALT2       = 8'h2C;
  localparam [7:0] A_SALT3       = 8'h30;
  localparam [7:0] A_PURP0       = 8'h34;
  localparam [7:0] A_PURP1       = 8'h38;
  localparam [7:0] A_PURP2       = 8'h3C;
  localparam [7:0] A_PURP3       = 8'h40;
  localparam [7:0] A_NONCE0      = 8'h44;
  localparam [7:0] A_NONCE1      = 8'h48;
  localparam [7:0] A_NONCE2      = 8'h4C;
  localparam [7:0] A_CTR_INIT    = 8'h50;
  localparam [7:0] A_PLAIN_WORDS = 8'h54;
  localparam [7:0] A_RESP0       = 8'h58;
  localparam [7:0] A_RESP1       = 8'h5C;
  localparam [7:0] A_RESP2       = 8'h60;
  localparam [7:0] A_RESP3       = 8'h64;
  localparam [7:0] A_SWKEY0      = 8'h68;   // 68..0x84 = SWKEY0..7
  localparam [7:0] A_HELP0       = 8'h88;
  localparam [7:0] A_HELP1       = 8'h8C;
  localparam [7:0] A_HELP2       = 8'h90;
  localparam [7:0] A_HELP3       = 8'h94;

  //--------------------------------------------------------------------
  // 写通道（照搬 puf_axi_lite 已验证的握手时序）
  //--------------------------------------------------------------------
  reg          aw_en;
  reg [AW-1:0] wr_addr;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      aw_en         <= 1'b1;
      wr_addr       <= {AW{1'b0}};
    end else begin
      if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        wr_addr       <= s_axi_awaddr;
        aw_en         <= 1'b0;
      end else begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid)
          aw_en <= 1'b1;
      end

      if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) begin
        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  wire wr_en = s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid;

  //--------------------------------------------------------------------
  // 寄存器文件
  //--------------------------------------------------------------------
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_ctrl        <= 32'd0;
      cfg_ctrl2       <= 32'd0;
      cfg_mask        <= {N_BITS{1'b0}};
      cfg_helper      <= {N_BITS{1'b0}};
      cfg_k           <= 8'd22;           // 默认 22 组（enrollment 会按实测覆盖）
      cfg_salt        <= 128'd0;
      cfg_purpose     <= 128'd0;
      cfg_nonce       <= 96'd0;
      cfg_ctr_init    <= 32'd0;
      cfg_plain_words <= 32'd0;
      cfg_resp_sw     <= {N_BITS{1'b0}};
      cfg_sw_key      <= 256'd0;
    end else begin
      // ---- 自清位（写 1 只维持一拍，变成脉冲）----
      cfg_ctrl[2]  <= 1'b0;     // soft_rst
      cfg_ctrl[3]  <= 1'b0;     // ctr_load
      cfg_ctrl2[1] <= 1'b0;     // sw_key_load

      if (wr_en) begin
        case (wr_addr[7:0])
          A_CTRL: begin
            cfg_ctrl[0] <= s_axi_wdata[0];   // fe_start（电平，软件显式清）
            cfg_ctrl[2] <= s_axi_wdata[2];   // soft_rst（脉冲）
            cfg_ctrl[3] <= s_axi_wdata[3];   // ctr_load（脉冲）
            cfg_ctrl[4] <= s_axi_wdata[4];   // dbg_use_sw_resp
          end
          A_CTRL2: begin
            cfg_ctrl2[0] <= s_axi_wdata[0];  // route_mode
            cfg_ctrl2[1] <= s_axi_wdata[1];  // sw_key_load（脉冲）
          end
          A_MASK0: cfg_mask[31:0]    <= s_axi_wdata;
          A_MASK1: cfg_mask[63:32]   <= s_axi_wdata;
          A_MASK2: cfg_mask[95:64]   <= s_axi_wdata;
          A_MASK3: cfg_mask[127:96]  <= s_axi_wdata;
          A_FE_K:  cfg_k             <= s_axi_wdata[7:0];
          A_SALT0: cfg_salt[31:0]    <= s_axi_wdata;
          A_SALT1: cfg_salt[63:32]   <= s_axi_wdata;
          A_SALT2: cfg_salt[95:64]   <= s_axi_wdata;
          A_SALT3: cfg_salt[127:96]  <= s_axi_wdata;
          A_PURP0: cfg_purpose[31:0]   <= s_axi_wdata;
          A_PURP1: cfg_purpose[63:32]  <= s_axi_wdata;
          A_PURP2: cfg_purpose[95:64]  <= s_axi_wdata;
          A_PURP3: cfg_purpose[127:96] <= s_axi_wdata;
          A_NONCE0: cfg_nonce[31:0]   <= s_axi_wdata;
          A_NONCE1: cfg_nonce[63:32]  <= s_axi_wdata;
          A_NONCE2: cfg_nonce[95:64]  <= s_axi_wdata;
          A_CTR_INIT:    cfg_ctr_init    <= s_axi_wdata;
          A_PLAIN_WORDS: cfg_plain_words <= s_axi_wdata;
          A_RESP0: cfg_resp_sw[31:0]   <= s_axi_wdata;
          A_RESP1: cfg_resp_sw[63:32]  <= s_axi_wdata;
          A_RESP2: cfg_resp_sw[95:64]  <= s_axi_wdata;
          A_RESP3: cfg_resp_sw[127:96] <= s_axi_wdata;
          A_HELP0: cfg_helper[31:0]    <= s_axi_wdata;
          A_HELP1: cfg_helper[63:32]   <= s_axi_wdata;
          A_HELP2: cfg_helper[95:64]   <= s_axi_wdata;
          A_HELP3: cfg_helper[127:96]  <= s_axi_wdata;
          default: begin
            // SWKEY0..7：只写不可读
            if (wr_addr[7:0] >= A_SWKEY0 && wr_addr[7:0] <= 8'h84) begin
              case (wr_addr[4:2])
                3'd0: cfg_sw_key[31:0]    <= s_axi_wdata;
                3'd1: cfg_sw_key[63:32]   <= s_axi_wdata;
                3'd2: cfg_sw_key[95:64]   <= s_axi_wdata;
                3'd3: cfg_sw_key[127:96]  <= s_axi_wdata;
                3'd4: cfg_sw_key[159:128] <= s_axi_wdata;
                3'd5: cfg_sw_key[191:160] <= s_axi_wdata;
                3'd6: cfg_sw_key[223:192] <= s_axi_wdata;
                3'd7: cfg_sw_key[255:224] <= s_axi_wdata;
                default: ;
              endcase
            end
          end
        endcase
      end
    end
  end

  wire [31:0] status = {16'd0, st_fe_k_used, st_route_mode, st_aes_key_ready,
                        st_key_locked, st_kdf_done, st_kdf_busy, st_fe_err,
                        st_fe_done, st_fe_busy};

  //--------------------------------------------------------------------
  // 读通道
  //
  // 关键（与 puf_axi_lite 同一教训）：R 数据必须**寄存器锁存**，绝不组合于读地址。
  // AXI4-Lite 要求 RVALID 期间数据稳定；且只在"上一笔 R 已被取走"时才接受新 AR。
  // ── SWKEY / KEY 类偏移一律不进 read case，落 default -> 读回 0xDEADBEEF。
  //--------------------------------------------------------------------
  reg [31:0] rd_mux;
  always @(*) begin
    case (s_axi_araddr[7:0])
      A_CTRL:        rd_mux = cfg_ctrl;
      A_STATUS:      rd_mux = status;
      A_VERSION:     rd_mux = const_version;
      A_CTRL2:       rd_mux = cfg_ctrl2;
      A_MASK0:       rd_mux = cfg_mask[31:0];
      A_MASK1:       rd_mux = cfg_mask[63:32];
      A_MASK2:       rd_mux = cfg_mask[95:64];
      A_MASK3:       rd_mux = cfg_mask[127:96];
      A_FE_K:        rd_mux = {24'd0, cfg_k};
      A_SALT0:       rd_mux = cfg_salt[31:0];
      A_SALT1:       rd_mux = cfg_salt[63:32];
      A_SALT2:       rd_mux = cfg_salt[95:64];
      A_SALT3:       rd_mux = cfg_salt[127:96];
      A_PURP0:       rd_mux = cfg_purpose[31:0];
      A_PURP1:       rd_mux = cfg_purpose[63:32];
      A_PURP2:       rd_mux = cfg_purpose[95:64];
      A_PURP3:       rd_mux = cfg_purpose[127:96];
      A_NONCE0:      rd_mux = cfg_nonce[31:0];
      A_NONCE1:      rd_mux = cfg_nonce[63:32];
      A_NONCE2:      rd_mux = cfg_nonce[95:64];
      A_CTR_INIT:    rd_mux = cfg_ctr_init;
      A_PLAIN_WORDS: rd_mux = cfg_plain_words;
      A_RESP0:       rd_mux = cfg_resp_sw[31:0];
      A_RESP1:       rd_mux = cfg_resp_sw[63:32];
      A_RESP2:       rd_mux = cfg_resp_sw[95:64];
      A_RESP3:       rd_mux = cfg_resp_sw[127:96];
      A_HELP0:       rd_mux = cfg_helper[31:0];
      A_HELP1:       rd_mux = cfg_helper[63:32];
      A_HELP2:       rd_mux = cfg_helper[95:64];
      A_HELP3:       rd_mux = cfg_helper[127:96];
      default:       rd_mux = 32'hDEAD_BEEF;   // 含 SWKEY -> 只写不可读
    endcase
  end

  reg [31:0] rdata_q;
  assign s_axi_rdata = rdata_q;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= 2'b00;
      rdata_q       <= 32'h0000_0000;
    end else begin
      if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        rdata_q       <= rd_mux;
      end else begin
        s_axi_arready <= 1'b0;
      end

      if (s_axi_arready && s_axi_arvalid) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
