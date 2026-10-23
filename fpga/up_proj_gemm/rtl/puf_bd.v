`timescale 1ns / 1ps
//=============================================================================
// puf_bd —— PUF 的 BD 模块引用顶层（**必须是纯 Verilog**）
//
// 为什么必须是 .v 而不是 .sv：
//   Vivado 的 Block Design "Add Module" 走 module-reference 流程时，顶层文件
//   只能用 Verilog-2001 语法。工程里的 gemm_up_proj_bd.v 就是为此而生的
//   （见 add_gemm_to_bd.tcl 的注释）。本文件因此**刻意不用** SystemVerilog
//   特性：不用 logic、不用 unpacked array 端口、不用 always_ff 等。
//   内部的 puf_axi_lite / bpuf_ctrl / bpuf_array 仍是 SystemVerilog，没问题 ——
//   module reference 只要求**被引用的那个顶层**是纯 Verilog。
//
// 与 GEMM 那条数据通路的差别（P1 的关键简化）：
//   PUF 是**纯控制型外设**，不参与数据流。它只需要 S_AXI（控制/状态）+
//   时钟/复位，**没有任何 AXI4-Stream 接口**。所以 P1 的 BD 改动只是"挂一个
//   新 cell 到 smartconnect 上"，不动任何已有流线 —— 比 P2 的 AES 插入简单得多。
//
// 端口命名遵循 Xilinx 接口推断规则（s_axi_* / s_axi_aclk / s_axi_aresetn），
// 以便 package_ip / Add Module 时自动识别协议、自动连线。
//=============================================================================
module puf_bd #(
  parameter N_BITS = 128,      // PUF 位宽（必须是 32 的倍数）
  parameter CNT_W  = 5         // 投票计数位宽，M 上限 = 2^CNT_W - 1
) (
  //-------------------------------------------------------------------
  // 时钟 / 复位
  //-------------------------------------------------------------------
  input  wire        s_axi_aclk,
  input  wire        s_axi_aresetn,

  //-------------------------------------------------------------------
  // AXI4-Lite 从机（控制/状态）
  //-------------------------------------------------------------------
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

  //-------------------------------------------------------------------
  // 暴露给同一 PL 内的加解密块（plan-B §8）：这是**fabric 网线**，
  // 不是 AXI 通道 —— PUF 响应经此直达 fuzzy_extract，绝不经过 PS。
  // （若走 AXI-Lite 由软件转发，密钥材料就会落进 PS 内存，方案 B 失去意义。）
  //-------------------------------------------------------------------
  output wire [N_BITS-1:0] resp_o,      // 锁存的多数表决响应
  output wire [N_BITS-1:0] unan_o       // 非一致掩码（诊断用）
);

  localparam N_WORD = N_BITS / 32;

  // ---- axi_lite <-> ctrl 之间的内部连线 ----
  wire [31:0] cfg_ctrl_w, cfg_n_samp_w, cfg_t_force_w, cfg_t_settle_w;
  wire [3:0]  c_state;
  wire        c_busy, c_done, c_err;
  wire [31:0] c_nsamp, c_stable;

  // ---- ctrl <-> array ----
  wire        a_clr, a_rst, a_sample;
  wire [N_BITS-1:0] a_q_raw, a_q_maj, a_q_unan;
  wire [31:0] a_nsamp;

  // ---- 响应拼接（字 0 在最低位）----
  wire [N_BITS-1:0] resp_bus, unan_bus;

  //===========================================================================
  // PUF 阵列
  //===========================================================================
  bpuf_array #(
    .N_BITS (N_BITS),
    .CNT_W  (CNT_W)
  ) u_array (
    .clk         (s_axi_aclk),
    .rst_n       (s_axi_aresetn),
    .clr         (a_clr),
    .puf_rst     (a_rst),
    .sample      (a_sample),
    .q_raw       (a_q_raw),
    .q_maj       (a_q_maj),
    .q_unan      (a_q_unan),
    .n_samp_done (a_nsamp)
  );

  //===========================================================================
  // 采样时序状态机
  //===========================================================================
  bpuf_ctrl #(
    .N_BITS (N_BITS),
    .CNT_W  (CNT_W)
  ) u_ctrl (
    .clk          (s_axi_aclk),
    .rst_n        (s_axi_aresetn),
    .start        (cfg_ctrl_w[0]),
    .soft_rst     (cfg_ctrl_w[1]),
    .t_force      (cfg_t_force_w),
    .t_settle     (cfg_t_settle_w),
    .n_samp       (cfg_n_samp_w),
    .array_clr    (a_clr),
    .array_rst  (a_rst),
    .array_sample (a_sample),
    .q_maj        (a_q_maj),
    .q_unan       (a_q_unan),
    .n_samp_done  (a_nsamp),
    .resp_reg     (resp_bus),
    .unan_reg     (unan_bus),
    .stable_cnt   (c_stable),
    .nsamp_reg    (c_nsamp),
    .busy         (c_busy),
    .done         (c_done),
    .err          (c_err),
    .state        (c_state)
  );

  //===========================================================================
  // AXI4-Lite 控制/状态寄存器组
  //===========================================================================
  puf_axi_lite #(
    .C_S_AXI_DATA_WIDTH (32),
    .C_S_AXI_ADDR_WIDTH (8),
    .N_WORD             (N_WORD)
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
    .cfg_n_samp    (cfg_n_samp_w),
    .cfg_t_force   (cfg_t_force_w),
    .cfg_t_settle  (cfg_t_settle_w),
    .resp_word_bus (resp_bus),
    .unan_word_bus (unan_bus),
    .st_busy       (c_busy),
    .st_done       (c_done),
    .st_err        (c_err),
    .st_state      (c_state),
    .st_nsamp_done (c_nsamp),
    .st_stable_cnt (c_stable),
    .const_nbits   (N_BITS[31:0]),
    .const_version (32'h0001_0000)
  );

  //===========================================================================
  // 把锁存的响应 / 非一致掩码引到端口，供同 PL 内的 puf_dec_bd 取用。
  // resp_bus/unan_bus 就是 bpuf_ctrl 在 S_DONE 锁存的 resp_reg/unan_reg，
  // 软件先触发一次 PUF 采样（puf_bd_0 的 CTRL.start），再拉加解密块的 fe_start。
  //===========================================================================
  assign resp_o = resp_bus;
  assign unan_o = unan_bus;

endmodule