#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
puf_stability.py -- Butterfly PUF 稳定性测量与统计（P1 的核心产出）

输入：board_test/puf_sample.c 采集的采样文件（默认 --append 追加的格式）：
    # PUF_SAMPLE v1 nbits=128 nwords=4 n_samp=9 t_force=8 t_settle=64 ...
    <resp_hex> [unan_hex]        <- 每次冷启动一行
    <resp_hex> [unan_hex]
    ...

    位序约定（与 puf_sample.c 一致，务必对齐）：
      · 响应是一个 nbits 位串，bit b 位于 word(b/32) 的第 (b%32) 位
      · 行内的十六进制按**从高字到低字**打印，即 bit(nbits-1) 在最左侧
      · 解析成整数后，bit b 就是 (value >> b) & 1

输出：
    · 逐位翻转率曲线（图，PNG）
    · 统计 JSON：稳定位数/不稳定位数、平均翻转率、可用密钥长度估计
    · 一份"稳定位掩码"，供 P3 的模糊提取器选位使用

用法：
    python tools/puf_stability.py --in puf_samples.txt
    python tools/puf_stability.py --in puf_samples.txt --threshold 0.02 --out-dir puf_out

关键判读：
    · 平均翻转率越低越好。业界经验：裸 PUF 位翻转率 1%~15% 都常见，
      靠"多采多数表决 + 选稳定位"能压到 <1%。
    · stable_bits 是能直接当密钥材料用的位数。若明显不够 256 bit，
      需要在 P3 用重复码/BCH 把不稳定位也利用起来，或加大 N_BITS。
