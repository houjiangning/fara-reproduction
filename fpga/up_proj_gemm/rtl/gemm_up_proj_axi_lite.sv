`timescale 1ns / 1ps
//=============================================================================
// gemm_up_proj_axi_lite —— AXI4-Lite 从机 + 控制/状态寄存器组
//
// 寄存器映射（字节偏移，32-bit）：
//   0x00 CTRL      W  [0] start(电平,写0清 done)  [1] soft_rst(自清1拍)  [2] irq_en
//   0x04 STATUS    R  [0] busy  [1] done  [2] err  [3] irq  [7:4] state
//   0x08 M_ROWS    R  每趟输出行数 M_TILE
//   0x0C K_COLS    RW 规约深度 K (1..K_MAX)
//   0x10 N_TOKENS  RW 本次 token 数 N (1..N_MAX)
//   0x14 LAYER_ID  RW 目标层标识（给 PS 做层识别，PL 不参与运算）
//   0x18 VERSION   R  0x0002_0000
//   0x1C N_TILES   R  总趟数 M_TOTAL/M_TILE
//   0x20 IN_WORDS  R  已消费的输入 fp32 字数
//   0x24 OUT_WORDS R  已产出的输出 fp32 字数
//   0x28 TILE_IDX  R  当前趟号
//   0x2C STATE     R  当前 FSM 状态码（同 STATUS[7:4]）
//
// ---- FaRMap 寄存器组（间接寻址：先写 FAR_IDX，再读写 FAR_A/INV/ND/D0/D1）----
//   0x30 FAR_CTRL  RW [0] far_en（0=基线直通，1=启用激活重路由）
//   0x34 FAR_NENT  RW [4:0] 条目数 n_entries (0..16)
//   0x38 FAR_IDX   RW [3:0] 当前条目下标（后续 FAR_* 的读写目标）
//   0x3C FAR_A     RW [15:0] 敏感输入通道 A（col）
//   0x40 FAR_INV   RW fp32  1/div 的位模式（div=2 → 0x3F000000）
//   0x44 FAR_ND    RW [1:0] 该条目 dead lane 条数（1..2）
//   0x48 FAR_D0    RW [15:0] dead 通道 #0
//   0x4C FAR_D1    RW [15:0] dead 通道 #1
//   0x50 FAR_HITS  R  本次重路由实际改写元素数（诊断）
//   0x54 FAR_PHASE R  far_reroute 相位码（诊断）
//
// 约定：CTRL.start 为电平信号，核在 start=1 且 done=0 时启动一次事务；
//       核置 done=1 后保持，软件写 CTRL.start=0（或写 soft_rst）即清 done。
//
// 间接寻址的时序：wr_en 是 aw/w 握手完成那一拍的单周期脉冲，wr_addr 在同一
// 拍有效；cfg_far_idx 由前一次事务写入，因此写 FAR_A..FAR_D1 时索引一定就绪。
// 软件顺序必须是：写 FAR_IDX -> 写该条目的 5 个字段。
//=============================================================================
module gemm_up_proj_axi_lite #(
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 8,
  parameter integer N_ENTRY_MAX        = 16
) (
  input  wire s_axi_aclk,
  input  wire s_axi_aresetn,

  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
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
  output reg  [C_S_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
  output reg  [1:0]                      s_axi_rresp,
  output reg                             s_axi_rvalid,
  input  wire                            s_axi_rready,

  // ---- 用户侧：配置 ----
  output reg  [31:0] cfg_ctrl,
  output reg  [31:0] cfg_k_cols,
  output reg  [31:0] cfg_n_tokens,
  output reg  [31:0] cfg_layer_id,

  // ---- 用户侧：FaRMap 配置（直达 core / far_reroute）----
  output reg  [31:0] cfg_far_ctrl,                              // [0] far_en
  output reg  [31:0] cfg_far_nent,                              // 条目数
  output reg  [15:0] cfg_ent_a   [0:N_ENTRY_MAX-1],             // 敏感通道 A
  output reg  [31:0] cfg_ent_inv [0:N_ENTRY_MAX-1],             // fp32 1/div
  output reg  [1:0]  cfg_ent_nd  [0:N_ENTRY_MAX-1],             // dead 条数
  output reg  [15:0] cfg_ent_d0  [0:N_ENTRY_MAX-1],             // dead 通道 #0
  output reg  [15:0] cfg_ent_d1  [0:N_ENTRY_MAX-1],             // dead 通道 #1

  // ---- 用户侧：状态 ----
  input  wire [3:0]  st_state,
  input  wire        st_busy,
  input  wire        st_done,
  input  wire        st_err,
  input  wire [31:0] st_in_words,
  input  wire [31:0] st_out_words,
  input  wire [31:0] st_tile_idx,
  input  wire [31:0] st_far_hits,
  input  wire [2:0]  st_far_phase,

  // ---- 用户侧：常量 ----
  input  wire [31:0] const_m_rows,
  input  wire [31:0] const_n_tiles,
  input  wire [31:0] const_version
);

  localparam integer AW = C_S_AXI_ADDR_WIDTH;

  // 地址译码（字地址）
  localparam [7:0] ADDR_CTRL      = 8'h00;
  localparam [7:0] ADDR_STATUS    = 8'h04;
  localparam [7:0] ADDR_M_ROWS    = 8'h08;
  localparam [7:0] ADDR_K_COLS    = 8'h0C;
  localparam [7:0] ADDR_N_TOKENS  = 8'h10;
  localparam [7:0] ADDR_LAYER_ID  = 8'h14;
  localparam [7:0] ADDR_VERSION   = 8'h18;
  localparam [7:0] ADDR_N_TILES   = 8'h1C;
  localparam [7:0] ADDR_IN_WORDS  = 8'h20;
  localparam [7:0] ADDR_OUT_WORDS = 8'h24;
  localparam [7:0] ADDR_TILE_IDX  = 8'h28;
  localparam [7:0] ADDR_STATE     = 8'h2C;

  localparam [7:0] ADDR_FAR_CTRL  = 8'h30;
  localparam [7:0] ADDR_FAR_NENT  = 8'h34;
  localparam [7:0] ADDR_FAR_IDX   = 8'h38;
  localparam [7:0] ADDR_FAR_A     = 8'h3C;
  localparam [7:0] ADDR_FAR_INV   = 8'h40;
  localparam [7:0] ADDR_FAR_ND    = 8'h44;
  localparam [7:0] ADDR_FAR_D0    = 8'h48;
  localparam [7:0] ADDR_FAR_D1    = 8'h4C;
  localparam [7:0] ADDR_FAR_HITS  = 8'h50;
  localparam [7:0] ADDR_FAR_PHASE = 8'h54;

  //--------------------------------------------------------------------
  // 写通道
  //--------------------------------------------------------------------
  reg aw_en;
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

  // FaRMap 间接寻址索引
  reg [3:0] cfg_far_idx;

  integer ri;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cfg_ctrl     <= 32'd0;
      cfg_k_cols   <= 32'd768;
      cfg_n_tokens <= 32'd1;
      cfg_layer_id <= 32'd0;
      cfg_far_ctrl <= 32'd0;
      cfg_far_nent <= 32'd0;
      cfg_far_idx  <= 4'd0;
      for (ri = 0; ri < N_ENTRY_MAX; ri = ri + 1) begin
        cfg_ent_a[ri]   <= 16'd0;
        cfg_ent_inv[ri] <= 32'd0;
        cfg_ent_nd[ri]  <= 2'd0;
        cfg_ent_d0[ri]  <= 16'd0;
        cfg_ent_d1[ri]  <= 16'd0;
      end
    end else begin
      // soft_rst 自清：写完下一拍自动归零
      cfg_ctrl[1] <= 1'b0;
      if (wr_en) begin
        case (wr_addr[7:0])
          ADDR_CTRL: begin
            cfg_ctrl[0] <= s_axi_wdata[0];
            cfg_ctrl[1] <= s_axi_wdata[1];
            cfg_ctrl[2] <= s_axi_wdata[2];
          end
          ADDR_K_COLS:   cfg_k_cols   <= s_axi_wdata;
          ADDR_N_TOKENS: cfg_n_tokens <= s_axi_wdata;
          ADDR_LAYER_ID: cfg_layer_id <= s_axi_wdata;

          ADDR_FAR_CTRL: cfg_far_ctrl <= {31'd0, s_axi_wdata[0]};
          ADDR_FAR_NENT: cfg_far_nent <= s_axi_wdata;
          ADDR_FAR_IDX:  cfg_far_idx  <= s_axi_wdata[3:0];
          ADDR_FAR_A:    cfg_ent_a  [cfg_far_idx] <= s_axi_wdata[15:0];
          ADDR_FAR_INV:  cfg_ent_inv[cfg_far_idx] <= s_axi_wdata;
          ADDR_FAR_ND:   cfg_ent_nd [cfg_far_idx] <= s_axi_wdata[1:0];
          ADDR_FAR_D0:   cfg_ent_d0 [cfg_far_idx] <= s_axi_wdata[15:0];
          ADDR_FAR_D1:   cfg_ent_d1 [cfg_far_idx] <= s_axi_wdata[15:0];
          default: ;
        endcase
      end
    end
  end

  //--------------------------------------------------------------------
  // 读通道
  //--------------------------------------------------------------------
  reg [AW-1:0] rd_addr;
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= 2'b00;
      rd_addr       <= {AW{1'b0}};
    end else begin
      if (!s_axi_arready && s_axi_arvalid) begin
        s_axi_arready <= 1'b1;
        rd_addr       <= s_axi_araddr;
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

  wire [31:0] status = {28'd0, (cfg_ctrl[2] & st_done), st_err, st_done, st_busy};

  always @(*) begin
    case (rd_addr[7:0])
      ADDR_CTRL:      s_axi_rdata = cfg_ctrl;
      ADDR_STATUS:    s_axi_rdata = {24'd0, st_state, 4'd0} | status;
      ADDR_M_ROWS:    s_axi_rdata = const_m_rows;
      ADDR_K_COLS:    s_axi_rdata = cfg_k_cols;
      ADDR_N_TOKENS:  s_axi_rdata = cfg_n_tokens;
      ADDR_LAYER_ID:  s_axi_rdata = cfg_layer_id;
      ADDR_VERSION:   s_axi_rdata = const_version;
      ADDR_N_TILES:   s_axi_rdata = const_n_tiles;
      ADDR_IN_WORDS:  s_axi_rdata = st_in_words;
      ADDR_OUT_WORDS: s_axi_rdata = st_out_words;
      ADDR_TILE_IDX:  s_axi_rdata = st_tile_idx;
      ADDR_STATE:     s_axi_rdata = {28'd0, st_state};

      ADDR_FAR_CTRL:  s_axi_rdata = cfg_far_ctrl;
      ADDR_FAR_NENT:  s_axi_rdata = cfg_far_nent;
      ADDR_FAR_IDX:   s_axi_rdata = {28'd0, cfg_far_idx};
      ADDR_FAR_A:     s_axi_rdata = {16'd0, cfg_ent_a  [cfg_far_idx]};
      ADDR_FAR_INV:   s_axi_rdata = cfg_ent_inv[cfg_far_idx];
      ADDR_FAR_ND:    s_axi_rdata = {30'd0, cfg_ent_nd [cfg_far_idx]};
      ADDR_FAR_D0:    s_axi_rdata = {16'd0, cfg_ent_d0 [cfg_far_idx]};
      ADDR_FAR_D1:    s_axi_rdata = {16'd0, cfg_ent_d1 [cfg_far_idx]};
      ADDR_FAR_HITS:  s_axi_rdata = st_far_hits;
      ADDR_FAR_PHASE: s_axi_rdata = {29'd0, st_far_phase};

      default:        s_axi_rdata = 32'hDEAD_BEEF;
    endcase
  end

endmodule
