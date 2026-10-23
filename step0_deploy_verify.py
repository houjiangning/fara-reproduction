"""GPT-2 small 部署验收脚本 — FaR 复现项目的第一步基线验证。

验收三项：
  [1] 模型加载 + 文本生成（推理基线 OK）
  [2] 枚举全部 nn.Linear（未来下沉 FPGA 的算子清单）
  [3] 反向传播拿梯度（FaR 敏感度分析的原料）

用法：python step0_deploy_verify.py
"""
import os
import sys

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

def main():
    print("=" * 60)
    print("[Step 0] GPT-2 small 部署验收")
    print("=" * 60)

    # ---------- 依赖检查 ----------
    try:
        import torch
        import transformers
        print(f"\n[依赖] torch {torch.__version__} | transformers {transformers.__version__}")
    except ImportError as e:
        print(f"[FAIL] 缺少依赖: {e}")
        print("       请运行: pip install torch transformers -i https://pypi.tuna.tsinghua.edu.cn/simple")
        sys.exit(1)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[设备] {device}" + (" (CPU 推理 GPT-2 124M 完全够用)" if device == "cpu" else ""))

    # ---------- [1] 加载 + 生成 ----------
    from transformers import GPT2LMHeadModel, GPT2TokenizerFast

    local_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpt2-local")
    print(f"\n[1/3] 加载 gpt2 (124M) 本地目录 {os.path.basename(local_dir)} 并生成文本...")
    model = GPT2LMHeadModel.from_pretrained(local_dir)
    tokenizer = GPT2TokenizerFast.from_pretrained(local_dir)
    model.eval()

    prompt = "The quick brown fox"
    inputs = tokenizer(prompt, return_tensors="pt")
    with torch.no_grad():
        out = model.generate(
            **inputs, max_new_tokens=30, do_sample=True,
            top_k=50, top_p=0.95, pad_token_id=tokenizer.eos_token_id,
        )
    text = tokenizer.decode(out[0], skip_special_tokens=True)
    print(f"    prompt: {prompt}")
    print(f"    生成:   {text}")
    print("    [PASS] 推理基线 OK" if len(text) > len(prompt) else "    [FAIL] 生成异常")

    # ---------- [2] 枚举线性层 ----------
    print("\n[2/3] 枚举线性投影层（FPGA 下沉清单）...")
    from transformers.pytorch_utils import Conv1D
    linears = []
    for n, m in model.named_modules():
        if isinstance(m, torch.nn.Linear):
            linears.append((n, m, m.in_features, m.out_features))
        elif isinstance(m, Conv1D):
            linears.append((n, m, m.weight.shape[0], m.weight.shape[1]))  # Conv1D: (in, out) 转置存储
    by_type = {}
    for n, m, fi, fo in linears:
        key = n.split(".")[-1]
        by_type.setdefault(key, []).append(n)
    total_params = sum(fi * fo for _, _, fi, fo in linears)
    print(f"    线性投影层总数: {len(linears)}  (nn.Linear + Conv1D)")
    print(f"    线性层参数总量: {total_params:,}")
    print("    分布:")
    for k, v in by_type.items():
        print(f"      {k:<12} x{len(v):<3}  例: {v[0]}")

    # 检查典型结构（12 层 x c_attn/c_proj/c_fc + lm_head）
    expect_keys = {"c_attn", "c_proj", "c_fc"}
    found_keys = set(by_type.keys())
    print(f"    [PASS] 关键投影层齐备: {sorted(expect_keys & found_keys)}"
          if expect_keys.issubset(found_keys)
          else f"    [WARN] 缺少: {expect_keys - found_keys}")

    # ---------- [3] 梯度检查 ----------
    print("\n[3/3] 反向传播取梯度（敏感度分析原料）...")
    model_grad = GPT2LMHeadModel.from_pretrained(local_dir)
    model_grad.train()
    ginputs = tokenizer("Hello, my name is", return_tensors="pt")
    labels = ginputs["input_ids"]
    loss = model_grad(**ginputs, labels=labels).loss
    loss.backward()

    n_with_grad = 0
    n_linear = 0
    sample = None
    for n, p in model_grad.named_parameters():
        if p.requires_grad and p.grad is not None:
            n_with_grad += 1
            if sample is None and "c_attn" in n and "weight" in n:
                g = p.grad
                sample = (n, tuple(g.shape), float(g.abs().max()), float(g.abs().mean()))
        if "c_attn.weight" in n or "c_proj.weight" in n or "c_fc.weight" in n:
            n_linear += 1
    print(f"    loss = {loss.item():.4f} | 有梯度的参数张量: {n_with_grad}")
    if sample:
        n, shape, gmax, gmean = sample
        print(f"    样例梯度 {n}: shape={shape}, |g|max={gmax:.3e}, |g|mean={gmean:.3e}")
        print("    [PASS] 梯度可用 → 可做敏感度排序")
    else:
        print("    [FAIL] 未取到梯度")

    # ---------- 汇总 ----------
    print("\n" + "=" * 60)
    print("验收结论：")
    print(f"  GPT-2 small (124M) 已就绪 — {len(linears)} 个线性层待 FaR 处理")
    print(f"  下一步: 编写 FaR 离线工具 (敏感度分析 → FaRMap + shadow weights)")
    print("=" * 60)

if __name__ == "__main__":
    main()
