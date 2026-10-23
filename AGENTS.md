# AGENTS.md —— BFA×FaR 攻击与防护评测框架（模型可切换）
> 本文件给智能体(如 TRAE / Claude / Cursor)在打开本项目时自动阅读并遵循。人类读者可看同一份 Quick Start。

## 一句话
本地因果语言模型（默认 GPT-2 small / 可切 Qwen2.5-3B）上的 **BFA 比特翻转攻击** 与 **FaR（Forget-and-Rewire）防护** 研究框架，含逐层余弦/一致率/KL 等离线严格评测、结果落盘 JSON/CSV、以及一个可交互的 Web 控制面板（attack_dashboard.py）。

## 关键文件与职责
| 文件 | 职责 |
|---|---|
| `model_profile.py` | **换模型唯一入口**。模型档案(gpt2 / qwen2.5-3b)，封装加载函数、默认敏感层、逐层余弦层数。切模型只改这里（或环境变量），其余代码不动。 |
| `eval_perplexity.py` | 困惑度评测 + `load()` 委托给 model_profile。 |
| `bfa_attack.py` | 梯度引导 BFA：`compute_gradients` / `build_plan` / `flip_bit`（fp32 指数位 24–26）。 |
| `far_defense.py` | FaR 核心：把敏感权重列复制进 dead lane、激活微分流，输出严格守恒；生成 FaRMap。 |
| `eval_benchmark.py` | 论文级离线评测：固定语料、512 滑动窗口、bootstrap 均值±std、基线、附加指标，落盘 `eval_benchmark_<mode>.[json|csv]`。 |
| `attack_dashboard.py` | 零框架 Web 面板(8099)：实时困惑度曲线、逐步回放动画、文本生成回放、**离线评测报告可视化**（PPL±std 表 + 逐层余弦热力图）。 |

## 运行（默认 GPT-2，模型须在 ./gpt2-local）
```bash
pip install -r requirements.txt
python eval_perplexity.py
python eval_benchmark.py --mode attack --budget 16 --lang english
python eval_benchmark.py --mode far   --layer transformer.h.2.mlp.c_proj --n 16 --div 2 --lang english
python attack_dashboard.py            # 浏览器打开 http://127.0.0.1:8099
```

## 换模型到 Qwen2.5-3B（在已部署该模型的那台电脑上）
三种方式，等价：
1. 环境变量：
   ```bash
   # 你这台机器若下的是对话版 -> Instruct；若已下到本地目录 -> 用绝对路径
   set FAR_MODEL=qwen2.5-3b
   set FAR_NAME_OR_PATH=Qwen/Qwen2.5-3B        # 或 D:/qwen2.5-3b
   set FAR_DEVICE=cpu                           # 有 GPU 改 cuda
   python eval_benchmark.py --mode far --n 16 --div 2 --lang chinese
   ```
2. 直接改 `model_profile.py` 里 `PROFILES["qwen2.5-3b"]["name_or_path"]` 为该机已部署路径/名称，再以默认 `gpt2`? 否——把 `FAR_MODEL` 默认值改掉即可一劳永逸。
3. 运行时显式指定敏感层：`--layer model.layers.3.mlp.down_proj`（不传时已按档案自动取）。

> Qwen2 是 Llama 风格 MLP：`model.layers.{i}.mlp.down_proj` 对应 GPT-2 的 `c_proj`（都做了同样的事）。逐层余弦层数 = num_hidden_layers+1，已自动按模型配置算，不用手改 13。

## 智能体操作守则（重要约定）
- **核心逻辑与模型无关**：攻击/防护/评测只依赖"前向得 logits"+"对参数做 fp32 位翻转"。所以换模型**绝不要**去改 bfa_attack.py / far_defense.py / eval_benchmark.py 的算法，只动 `model_profile.py`（或环境变量）。
- **保持离线评测规范**：固定语料选后不换；PPL 用 NLL（=log ppl）判伤（`达标 = ppl ≥ 基线×threshold ⇔ NLL ≥ 基线+ln(threshold)`，阈值默认 4）；bootstrap 报告均值±std；先测干净基线再比较；裸/FaR 必须共用同一组 bootstrap 子集。
- **用法规遵从**：`--budget` 是翻转预算；`--mode far` 时 `--layer`/`--n`/`--div` 决定被保护层与敏感位数量；`--lang english|chinese|all` 按引擎语言能力选。
- **禁止事项**：不要翻 bit30（会制造 ~2^127 权重→softmax 上溢 NaN）；面板是演示，攻击只改内存副本、不落盘真实模型权重。
- 报告以 `eval_benchmark_<mode>.json` 为准，面板 `/api/bench?mode=<mode>` 直接加载它。

## 给使用者的提示词（可粘贴给另一台的智能体）
> 请阅读项目根目录 AGENTS.md。以 Qwen2.5-3B 作为被测模型：设 FAR_MODEL=qwen2.5-3b、FAR_NAME_OR_PATH=<本机 Qwen 路径/名>、FAR_DEVICE=cpu|cuda。先跑 `python eval_benchmark.py --mode far --n 16 --div 2 --lang chinese|english` 生成报告，再 `python attack_dashboard.py` 打开面板核实 PPL±std 表与逐层余弦热力图正常。