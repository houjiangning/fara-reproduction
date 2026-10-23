#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
export_far_bench.py —— 生成板卡「软硬对比」基准包（FBEN）

为什么需要它
    gen_far_vectors.py 造的是**合成**激励，只证明 far_reroute 数据通路 bit-exact。
    真正要回答的问题是：把**真实 GPT-2 第 0 层 up_proj** 的激活喂给板卡，
    硬件 FaR 的输出是否
        (a) 与软件 FaR 逐 bit 一致（硬件重路由忠实复刻软件）
        (b) 与未加固原始层近似一致（防护无损，守恒）
        (c) 相对软件 FaR，硬件没有额外 CPU 开销（防护在数据通路里完成）
    本脚本就把这三件事所需的**全部参考数据**打包成一个 FBEN 文件。

数据从哪来
    · 激活 X   ：真实 GPT-2 在 transformer.h.0.mlp.c_fc 入口处的输入（LN 之后）
    · shadow W ：board_export/board_W_*.bin（dead 列已被 donor 列覆盖，离线烘焙）
    · FaRMap   ：board_export/board_cfg_*.json（col/dead/div）
    · 原始 W   ：从模型现场取，用于算「守恒参考」Y_base（板卡没有原始 W）

FBEN 文件布局（全小端）
    magic  "FBEN"                          4 B
    header 7 × uint32 : K N M_TOTAL M_TILE G n_in n_out
    in_words      [n_in]  : [X_raw | b | W_shadow]   （X 是**原始**激活，重路由在 PL 内做）
    out_far       [n_out] : 软件 golden Y_far    = hw_order(rewire(X), W_shadow, b)
    out_shadow    [n_out] : 软件 golden Y_shadow = hw_order(X,          W_shadow, b)
    out_base      [n_out] : 软件 golden Y_base   = hw_order(X,          W_orig,   b)

附带输出
    *.fmap  FaRMap 文本（与 gen_far_vectors.py 同格式，板卡按它写 0x30~0x4C 寄存器）
    *.json  元数据 + 软件侧计时 + 守恒统计

用法
    # 真实激活（需 transformers + gpt2-local/）
    python tools/export_far_bench.py --n 1 --out board_test/far_bench.bin

    # 指定提示词与取哪几个 token
    python tools/export_far_bench.py --n 4 --text "FPGA security is important." --out board_test/far_bench.bin

    # 不加载模型，用合成激活（CI / 无 transformers 时）
    python tools/export_far_bench.py --synthetic --n 1 --out board_test/far_bench.bin

    # 已有激活 .npy（[N,K] fp32）
    python tools/export_far_bench.py --x-npy X.npy --out board_test/far_bench.bin
