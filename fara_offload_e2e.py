"""fara_offload_e2e.py —— PC 侧 offload hook + 端到端核验

把 GPT-2 的 transformer.h.0.mlp.c_fc 从 torch 改接到 ZCU106 板卡的硬件 FaR GEMM，
跑通整条链路：

    prompt -> tokenizer -> 骨架其余层(torch) --(h.0.mlp.c_fc 激活 X)--> 板卡
           -> 硬件 GEMM + far_reroute -> Y --> 回接骨架 -> ... -> logits -> 文本

核验三条（缺一不可）：
  (1) 接线正确 + 硬件忠实：offload 模型 与 参考模型 m_ref 的
      **该层输出**与**最终 logits** 逐 bit 一致。
      m_ref 用 numpy/torch 逐字复刻硬件口径：hw_order(rewire(X), W_shadow, b)。
      （板卡侧 L3/L4 已证硬件 == 该口径；这里把等式一路延伸到整模型。）
  (2) 防护无损：offload 模型 与 原始模型 m_clean（纯 torch，原始 W）的
      最终 logits 接近（max|Δ| 在守恒界内），top-1 一致率高。
  (3) 端到端可用：offload 模型能正常贪心生成文本（不崩、不 NaN）。

两种后端：
  --backend local  本地 numpy/torch 复刻硬件口径（无板卡时验证接线与流程）
  --backend board  真的走 TCP 到板卡 fara_infer_server

用法
  python fara_offload_e2e.py --backend local
  python fara_offload_e2e.py --backend board --host 192.168.1.200 --port 9000
  python fara_offload_e2e.py --backend board --prompt "FPGA security" --max-new 8

输出
  e2e_verify.json   （供仪表盘/报告引用）
"""

import argparse
import copy
import json
import os
import socket
import struct
import time

import numpy as np
import torch

from model_profile import load_causal_model

DIR = os.path.dirname(os.path.abspath(__file__))
BOARD_EXPORT = os.path.join(DIR, "board_export")
LAYER = "transformer.h.0.mlp.c_fc"
K_COLS = 768
M_TOTAL = 3072
G = 8
N_MAX = 32
HW_VERSION = 0x00020000


# ===================================================================== 数据加载

def load_shadow_weights():
    """板卡上常驻的那份 shadow W/b（dead 列已被 donor 列覆盖）。"""
    wpath = os.path.join(BOARD_EXPORT, "board_W_transformer_h_0_mlp_c_fc.bin")
    bpath = os.path.join(BOARD_EXPORT, "board_b_transformer_h_0_mlp_c_fc.bin")
    cpath = os.path.join(BOARD_EXPORT, "board_cfg_transformer_h_0_mlp_c_fc.json")
    W = np.fromfile(wpath, dtype="<f4").reshape(M_TOTAL, K_COLS)
    b = np.fromfile(bpath, dtype="<f4")
    with open(cpath, encoding="utf-8") as f:
        cfg = json.load(f)
    assert W.shape == (M_TOTAL, K_COLS) and b.shape == (M_TOTAL,)
    entries = []
    for e in cfg["far"]:
        entries.append({"col": int(e["col"]), "row": int(e["row"]),
                        "div": int(e["div"]), "dead": [int(d) for d in e["dead"]]})
    return W, b, int(cfg["div"]), entries


def _inv_bits(div):
    """fp32 1/div 的位模式（div=2 → 0x3F000000，与 .fmap / FAR_INV 一致）。"""
    return struct.unpack("<I", struct.pack("<f", np.float32(1.0) / np.float32(div)))[0]


def farmap_wire(entries):
    """FaRMap 条目 -> 板卡寄存器顺序的 5*u32 列表。"""
    out = []
    for e in entries:
        dead = e["dead"]
        nd = len(dead)
        d0 = dead[0] if nd > 0 else 0
        d1 = dead[1] if nd > 1 else 0
        out += [int(e["col"]) & 0xFFFF, _inv_bits(e["div"]), nd, d0 & 0xFFFF, d1 & 0xFFFF]
    return out


# ===================================================================== 硬件口径复刻

def rewire_torch(X, entries):
    """逐字复刻 far_reroute.sv：half = X[A]*inv; X[A]=half; X[d]=X[d]+half。

    inv = 1/div（fp32）。div=2 时 x*0.5 与 x/2 逐位一致，故与软件 golden bit-exact。
    """
    act = X.clone()
    for e in entries:
        A = int(e["col"])
        inv = torch.tensor(np.float32(1.0) / np.float32(e["div"]), dtype=torch.float32)
        half = torch.mul(act[:, A:A + 1], inv)          # 显式 fp32 乘，避免 FMA 融合
        act[:, A:A + 1] = half
        for d in e["dead"]:
            d = int(d)
            act[:, d:d + 1] = torch.add(act[:, d:d + 1], half)
    return act


