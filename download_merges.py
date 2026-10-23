"""多源下载 GPT-2 merges.txt（含 jsDelivr/ModelScope 备选源）。"""
import os
import sys
import time
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(DIR, "gpt2-local")

SOURCES = [
    ("https://hf-mirror.com/gpt2/resolve/main/merges.txt", "merges.txt"),
    ("https://huggingface.co/gpt2/resolve/main/merges.txt", "merges.txt"),
    ("https://cdn.jsdelivr.net/gh/openai/gpt-2@master/model/vocab.bpe", "merges.txt"),
    ("https://www.modelscope.cn/models/AI-ModelScope/gpt2/resolve/master/merges.txt", "merges.txt"),
    ("https://gitee.com/mirrors/gpt-2/raw/master/model/vocab.bpe", "merges.txt"),
]
HDR = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}


def log(m):
    print(m)
    sys.stdout.flush()


def dl(url, path):
    req = urllib.request.Request(url, headers=HDR)
    with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as w:
        while True:
            b = r.read(1 << 18)
            if not b:
                break
            w.write(b)
    return os.path.getsize(path)


p = os.path.join(LOCAL, "merges.txt")
done = False
for src, out in SOURCES:
    host = src.split("/")[2]
    for attempt in range(2):
        try:
            n = dl(src, os.path.join(LOCAL, out))
            if n > 400000:
                log(f"OK {n} bytes from {host}")
                done = True
                break
            log(f"too small ({n}) from {host}")
        except Exception as e:
            log(f"retry {host} #{attempt + 1}: {str(e)[:70]}")
        time.sleep(2)
    if done:
        break
log("DONE" if done else "ALL FAIL")
