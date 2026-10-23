`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// puf_axi_lite —— PUF 的 AXI4-Lite 从机 + 控制/状态寄存器组
//
// 寄存器映射（字节偏移，32-bit），基址 0xA0030000 / 64 KB：
//   0x00 CTRL      W  [0] start(电平,写0清 done)  [1] soft_rst(自清1拍)
//   0x04 STATUS    R  [0] busy  [1] done  [2] err  [7:4] state
//   0x08 NBITS     R  PUF 位宽（128）
//   0x0C NWORDS    R  响应字数（NBITS/32 = 4）
//   0x10 N_SAMP    RW 采样次数 M（**必须为奇数**，上限 2^CNT_W-1=31）
//   0x14 T_FORCE   RW 强制态保持周期数
//   0x18 T_SETTLE  RW 释放后等待收敛周期数
//   0x1C VERSION   R  0x0001_0000
//   0x20 NSAMP_DONE R 本次实际完成的采样次数
//   0x24 STABLE_CNT R 稳定位数 = NBITS - popcount(UNAN)
//
// ---- 响应读取（间接寻址：先写 IDX，再读 DATA / UNAN）----
//   0x28 IDX       RW [3:0] 当前字下标（0..NWORDS-1，bit0 对应响应最低位）
//   0x2C DATA      R  该字的多数表决响应
//   0x30 UNAN      R  该字的非一致掩码（1 = 该位在本次序列内翻转，不可用）
//
// 约定与 GEMM 侧一致：
//   · CTRL.start 为电平信号：start=1 且 done=0 时启动一次采样；
//     done 置 1 后保持，软件写 start=0（或 soft_rst）即清 done。
//   · 未映射偏移读回 0xDEADBEEF —— 这是既有的"默认安全"约定，
//     后续若加密钥类只写寄存器，只要不进 read case 即可自动不泄露。
//=============================================================================
module puf_axi_lite #(
  parameter integer C_S_AXI_DATA_WIDTH  = 32,
  parameter integer C_S_AXI_ADDR_WIDTH  = 8,
  parameter integer N_WORD              = 4
) (
  input  wire s_axi_aclk,
  input  wire s_axi_aresetn,

  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  wire [2:0]                       s_axi_awprot,
  input  wire                             s_axi_awvalid,
  output reg                              s_axi_awready,
  input  wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_wdata,
  input  wire [C_S_AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
  input  wire                             s_axi_wvalid,
  output reg                              s_axi_wready,
  output reg  [1:0]                       s_axi_bresp,
  output reg                              s_axi_bvalid,
  input  wire                             s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
  input  wire [2:0]                       s_axi_arprot,
  input  wire                             s_axi_arvalid,
  output reg                              s_axi_arready,
  output wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_rdata,
  output reg  [1:0]                       s_axi_rresp,
  output reg                              s_axi_rvalid,
  input  wire                             s_axi_rready,

  // ---- 用户侧：配置 ----
  output reg  [31:0] cfg_ctrl,
  output reg  [31:0] cfg_n_samp,
  output reg  [31:0] cfg_t_force,
  output reg  [31:0] cfg_t_settle,

  // ---- 用户侧：响应（逐字间接读出）----
  input  wire [N_WORD*32-1:0] resp_word_bus,   // 拼接的响应（字 0 在最低位）
  input  wire [N_WORD*32-1:0] unan_word_bus,   // 拼接的非一致掩码

  // ---- 用户侧：状态 ----
  input  wire        st_busy,
  input  wire        st_done,
  input  wire        st_err,
  input  wire [3:0]  st_state,
  input  wire [31:0] st_nsamp_done,
  input  wire [31:0] st_stable_cnt,

  // ---- 用户侧：常量 ----
  input  wire [31:0] const_nbits,
  input  wire [31:0] const_version
);

  localparam integer AW = C_S_AXI_ADDR_WIDTH;

  localparam [7:0] ADDR_CTRL        = 8'h00;
  localparam [7:0] ADDR_STATUS      = 8'h04;
  localparam [7:0] ADDR_NBITS       = 8'h08;
  localparam [7:0] ADDR_NWORDS      = 8'h0C;
  localparam [7:0] ADDR_N_SAMP      = 8'h10;
  localparam [7:0] ADDR_T_FORCE     = 8'h14;
  localparam [7:0] ADDR_T_SETTLE    = 8'h18;
  localparam [7:0] ADDR_VERSION     = 8'h1C;
  localparam [7:0] ADDR_NSAMP_DONE  = 8'h20;
  localparam [7:0] ADDR_STABLE_CNT  = 8'h24;
  localparam [7:0] ADDR_IDX         = 8'h28;
  localparam [7:0] ADDR_DATA        = 8'h2C;
  localparam [7:0] ADDR_UNAN        = 8'h30;

  //--------------------------------------------------------------------
  // 写通道
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

  // 间接寻址索引
  reg [3:0] cfg_idx;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_ctrl      <= 32'd0;
      cfg_n_samp    <= 32'd9;             // 默认 9 次采样（奇数）
      cfg_t_force   <= 32'd8;
      cfg_t_settle  <= 32'd64;
      cfg_idx       <= 4'd0;
    end else begin
      // soft_rst 自清：写完下一拍自动归零
      cfg_ctrl[1] <= 1'b0;
      if (wr_en) begin
        case (wr_addr[7:0])
          ADDR_CTRL: begin
            cfg_ctrl[0] <= s_axi_wdata[0];
            cfg_ctrl[1] <= s_axi_wdata[1];
          end
          ADDR_N_SAMP:   cfg_n_samp   <= s_axi_wdata;
          ADDR_T_FORCE:  cfg_t_force  <= s_axi_wdata;
          ADDR_T_SETTLE: cfg_t_settle <= s_axi_wdata;
          ADDR_IDX:      cfg_idx      <= s_axi_wdata[3:0];
          default: ;
        endcase
      end
    end
  end

  wire [31:0] status = {24'd0, st_state, 4'd0} |
                       {28'd0, (cfg_ctrl[0] & st_done), st_err, st_done, st_busy};

  // 间接读出的字
  wire [31:0] resp_word = resp_word_bus[cfg_idx*32 +: 32];
  wire [31:0] unan_word = unan_word_bus[cfg_idx*32 +: 32];

  //--------------------------------------------------------------------
  // 读通道
  //
  // 关键：R 数据必须**寄存器锁存**，绝不能组合于读地址。
  //   AXI4-Lite 要求 RVALID 有效期间 R 数据保持稳定，直到 RREADY 握手。
  //   若 s_axi_rdata 直接组合于地址（旧实现），背靠背读不同地址时地址一更新
  //   就会改写上一次的读出值 —— 违反 R 数据保持语义；接入密钥 / helper data
  //   类寄存器后会读到脏数据。
  //   现改为：在 AR 握手沿把「该地址对应的数据」锁进 rdata_q，RVALID 期间
  //   只输出 rdata_q；且**仅在 rvalid=0（上一笔 R 已被取走）时才接受新 AR**，
  //   从而保证 rdata_q 在整个 RVALID 窗口内恒定，不会被后续 AR 改写。
  //--------------------------------------------------------------------
  // 组合译码：对本次 AR 呈现的地址算出读数据，供握手沿锁存
  reg [31:0] rd_mux;
  always @(*) begin
    case (s_axi_araddr[7:0])
      ADDR_CTRL:       rd_mux = cfg_ctrl;
      ADDR_STATUS:     rd_mux = status;
      ADDR_NBITS:      rd_mux = const_nbits;
      ADDR_NWORDS:     rd_mux = N_WORD[31:0];
      ADDR_N_SAMP:     rd_mux = cfg_n_samp;
      ADDR_T_FORCE:    rd_mux = cfg_t_force;
      ADDR_T_SETTLE:   rd_mux = cfg_t_settle;
      ADDR_VERSION:    rd_mux = const_version;
      ADDR_NSAMP_DONE: rd_mux = st_nsamp_done;
      ADDR_STABLE_CNT: rd_mux = st_stable_cnt;
      ADDR_IDX:        rd_mux = {28'd0, cfg_idx};
      ADDR_DATA:       rd_mux = resp_word;
      ADDR_UNAN:       rd_mux = unan_word;
      default:         rd_mux = 32'hDEAD_BEEF;
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
      // 仅在「无未取走的 R 数据」时接受新 AR，保证 RVALID 期间 rdata_q 恒定
      if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        rdata_q       <= rd_mux;         // 锁存本次读数据（此后不再随地址变化）
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