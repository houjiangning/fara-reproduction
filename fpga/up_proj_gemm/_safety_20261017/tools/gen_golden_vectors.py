#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_golden_vectors.py —— 为 GEMM 自检 testbench 生成激励 + 期望输出

严格复刻 rtl/gemm_up_proj_core.sv 文件头声明的浮点累加顺序：

    1) 每条 lane 负责一个输出行 m；K 个乘积分摊到 G 条部分和链：
         acc[g] 累加所有 (k mod G)==g 的乘积，k 由小到大；
    2) acc[0] 预置为 bias[m]，acc[1..G-1] 预置 0；
    3) 归约从 acc[0] 起串行左折：red = (((acc0+acc1)+acc2)+...+acc[G-1])；
    4) Y[m][n] = red。

所有算术都按 IEEE-754 binary32 逐次舍入（numpy.float32），与 Xilinx
floating_point IP 的 round-to-nearest-even、以及 xsim 的 shortreal 一致。

数据布局（与 RTL 输入流契约一致，64-bit beat 低字先发）：
    [ X : N*K 字 ]         X[n][k]     @ n*K + k
    [ b : M_TOTAL 字 ]     b[m]        @ N*K + m
    [ W : M_TOTAL*K 字 ]   W[m][k]     @ N*K + M_TOTAL + m*K + k

输出布局：
    for t in 0..N_TILES-1: for n in 0..N-1: for ml in 0..M_TILE-1:
        Y[t*M_TILE + ml][n]

输出 .mem 文本格式（TB 用 $fscanf 读）：
    第 1 行：9 个空格分隔整数
             K N M_TOTAL M_TILE G ADD_LAT MUL_LAT N_IN N_OUT
    随后 N_IN  行：输入流每个 fp32 字的 8 位十六进制（小写，无前缀）
    随后 N_OUT 行：期望输出每个 fp32 字的 8 位十六进制
