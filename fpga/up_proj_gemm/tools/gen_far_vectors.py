#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_far_vectors.py —— 为 GEMM 的 FaR（激活重路由）自检生成激励 + 期望输出

与 gen_golden_vectors.py 的关系
    基线向量（gen_golden_vectors.py）验证的是 GEMM 数据通路本身；
    本脚本验证的是 far_reroute.sv 这一步 —— 在 X 进 xbuf 之后、GEMM 之前
    就地施加的激活重路由。两者共用同一套浮点累加顺序契约。

硬件在做什么（逐字对应 rtl/far_reroute.sv）
    对每条 FaRMap 条目 e = (A, inv=1/div, dead[])，对每个 token n：
        half      = X[n][A] * inv        # 乘 1/div，不是除（省一个除法器）
        X[n][A]   = half                 # 主 lane：激活规约到 1/div
        X[n][d]   = X[n][d] + half       # 每条 dead lane 吃入 x[A]/div
    权重侧不动：shadow（dead 列 = donor 列 W[:,A]）由 PC 离线烘焙进 board_W。

    因此输入流里 X 必须是**原始激活**（重路由在 PL 内部做），
    而 W 必须是 **shadow 权重**。这一点最容易搞反，务必注意。

    为什么守恒：Y = Σ_k x'[k]·W'[m,k]
        = (x[A]/div)·W[m,A] + Σ_d (x[d]+x[A]/div)·W[m,A]   # dead 列被 shadow 成 W[:,A]
        = (x[A]/div)·W[m,A]·(1 + (div-1))  +  Σ_d x[d]·W[m,A]
        = x[A]·W[m,A] + Σ_d x[d]·W[m,A]
        ≈ x[A]·W[m,A]      （d 是真死通道，x[d]≈0）
    与未加固的 x[A]·W[m,A] 一致 → 输出守恒。

    --dead-zero 把 dead 通道激活压到 ~1e-7，用于把「守恒误差」这一指标
    做成有意义的数字；不加则 dead 通道是稠密随机值，此时只验证 bit-exact
    （重路由数据通路是否与 Python 模型逐位一致），守恒不成立也不该成立。

输出（两个文件）
    *.mem   与 gen_golden_vectors.py 完全相同的格式（TB 的 $fscanf 不变）：
              第 1 行 9 个整数 K N M_TOTAL M_TILE G ADD_LAT MUL_LAT N_IN N_OUT
              随后 N_IN  行输入字（8 位十六进制）
              随后 N_OUT 行期望输出字
    *.fmap  FaRMap 文本（TB 用 +FARMAP= 载入后写 0x34~0x4C 寄存器）：
              第 1 行：N_FAR
              随后 N_FAR 行：A INV ND D0 D1（均为十六进制）

用法：
    python tools/gen_far_vectors.py                       # 默认稠密 dead（压数据通路）
    python tools/gen_far_vectors.py --dead-zero           # dead≈0（看守恒误差）
    python tools/gen_far_vectors.py --n-far 6 --div 2 --k 32 --n 4
