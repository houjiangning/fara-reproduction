# FaR（Forget and Rewire）机制实现规格

> 来源：FaR_USENIX2024_nazari.pdf（USENIX Security '24，19 页），本文件是**从论文正文逐句提炼**的实现规格，供后续编写 FaR 软件端 / FaRAccel 硬件端时对照。引用的原文位置均为论文章节，非推测。

## 0. 一句话原理
FaR 通过把"层内最敏感参数"的**激活**分流复制到"dead 神经元（激活≈0）"及其权重上，从而**稀释/混淆参数敏感度**，迫使攻击者需翻转更多 bit 才能造成同等破坏。**层的功能性几乎不变**（输出上 `Y = f(X1W1 + X3W3 + b)` 在 FaR 前后保持一致）。

## 1. 两个关键动作 + 一个超参
- **Forget（遗忘）**：把 dead 神经元产生的激活"断开"（不再传给其他神经元），其权重参数被**新值覆盖**。
  - dead 神经元定义 = 用一批输入数据评估时**激活趋近于 0 或非常接近 0** 的神经元（对功能影响最小）。论文把它与"Pruning 技术（一般丢弃线性层 10–15% 神经元而不损失精度）"关联。
- **Rewire（重连）**：把对一个重要参数有贡献的激活**重定向**到另一个参数；重定向过程中该激活的**幅值除以 division factor**。
- **division factor（除法因子）**：决定重连的复杂度/有效性——过大→用多个神经元冗余、可能降低泛化与精度；过小→遮盖不充分、鲁棒性不足。论文评估范围是 **1–10**（Figure 8/9）。

## 2. 敏感度分析（怎么找"重要参数"）
- 用**一批输入数据**做**损失反向传播**计算梯度，然后**排序**参数。
- 梯度绝对值越大 → 该参数对输出/损失越敏感 → 越"重要"（标记为需要保护）。
- dead 神经元则通过对梯度做**逆序排序**（最小贡献者）得到。
- 论文 Fig.6：以 `C = ½(a1 − y)²` 为例，链式展开 `∂C/∂w1..w4` 得到各权重敏感度。

## 3. Algorithm 1：Forget and Rewire 伪代码（论文 5.3 节）
```
Input: model, sample_data, labels, max_far
Output: Enhanced model
for i = 1 to max_far:
  Step1 Identify Important Parameter:
     important_param_d ← compute_gradient_wrt_input(model, sample_data, labels)
  Step2 Locate Dead Neurons:
     dead_param_d ← get_dead_params(model, sample_data, labels, important_param_d)
  Step3 Generate Forget and Rewire Configuration:
     far_cfg_d ← get_forget_rewire_cfg(important_param_d, dead_param_d, model)
  Step4 Apply Forget and Rewire Configuration:
     model ← apply_far_cfg_to_model(model, far_cfg_d)
```
- 每轮迭代 = 一次 FaR 操作（保护 1 个重要参数）。迭代直到：**精度开始下降 或 达到期望的 BFA 鲁棒性** 即停。
- **关键约束**：每完成一次 forget+rewire 后，**必须重新做整次梯度计算**（整个梯度计算过程要重跑）。
- FaR 配置很小、**不含全部参数** → 可安全地存在片上（供硬件端读取）。

## 4. 单层操作细节（图 5 示例，3 输入→1 输出）
- 原层：`Y = f(X1W1 + X2W2 + X3W3 + b)`，且 `X1 > X3 > X2 ≈ 0` → 实际 `Y = f(X1W1 + X3W3 + b)`，`W1` 最敏感、`W2` 是 dead（X2≈0）。
- 操作：
  1. Forget：断开 m2 到 n1 的连接（dead 路径）。
  2. Rewire：`W2` 的值被替换成 `W1` 的值（`W2 := W1`）。
  3. 激活重新分配：把 m1 的激活 `X1` 除以 2（division factor=2），一半走原 `W1`，另一半走已变成 `W1` 的 `W2`。
- 结果：`Y = f((X1/2)W1 + (X1/2)W1 + X3W3 + b) = f(X1W1 + X3W3 + b)`——输出不变。
- 净效应：攻击者重新做梯度时，"最重要"的变成了 `W3`，`W1` 的敏感度被两半均分隐藏；攻击 `W1` 无效，因为它的重要性已摊到 `W2`。

## 5. 从 FaR 到 FaRAccel 的桥接（硬件端要消费什么）
> （此节依据 FaRAccel 论文，非 FaR 论文）
- FaR 软件离线端只需产出两个小件供 FPGA 运行期消费：
  1. **FaRMap**：每层的 victim/donor/skip 稀疏表（每输出行重连预算 ≤15%，division factor 限 2 或 3）。
  2. **shadow store**：被引用的 donor 权重，**预先算好** ×1/2、×1/3 的 FP16 副本（避免硬件插除法器）。
- 硬件端（FaRAccel）运行期**不算 FaR 逻辑**，只做"每行 32 项 select 向量（baseline/shadow/zero）"+ 乘法器前 3 路操作数选择。

## 6. 论文给的可验收判据（复现时对表）
| 指标 | 论文给定值 |
|---|---|
| BFA 成功率下降 | 约 1.4–4.2× |
| 精度损失 | <2% |
| division factor 评估范围 | 1–10 |
| Oracle 攻击者所需翻转（归一化） | ≥1.68（Figure 9 所示） |
| Pruning 类比丢弃比例 | 约 10–15% |
| FaRAccel：单层重连预算 | ≤15% 输入 |
| FaRAccel：division factor | 限 2 或 3 |

## 7. 需注意的"论文明说但易被忽略"点
- FaR 是**一次性、训练后（post-training）**的改造，不需要重训练、不改模型拓扑。
- 每轮后重算梯度（高计算成本，是软件端主要开销来源之一）。
- FaR 与检测/恢复类（NeuroPots、Aegis）**互补**而非替代。
- 停止条件：精度开始下降 或 达到目标鲁棒性 时停。