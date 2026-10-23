"""GPT-2 对话优化版（方向A）：格式化对话模板 + 稳定采样。

用法：
  python chat_gpt2_v2.py "你的问题"     # 单次生成
  python chat_gpt2_v2.py               # 交互模式（q 退出）

要点：
  GPT-2 是基座模型，靠 Human/Assistant 模板 + 采样参数模拟对话。
  消息格式参考 OpenAI 老版 instruct 风格，使续写更贴近一问一答。
"""
import os
import sys

import torch
from transformers import GPT2LMHeadModel, GPT2TokenizerFast

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")

# 对话模板：User/Assistant 轮次
BOS = "<|endoftext|>"
USER_TAG, ASST_TAG = "User:", "Assistant:"


def build_prompt(user_msg: str) -> str:
    """把用户输入包装成网上常见格式，促进模型按对话续写。"""
    return (
        f"{BOS}\n{USER_TAG} {user_msg}\n{ASST_TAG}"
    )


def clean_output(text: str) -> str:
    """截断到 Assistant 首段为止，避免长文跑偏。"""
    # 去掉标签本身
    for tag in (ASST_TAG, USER_TAG):
        text = text.replace(tag, "")
    # 遇到新的 User 轮次即截断
    for stop in ("\nUser:", " User:"):
        if stop in text:
            text = text.split(stop)[0]
    return text.strip()


@torch.no_grad()
def generate(model, tokenizer, user_msg, max_new_tokens=80):
    prompt = build_prompt(user_msg)
    inputs = tokenizer(prompt, return_tensors="pt")
    out = model.generate(
        **inputs,
        max_new_tokens=max_new_tokens,
        do_sample=True,
        top_k=40,
        top_p=0.92,
        temperature=0.7,
        repetition_penalty=1.15,
        pad_token_id=tokenizer.eos_token_id,
    )
    full = tokenizer.decode(out[0], skip_special_tokens=True)
    return clean_output(full)


def load():
    tokenizer = GPT2TokenizerFast.from_pretrained(LOCAL)
    model = GPT2LMHeadModel.from_pretrained(LOCAL)
    model.eval()
    return model, tokenizer


def main():
    model, tokenizer = load()
    print("=" * 62)
    print("GPT-2 对话优化版（模板 + 稳定采样）—— q 退出")
    print("=" * 62)

    if len(sys.argv) > 1:
        q = " ".join(sys.argv[1:])
        print(f"\n[你] {q}")
        print(f"\n[助手] {generate(model, tokenizer, q)}")
        return

    while True:
        try:
            q = input("\n[你] ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not q or q.lower() in ("q", "quit", "exit"):
            break
        print(f"\n[助手] {generate(model, tokenizer, q)}")
    print("\n再见。")


if __name__ == "__main__":
    main()