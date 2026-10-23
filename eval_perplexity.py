"""困惑度(perplexity)评测 —— 多段代表性语料版。

用于量化 BFA 攻击 / FaR 防护对 GPT-2 的影响：
  - perplexity 越低 = 模型对文本越不惊讶 = 输出越流畅 = 越“正常”
  - 攻击后 perplexity 暴涨 = 模型被破坏
  - 防护后 perplexity 波动小 = 防护有效

代表性改进：
  1) 多段固定语料（通用英语 + 硬件安全/端侧LLM场景英语），非单句随手文本
  2) 逐段测 perplexity 后输出 均值±标准差，降低单段偏倚

用法：
  python eval_perplexity.py                 # 内置代表性语料
  python eval_perplexity.py "自定义文本"     # 只测单段自定义文本
"""
import os
import sys

import torch
import torch.nn.functional as F

from model_profile import load_causal_model

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")

# 代表性参考语料（多段，混合通用英语与硬件安全/端侧LLM场景）
REFERENCE_CORPUS = [
    # 通用英语
    "The quick brown fox jumps over the lazy dog. The weather today is "
    "sunny and warm, a perfect day for a walk in the park with friends "
    "and family. Learning new things every day keeps the mind active "
    "and healthy.",
    # 硬件安全 / 加速器场景
    "Field programmable gate arrays, usually called FPGAs, offer "
    "flexible hardware that can be reconfigured for many different "
    "tasks. They are widely used for accelerating deep neural networks "
    "at the edge, because they provide a good balance of performance "
    "and energy efficiency.",
    # 端侧LLM / AI安全场景
    "Deploying large language models on embedded devices is becoming "
    "more common. However, protecting these models from hardware "
    "attacks is important, because a single flipped bit in the model "
    "weights can cause the system to produce incorrect or harmful "
    "output.",
    # 对话/交互场景
    "The assistant carefully read the user question and then prepared "
    "a clear answer. It considered the context of the conversation "
    "and tried to give a useful and concise response.",
]


def load(name=None):
    """按模型档案加载（默认 GPT-2 本地；设 FAR_MODEL=qwen2.5-3b 可换 Qwen2.5-3B）。"""
    return load_causal_model(name)


@torch.no_grad()
def perplexity(model, tok, text):
    """滑动窗口求平均困惑度，避免超长文本显存/内存爆炸。"""
    ids = tok(text, add_special_tokens=True)["input_ids"]
    max_len = 180
    stride = 128
    # 长度不足一段时整段计算
    if len(ids) <= max_len + 1:
        block = torch.tensor([ids], device="cpu")
        input_ids = block
    else:
        blocks = []
        start = 0
        while True:
            end = min(start + max_len, len(ids) - 1)
            # window [start, end+1)
            blocks.append(torch.tensor([ids[start:end + 1]], device="cpu"))
            if end == len(ids) - 1:
                break
            start += stride
        input_ids = torch.cat(blocks, dim=0)

    nll_sum, n = 0.0, 0
    with torch.no_grad():
        out = model(input_ids, labels=input_ids)
        logits = out.logits  # [*, max_len, vocab]
        shift_logits = logits[:, :-1, :].contiguous()
        shift_labels = input_ids[:, 1:].contiguous()
        per_block = F.cross_entropy(
            shift_logits.reshape(-1, shift_logits.size(-1)),
            shift_labels.reshape(-1),
            reduction="sum",
        )
        nll_sum += per_block.item()
        n += (shift_labels != -100).sum().item()
    return float(torch.exp(torch.tensor(nll_sum / max(n, 1))))


def _eval_one(model, tok, text):
    return perplexity(model, tok, text)


def main():
    model, tok = load()

    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
        print("=" * 62)
        print("单段自定义文本困惑度：")
        print("=" * 62)
        try:
            ppl = _eval_one(model, tok, text)
            print(f"\nperplexity = {ppl:.2f}   (越低 = 模型对此文本越流畅/越正常)")
        except Exception as e:  # pragma: no cover
            print(f"评测出错: {e}")
        return

    print("=" * 62)
    print(f"多段代表性语料困惑度（共 {len(REFERENCE_CORPUS)} 段）")
    print("=" * 62)
    vals = []
    for i, text in enumerate(REFERENCE_CORPUS, 1):
        try:
            ppl = _eval_one(model, tok, text)
        except Exception as e:  # pragma: no cover
            print(f"  段 {i}: 出错 {e}")
            continue
        vals.append(ppl)
        print(f"  段 {i}: perplexity = {ppl:8.2f}    " + text[:30] + "…")

    if vals:
        import statistics
        mean = statistics.mean(vals)
        stdev = statistics.stdev(vals) if len(vals) > 1 else 0.0
        print("\n" + "-" * 62)
        print(f"平均 perplexity = {mean:.2f}  ± {stdev:.2f}")
        print("（越低 = 模型对代表性语料越流畅/越正常）")


if __name__ == "__main__":
    main()