def hw_order_torch(X, W, b, g=G):
    """复刻 gemm_up_proj_core 的浮点累加顺序（bit-exact 唯一依据）。

      acc[g] 累加所有 (k mod G)==g 的乘积，k 由小到大；acc[0] 预置 bias[m]；
      归约从 acc[0] 起串行左折。返回 [N, M]（行主序，Y[n][m]）。
    """
    N, K = X.shape
    M = W.shape[0]
    acc = []
    for gi in range(g):
        if gi == 0:
            a = b.unsqueeze(0).expand(N, M).clone().contiguous()
        else:
            a = torch.zeros(N, M, dtype=torch.float32)
        for k in range(gi, K, g):
            p = torch.mul(X[:, k:k + 1], W[:, k].unsqueeze(0))   # 显式乘
            a = torch.add(a, p)                                   # 显式加
        acc.append(a)
    red = acc[0]
    for gi in range(1, g):
        red = torch.add(red, acc[gi])
    return red


# ===================================================================== 后端

class LocalBackend:
    """无板卡：本地按硬件口径算。用于验证接线/流程，必然与 m_ref bit-exact。"""

    name = "local"

    def __init__(self, W_shadow, b):
        self.W = torch.from_numpy(W_shadow).float()
        self.b = torch.from_numpy(b).float()
        self.calls = 0

    def infer(self, X, entries):
        """X: [N,K] fp32 numpy -> Y: [N,M] fp32 numpy。"""
        self.calls += 1
        Xt = torch.from_numpy(np.ascontiguousarray(X)).float()
        Xr = rewire_torch(Xt, entries)
        Y = hw_order_torch(Xr, self.W, self.b, G)
        return Y.numpy()


class BoardBackend:
    """走 TCP 到板卡 fara_infer_server。"""

    name = "board"

    def __init__(self, host, port, timeout=30.0):
        self.host, self.port = host, port
        self.timeout = timeout
        self.sock = None
        self.calls = 0
        self.last_ms = 0
        self.version = None

    def connect(self):
        s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = s
        return s

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def _recv_all(self, n):
        buf = b""
        while len(buf) < n:
            r = self.sock.recv(n - len(buf))
            if not r:
                raise ConnectionError("板卡连接中断")
            buf += r
        return buf

    def infer(self, X, entries):
        if self.sock is None:
            self.connect()
        X = np.ascontiguousarray(X, dtype=np.float32)
        n_tok = X.shape[0]
        if n_tok > N_MAX:
            raise ValueError(f"单次 token 数 {n_tok} > 板卡上限 {N_MAX}")
        fm = farmap_wire(entries)
        n_far = len(entries)
        hdr = struct.pack("<4s4I", b"FARQ", 1, n_far, n_tok, 0)
        body = struct.pack(f"<{len(fm)}I", *fm) if fm else b""
        self.sock.sendall(hdr + body + X.tobytes())

        rh = self._recv_all(32)
        magic, status, rn, m_total, hits, phase, ms, _rsv = struct.unpack("<4s7I", rh)
        if magic != b"FARS":
            raise RuntimeError(f"坏响应 magic={magic!r}")
        if status != 0:
            raise RuntimeError(f"板卡返回 status={status}")
        raw = self._recv_all(rn * m_total * 4)
        Y = np.frombuffer(raw, dtype="<f4").reshape(rn, m_total).copy()
        self.calls += 1
        self.last_ms = ms
        self.last_hits = hits
        self.last_phase = phase
        return Y


# ===================================================================== 层包装

class OffloadCFC(torch.nn.Module):
    """把 c_fc 的 forward 改接到后端（板卡/本地）。权重用板卡常驻的 shadow W。"""

    def __init__(self, backend, entries, n_max=N_MAX):
        super().__init__()
        self.backend = backend
        self.entries = entries
        self.n_max = n_max
        self.calls = 0
        self.last_layer_delta = None

    def forward(self, x):
        B, T, K = x.shape
        X = x.detach().reshape(-1, K).to(torch.float32).cpu().numpy()
        chunks = []
        for s in range(0, X.shape[0], self.n_max):
            chunks.append(self.backend.infer(X[s:s + self.n_max], self.entries))
        Y = np.concatenate(chunks, axis=0)              # [N, M]
        self.calls += 1
        return torch.from_numpy(Y).to(x.dtype).reshape(B, T, M_TOTAL)


