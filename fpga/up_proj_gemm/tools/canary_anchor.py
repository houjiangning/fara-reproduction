#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
canary_anchor.py -- 7-3 HD 门限校准 + 封印锚点生成（PC 侧，一次性）

背景：
    7-2 enrollment 的 FE 参考响应 = 采样文件第 1 条（enroll_gen.w_clean_of(resp[0])）。
    7-3 运行期 HD 门禁需要该参考，但原始响应绝不能与 helper data 同盘明文存放
    （sample XOR helper -> 重复码 -> 暴力恢复密钥材料）。
    本工具在销毁全部采样文件【之前】运行，产出：
      1. ref66 十六进制（66 个选中位按选位序打包，bit i = 第 i 个选中位）
         -> 交板卡 --seal 模式封进 canary.bin（AES 密钥加密后落盘）
      2. HD 校准统计（32 条冷启动样本在选中位上 vs 参考的 HD 分布）
         -> 用于设定运行期门限

用法：
    python tools/canary_anchor.py \
        --samples puf_out/puf_samples_cold.txt \
        --config  puf_out/provision_cold/fara_enroll_config.json \
        --out-dir puf_out/provision_cold

输出：
    ref66.txt            66-bit 打包十六进制（18 个 hex 字符，bit0 = 第 1 个选中位）
    canary_anchor.json   统计与门限建议（归档，非密）
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from puf_stability import parse_samples          # noqa: E402
from gen_fe_vectors import sel_positions         # noqa: E402

NSEL = 66                                        # k=22 -> 3k=66 选中位


def pack_bits(bits):
    """bit[i] -> 整数（bit i = 第 i 个选中位值），再转 hex（bit0 在最低位）"""
    v = 0
    for i, b in enumerate(bits):
        v |= (b & 1) << i
    return v


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", default=os.path.join(here, "..", "puf_out", "puf_samples_cold.txt"))
    ap.add_argument("--config", default=os.path.join(here, "..", "puf_out", "provision_cold",
                                                     "fara_enroll_config.json"))
    ap.add_argument("--out-dir", default=os.path.join(here, "..", "puf_out", "provision_cold"))
    a = ap.parse_args()

    meta, resp, unan = parse_samples(a.samples)
    with open(a.config, "r", encoding="ascii") as f:
        cfg = json.load(f)
    mask = int(cfg["mask"], 16)
    k = int(cfg["k"])
    need = 3 * k
    assert need == NSEL, "k=%d 与 NSEL=%d 不符" % (k, NSEL)

    pos = sel_positions(mask)[:need]
    ref = resp[0]
    ref_bits = [(ref >> b) & 1 for b in pos]
    ref66 = pack_bits(ref_bits)

    hds = []
    for i, r in enumerate(resp):
        hd = sum(((r >> b) & 1) != ref_bits[j] for j, b in enumerate(pos))
        hds.append(hd)

    hist = {}
    for h in hds:
        hist[h] = hist.get(h, 0) + 1
    hmax = max(hds)
    hmean = sum(hds) / len(hds)

    # 与 provisioning 报告口径互验（报告：均值1.75，0x1/1x14/2x11/3x5/5x1）
    report = {
        "n_samples": len(resp),
        "ref_sample_index": 0,
        "ref_resp_hex": "%032x" % ref,
        "mask_hex": "%032x" % mask,
        "n_selected": len(pos),
        "hd_hist": {str(k_): v for k_, v in sorted(hist.items())},
        "hd_mean": round(hmean, 3),
        "hd_max": hmax,
        "thresholds": {
            "pass_le": 1,
            "warn_band": [2, 5],
            "refuse_gt": 5,
            "note": ("pass<=1 为干净路径；2..5 超出 enroll 观测均值但在重复码纠错"
                     "与 canary 仲裁范围内，放行但记 WARNING；>5 超出全部 32 条"
                     "enrollment 观测（max=5），重采样后仍 >5 则拒绝启动（不解密）"),
        },
        "meta_sample_header": meta,
    }

    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "ref66.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("%017x\n" % ref66)               # 66 bit -> ceil(66/4)=17 hex
    with open(os.path.join(a.out_dir, "canary_anchor.json"), "w", encoding="ascii",
              newline="\n") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    print("=" * 64)
    print("canary anchor 生成完成")
    print("  样本数      : %d" % len(resp))
    print("  参考样本    : #0 (%s...)" % ("%032x" % ref)[:16])
    print("  选中位 HD   : 均值 %.2f  分布 %s" % (hmean, dict(sorted(hist.items()))))
    print("  ref66       : %017x  (bit i = 第 i 个选中位)" % ref66)
    print("  门限建议    : pass<=1 / warn 2..5 / refuse>5")
    print("  产物        : %s/{ref66.txt, canary_anchor.json}" % a.out_dir)
    print("  下一步      : ref66.txt 传板卡 /dev/shm 做 --seal，seal 完成后销毁；")
    print("                随后销毁全部采样文件（板卡+PC）")
    print("=" * 64)
    return 0


if __name__ == "__main__":
    sys.exit(main())