"""

import argparse
import json
import os
import sys

import numpy as np


def bits32(v):
    """np.float32 -> uint32 位模式"""
    return int(np.float32(v).view(np.uint32))


def gen_data(K, N, M_TOTAL, seed, stress):
    rng = np.random.default_rng(seed)
    X = (rng.standard_normal((N, K)) * 1.0).astype(np.float32)
    W = (rng.standard_normal((M_TOTAL, K)) * 0.5).astype(np.float32)
    b = (rng.standard_normal(M_TOTAL) * 0.25).astype(np.float32)

    if stress:
        # 给一部分元素乘 2^k（k∈[-12,12]），制造指数跨度与相消，
        # 让不同累加顺序的结果在低位真正分叉（否则测试对顺序不敏感）。
        for arr in (X, W):
            mask = rng.random(arr.shape) < 0.10
            expo = rng.integers(-12, 13, size=arr.shape).astype(np.float32)
            arr[mask] = (arr[mask] * np.exp2(expo[mask])).astype(np.float32)
    return X, W, b


def compute_hw_order(X, W, b, M_TILE, G):
    """按硬件累加顺序算 Y。"""
    N, K = X.shape
    M_TOTAL = W.shape[0]
    assert M_TOTAL % M_TILE == 0, "M_TOTAL 必须被 M_TILE 整除"
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


def compute_naive(X, W, b):
    """朴素顺序和（bias 最后加）——仅用于灵敏度报告，不参与比对。"""
    N, K = X.shape
    M_TOTAL = W.shape[0]
    Y = np.zeros((M_TOTAL, N), dtype=np.float32)
    for n in range(N):
        for m in range(M_TOTAL):
            s = np.float32(0.0)
            for k in range(K):
                s = np.float32(s + np.float32(X[n, k] * W[m, k]))
            Y[m, n] = np.float32(s + np.float32(b[m]))
    return Y


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    ap = argparse.ArgumentParser(description="生成 GEMM 自检向量")
    ap.add_argument("--k", type=int, default=16, help="规约深度 K")
    ap.add_argument("--n", type=int, default=2, help="token 数 N")
    ap.add_argument("--m-total", type=int, default=64, help="输出总行数 M_TOTAL")
    ap.add_argument("--m-tile", type=int, default=16, help="每趟输出行数 M_TILE")
    ap.add_argument("--g", type=int, default=8, help="部分和链数 G")
    ap.add_argument("--add-lat", type=int, default=4)
    ap.add_argument("--mul-lat", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20260930)
    ap.add_argument("--no-stress", action="store_true", help="关闭指数跨度注入")
    ap.add_argument("--force", action="store_true",
                    help="忽略 G >= ADD_LAT+1 硬约束（仅供反向测试：验证 TB 能抓到该缺陷）")
    ap.add_argument("--out", type=str,
                    default=os.path.join(root, "sim", "golden_vectors.mem"))
    ap.add_argument("--bin", type=str, default=None,
                    help="额外写出板卡 L3 用的二进制激励包（gemm_dma_test 读取）")
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

    X, W, b = gen_data(K, N, M_TOTAL, args.seed, not args.no_stress)
    Y = compute_hw_order(X, W, b, M_TILE, G)

    # ---- 拼输入流 ----
    in_words = []
    for n in range(N):
        for k in range(K):
            in_words.append(bits32(X[n, k]))
    for m in range(M_TOTAL):
        in_words.append(bits32(b[m]))
    for m in range(M_TOTAL):
        for k in range(K):
            in_words.append(bits32(W[m, k]))

    # ---- 拼期望输出 ----
    N_TILES = M_TOTAL // M_TILE
    out_words = []
    for t in range(N_TILES):
        for n in range(N):
            for ml in range(M_TILE):
                out_words.append(bits32(Y[t * M_TILE + ml, n]))

    n_in, n_out = len(in_words), len(out_words)
    if n_in % 2 != 0:
        print(f"[FATAL] 输入字数 {n_in} 不是偶数，无法按 64-bit beat 打包")
        sys.exit(2)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="ascii") as f:
        f.write(f"{K} {N} {M_TOTAL} {M_TILE} {G} {args.add_lat} {args.mul_lat} "
                f"{n_in} {n_out}\n")
        for w in in_words:
            f.write(f"{w:08x}\n")
        for w in out_words:
            f.write(f"{w:08x}\n")

    # ---- 板卡 L3 二进制激励包 ----
    # 布局（全小端）：magic"GEMV" | 7 x u32 头 | n_in x u32 输入 | n_out x u32 期望输出
    # 头字段顺序：K N M_TOTAL M_TILE G n_in n_out
    if args.bin:
        import struct
        os.makedirs(os.path.dirname(os.path.abspath(args.bin)), exist_ok=True)
        with open(args.bin, "wb") as fb:
            fb.write(b"GEMV")
            fb.write(struct.pack("<7I", K, N, M_TOTAL, M_TILE, G, n_in, n_out))
            fb.write(struct.pack(f"<{n_in}I", *in_words))
            fb.write(struct.pack(f"<{n_out}I", *out_words))
        print(f"[OK] 写出 {args.bin} "
              f"({4 * (8 + n_in + n_out)} 字节，板卡 L3 用)")

    # ---- 灵敏度报告：换成朴素顺序会不会改变结果 ----
    Yn = compute_naive(X, W, b)
    diff = int(np.count_nonzero(Y.view(np.uint32) != Yn.view(np.uint32)))
    ulp_max = 0
    for m in range(M_TOTAL):
        for n in range(N):
            a = int(Y[m, n].view(np.uint32))
            c = int(Yn[m, n].view(np.uint32))
            ulp_max = max(ulp_max, abs(a - c))

    meta = {
        "K": K, "N": N, "M_TOTAL": M_TOTAL, "M_TILE": M_TILE, "G": G,
        "ADD_LAT": args.add_lat, "MUL_LAT": args.mul_lat,
        "N_IN": n_in, "N_OUT": n_out, "seed": args.seed,
        "stress": not args.no_stress,
        "sensitivity_vs_naive_order": {
            "differing_words": diff,
            "total_words": M_TOTAL * N,
            "max_ulp_distance": ulp_max,
        },
        "mem_file": os.path.relpath(args.out, root).replace("\\", "/"),
    }
    json_path = os.path.splitext(args.out)[0] + ".json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)

    print(f"[OK] 写出 {args.out}")
    print(f"     配置 K={K} N={N} M_TOTAL={M_TOTAL} M_TILE={M_TILE} G={G} "
          f"ADD_LAT={args.add_lat} MUL_LAT={args.mul_lat}")
    print(f"     输入 {n_in} 字 / {n_in // 2} beat，期望输出 {n_out} 字")
    print(f"[灵敏度] 若把累加顺序换成朴素顺序，{diff}/{M_TOTAL * N} 个输出字会变 "
          f"(最大 {ulp_max} ulp)")
    if diff == 0:
        print("     警告：该组数据对累加顺序不敏感，测试无法区分顺序错误；"
              "建议换 seed 或调大 --k")


if __name__ == "__main__":
    main()