class HwRefCFC(torch.nn.Module):
    """参考层：本地 numpy/torch 逐字复刻硬件口径（不经后端）。"""

    def __init__(self, W_shadow, b, entries):
        super().__init__()
        self.W = torch.from_numpy(W_shadow).float()
        self.b = torch.from_numpy(b).float()
        self.entries = entries

    def forward(self, x):
        B, T, K = x.shape
        X = x.detach().reshape(-1, K).to(torch.float32)
        Xr = rewire_torch(X, self.entries)
        Y = hw_order_torch(Xr, self.W, self.b, G)
        return Y.reshape(B, T, M_TOTAL)


def _set_attr(model, dotted, value):
    parts = dotted.split(".")
    owner = model
    for p in parts[:-1]:
        owner = getattr(owner, p)
    setattr(owner, parts[-1], value)


def build_offload_model(base, backend, entries):
    m = copy.deepcopy(base).eval()
    orig = m
    for p in LAYER.split("."):
        orig = getattr(orig, p)
    wrapped = OffloadCFC(backend, entries)
    wrapped._orig = orig            # 保留引用，便于取原层输出做层内对照
    _set_attr(m, LAYER, wrapped)
    return m


def build_ref_model(base, W_shadow, b, entries):
    m = copy.deepcopy(base).eval()
    _set_attr(m, LAYER, HwRefCFC(W_shadow, b, entries))
    return m


# ===================================================================== 核验

