# FaRAccel 复现 · 单层 up_proj 硬件 FaR 加速 MVP

> 目标：参照 FaRAccel 论文的**卸载（offload）**思路，把本地 GPT-2-small(124M) 的 **MLP 升维层 up_proj（`h.{i}.mlp.c_fc`）** 的矩阵运算与权重放进 Zynq 板卡，做一个**参数化单层 FaR 硬件加速器**，打通 PC↔板卡通路，最终形成一个"即插即用"的本地端侧 LLM 硬件防护器（原型）。
> 本版**不做四层防护**（CRC/MAED/字符过滤/XADC/DPR 全部放下），PL 内只有：GEMM 阵列 + select 激活重路由 + shadow 权重/FaRMap 配置存储。

## 0. 已锁定的决策（2026-09 确认）
- 模型实例：**GPT-2-small（124M）**。up_proj = `h.{i}.mlp.c_fc`（GPT-2 命名中 MLP 的升维投影）。之前演示用的 c_proj 是降维，二者不同。
- 骨架运行位置：**先 PC 后 PS**。Phase A = PC 用 torch 跑其余层、仅 up_proj offload 到板；Phase B = 将骨架迁到 PS 端 ARM，进化为真端侧。
- 覆盖范围：只做 FaR；只证明一个 Linear 层的 FaR 硬件加速，作为"可扩展到所有 Linear 层"的原理验证。
- 交付时限：2026-11 初（约 6 周）。

## 1. 架构形态（卸载式，软硬协同）
- FPGA 侧（PL）：**参数化 FaR 加速器**，仅替换模型里的 up_proj 层。
- 软件侧：推理骨架算其余全部层（embedding / attention / 其它 Linear / LN / GELU / softmax）；遇到目标层时切出激活，经通路送 FPGA，硬件算完（含 FaR 激活重路由与 shadow 权重）把输出激活接回流水线。
- 这就是 FaRAccel 的"卸载 + 动态激活重路由"含义：**不是把 FaR 拆到多设备，而是把 FaR 受护的单一层推理交给 PL**。

## 2. 系统分区（Phase A）
| 端 | 承担 |
|---|---|
| PC | 推理骨架其余层(torch)；攻击/评测编排(PBS-BFA)；FaR 离线变换生成 FaRMap+shadow 权重；乱码回显 dash；UART/ETH 通信 |
| PS | 通路中转：从 DDR 读入激活→送 PL；取回 PL 结果；收发 PC 命令；加载权重/FaRMap 到 DDR（后续 Phase B 兼任骨架运行时） |
| PL | 参数化 GEMM 阵列 + select 激活重路由 + shadow 权重/FaRMap + 控制寄存器 |

通路：`PC ↔(UART/以太网)↔ PS(ARM) ↔(AXI + 共享DDR)↔ PL`。

## 3. 单层加速器微架构（PL 内，最少件）
- **参数化 GEMM 阵列**：`M(m×k→m×n)` 可配置；lane 数、div 作为参数，确保"换层=换配置"。
- **激活重路由（FaRAccel 核心）**：控制器按当前输出行从 FaRMap 综合出 **select 向量**，决定每条乘法 lane 取 baseline 还是 shadow 权重列，并对输入激活做 dead-lane 分裂/合并，保证输出守恒。
- **配置/权重存储**：shadow 权重 + FaRMap 用离线导出的格式，PS 载入 DDR，PL 按 tile 取用（不整份摊片上）。
- **控制寄存器（AXI-Lite）**：启停、目标层识别、状态回读。

## 4. 与论文口径的对应（用于论证）
- 卸载与优化 FaR 运算 → Phase A 的 up_proj offload。
- 动态激活重路由（select 向量选 baseline/shadow lane）→ 第 3 节控制器。
- 轻量离线存储 rewiring 配置 → FaRMap/shadow 权重离线导出 + DDR 驻留。
- 不混入自己设计的 DPR 四档 / CRC / MAED（本版范围外，注释即可）。

## 5. 里程碑（6 周 MVP）
- **W1/Golden**（**已完成 2026-09**）：代表层选定 = **`transformer.h.0.mlp.c_fc`**（跨层扫描：h.0 翻 6 位 ppl ×232，其余层≈×1，浅层最易被破坏、演示最直观）。golden：裸到阈值(ppl≥基线×4)需 **3 位**，FaR 后预算 16 内未达阈值 → 比值 **≥5.33×**（超过论文典型 1.4–4.2×，更强）。FaR 基线 NLL 3.2729→3.2703 守恒。板卡可加载格式已导出到 `board_export/`，bit-exact。
- **W2/通路**：UART/ETH 连通 PC↔PS；AXI DMA 做最小 GEMM 冒烟（写激活 → PL 算 → 读回比对 bit-exact）。
- **W3/单层硬件**：参数化 GEMM + select 重路由；输出 bit-exact 对齐 torch；加 FaR 后守恒成立。
- **W4/端到端**：软骨架 hook 把 up_proj 交给 FPGA；PC 下发 prompt、收结果，回显"裸 vs FaR 到阈值翻位"曲线；交付原型。

## 6. 验收判据（逐条）
- 单层硬件 GEMM 与 torch up_proj 逐位一致（bit-exact，或给出误差界）。
- 加 FaR 后的硬件输出守恒（与软 FaR 无损一致，误差 < 阈值）。
- 同一 up_proj 上，PBS 到阈值需翻位数：裸 < FaR，比值落在 FaR/FaRAccel 报告范围（1.4–4.2×）。
- "换层"仅改配置/权重重定位即可复用（参数化验证）。
- 通路：PC 发一次推理往返延迟可测、结果回显正确。

## 7. 风险与对策
| 风险 | 对策 |
|---|---|
| 6 周做整套推理机过大 | 只做一个参数化层，其余软件；先 A 后 B |
| bit-exact 偏差破坏 FaR 守恒 | W3 以 bit-exact/误差界为硬门禁，别提前接 FaR |
| shadow 权重翻倍 + up_proj 尺寸内存压力 | 按 tile/窗口取用，不整份摊片上；估计 BRAM/URAM |
| 目标层命名歧义（c_fc vs c_proj） | 全局统一用 transformers 规范名 `h.{i}.mlp.c_fc` |