"""

import argparse
import json
import os
import re
import sys

import numpy as np


# ============================================================================
# 采样文件解析
# ============================================================================

META_RE = re.compile(r"^#\s*PUF_SAMPLE\s+(.*)$")


def parse_samples(path):
    """返回 (meta:dict, resp:list[int], unan:list[int])"""
    meta = {}
    resp = []
    unan = []
    with open(path, "r", encoding="ascii", errors="replace") as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                m = META_RE.match(line)
                if m:
                    for kv in m.group(1).split():
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            meta[k] = v
                continue
            parts = line.split()
            if not parts:
                continue
            try:
                resp.append(int(parts[0], 16))
                unan.append(int(parts[1], 16) if len(parts) > 1 else 0)
            except ValueError:
                print(f"  警告: 第 {ln} 行无法解析，跳过: {line[:60]}", file=sys.stderr)
    return meta, resp, unan


# ============================================================================
# 统计
# ============================================================================

def analyze(resp, unan, nbits, thr):
    n = len(resp)
    if n < 2:
        print("ERROR: 至少需要 2 次采样才能算翻转率", file=sys.stderr)
        sys.exit(2)

    # [n, nbits] 的位矩阵。nbits 只有 128 级别、n 也就几十，直接双循环最直白，
    # 不用对象数组那些花活（曾写错过一次位提取，得不偿失）。
    bits = np.zeros((n, nbits), dtype=np.uint8)
    for i, v in enumerate(resp):
        for b in range(nbits):
            bits[i, b] = (v >> b) & 1

    # 逐位"为 1 的比例"
    p1 = bits.mean(axis=0)
    # 逐位翻转率 = 与该位多数值的偏离比例（直观且与阈值可直接比较）
    maj = (p1 >= 0.5).astype(np.uint8)
    flip_rate = np.mean(bits != maj[None, :], axis=0)

    stable_mask = flip_rate <= thr
    idx_stable = np.nonzero(stable_mask)[0]
    idx_unstable = np.nonzero(~stable_mask)[0]

    # 相邻两次采样的 intra-device Hamming distance（跨上电）
    hd = []
    for i in range(1, n):
        hd.append(int(np.count_nonzero(bits[i - 1] != bits[i])))
    hd = np.array(hd, dtype=np.float64) if hd else np.array([0.0])

    # 位偏置：为 1 的比例偏离 0.5 的程度越小越"随机"
    bias = np.abs(p1 - 0.5)

    # 熵估计（按位独立、Bernoulli 的粗略下界）
    eps = 1e-12
    ent_bits = float(np.sum(-(p1 * np.log2(p1 + eps) + (1 - p1) * np.log2(1 - p1 + eps))))

    # UNAN 掩码的并集（跨所有采样）
    unan_or = 0
    for u in unan:
        unan_or |= u

    return {
        "n_samples": n,
        "nbits": nbits,
        "threshold": thr,
        "flip_rate_mean": float(np.mean(flip_rate)),
        "flip_rate_max": float(np.max(flip_rate)),
        "flip_rate_per_bit": [float(x) for x in flip_rate],
        "stable_bits": int(len(idx_stable)),
        "unstable_bits": int(len(idx_unstable)),
        "stable_indices": [int(i) for i in idx_stable],
        "unstable_indices": [int(i) for i in idx_unstable],
        "hd_cross_boot_mean": float(np.mean(hd)),
        "hd_cross_boot_max": float(np.max(hd)),
        "hd_per_pair": [int(x) for x in hd],
        "bias_mean": float(np.mean(bias)),
        "bias_max": float(np.max(bias)),
        "entropy_bits_est": ent_bits,
        "unan_union_hex": f"{unan_or:0{(nbits + 3)//4}x}",
        "bit_one_ratio": [float(x) for x in p1],
    }


# ============================================================================
# 出图
# ============================================================================

def plot(res, out_png, nbits):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:
        print(f"  (跳过出图，matplotlib 不可用: {e})")
        return False

    fr = np.array(res["flip_rate_per_bit"]) * 100.0
    x = np.arange(nbits)

    fig, ax = plt.subplots(2, 1, figsize=(12, 7))

    # 图内文字一律用 ASCII：matplotlib 默认字体 DejaVu Sans 没有中文字形，
    # 写中文只会得到一堆 missing-glyph 警告和方框，不如直接用英文。
    ax[0].bar(x, fr, width=1.0, color="#4B3FE3")
    ax[0].axhline(res["threshold"] * 100.0, color="#FF4D4F", linestyle="--",
                  linewidth=1.2, label="threshold %.1f%%" % (res["threshold"] * 100))
    ax[0].set_xlabel("PUF bit index")
    ax[0].set_ylabel("flip rate (%)")
    ax[0].set_title("Butterfly PUF per-bit flip rate (across %d cold boots)" % res["n_samples"])
    ax[0].legend()
    ax[0].grid(alpha=0.25)

    bins = np.arange(0, 105, 5)
    ax[1].hist(np.array(res["bit_one_ratio"]) * 100.0, bins=bins,
               color="#22A5F7", edgecolor="white")
    ax[1].set_xlabel("bit == 1 ratio (%)")
    ax[1].set_ylabel("count of bits")
    ax[1].set_title("Bit bias distribution (near 50%% is ideal, near 0/100 means biased)")
    ax[1].grid(alpha=0.25)

    fig.tight_layout()
    fig.savefig(out_png, dpi=130)
    plt.close(fig)
    print(f"  图已保存: {out_png}")
    return True


# ============================================================================

def main():
    ap = argparse.ArgumentParser(description="Butterfly PUF 稳定性统计")
    ap.add_argument("--in", dest="src", required=True, help="采样文件（puf_sample.c 追加输出）")
    ap.add_argument("--threshold", type=float, default=0.01,
                    help="判定'稳定位'的翻转率阈值（默认 0.01 = 1%%）")
    ap.add_argument("--out-dir", default="puf_out", help="输出目录")
    ap.add_argument("--no-plot", action="store_true", help="跳过出图")
    a = ap.parse_args()

    if not os.path.isfile(a.src):
        print(f"ERROR: 找不到采样文件 {a.src}", file=sys.stderr)
        sys.exit(2)

    meta, resp, unan = parse_samples(a.src)
    nbits = int(meta.get("nbits", "128"))

    print("=" * 70)
    print("Butterfly PUF 稳定性分析")
    print("=" * 70)
    print(f"  采样文件 : {a.src}")
    if meta:
        for k in ("nbits", "nwords", "n_samp", "t_force", "t_settle", "bitstream"):
            if k in meta:
                print(f"  {k:9s}: {meta[k]}")
    print(f"  采样条数 : {len(resp)}")
    print(f"  位宽     : {nbits}")

    if len(resp) < 2:
        print("ERROR: 至少 2 次采样", file=sys.stderr)
        sys.exit(2)

    res = analyze(resp, unan, nbits, a.threshold)

    print("-" * 70)
    print(f"  平均翻转率   : {res['flip_rate_mean']*100:.3f} %")
    print(f"  最大位翻转率 : {res['flip_rate_max']*100:.3f} %")
    print(f"  稳定位数     : {res['stable_bits']} / {nbits}  (阈值 {a.threshold*100:.2f}%)")
    print(f"  不稳定位数   : {res['unstable_bits']}")
    print(f"  跨启动 HD    : 均值 {res['hd_cross_boot_mean']:.2f} bit，"
          f"最大 {res['hd_cross_boot_max']:.0f} bit")
    print(f"  位偏置       : 均值 {res['bias_mean']:.3f}（0.5 为最理想）")
    print(f"  熵估计       : {res['entropy_bits_est']:.1f} bit（按位独立的下界）")
    print(f"  UNAN 并集    : 0x{res['unan_union_hex']}（这些位在至少一次采样内抖动过）")

    print("-" * 70)
    if res["stable_bits"] >= 256:
        print("  判读: 稳定位 >= 256 bit，可直接支撑 AES-256 密钥材料。")
    elif res["stable_bits"] >= 128:
        print("  判读: 稳定位在 128~255 之间。够 AES-256 需要配合熵提取（如 SHA-256 压缩），")
        print("        但建议在 P3 用重复码/BCH 把不稳定位也利用起来以增加余量。")
    else:
        print("  判读: 稳定位 < 128 bit，**不足以生成 AES-256 密钥**。")
        print("        对策：① 加大 N_BITS（如 256/512）；② 收紧阈值前先改善单元结构；")
        print("              ③ 提高 M（多数表决次数）；④ 调 T_SETTLE 找翻转率拐点。")

    os.makedirs(a.out_dir, exist_ok=True)
    mp = os.path.join(a.out_dir, "puf_stability.json")
    with open(mp, "w", encoding="utf-8") as f:
        json.dump({"input": a.src, "meta": meta, **res}, f, indent=2, ensure_ascii=False)
    print(f"  统计 JSON    : {mp}")

    # 稳定位掩码（供 P3 选位）
    sp = os.path.join(a.out_dir, "puf_stable_mask.txt")
    with open(sp, "w", encoding="ascii") as f:
        f.write("# stable bit indices (flip_rate <= %g), %d of %d\n"
                % (a.threshold, res["stable_bits"], nbits))
        for i in res["stable_indices"]:
            f.write("%d\n" % i)
    print(f"  稳定位掩码   : {sp}")

    if not a.no_plot:
        plot(res, os.path.join(a.out_dir, "puf_flip_rate.png"), nbits)

    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())