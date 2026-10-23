`timescale 1ns / 1ps
//=============================================================================
// puf_dec_bd —— 方案 B 加解密 / 密钥派生块的 BD module-reference 顶层
//                （**必须是纯 Verilog**，理由同 gemm_up_proj_bd.v / puf_bd.v）
//
// 组成（全部在 PL 内，密钥路径不经过任何 AXI）：
//   fuzzy_extract  : PUF 响应 -> 选位 + 3取2多数 -> seed
//   sha256_kdf     : key = SHA-256(seed || salt || purpose)
//   key_mgr        : 只写不可读密钥寄存器 + lock，key_new 驱动 AES 密钥扩展
//   wdec_stream    : [X|b] 明文直通 / [W] 经内部 aes256_ctr 解密 -> 送 GEMM
//   puf_dec_axi_lite: 控制/状态寄存器组，基址 0xA0020000
//
// 硬件链（软件只拉一根 fe_start，其余全在 RTL 里串起来）：
//   cfg_ctrl[0]=fe_start -> FE -> fe_done(=KDF start) -> KDF -> kdf_done
//     -> (上升沿脉冲) key_mgr.kdf_valid -> 密钥锁定 -> AES 密钥扩展
//
// 这样软件无法在 FE 与 KDF 之间插入竞争，也不会把 seed 暴露到任何寄存器。
//
// AXI4-Stream 方向：
//   s_axis <- DMA MM2S（[X|b|W] 拼接流）
//   m_axis -> axis_route2/aes -> GEMM s_axis
// route_mode_o 送给 axis_route2.mode（0=运行期, 1=provisioning）。
//=============================================================================
module puf_dec_bd #(
  parameter N_BITS     = 128,
  parameter FIFO_DEPTH = 32,
  parameter CTR_W      = 32
) (
  //-------------------------------------------------------------------
  input  wire        s_axi_aclk,
  input  wire        s_axi_aresetn,

  // ---- AXI4-Lite 从机 ----
  input  wire [7:0]  s_axi_awaddr,
  input  wire [2:0]  s_axi_awprot,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,
  input  wire [31:0] s_axi_wdata,
  input  wire [3:0]  s_axi_wstrb,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,
  input  wire [7:0]  s_axi_araddr,
  input  wire [2:0]  s_axi_arprot,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,

  // ---- AXI4-Stream 从机（DMA MM2S：[X|b|W]）----
  input  wire [63:0] s_axis_tdata,
  input  wire        s_axis_tvalid,
  output wire        s_axis_tready,
  input  wire        s_axis_tlast,

  // ---- AXI4-Stream 主机（-> axis_route2 -> GEMM s_axis）----
  output wire [63:0] m_axis_tdata,
  output wire        m_axis_tvalid,
  input  wire        m_axis_tready,
  output wire        m_axis_tlast,

  // ---- PUF 硬件响应（来自 puf_bd_0，fabric 网线，绝不经 AXI）----
  input  wire [N_BITS-1:0] puf_resp_i,
  input  wire [N_BITS-1:0] puf_unan_i,

  // ---- 选路模式（-> axis_route2.mode）----
  output wire        route_mode_o
);

  //-------------------------------------------------------------------
  // AXI-Lite 配置 / 状态
  //-------------------------------------------------------------------
  wire [31:0]    cfg_ctrl, cfg_ctrl2;
  wire [N_BITS-1:0] cfg_mask, cfg_helper, cfg_resp_sw;
  wire [7:0]     cfg_k;
  wire [127:0]   cfg_salt, cfg_purpose;
  wire [95:0]    cfg_nonce;
  wire [31:0]    cfg_ctr_init, cfg_plain_words;
  wire [255:0]   cfg_sw_key;

  wire        fe_busy, fe_done, fe_err;
  wire [7:0]  fe_k_used;
  wire        kdf_busy, kdf_done;
  wire        key_locked, aes_key_ready;

  //-------------------------------------------------------------------
  // 1) FE 输入：正常取 PUF 硬件响应；调试可换成软件合成响应
  //-------------------------------------------------------------------
  wire [N_BITS-1:0] fe_resp_in = cfg_ctrl[4] ? cfg_resp_sw : puf_resp_i;
  wire [N_BITS-1:0] fe_seed;

  fuzzy_extract #(
    .NBITS (N_BITS)
  ) u_fe (
    .clk      (s_axi_aclk),
    .rst_n    (s_axi_aresetn),
    .cfg_mask (cfg_mask),
    .cfg_helper (cfg_helper),
    .cfg_k    (cfg_k),
    .puf_resp (fe_resp_in),
    .start    (cfg_ctrl[0]),        // 软件唯一的"启动"位
    .busy     (fe_busy),
    .done     (fe_done),
    .err      (fe_err),
    .seed     (fe_seed),
    .k_used   (fe_k_used)
  );

  //-------------------------------------------------------------------
  // 2) KDF：start 直接接 fe_done（硬件链，软件无法插入竞争）
  //-------------------------------------------------------------------
  wire [255:0] kdf_digest;

  sha256_kdf u_kdf (
    .clk     (s_axi_aclk),
    .rst_n   (s_axi_aresetn),
    .start   (fe_done),
    .seed    (fe_seed),
    .salt    (cfg_salt),
    .purpose (cfg_purpose),
    .busy    (kdf_busy),
    .done    (kdf_done),
    .digest  (kdf_digest)
  );

  // kdf_done 是电平，必须转成**单拍脉冲**喂 key_mgr，
  // 否则 key_new 会一直拉高，aes256_core 的密钥扩展会被反复重启、永远 ready 不了。
  reg kdf_done_r;
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) kdf_done_r <= 1'b0;
    else                kdf_done_r <= kdf_done;
  end
  wire kdf_valid_pulse = kdf_done & ~kdf_done_r;

  //-------------------------------------------------------------------
  // 3) 密钥寄存器（只写不可读 + lock）
  //-------------------------------------------------------------------
  wire [255:0] aes_key;
  wire         key_new;

  key_mgr u_km (
    .clk       (s_axi_aclk),
    .rst_n     (s_axi_aresetn),
    .kdf_valid (kdf_valid_pulse),
    .kdf_key   (kdf_digest),
    .sw_write  (cfg_ctrl2[1]),      // 调试用；locked 后无效
    .sw_key    (cfg_sw_key),
    .aes_key   (aes_key),
    .locked    (key_locked),
    .key_new   (key_new)
  );

  //-------------------------------------------------------------------
  // 4) 权重解密流（内部例化 aes256_ctr；密钥内部直连）
  //-------------------------------------------------------------------
  wdec_stream #(
    .FIFO_DEPTH (FIFO_DEPTH),
    .CTR_W      (CTR_W)
  ) u_wdec (
    .clk         (s_axi_aclk),
    .rst_n       (s_axi_aresetn),
    .plain_words (cfg_plain_words),
    .key_load    (key_new),
    .key_in      (aes_key),
    .key_ready   (aes_key_ready),
    .nonce       (cfg_nonce),
    .ctr_init    (cfg_ctr_init[CTR_W-1:0]),
    .ctr_load    (cfg_ctrl[3]),
    .s_tdata     (s_axis_tdata),
    .s_tvalid    (s_axis_tvalid),
    .s_tready    (s_axis_tready),
    .s_tlast     (s_axis_tlast),
    .m_tdata     (m_axis_tdata),
    .m_tvalid    (m_axis_tvalid),
    .m_tready    (m_axis_tready),
    .m_tlast     (m_axis_tlast),
    .st_blk_cnt  ()
  );

  //-------------------------------------------------------------------
  // 5) 控制/状态寄存器组
  //-------------------------------------------------------------------
  puf_dec_axi_lite #(
    .C_S_AXI_DATA_WIDTH (32),
    .C_S_AXI_ADDR_WIDTH (8),
    .N_BITS             (N_BITS)
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
    .cfg_ctrl        (cfg_ctrl),
    .cfg_ctrl2       (cfg_ctrl2),
    .cfg_mask        (cfg_mask),
    .cfg_helper      (cfg_helper),
    .cfg_k           (cfg_k),
    .cfg_salt        (cfg_salt),
    .cfg_purpose     (cfg_purpose),
    .cfg_nonce       (cfg_nonce),
    .cfg_ctr_init    (cfg_ctr_init),
    .cfg_plain_words (cfg_plain_words),
    .cfg_resp_sw     (cfg_resp_sw),
    .cfg_sw_key      (cfg_sw_key),
    .st_fe_busy      (fe_busy),
    .st_fe_done      (fe_done),
    .st_fe_err       (fe_err),
    .st_kdf_busy     (kdf_busy),
    .st_kdf_done     (kdf_done),
    .st_key_locked   (key_locked),
    .st_aes_key_ready(aes_key_ready),
    .st_route_mode   (cfg_ctrl2[0]),
    .st_fe_k_used    (fe_k_used),
    .const_version   (32'h0003_0000)
  );

  // 选路模式出到 axis_route2.mode（0=运行期，复位默认 0）
  assign route_mode_o = cfg_ctrl2[0];

  // 说明：puf_unan_i 目前不参与 FE（稳定位由公开的 mask 决定，而非逐次判决的
  // unan），端口保留以备后续把 unan 接入诊断/掩码自检。悬空输入只会有综合警告。

endmodule

`default_nettype wire
