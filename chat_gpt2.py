"""GPT-2 交互式文本生成（本地模型，无需联网）。

用法：
  python chat_gpt2.py            # 交互模式，输入文本回车生成，输入 q 退出
  python chat_gpt2.py "一句话"    # 单次生成模式

说明：GPT-2 是基座模型，做的是【文本续写】而非指令问答。
"""
import os
import sys

import torch
from transformers import GPT2LMHeadModel, GPT2TokenizerFast

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")


def load():
    tokenizer = GPT2TokenizerFast.from_pretrained(LOCAL)
    model = GPT2LMHeadModel.from_pretrained(LOCAL)
    model.eval()
    return model, tokenizer


@torch.no_grad()
def generate(model, tokenizer, prompt, max_new_tokens=60):
    inputs = tokenizer(prompt, return_tensors="pt")
    out = model.generate(
        **inputs,
        max_new_tokens=max_new_tokens,
        do_sample=True,
        top_k=50,
        top_p=0.95,
        temperature=0.9,
        pad_token_id=tokenizer.eos_token_id,
    )
    return tokenizer.decode(out[0], skip_special_tokens=True)


def main():
    model, tokenizer = load()
    print("=" * 62)
    print("GPT-2 本地生成（基座模型 = 文本续写，非指令问答）")
    print("输入文本回车续写；输入 q 退出")
    print("=" * 62)

    if len(sys.argv) > 1:
        prompt = " ".join(sys.argv[1:])
        print(f"\n[你] {prompt}")
        print(f"\n[GPT-2] {generate(model, tokenizer, prompt)}")
        return

    while True:
        try:
            prompt = input("\n[你] ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not prompt or prompt.lower() in ("q", "quit", "exit"):
            break
        print(f"\n[GPT-2] {generate(model, tokenizer, prompt)}")
    print("\n再见。")


if __name__ == "__main__":
    main()
