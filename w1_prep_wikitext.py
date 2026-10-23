"""把 WikiText-2 训练集(wiki.train.tokens) 解析成 eval_benchmark 可用的语料。

eval_benchmark.py 的 --corpus-file 要求"每行一个自然段(原始文本)"，
而 WikiText-2 .tokens 是已按空格预分词、含 "<unk>"/"@-@" 特殊记号的字节级文件，
且按句子一行、空行分隔自然段。本脚本：
  1. 跳过空行与 "= = 标题 = =" 行
  2. 把同段内连续句子合并成一行(自然段)
  3. 用与评测一致的 GPT-2 tokenizer 精确统计子词数，截到累计 >= target 子词为止
  4. 写出 → wikitext_corpus.txt（每行一段）

用法：python w1_prep_wikitext.py [target_subwords]
"""
import os
import sys

from eval_perplexity import load

DIR = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(DIR, "..", "wikitext-2", "wiki.train.tokens")
OUT = os.path.join(DIR, "wikitext_corpus.txt")
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 130_000
MIN_CHARS = 40  # 与 eval_benchmark.build_corpus 的过滤阈值保持一致


def is_heading(line):
    return line.startswith("=")


def main():
    model, tok = load()
    paras = []
    buf = []
    with open(SRC, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                if buf:
                    paras.append(" ".join(buf))
                    buf = []
                continue
            if is_heading(line):
                continue
            buf.append(line)
    if buf:
        paras.append(" ".join(buf))

    total = 0
    written = 0
    with open(OUT, "w", encoding="utf-8") as out:
        for seg in paras:
            if len(seg) < MIN_CHARS:
                continue
            ids = tok(seg, add_special_tokens=True)["input_ids"]
            if len(ids) <= 2:
                continue
            total += len(ids)
            out.write(seg.replace("\n", " ") + "\n")
            written += 1
            if total >= TARGET:
                break

    print("=" * 62)
    print("WikiText-2 解析完成 →", OUT)
    print(f"  写入段落(行) = {written}")
    print(f"  累计 GPT-2 子词 = {total:,}")
    print(f"  是否达到 ≥10 万：{'是 ✓' if total >= 100_000 else '否 ✗'}")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    raise SystemExit(main() or 0)