"""

import argparse
import json
import os
import struct
import sys
import time

import numpy as np

# 与 gen_far_vectors.py 共用累加顺序契约，避免两处实现漂移
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from gen_far_vectors import bits32, f32, compute_hw_order, apply_rewire  # noqa: E402

_ROOT = os.path.dirname(_HERE)                                   # .../fpga/up_proj_gemm
_REPO = os.path.dirname(os.path.dirname(_ROOT))                  # .../fara-reproduction
# model_profile.py 在仓库根，脚本从 tools/ 下运行时根目录不在 sys.path 上
if _REPO not in sys.path:
    sys.path.insert(0, _REPO)
_BOARD_EXPORT = os.path.join(_REPO, "board_export")

# 板卡上综合锁死的参数（gemm_up_proj_core.sv 默认值）
HW_M_TILE = 16
HW_M_TOTAL = 3072
HW_G = 8
HW_K = 768


# --------------------------------------------------------------------- 载入

def load_far_cfg(path):
    """读 board_cfg_*.json -> (entries, div)。"""
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    div = int(cfg["div"])
    entries = []
    for e in cfg["far"]:
        entries.append({
            "col": int(e["col"]),
            "dead": [int(d) for d in e["dead"]],
            "div": div,
            "inv_bits": bits32(f32(1.0) / f32(div)),
        })
    return entries, div, cfg


def load_bin_f32(path, count):
    a = np.fromfile(path, dtype="<f4", count=count)
    if a.size != count:
        raise SystemExit(f"[FATAL] {path} 期望 {count} 个 fp32，实到 {a.size}")
    return a.astype(np.float32)


def capture_activations(layer, n_tokens, text):
    """跑一次真实前向，钩住 mlp.c_fc 的输入，取末 n_tokens 个 token 的激活 [N,768]。"""
    from model_profile import load_causal_model
    model, tok = load_causal_model(None)
    model.eval()

    holder = {}
    owner = model
    for p in layer.split("."):
        owner = getattr(owner, p)
    h = owner.register_forward_pre_hook(
        lambda m, inp: holder.__setitem__("x", inp[0].detach().float().clone()))
    try:
        import torch
        ids = tok(text, return_tensors="pt")["input_ids"]
        model(ids)
    finally:
        h.remove()

    x = holder["x"][0]                      # [seq, 768]
    if x.shape[0] < n_tokens:
        raise SystemExit(f"[FATAL] 提示词只有 {x.shape[0]} 个 token，取不出 {n_tokens} 个")
    return x[-n_tokens:].contiguous().numpy().astype(np.float32)


# --------------------------------------------------------------------- 计时

def time_sw_far(W_shadow, W_orig, b, X, entries, reps):
    """软件侧计时：裸 Linear vs 软件 FaR forward（重路由 + Linear）。

    两者都在 CPU 上跑同一份 fp32 数据，差值即『软件 FaR 的额外开销』。
    板卡侧对应量：far_en=0 与 far_en=1 的墙钟时间差（应≈0，重路由在数据通路里）。
    """
    import torch
    Ws = torch.from_numpy(W_shadow)
    Wo = torch.from_numpy(W_orig)
    bt = torch.from_numpy(b)
    Xt = torch.from_numpy(X)

    def sw_base():
        return torch.nn.functional.linear(Xt, Wo, bt)

    def sw_far():
        act = Xt.clone()
        for e in entries:
            A = e["col"]
            inv = float(np.uint32(e["inv_bits"]).view(np.float32))
            half = act[..., A] * inv
            act[..., A] = half
            for d in e["dead"]:
                act[..., d] = act[..., d] + half
        return torch.nn.functional.linear(act, Ws, bt)

    # 预热
    for _ in range(3):
        sw_base(); sw_far()

    def bench(fn):
        t0 = time.perf_counter()
        for _ in range(reps):
            fn()
        return (time.perf_counter() - t0) / reps

    t_base = bench(sw_base)
    t_far = bench(sw_far)
    return t_base, t_far


# --------------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description="生成板卡软硬对比基准包 FBEN")
    ap.add_argument("--layer", default="transformer.h.0.mlp.c_fc")
    ap.add_argument("--n", type=int, default=1, help="token 数（<= RTL N_MAX=32）")
    ap.add_argument("--m-tile", type=int, default=HW_M_TILE)
    ap.add_argument("--g", type=int, default=HW_G)
    ap.add_argument("--cfg", default=os.path.join(_BOARD_EXPORT,
                    "board_cfg_transformer_h_0_mlp_c_fc.json"))
    ap.add_argument("--wbin", default=os.path.join(_BOARD_EXPORT,
                    "board_W_transformer_h_0_mlp_c_fc.bin"))
    ap.add_argument("--bbin", default=os.path.join(_BOARD_EXPORT,
                    "board_b_transformer_h_0_mlp_c_fc.bin"))
    ap.add_argument("--text", default=None, help="取激活用的提示词")
    ap.add_argument("--x-npy", default=None, help="直接从 .npy 读激活 [N,K]")
    ap.add_argument("--synthetic", action="store_true",
                    help="不加载模型，用固定 seed 合成激活")
    ap.add_argument("--seed", type=int, default=20261005)
    ap.add_argument("--reps", type=int, default=50, help="软件计时重复次数")
    ap.add_argument("--out", default=os.path.join(_ROOT, "board_test", "far_bench.bin"))
    args = ap.parse_args()

    K, M_TOTAL = HW_K, HW_M_TOTAL
    M_TILE, G = args.m_tile, args.g
    if M_TOTAL % M_TILE != 0:
        raise SystemExit("[FATAL] M_TOTAL 不能被 M_TILE 整除")

    # ---- 1. FaRMap + shadow W + b ----
    entries, div, cfg_raw = load_far_cfg(args.cfg)
    if cfg_raw["in_features"] != K or cfg_raw["out_features"] != M_TOTAL:
        raise SystemExit(f"[FATAL] 配置维度 {cfg_raw['in_features']}x{cfg_raw['out_features']} "
                         f"与板卡 {K}x{M_TOTAL} 不符")
    W_shadow = load_bin_f32(args.wbin, M_TOTAL * K).reshape(M_TOTAL, K)
    b = load_bin_f32(args.bbin, M_TOTAL)
    print(f"[cfg] layer={args.layer}  div={div}  n_far={len(entries)}  "
          f"K={K} M_TOTAL={M_TOTAL} M_TILE={M_TILE} G={G}")

    # ---- 2. 激活 X ----
    if args.x_npy:
        X = np.load(args.x_npy).astype(np.float32)
        if X.shape != (args.n, K):
            raise SystemExit(f"[FATAL] {args.x_npy} 形状 {X.shape} != ({args.n}, {K})")
        src = f"npy:{args.x_npy}"
    elif args.synthetic:
        rng = np.random.default_rng(args.seed)
        X = (rng.standard_normal((args.n, K)) * 1.0).astype(np.float32)
        src = f"synthetic(seed={args.seed})"
    else:
        text = args.text or (
            "Field programmable gate arrays offer flexible hardware that can be "
            "reconfigured for accelerating deep neural networks at the edge.")
        X = capture_activations(args.layer, args.n, text)
        src = f"model:{args.layer}"
    print(f"[cfg] 激活 X {X.shape}  来源 {src}")

    # ---- 3. 原始 W（守恒参考）----
    if args.synthetic or args.x_npy:
        # 没有模型时无法拿原始 W：用「把 shadow 的 dead 列换回不了」的近似说明，
        # 这里退化为 shadow 本身，守恒参考无意义，会在 JSON 里标注。
        W_orig = W_shadow.copy()
        have_orig = False
        print("[warn] 无模型：无法取原始 W，Y_base 退化为 Y_shadow（守恒参考无效）")
    else:
        from model_profile import load_causal_model
        model, _ = load_causal_model(None)
        m = model
        for p in args.layer.split("."):
            m = getattr(m, p)
        w = m.weight.detach().float()
        if w.shape[0] != M_TOTAL:          # Conv1D 是 [in,out]
            w = w.t().contiguous()
        W_orig = w.numpy().astype(np.float32)
        have_orig = True
        if not np.array_equal(W_orig.reshape(-1)[:64], W_shadow.reshape(-1)[:64]):
            print("[warn] 原始 W 与 shadow W 前 64 元素不同（预期：dead 列被覆盖）")

    # ---- 4. 软件 golden ----
    Xf = apply_rewire(X, entries)
    Y_far = compute_hw_order(Xf, W_shadow, b, M_TILE, G)
    Y_shadow = compute_hw_order(X, W_shadow, b, M_TILE, G)
    Y_base = compute_hw_order(X, W_orig, b, M_TILE, G)

    # 守恒：FaR 硬件输出（≈Y_far）与未加固原始层（Y_base）的偏差
    dif = np.abs(Y_far.astype(np.float64) - Y_base.astype(np.float64))
    scale = max(float(np.abs(Y_base).max()), 1e-30)
    cons_rel = float(dif.max()) / scale

    # ---- 5. 拼输入流：X 用原始激活，W 用 shadow ----
    in_words = []
    for n in range(args.n):
        for k in range(K):
            in_words.append(bits32(X[n, k]))
    for m in range(M_TOTAL):
        in_words.append(bits32(b[m]))
    for m in range(M_TOTAL):
        for k in range(K):
            in_words.append(bits32(W_shadow[m, k]))
    if len(in_words) % 2 != 0:
        raise SystemExit("[FATAL] 输入字数非偶，无法按 64-bit beat 打包")

    n_out = M_TOTAL * args.n
    def pack_y(Y):
        out = []
        for t in range(M_TOTAL // M_TILE):
            for n in range(args.n):
                for ml in range(M_TILE):
                    out.append(bits32(Y[t * M_TILE + ml, n]))
        return out

    out_far, out_shadow, out_base = pack_y(Y_far), pack_y(Y_shadow), pack_y(Y_base)
    n_in = len(in_words)

    # ---- 6. 写 FBEN ----
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(b"FBEN")
        f.write(struct.pack("<7I", K, args.n, M_TOTAL, M_TILE, G, n_in, n_out))
        f.write(struct.pack(f"<{n_in}I", *in_words))
        f.write(struct.pack(f"<{n_out}I", *out_far))
        f.write(struct.pack(f"<{n_out}I", *out_shadow))
        f.write(struct.pack(f"<{n_out}I", *out_base))

    # ---- 7. 写 .fmap（板卡按它写 0x30~0x4C）----
    fmap_path = os.path.splitext(args.out)[0] + ".fmap"
    with open(fmap_path, "w", encoding="ascii") as f:
        f.write(f"{len(entries)}\n")
        for e in entries:
            nd = len(e["dead"])
            d0 = e["dead"][0] if nd > 0 else 0
            d1 = e["dead"][1] if nd > 1 else 0
            f.write(f"{e['col']:08x} {e['inv_bits']:08x} {nd:01x} {d0:08x} {d1:08x}\n")

    # ---- 8. 软件计时 ----
    t_base = t_far = float("nan")
    if not args.synthetic and not args.x_npy:
        try:
            t_base, t_far = time_sw_far(W_shadow, W_orig, b, X, entries, args.reps)
        except Exception as e:      # pragma: no cover
            print(f"[warn] 软件计时失败: {e}")

    n_hits = sum(args.n * (1 + len(e["dead"])) for e in entries)
    meta = {
        "layer": args.layer, "div": div, "n_far": len(entries), "n_tokens": args.n,
        "K": K, "M_TOTAL": M_TOTAL, "M_TILE": M_TILE, "G": G,
        "N_IN": n_in, "N_OUT": n_out, "n_hits": n_hits,
        "activation_source": src, "have_original_W": have_orig,
        "conservation": {
            "max_abs_err": float(dif.max()),
            "rel_err": cons_rel,
            "note": ("dead 通道是真实激活，守恒误差取决于其活跃度"
                     if have_orig else "无原始 W，守恒参考无效"),
        },
        "sw_timing_s": {"base_linear": t_base, "far_forward": t_far,
                        "far_overhead": (t_far - t_base) if t_far == t_far else float("nan"),
                        "reps": args.reps},
        "bin_file": os.path.relpath(args.out, _REPO).replace("\\", "/"),
        "fmap_file": os.path.relpath(fmap_path, _REPO).replace("\\", "/"),
    }
    with open(os.path.splitext(args.out)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    # ---- 9. 汇报 ----
    print(f"[OK] 写出 {args.out}  ({4 * (8 + n_in + 3 * n_out) / 1e6:.2f} MB)")
    print(f"[OK] 写出 {fmap_path}")
    print(f"     输入 {n_in} 字（{n_in // 2} beat）  期望输出 {n_out} 字 × 3 份")
    print(f"     FAR_HITS 应为 {n_hits}")
    print(f"[守恒] max|Y_far-Y_base| = {dif.max():.3e}  相对 {cons_rel:.3e}")
    if t_base == t_base:
        print(f"[计时] 软件 Linear {t_base * 1e6:.1f} us   "
              f"软件 FaR forward {t_far * 1e6:.1f} us   "
              f"FaR 额外开销 {(t_far - t_base) * 1e6:.1f} us")


if __name__ == "__main__":
    main()
