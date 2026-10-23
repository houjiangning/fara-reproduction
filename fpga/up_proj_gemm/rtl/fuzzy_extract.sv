`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// fuzzy_extract —— 模糊提取器（Fuzzy Extractor）的**重建侧**（RTL）
//
// 分工（plan-B §5.1）：
//   · Enrollment（一次性、离线）：PC/PS 用多次冷启动采样算出
//        - cfg_mask：128 位稳定位掩码（跨上电不翻转的位）
//     这是**公开** helper data，明文存 SD 卡 / /opt/fara/puf/。
//   · Reconstruction（每次上电、**必须在 PL**）：把本次上电的 PUF 响应按
//     mask 选位、每 3 位取多数（重复码 3 取 2）-> seed -> SHA-256 KDF。
//     之所以必须在 PL：它的输出就是密钥本身，跑在 PS 上密钥就进了 PS 内存。
//
// 方案：**码偏移（code-offset）+ 重复码**
//   为什么不是"直接把 3 个位取多数就完事"：
//     若把 3 个**不同**的 PUF 单元当成一个密钥位，取它们的多数，这**不是**纠错码：
//     干净三元组本身可能就是 1-2 分裂（如 [0,0,1]，多数=0），一旦翻转的是两个多数位
//     之一，多数就翻成 1 -> 出错。生成器自检就抓到了这一点。
//   正确构造（码偏移）：
//     Enrollment（离线、公开 helper）：
//       w  = 从参考响应里按 mask 选出的 3k 个位
//       c  = **随机** k 位密钥材料（不落盘）
//       cw = repeat3(c)   （每 1 位重复 3 次，共 3k 位）
//       helper = w XOR cw （公开，存 SD）
//     Reconstruction（每次上电、PL）：
//       x = w' XOR helper = cw XOR e   （e = 本次上电在选中位上的噪声）
//       每个三元组取多数 -> c'；只要每个三元组内错误 <= 1 位，就 c' == c
//   这样"重复码能纠 1 位"才是**真的**：码字是规整的 [b,b,b]，不是随意三元组。
//
// 为什么重复码这一档就够（实测依据 tools/puf_fe_sizing.py）：
//   留一法（LOO）实测：先用 32 次冷启动挑出 72 个"零翻转"位后，在这些位里
//   **新一次上电最多只翻 1 位**（32 次里 4 次出现，其余 0）。1 位噪声最多影响
//   1 个三元组，3 取 2 多数即可纠回。
//   反之，plan-B v1 的"只选稳定位、不纠错"**不够** —— 它假设选出的位永不再翻，
//   而实测证明约 12% 的上电会翻 1 位，直接用会让那些上电派生出错密钥。
//
// 位序约定（必须与 tools 侧 Python golden 一致）：
//   · puf_resp[b] 是响应位 b（b=0 为最低位，与 puf_axi_lite DATA 字序一致）
//   · 扫描方向 b = 0 -> NBITS-1，遇到 cfg_mask[b]==1 就取该位，得到选中序 i=0,1,...
//   · 参与判决的位 = puf_resp[b] XOR cfg_helper[i]
//   · 每 3 个成一组取多数 -> seed[gidx]，gidx 从 0 递增（seed 即密钥材料 c）
//   · 输出 seed 的低 cfg_k 位有效，其余补 0
//
// cfg_k（组数）不是写死常量而是**配置寄存器**：最终冻结比特流上的稳定位数
// 只有 enrollment 时才知道，这样同一版 RTL 能适配不同 k，无需重新综合。
// 约束：1 <= cfg_k <= NBITS/3（128/3 -> 42）。
//=============================================================================
module fuzzy_extract #(
  parameter integer NBITS = 128
) (
  input  wire             clk,
  input  wire             rst_n,

  // ---- 配置（来自 AXI-Lite，enrollment 时写入；公开值）----
  input  wire [NBITS-1:0] cfg_mask,       // 稳定位掩码
  input  wire [NBITS-1:0] cfg_helper,     // 码偏移 helper（公开，与 mask 一起存 SD）
  input  wire [7:0]       cfg_k,          // 输出位数（组数）

  // ---- 输入：本次上电的 PUF 多数表决响应（bpuf_ctrl.resp_reg）----
  input  wire [NBITS-1:0] puf_resp,

  // ---- 控制 ----
  input  wire             start,          // 电平：start=1 且 done=0 启动；写 0 清 done
  output reg              busy,
  output reg              done,
  output reg              err,            // 选位不足 / cfg_k 非法

  // ---- 输出：seed（低位 cfg_k 位有效）----
  output reg  [NBITS-1:0] seed,
  output reg  [7:0]       k_used
);

  localparam [1:0] S_IDLE = 2'd0,
                   S_SCAN = 2'd1,
                   S_DONE = 2'd2,
                   S_ERR  = 2'd3;

  reg [1:0] state;
  reg [7:0] bidx;       // 扫描位下标
  reg [7:0] sel_cnt;    // 已取出的位数（目标 need = 3*cfg_k）
  reg [7:0] gidx;       // 已生成的 seed 位下标
  reg [1:0] tri_pos;    // 三元组内位置 0/1/2
  // 注意：不能把三元组寄存器叫 "tri" —— tri 是 SystemVerilog 保留关键字（net 类型），
  // 会被 xvlog 判为语法错误。故命名 tri_acc。
  reg [2:0] tri_acc;    // 三元组收集（tri_acc[1]=组内第 1 位，tri_acc[0]=组内第 2 位）

  wire [7:0] need = cfg_k * 8'd3;

  wire k_ok = (cfg_k != 8'd0) && (cfg_k <= 8'd42);

  // ---- 当前扫描位（码偏移：先与 helper 异或，再做多数判决）----
  wire       take_cur = cfg_mask[bidx];
  wire       cur_bit  = puf_resp[bidx] ^ cfg_helper[sel_cnt];
  wire [7:0] sel_next = sel_cnt + (take_cur ? 8'd1 : 8'd0);
  wire       reach    = (sel_next >= need);      // 含本次位后是否已凑够 3*k
  wire       last_bit = (bidx == NBITS[7:0] - 8'd1);

  // ---- 三元组多数（含本次位）----
  wire [2:0] tri_now = {tri_acc[1:0], cur_bit};  // [2]=组内第 1 位, [1]=第 2 位, [0]=本次
  wire       maj     = (tri_now[0] & tri_now[1]) |
                       (tri_now[0] & tri_now[2]) |
                       (tri_now[1] & tri_now[2]);

  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      bidx    <= 8'd0;
      sel_cnt <= 8'd0;
      gidx    <= 8'd0;
      tri_pos <= 2'd0;
      tri_acc <= 3'd0;
      busy    <= 1'b0;
      done    <= 1'b0;
      err     <= 1'b0;
      seed    <= {NBITS{1'b0}};
      k_used  <= 8'd0;
    end else begin
      case (state)

        //------------------------------------------------------------------
        S_IDLE: begin
          busy <= 1'b0;
          if (start && !done) begin
            if (!k_ok) begin
              err   <= 1'b1;
              state <= S_ERR;
            end else begin
              err     <= 1'b0;
              done    <= 1'b0;
              bidx    <= 8'd0;
              sel_cnt <= 8'd0;
              gidx    <= 8'd0;
              tri_pos <= 2'd0;
              tri_acc <= 3'd0;
              for (i = 0; i < NBITS; i = i + 1) seed[i] <= 1'b0;
              busy    <= 1'b1;
              state   <= S_SCAN;
            end
          end
        end

        //------------------------------------------------------------------
        S_SCAN: begin
          // 只有当前位被 mask 选中时才参与收集
          if (take_cur) begin
            if (tri_pos == 2'd2) begin
              // 本组第 3 位到达 -> 出多数结果，写进 seed[gidx]
              seed[gidx] <= maj;
              gidx       <= gidx + 8'd1;
              tri_pos    <= 2'd0;
              tri_acc    <= 3'd0;
            end else begin
              tri_acc <= tri_now;               // 累积组内第 1/2 位
              tri_pos <= tri_pos + 2'd1;
            end
            sel_cnt <= sel_next;
          end

          if (reach) begin
            // 恰好凑够 3*k：本拍已写最后一组多数
            k_used <= cfg_k;
            done   <= 1'b1;
            busy   <= 1'b0;
            state  <= S_DONE;
          end else if (last_bit) begin
            // 扫完 128 位仍不足 3*k -> 选位不足
            err   <= 1'b1;
            busy  <= 1'b0;
            state <= S_ERR;
          end else begin
            bidx <= bidx + 8'd1;
          end
        end

        //------------------------------------------------------------------
        // 与工程既有语义一致：done 置 1 后保持，软件把 start 写 0 才清 done。
        S_DONE: begin
          busy <= 1'b0;
          if (!start) begin
            done  <= 1'b0;
            state <= S_IDLE;
          end
        end

        //------------------------------------------------------------------
        S_ERR: begin
          busy <= 1'b0;
          err  <= 1'b1;
          if (!start) begin
            err   <= 1'b0;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;

      endcase
    end
  end

endmodule

`default_nettype wire