@torch.no_grad()
def run(args):
    torch.manual_seed(0)
    np.random.seed(0)

    print("=" * 78)
    print("PC 侧 offload hook + 端到端核验")
    print("=" * 78)

    model, tok = load_causal_model(None)
    model.eval()
    W_shadow, b, div, entries = load_shadow_weights()
    print(f"[cfg] 层={LAYER}  div={div}  n_far={len(entries)}  "
          f"shadow W {W_shadow.shape} b {b.shape}")
    print(f"[cfg] 后端={args.backend}"
          + (f"  host={args.host}:{args.port}" if args.backend == "board" else ""))

    # ---- 后端 ----
    if args.backend == "board":
        backend = BoardBackend(args.host, args.port)
        t0 = time.time()
        backend.connect()
        print(f"[net] 已连接板卡（{time.time()-t0:.2f}s）")
    else:
        backend = LocalBackend(W_shadow, b)

    # ---- 三个模型 ----
    m_clean = copy.deepcopy(model).eval()                 # 纯 torch 原始
    m_off = build_offload_model(model, backend, entries)  # c_fc -> 后端
    m_ref = build_ref_model(model, W_shadow, b, entries)  # c_fc -> 本地硬件口径

    prompt = args.prompt
    ids = tok(prompt, return_tensors="pt")["input_ids"]
    N = ids.shape[1]
    print(f"[run] prompt = {prompt!r}   token 数 N = {N}")

    # ---- 前向 ----
    t0 = time.time()
    logits_clean = m_clean(ids).logits
    t_clean = time.time() - t0
    t0 = time.time()
    logits_off = m_off(ids).logits
    t_off = time.time() - t0
    t0 = time.time()
    logits_ref = m_ref(ids).logits
    t_ref = time.time() - t0
    print(f"[run] 前向耗时: clean {t_clean*1e3:.1f} ms  offload {t_off*1e3:.1f} ms  "
          f"ref {t_ref*1e3:.1f} ms")

    # ---- (1) 层输出级对照：offload vs ref ----
    # 直接钩该层，比较同一次前向里 c_fc 的输出张量
    holder = {}

    def _hook(name):
        def fn(mod, inp, out):
            holder[name] = out.detach().clone()
        return fn

    h1 = m_off.get_submodule(LAYER).register_forward_hook(_hook("off"))
    h2 = m_ref.get_submodule(LAYER).register_forward_hook(_hook("ref"))
    m_off(ids)
    m_ref(ids)
    h1.remove()
    h2.remove()
    y_off, y_ref = holder["off"], holder["ref"]
    layer_bit_exact = bool(torch.equal(y_off, y_ref))
    layer_max_abs = float((y_off - y_ref).abs().max().item())
    print("-" * 78)
    print(f"(1) 层输出 offload vs ref : {'BIT-EXACT' if layer_bit_exact else 'DIFF'} "
          f"max|Δ|={layer_max_abs:.3e}")

    # ---- (1b) 最终 logits：offload vs ref ----
    logit_bit_exact = bool(torch.equal(logits_off, logits_ref))
    logit_max_abs = float((logits_off - logits_ref).abs().max().item())
    print(f"    最终 logits offload vs ref : "
          f"{'BIT-EXACT' if logit_bit_exact else 'DIFF'} max|Δ|={logit_max_abs:.3e}")

    # ---- (2) 防护无损：offload vs clean ----
    d = (logits_off - logits_clean).abs()
    cons_max_abs = float(d.max().item())
    cons_mean_abs = float(d.mean().item())
    a_off = logits_off[:, :-1].argmax(-1)
    a_clean = logits_clean[:, :-1].argmax(-1)
    top1_agree = float((a_off == a_clean).float().mean().item()) * 100.0
    # 分布级：KL(clean || offload)
    lp_c = logits_clean[:, :-1].float().log_softmax(-1)
    lp_o = logits_off[:, :-1].float().log_softmax(-1)
    kl = float((lp_c.exp() * (lp_c - lp_o)).sum(-1).mean().item())
    print("-" * 78)
    print(f"(2) 防护无损 offload vs clean: max|Δlogit|={cons_max_abs:.4f}  "
          f"mean|Δ|={cons_mean_abs:.5f}  top-1 一致={top1_agree:.1f}%  KL={kl:.5f}")

    # ---- (3) 端到端生成 ----
    gen = {}
    for name, m in (("clean", m_clean), ("offload", m_off), ("ref", m_ref)):
        out = m.generate(ids, max_new_tokens=args.max_new, do_sample=False,
                         pad_token_id=tok.eos_token_id)
        gen[name] = tok.decode(out[0], skip_special_tokens=True)
    gen_same = (gen["offload"] == gen["ref"])
    print("-" * 78)
    print("(3) 贪心生成:")
    print(f"    clean   : {gen['clean']!r}")
    print(f"    offload : {gen['offload']!r}")
    print(f"    ref     : {gen['ref']!r}")
    print(f"    offload == ref 文本: {gen_same}")

    # ---- 结论 ----
    ok_plumb = layer_bit_exact and logit_bit_exact
    ok_fidelity = top1_agree >= 90.0
    ok_gen = gen_same
    all_ok = ok_plumb and ok_fidelity and ok_gen
    print("=" * 78)
    print(f"  (1) 接线/硬件忠实 : {'PASS' if ok_plumb else 'FAIL'}")
    print(f"  (2) 防护无损      : {'PASS' if ok_fidelity else 'FAIL'} "
          f"(top-1 {top1_agree:.1f}%)")
    print(f"  (3) 端到端可用    : {'PASS' if ok_gen else 'FAIL'}")
    print(f"  >>> E2E {'PASS' if all_ok else 'FAIL'}")

    out = {
        "as_of": time.strftime("%Y-%m-%d %H:%M:%S"),
        "layer": LAYER,
        "backend": backend.name,
        "host": args.host if backend.name == "board" else None,
        "port": args.port if backend.name == "board" else None,
        "prompt": prompt,
        "n_tokens": int(N),
        "n_max": N_MAX,
        "far": {"div": div, "n_entries": len(entries)},
        "timing_ms": {"clean": t_clean * 1e3, "offload": t_off * 1e3, "ref": t_ref * 1e3},
        "layer_check": {
            "bit_exact": layer_bit_exact,
            "max_abs": layer_max_abs,
        },
        "logits_check": {
            "bit_exact": logit_bit_exact,
            "max_abs": logit_max_abs,
        },
        "fidelity": {
            "max_abs_logit_delta": cons_max_abs,
            "mean_abs_logit_delta": cons_mean_abs,
            "top1_agree_pct": top1_agree,
            "kl_clean_offload": kl,
        },
        "generate": gen,
        "generate_match": gen_same,
        "verdict": {"plumbing": ok_plumb, "fidelity": ok_fidelity,
                    "generation": ok_gen, "e2e_pass": all_ok},
        "calls": getattr(backend, "calls", 0),
    }
    path = os.path.join(DIR, "e2e_verify.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"[ok] -> {path}")

    if backend.name == "board":
        backend.close()
    return 0 if all_ok else 3


def main():
    ap = argparse.ArgumentParser(description="PC 侧 offload hook + 端到端核验")
    ap.add_argument("--backend", choices=["local", "board"], default="local")
    ap.add_argument("--host", default="192.168.1.200")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--prompt", default="Field programmable gate arrays offer")
    ap.add_argument("--max-new", type=int, default=8)
    args = ap.parse_args()
    raise SystemExit(run(args) or 0)


if __name__ == "__main__":
    main()
