`timescale 1ns / 1ps
// 禁止隐式网线：端口连线写错名字会直接报错，而不是静默产生悬空网线
`default_nettype none
//=============================================================================
// gemm_up_proj_top —— up_proj GEMM 的 AXI 顶层封装（打包成 Vivado IP 用）
//
//   S_AXI  (AXI4-Lite, 8-bit 字地址) : 控制/状态寄存器，映射见 gemm_up_proj_axi_lite.sv
//   S_AXIS (AXI4-Stream, 64-bit)     : 输入 [X | b | W]，低 32 位字先发
//   M_AXIS (AXI4-Stream, 64-bit)     : 输出 Y，低 32 位字先发
//
// 单时钟域：s_axi_aclk 同时驱动 AXI-Lite 与两条流。
// 复位：axi_lite 与 core 均为低有效复位，共用 s_axi_aresetn。
//
// 数据布局契约与浮点累加顺序契约见 rtl/gemm_up_proj_core.sv 文件头。
// 本模块只做连线，不含任何逻辑；行为等价于 sim/tb_gemm_up_proj.sv 里
// 直接例化 axi_lite + core 两个模块。
//
// FaR（Forget-and-Rewire）：
//   AXI-Lite 侧 0x30~0x54 的 FaRMap 寄存器组经这里透传给 core，core 再交给
//   far_reroute 引擎，在 S_LOAD_X 结束后就地改写 xbuf 里的激活。
//   权重侧的 shadow（dead 列 = donor 列）由 PC 离线烘焙进 board_W*.bin，
//   硬件不再改动权重。
//
// 端口命名刻意遵循 Xilinx 接口推断规则：
//   s_axi_*  -> S_AXI (AXI4-Lite)
//   s_axis_* -> S_AXIS (AXI4-Stream)
//   m_axis_* -> M_AXIS (AXI4-Stream)
// 以便 package_ip 时自动识别协议、在 BD 里自动连线。
//=============================================================================
module gemm_up_proj_top #(
  parameter integer M_TILE  = 16,     // 并行输出行数 = MAC lane 数
  parameter integer M_TOTAL = 3072,   // 输出总行数（GPT-2 small c_fc out_features）
  parameter integer K_MAX   = 768,    // 规约深度上限（c_fc in_features）
  parameter integer N_MAX   = 32,     // 单次事务 token 数上限
  parameter integer G       = 8,      // 部分和链数，硬约束 G >= ADD_LAT+1
  parameter integer ADD_LAT = 4,      // 与 fp32_add_ip 的 C_Latency 一致
  parameter integer MUL_LAT = 8,      // 与 fp32_mul_ip 的 C_Latency 一致
  parameter integer N_ENTRY_MAX = 16, // FaRMap 条目数上限
  parameter integer MAX_DEAD    = 2,  // 每条目 dead lane 上限（div∈{2,3}）
  parameter integer C_S_AXI_DATA_WIDTH = 32,
  parameter integer C_S_AXI_ADDR_WIDTH = 8,
  parameter integer AXIS_TDATA_WIDTH   = 64
) (
  //-------------------------------------------------------------------
  // 时钟 / 复位
  //-------------------------------------------------------------------
  input  wire s_axi_aclk,
  input  wire s_axi_aresetn,

  //-------------------------------------------------------------------
  // AXI4-Lite 从机（控制/状态）
  //-------------------------------------------------------------------
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  wire [2:0]                       s_axi_awprot,
  input  wire                             s_axi_awvalid,
  output wire                             s_axi_awready,
  input  wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_wdata,
  input  wire [C_S_AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
  input  wire                             s_axi_wvalid,
  output wire                             s_axi_wready,
  output wire [1:0]                       s_axi_bresp,
  output wire                             s_axi_bvalid,
  input  wire                             s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
  input  wire [2:0]                       s_axi_arprot,
  input  wire                             s_axi_arvalid,
  output wire                             s_axi_arready,
  output wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_rdata,
  output wire [1:0]                       s_axi_rresp,
  output wire                             s_axi_rvalid,
  input  wire                             s_axi_rready,

  //-------------------------------------------------------------------
  // AXI4-Stream 从机：输入 [X | b | W]
  // tkeep 由上游给全 1（本核按偶数字数消费，末拍不截断）
  //-------------------------------------------------------------------
  input  wire [AXIS_TDATA_WIDTH-1:0] s_axis_tdata,
  input  wire [AXIS_TDATA_WIDTH/8-1:0] s_axis_tkeep,
  input  wire                        s_axis_tvalid,
  output wire                        s_axis_tready,
  input  wire                        s_axis_tlast,

  //-------------------------------------------------------------------
  // AXI4-Stream 主机：输出 Y
  //-------------------------------------------------------------------
  output wire [AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
  output wire [AXIS_TDATA_WIDTH/8-1:0] m_axis_tkeep,
  output wire                        m_axis_tvalid,
  input  wire                        m_axis_tready,
  output wire                        m_axis_tlast
);

  // 上游 tkeep 本核不参与运算（契约要求偶数字数、末拍无空洞）。
  // 显式引用一次，避免综合报 unused 警告干扰。
  wire unused_s_axis_tkeep = &s_axis_tkeep;

  // ---- axi_lite <-> core 之间的内部连线 ----
  wire [31:0] cfg_ctrl_w, cfg_k_w, cfg_n_w, cfg_layer_w;
  wire [3:0]  c_state;
  wire        c_busy, c_done, c_err;
  wire [31:0] c_inw, c_outw, c_tile;

  // ---- FaRMap 连线（axi_lite -> core -> far_reroute）----
  wire [31:0] far_ctrl_w, far_nent_w;
  wire [15:0] far_a_w   [0:N_ENTRY_MAX-1];
  wire [31:0] far_inv_w [0:N_ENTRY_MAX-1];
  wire [1:0]  far_nd_w  [0:N_ENTRY_MAX-1];
  wire [15:0] far_d0_w  [0:N_ENTRY_MAX-1];
  wire [15:0] far_d1_w  [0:N_ENTRY_MAX-1];
  wire [31:0] c_far_hits;
  wire [2:0]  c_far_phase;

  //===========================================================================
  // AXI4-Lite 控制/状态寄存器组
  //===========================================================================
  gemm_up_proj_axi_lite #(
    .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
    .N_ENTRY_MAX        (N_ENTRY_MAX)
  ) u_axi (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .cfg_ctrl      (cfg_ctrl_w),
    .cfg_k_cols    (cfg_k_w),
    .cfg_n_tokens  (cfg_n_w),
    .cfg_layer_id  (cfg_layer_w),
    .cfg_far_ctrl  (far_ctrl_w),
    .cfg_far_nent  (far_nent_w),
    .cfg_ent_a     (far_a_w),
    .cfg_ent_inv   (far_inv_w),
    .cfg_ent_nd    (far_nd_w),
    .cfg_ent_d0    (far_d0_w),
    .cfg_ent_d1    (far_d1_w),
    .st_state      (c_state),
    .st_busy       (c_busy),
    .st_done       (c_done),
    .st_err        (c_err),
    .st_in_words   (c_inw),
    .st_out_words  (c_outw),
    .st_tile_idx   (c_tile),
    .st_far_hits   (c_far_hits),
    .st_far_phase  (c_far_phase),
    .const_m_rows  (M_TILE[31:0]),
    .const_n_tiles (M_TOTAL / M_TILE),
    .const_version (32'h0002_0000)
  );

  //===========================================================================
  // GEMM 计算核心
  //===========================================================================
  gemm_up_proj_core #(
    .M_TILE       (M_TILE),
    .M_TOTAL      (M_TOTAL),
    .K_MAX        (K_MAX),
    .N_MAX        (N_MAX),
    .G            (G),
    .ADD_LAT      (ADD_LAT),
    .MUL_LAT      (MUL_LAT),
    .N_ENTRY_MAX  (N_ENTRY_MAX),
    .MAX_DEAD     (MAX_DEAD),
    .AXIS_TDATA_WIDTH (AXIS_TDATA_WIDTH)
  ) u_gemm (
    .clk            (s_axi_aclk),
    .rst_n          (s_axi_aresetn),
    .cfg_k_cols     (cfg_k_w),
    .cfg_n_tokens   (cfg_n_w),
    .cfg_start      (cfg_ctrl_w[0]),
    .cfg_soft_rst   (cfg_ctrl_w[1]),
    .cfg_far_en     (far_ctrl_w[0]),
    .cfg_far_n      (far_nent_w),
    .cfg_ent_a      (far_a_w),
    .cfg_ent_inv    (far_inv_w),
    .cfg_ent_nd     (far_nd_w),
    .cfg_ent_d0     (far_d0_w),
    .cfg_ent_d1     (far_d1_w),
    .st_in_words    (c_inw),
    .st_out_words   (c_outw),
    .st_tile_idx    (c_tile),
    .st_state       (c_state),
    .st_busy        (c_busy),
    .st_done        (c_done),
    .st_err         (c_err),
    .st_far_hits    (c_far_hits),
    .st_far_phase   (c_far_phase),
    .s_axis_in_tdata  (s_axis_tdata),
    .s_axis_in_tvalid (s_axis_tvalid),
    .s_axis_in_tready (s_axis_tready),
    .s_axis_in_tlast  (s_axis_tlast),
    .m_axis_out_tdata  (m_axis_tdata),
    .m_axis_out_tvalid (m_axis_tvalid),
    .m_axis_out_tready (m_axis_tready),
    .m_axis_out_tlast  (m_axis_tlast)
  );

  // 输出恒为满拍（每拍 2 个 fp32 字，无空洞）
  assign m_axis_tkeep = {(AXIS_TDATA_WIDTH/8){1'b1}};

endmodule

`default_nettype wire
