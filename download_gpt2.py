"""补齐 GPT-2 tokenizer 文件（merges.txt / tokenizer.json），并验证 vocab.json 完整性。"""
import json
import os
import sys
import time
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")
SOURCES = [
    "https://hf-mirror.com/gpt2/resolve/main/",
    "https://huggingface.co/gpt2/resolve/main/",
]
FILES = ["merges.txt", "tokenizer.json"]
HDR = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}


def log(msg):
    print(msg)
    sys.stdout.flush()


def dl(url, path):
    req = urllib.request.Request(url, headers=HDR)
    with urllib.request.urlopen(req, timeout=90) as r, open(path, "wb") as w:
        while True:
            b = r.read(1 << 18)
            if not b:
                break
            w.write(b)
    return os.path.getsize(path)


def valid_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            json.load(f)
        return True
    except Exception:
        return False


def main():
    os.makedirs(LOCAL, exist_ok=True)

    if not valid_json(os.path.join(LOCAL, "vocab.json")):
        FILES.insert(0, "vocab.json")
        log("vocab.json 损坏，加入重下清单")

    for f in FILES:
        p = os.path.join(LOCAL, f)
        done = False
        for src in SOURCES:
            for attempt in range(3):
                try:
                    n = dl(src + f, p)
                    log(f"OK {f} {n} bytes")
                    done = True
                    break
                except Exception as e:
                    log(f"retry {f} @ {src.split('/')[2]} #{attempt + 1}: {str(e)[:70]}")
                    time.sleep(3)
            if done:
                break
        if not done:
            log(f"FAIL {f}")

    if valid_json(os.path.join(LOCAL, "vocab.json")):
        log("vocab.json JSON 校验通过")
    if valid_json(os.path.join(LOCAL, "tokenizer.json")):
        log("tokenizer.json JSON 校验通过")
    with open(os.path.join(LOCAL, "merges.txt"), encoding="utf-8", errors="ignore") as fh:
        lines = fh.read().splitlines()
    if len(lines) > 50000:
        log(f"merges.txt 行数 {len(lines)} (GPT-2 应约 50001)")

    log("---最终文件清单---")
    for n in sorted(os.listdir(LOCAL)):
        log(f"  {n:<26} {os.path.getsize(os.path.join(LOCAL, n)):>12,}")


if __name__ == "__main__":
    main()