"""

import argparse
import json
import os
import struct
import sys

import numpy as np


# --------------------------------------------------------------------- 基础

def bits32(v):
    return int(np.float32(v).view(np.uint32))


def f32(v):
    return np.float32(v)


def gen_data(K, N, M_TOTAL, seed, stress):
    """与 gen_golden_vectors.gen_data 完全一致，保证同 seed 同数据。"""
    rng = np.random.default_rng(seed)
    X = (rng.standard_normal((N, K)) * 1.0).astype(np.float32)
    W = (rng.standard_normal((M_TOTAL, K)) * 0.5).astype(np.float32)
    b = (rng.standard_normal(M_TOTAL) * 0.25).astype(np.float32)

    if stress:
        for arr in (X, W):
            mask = rng.random(arr.shape) < 0.10
            expo = rng.integers(-12, 13, size=arr.shape).astype(np.float32)
            arr[mask] = (arr[mask] * np.exp2(expo[mask])).astype(np.float32)
    return X, W, b


def compute_hw_order(X, W, b, M_TILE, G):
    """按硬件累加顺序算 Y（与 gen_golden_vectors.compute_hw_order 同源）。"""
    N, K = X.shape
    M_TOTAL = W.shape[0]
    assert M_TOTAL % M_TILE == 0
    N_TILES = M_TOTAL // M_TILE

    Y = np.zeros((M_TOTAL, N), dtype=np.float32)
    for t in range(N_TILES):
        for n in range(N):
            for ml in range(M_TILE):
                m = t * M_TILE + ml
                acc = [np.float32(0.0)] * G
                acc[0] = np.float32(b[m])
                for k in range(K):
                    p = np.float32(X[n, k] * W[m, k])
                    g = k % G
                    acc[g] = np.float32(acc[g] + p)
                red = acc[0]
                for g in range(1, G):
                    red = np.float32(red + acc[g])
                Y[m, n] = red
    return Y


# --------------------------------------------------------------------- FaRMap

def make_farmap(K, n_far, div):
    """造一张小而全覆盖的 FaRMap。

    约束（与 far_defense.apply_rewire 的保证一致，也是 far_reroute 正确性的前提）：
      * 各条目的 A 互不相同；
      * 各条目的 dead 互不相同，且不与任何 A 重合。
    取法：dead 占低位 [0, n_far)，A 占高位 [K-n_far, K)，天然不相交。
    """
    if 2 * n_far > K:
        print(f"[FATAL] K={K} 太小，放不下 n_far={n_far} 条互不冲突的条目")
        sys.exit(2)
    inv_bits = bits32(f32(1.0) / f32(div))
    entries = []
    for i in range(n_far):
        entries.append({
            "col": K - 1 - i,      # A：敏感输入通道
            "dead": [i],           # div=2 → 1 条 dead lane
            "div": div,
            "inv_bits": inv_bits,
        })
    return entries


def apply_rewire(X, entries):
    """在 X 上就地施加激活重路由，逐字复刻 far_reroute.sv。

    顺序：条目外层、token 内层；同一 (e, n) 先写 A 再写各 dead。
    A 之间、dead 之间、A 与 dead 之间均不相交，故就地改写无副作用。
    """
    Xp = X.copy()
    N = X.shape[0]
    for e in entries:
        A = e["col"]
        inv = f32(np.uint32(e["inv_bits"]).view(np.float32))
        for n in range(N):
            half = f32(Xp[n, A] * inv)          # 主 lane
            Xp[n, A] = half
            for d in e["dead"]:                 # dead lane
                Xp[n, d] = f32(Xp[n, d] + half)
    return Xp


def apply_shadow(W, entries):
    """把 donor 整列复制到 dead 列（离线 shadow，PC 侧做，硬件不做）。"""
    Wp = W.copy()
    for e in entries:
        A = e["col"]
        for d in e["dead"]:
            Wp[:, d] = W[:, A]
    return Wp


# --------------------------------------------------------------------- 主流程

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser(description="生成 GEMM FaR 重路由自检向量")
    ap.add_argument("--k", type=int, default=16)
    ap.add_argument("--n", type=int, default=2)
    ap.add_argument("--m-total", type=int, default=64)
    ap.add_argument("--m-tile", type=int, default=16)
    ap.add_argument("--g", type=int, default=8)
    ap.add_argument("--add-lat", type=int, default=4)
    ap.add_argument("--mul-lat", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20261005)
    ap.add_argument("--n-far", type=int, default=4, help="FaRMap 条目数")
    ap.add_argument("--div", type=int, default=2, choices=[2, 3])
    ap.add_argument("--dead-zero", action="store_true",
                    help="把 dead 通道激活压到 ~1e-7，用于演示输出守恒")
    ap.add_argument("--no-stress", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="忽略 G >= ADD_LAT+1 硬约束（反向测试用）")
    ap.add_argument("--out", type=str,
                    default=os.path.join(root, "sim", "far_vectors.mem"))
    ap.add_argument("--fmap", type=str, default=None,
                    help="FaRMap 输出路径，默认与 --out 同目录同名 .fmap")
    ap.add_argument("--bin", type=str, default=None,
                    help="额外写出板卡用的二进制激励包（GEMV 格式）")
    args = ap.parse_args()

    K, N, M_TOTAL, M_TILE, G = args.k, args.n, args.m_total, args.m_tile, args.g
    if G < args.add_lat + 1 and not args.force:
        print(f"[FATAL] 违反硬约束 G >= ADD_LAT+1：G={G}, ADD_LAT={args.add_lat}")
        sys.exit(2)
    if M_TOTAL % M_TILE != 0:
        print(f"[FATAL] M_TOTAL({M_TOTAL}) 不能被 M_TILE({M_TILE}) 整除")
        sys.exit(2)
    if K > 768:
        print("[FATAL] K 超过 RTL K_MAX=768")
        sys.exit(2)
    if args.n_far > 16:
        print("[FATAL] n_far 超过 RTL N_ENTRY_MAX=16")
        sys.exit(2)

    fmap_path = args.fmap or (os.path.splitext(args.out)[0] + ".fmap")

    # ---- 1. 数据与 FaRMap ----
    X0, W0, b = gen_data(K, N, M_TOTAL, args.seed, not args.no_stress)
    entries = make_farmap(K, args.n_far, args.div)

    # dead 通道压零（可选）：必须在重路由之前改，硬件看到的就是改后的 X
    if args.dead_zero:
        for e in entries:
            for d in e["dead"]:
                X0[:, d] = (X0[:, d] * np.float32(1e-7)).astype(np.float32)

    Xf = apply_rewire(X0, entries)          # 硬件内部会得到的那份 X
    Ws = apply_shadow(W0, entries)          # 输入流里携带的 shadow W

    Y_far  = compute_hw_order(Xf, Ws, b, M_TILE, G)
    Y_base = compute_hw_order(X0, W0, b, M_TILE, G)

    # ---- 2. 拼输入流：X 用原始激活，W 用 shadow ----
    in_words = []
    for n in range(N):
        for k in range(K):
            in_words.append(bits32(X0[n, k]))
    for m in range(M_TOTAL):
        in_words.append(bits32(b[m]))
    for m in range(M_TOTAL):
        for k in range(K):
            in_words.append(bits32(Ws[m, k]))

    N_TILES = M_TOTAL // M_TILE
    out_words = []
    for t in range(N_TILES):
        for n in range(N):
            for ml in range(M_TILE):
                out_words.append(bits32(Y_far[t * M_TILE + ml, n]))

    n_in, n_out = len(in_words), len(out_words)
    if n_in % 2 != 0:
        print(f"[FATAL] 输入字数 {n_in} 不是偶数，无法按 64-bit beat 打包")
        sys.exit(2)

    # ---- 3. 写 .mem ----
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="ascii") as f:
        f.write(f"{K} {N} {M_TOTAL} {M_TILE} {G} {args.add_lat} {args.mul_lat} "
                f"{n_in} {n_out}\n")
        for w in in_words:
            f.write(f"{w:08x}\n")
        for w in out_words:
            f.write(f"{w:08x}\n")

    # ---- 4. 写 .fmap ----
    with open(fmap_path, "w", encoding="ascii") as f:
        f.write(f"{len(entries)}\n")
        for e in entries:
            nd = len(e["dead"])
            d0 = e["dead"][0] if nd > 0 else 0
            d1 = e["dead"][1] if nd > 1 else 0
            f.write(f"{e['col']:08x} {e['inv_bits']:08x} {nd:01x} "
                    f"{d0:08x} {d1:08x}\n")

    # ---- 5. 板卡二进制包（可选）----
    if args.bin:
        os.makedirs(os.path.dirname(os.path.abspath(args.bin)), exist_ok=True)
        with open(args.bin, "wb") as fb:
            fb.write(b"GEMV")
            fb.write(struct.pack("<7I", K, N, M_TOTAL, M_TILE, G, n_in, n_out))
            fb.write(struct.pack(f"<{n_in}I", *in_words))
            fb.write(struct.pack(f"<{n_out}I", *out_words))
        print(f"[OK] 写出 {args.bin} "
              f"({4 * (8 + n_in + n_out)} 字节，板卡 L3 用)")

    # ---- 6. 守恒与命中的报告 ----
    dif = np.abs(Y_far.astype(np.float64) - Y_base.astype(np.float64))
    scale = max(float(np.abs(Y_base).max()), 1e-30)
    rel = float(dif.max()) / scale
    bit_diff = int(np.count_nonzero(Y_far.view(np.uint32) != Y_base.view(np.uint32)))

    n_hits = sum(N * (1 + len(e["dead"])) for e in entries)

    meta = {
        "K": K, "N": N, "M_TOTAL": M_TOTAL, "M_TILE": M_TILE, "G": G,
        "ADD_LAT": args.add_lat, "MUL_LAT": args.mul_lat,
        "N_IN": n_in, "N_OUT": n_out, "seed": args.seed,
        "stress": not args.no_stress, "dead_zero": bool(args.dead_zero),
        "n_far": len(entries), "div": args.div, "n_hits": n_hits,
        "far": entries,
        "conservation": {
            "max_abs_err": float(dif.max()),
            "rel_err": rel,
            "differing_words_vs_baseline": bit_diff,
            "total_words": M_TOTAL * N,
        },
        "mem_file": os.path.relpath(args.out, root).replace("\\", "/"),
        "fmap_file": os.path.relpath(fmap_path, root).replace("\\", "/"),
    }
    with open(os.path.splitext(args.out)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    print(f"[OK] 写出 {args.out}   与   {fmap_path}")
    print(f"     配置 K={K} N={N} M_TOTAL={M_TOTAL} M_TILE={M_TILE} G={G} "
          f"ADD_LAT={args.add_lat} MUL_LAT={args.mul_lat}")
    print(f"     FaRMap {len(entries)} 条（div={args.div}）："
          + ", ".join(f"A={e['col']}->d{e['dead']}" for e in entries))
    print(f"     输入 {n_in} 字 / {n_in // 2} beat，期望输出 {n_out} 字")
    print(f"     重路由写入元素数 FAR_HITS 应为 {n_hits}")
    print(f"[守恒] max|Y_far-Y_base| = {dif.max():.3e}  相对 {rel:.3e}  "
          f"({bit_diff}/{M_TOTAL * N} 个输出字不同)")
    if args.dead_zero and rel > 1e-3:
        print("     !! dead-zero 下守恒误差仍偏大，检查 dead 通道是否真的被压零")
    if not args.dead_zero:
        print("     注意：未加 --dead-zero 时 dead 通道是稠密随机值，"
              "守恒不成立属预期，本用例只验证重路由数据通路 bit-exact")


if __name__ == "__main__":
    main()
