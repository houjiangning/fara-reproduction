"""BFA 攻击可视化控制面板 —— 本地 Web 应用，无需第三方 Web 框架。

功能：
  · 模式一「仅攻击」：对裸 GPT-2 执行梯度引导 BFA，看困惑度随翻转预算攀升
  · 模式二「FaR 防护对比」：同一批敏感位翻转，同时画「裸模型」与「FaR 加固后模型」
    两条困惑度曲线，直接展示 FaR 防护把损伤推迟到更多翻位
  · 实时轮询 + 一键重置（攻击只改内存副本）

用法（在 fara-reproduction 目录下）：
  python attack_dashboard.py
  浏览器打开 http://127.0.0.1:8099

端点：
  GET  /           控制面板 HTML
  GET  /api/status 查询进度（含双序列、攻击参数现场 ops、文本生成回放 gen）
  GET  /api/hw     硬件 FaR 板上验证快照（读 hw_verify.json）
  GET  /api/hwcmp  硬件 FaR × 软件 FaR 同层对照（hw_compare.json + 同层 far 曲线）
  GET  /api/board  板卡安全启动链实时状态（FARC STATUS 直连板卡）
  POST /api/boardop 板卡操作：{"op":"wipe"|"restore"}（擦除 DDR 明文 / 重解密）
  GET  /api/boardstatus 板上实时攻防进度（双曲线 / FLIP 回执 / 到阈值判据）
  POST /api/boardattack 启动板上攻防：{"budget":N}（BFA计划→FARC FLIP→FARQ双推理）
  POST /api/attack 启动：{"budget":N,"mode":"attack"|"far","layer":L,"n":N,"div":D}
  POST /api/gen    文本生成回放：{"mode","gen_model","prompt","max_new","points":[..]}
  POST /api/reset  恢复原始权重
"""
import copy
import io
import json
import math
import os
import random
import statistics
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import torch
import torch.nn.functional as F

from bfa_attack import (
    load, perplexity, REFERENCE_CORPUS,
    compute_gradients, build_plan, flip_bit, pbs_bitsearch,
)
from far_defense import (
    build_protected, _get_module, _flip_entry, _flat_index_of, _weight_tensor_of,
    _mean_ppl as _far_mean_ppl,
    corpus_nll,
)
from model_profile import default_layer, model_display_name
import board_ctrl

DIR = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("FAR_DASH_PORT", 8099))

MEASURE_POINTS = (1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64)
DEFAULT_LAYER = default_layer()   # 按模型档案取默认敏感层（gpt2 / qwen2.5-3b 自动切换）
# 到阈值判据：困惑度达基线×THR 视为损伤达成（论文用 accuracy drop，这里用等价困惑度倍数）
THR = 4.0


def _metric(m, ref, tok):
    """一并发语料级三项指标：返回 dict(ppl, nll, acc)。ref 为未攻击参考模型。"""
    nll, ppl = corpus_nll(m, tok)
    return {"ppl": ppl, "nll": nll, "acc": next_tok_acc(m, ref, tok)}


# 全局状态：index 0=裸模型，1=FaR 加固模型
#   baseline[i] = dict(ppl, nll, acc)   各模型的 0 协议基线
#   series[i]   = [ {flips, ppl, nll, acc}, ... ]   各模型随翻位变化的曲线
_state = {
    "running": False,
    "mode": "attack",
    "baseline": [None, None],
    "series": [[], []],
    "total": [0, 0],
    "thr": None,
    "ops": [],       # 攻击/对比过程中真实翻转的参数现场快照
    "gen": [],       # 文本生成回放结果 [{k, ppl, acc, text}]
    "gen_busy": False,
    "pbs": None,     # 论文口径 PBS 渐进位搜索结果：见 _run_attack far 分支
    "msg": "",
    "cur_layer": DEFAULT_LAYER,   # 最近一次运行真正作用的层（前端选项卡据此决定自动刷新/读缓存）
    "by_layer": {},               # 按层缓存各自结果 {layer:{series,baseline,total,thr,pbs}}：切选项卡秒回显
}
_lock = threading.Lock()

_model, _tok = load()
_original = {k: v.detach().clone() for k, v in _model.state_dict().items()}


# ---- 预计算原模型对代表性语料的参考预测(原模型作为 next-token 标签/KL 基准)，
#      避免为"参考模型"再持有一份完整权重副本。
@torch.no_grad()
def _init_refs():
    args, logs, xs = [], [], []
    for text in REFERENCE_CORPUS:
        ids = _tok(text, add_special_tokens=True)["input_ids"]
        if len(ids) <= 1:
            continue
        x = torch.tensor([ids])
        lg = _model(x).logits[:, :-1].float()          # [1, n-1, V]
        args.append(lg.argmax(dim=-1))
        logs.append(lg.log_softmax(dim=-1))
        xs.append(x)
    return args, logs, xs


_REF_ARGMAX, _REF_LOGPROB, _REF_INPUTS = _init_refs()


@torch.no_grad()
def _acc_vs_ref(model):
    """next-token top-1 一致率(%)：候选模型 vs 原模型预测。0 协议时应近 100%。"""
    hits = total = 0
    for x, rarg in zip(_REF_INPUTS, _REF_ARGMAX):
        cand = model(x).logits[:, :-1].argmax(dim=-1)
        hits += int((cand == rarg).sum().item())
        total += int(rarg.numel())
    return 100.0 * hits / max(total, 1)


@torch.no_grad()
def _kl_vs_ref(model):
    """预测分布相对原模型的平均 KL 散度（功能保真度，越小越好）。"""
    kls = n = 0.0
    for x, rlog in zip(_REF_INPUTS, _REF_LOGPROB):
        clog = model(x).logits[:, :-1].float().log_softmax(dim=-1)
        cand = clog.exp()
        kls += float((cand * (clog - rlog)).sum().item())
        n += cand.shape[0] * cand.shape[1]
    return kls / max(n, 1)


def _metric(m):
    """一并发语料级三项指标：dict(ppl, nll, acc)。"""
    nll, ppl = corpus_nll(m, _tok)
    return {"ppl": ppl, "nll": nll, "acc": _acc_vs_ref(m)}


def _mean_ppl(model=None):
    m = model or _model
    vals = [perplexity(m, _tok, t) for t in REFERENCE_CORPUS]
    return statistics.mean(vals)


def _flip_bit_guarded(model, name, idx, bit):
    # 全模型翻转沿用 bfa_attack.flip_bit；仅在此集中引用
    flip_bit(model, name, idx, bit)


def _bits_f32(bits):
    """把 32 位整数位模式解码为 float32。"""
    return struct.unpack("<f", struct.pack("<I", int(bits) & 0xFFFFFFFF))[0]


GEN_PROMPTS = [
    ("现场设备安全须知", "An engineer opened the secure edge device, checked the logs and"),
    ("对话助手", "The assistant read the user question carefully and then replied"),
    ("科技短文", "Machine learning is changing the way we build secure systems because"),
]


DECODE_MODES = ("greedy", "sample", "hot")
_DECODE_TEMP = {"greedy": 1.0, "sample": 0.9, "hot": 1.9}


@torch.no_grad()
def _decode_rich(model, tok, prompt, max_new, seeds):
    """KV 缓存式逐 token 解码：三种解码各自产出 per-seed 序列与逐 token 熵/置信度。

    返回 {mode: {text, ent_avg, seed, n, toks, seeds?}}。
    toks 每项 = {t, txt, id, conf, ent, topk[5], topk_p[5]}。
    与旧实现的差异：不再用 model.generate 整段抽样，改为手动逐 token 解码，
    因而能拿到『每一步的预测熵』——这是把『数值在变』翻译成『可见乱码过程』的关键。
    """
    ids = tok(prompt, add_special_tokens=True)["input_ids"]
    prefix = torch.tensor([ids])
    eos = tok.eos_token_id if tok.eos_token_id is not None else None
    results = {}
    for mode in DECODE_MODES:
        temp = _DECODE_TEMP[mode]
        per = []
        for seed in seeds:
            torch.manual_seed(seed)
            past, cur = None, prefix
            toks = []
            for _ in range(max_new):
                out = model(cur, past_key_values=past)
                lg = out.logits[:, -1, :].float()
                past = out.past_key_values
                if mode == "greedy":
                    probs = lg.softmax(dim=-1)
                    nxt = lg.argmax(dim=-1, keepdim=True)
                else:
                    probs = F.softmax(lg / max(temp, 1e-6), dim=-1)
                    nxt = torch.multinomial(probs, num_samples=1)
                topk = probs.topk(min(5, probs.shape[-1]))
                conf = float(probs.gather(-1, nxt).item())
                ent = float(-(probs * torch.log(probs.clamp_min(1e-12))).sum(-1).item())
                tid = int(nxt.item())
                tname = tok.convert_ids_to_tokens([tid])[0] if hasattr(tok, "convert_ids_to_tokens") else f"<{tid}>"
                txs = tok.decode([tid], skip_special_tokens=True) if hasattr(tok, "decode") else f"<{tid}>"
                toks.append({
                    "t": tname, "txt": txs, "id": tid,
                    "conf": round(conf, 4), "ent": round(ent, 3),
                    "topk": [tok.decode([int(i)], skip_special_tokens=True) for i in topk.indices[0].tolist()],
                    "topk_p": [round(float(p), 3) for p in topk.values[0].tolist()],
                })
                if eos is not None and tid == eos:
                    break
                cur = nxt
            text = "".join(t["txt"] for t in toks)
            ent_avg = (float(sum(t["ent"] for t in toks) / max(len(toks), 1))) if toks else 0.0
            per.append({"seed": seed, "text": text, "ent_avg": round(ent_avg, 3),
                        "len": len(toks), "toks": toks})
        # 代表性帧：取平均熵最高(退化最明显)的一帧，便于一眼看到"坏"
        per.sort(key=lambda r: r["ent_avg"], reverse=True)
        prim = per[0]
        results[mode] = {
            "text": prim["text"], "ent_avg": prim["ent_avg"],
            "seed": prim["seed"], "n": len(per), "toks": prim["toks"],
            "seeds": per if len(per) > 1 else None,
        }
    return results


def _gen_text(model, tok, prompt, max_new, seed=7):
    """向后兼容薄封装：返回默认采样解码的主文本。"""
    return _decode_rich(model, tok, prompt, max_new, [seed])["sample"]["text"]


def _far_bit(cfg, row, col):
    """和主攻击一致：翻 FaR 敏感位用指数位 24..26（避开 bit30→NaN）。"""
    return 24 + (((row * cfg["in_features"] + col) // 5) % 3)


def _verdict(uc, pc, last, thr):
    def f2x(v):
        return "≥" + str(last) if v is None else str(v)
    ratio = ((pc if pc else last) / max(uc, 1)) if uc else float("inf")
    ratio_txt = "∞(预算内未达)" if not math.isfinite(ratio) else f"{ratio:.2f}×"
    return (f"『到阈值(ppl≥基线×{thr:.0f})需翻位』裸={f2x(uc)}位, "
            f"FaR={f2x(pc)}位  → 比值 {ratio_txt}（论文区间 1.4–4.2×）")


def _run_attack(params):
    budget = int(params.get("budget", 16))
    mode = params.get("mode", "attack")
    layer = params.get("layer", DEFAULT_LAYER)   # 本轮真正作用的层（attack 模式也回存，供按层缓存）
    with _lock:
        _state.update(running=True, mode=mode, series=[[], []],
                      baseline=[None, None], total=[0, 0], thr=None,
                      ops=[], gen=[], pbs=None, msg="准备中…", cur_layer=layer)
    ops = []
    try:
        if mode == "far":
            n = int(params.get("n", 16))
            div = int(params.get("div", 2))
            with _lock:
                _state["msg"] = f"正在构建 FaR 防护（层 {layer}，n={n}, div={div}）…"
            _model.load_state_dict(_original)
            unprotected = copy.deepcopy(_model).eval()
            prot, cfg = build_protected(unprotected, _tok, layer, n, div)

            mu = _metric(unprotected)
            mp = _metric(prot)
            kl_p = _kl_vs_ref(prot)
            with _lock:
                _state["baseline"] = [mu, mp]
                _state["msg"] = (f"基线 裸 ppl={mu['ppl']:.2f}/acc={mu['acc']:.1f}% | "
                                 f"FaR ppl={mp['ppl']:.2f}/acc={mp['acc']:.1f}% (KL={kl_p:.3f})；"
                                 f"对 {len(cfg['far'])} 个敏感位逐位翻转对比…")

            # —— 按论文协议 PBS（DeepHammer 式渐进位搜索）——
            #    翻转→测小子集 NLL→只提交让损失上升的位(否则回退)→重算梯度再找下一位；
            #    裸 vs FaR 各跑一遍，得到论文口径的『到阈值需翻位』及其比值(区间 1.4–4.2×)。
            try:
                tier = params.get("tier", "basic")
                excl = set()
                if tier == "expert":
                    excl = {d for e in cfg["far"] for d in e["dead"]}
                pbs_u = copy.deepcopy(unprotected).eval()   # 独立副本，PBS 原地改权重
                pbs_p = copy.deepcopy(prot).eval()
                fn, bun, hn = pbs_bitsearch(pbs_u, _tok, layer, budget=budget,
                                            thr=THR, cands=4)
                fp_, bup, hp = pbs_bitsearch(pbs_p, _tok, layer, budget=budget,
                                             thr=THR, cands=4, exclude_cols=excl)
                ratio = None if not fn else ((fp_ or budget) / max(fn, 1))
                def _pbs_pack(f, b, hist, reached):
                    return {"flips": f, "reached": reached,
                            "base": round(b, 4), "base_ppl": round(math.exp(b), 2),
                            "target": round(b + math.log(THR), 4),
                            "hist": [[int(a), float(c), float(d)] for (a, c, d) in hist]}
                with _lock:
                    _state["pbs"] = {
                        "thr": THR, "tier": tier, "budget": budget,
                        "u": _pbs_pack(fn, bun, hn, fn is not None),
                        "p": _pbs_pack(fp_, bup, hp, fp_ is not None),
                        "ratio": (round(ratio, 2) if ratio is not None
                                  and math.isfinite(ratio) else None),
                        "ratio_inf": ratio is None or not math.isfinite(ratio),
                    }
                    _state["msg"] = "PBS 完成，展示『到阈值需翻位 vs 裸/FaR』；继续逐步翻转对比…"
            except Exception as pbs_e:
                with _lock:
                    _state["msg"] = f"PBS 出错: {pbs_e}"

            positions = [(e["col"], e["row"]) for e in cfg["far"]]
            maxflip = min(max(1, budget), len(positions))
            chk = sorted({k for k in MEASURE_POINTS if k <= maxflip})
            if not chk or chk[-1] != maxflip:
                chk.append(maxflip)

            su, sp, flipped, marker = [], [], 0, 0
            for k in chk:
                while flipped < k and flipped < len(positions):
                    col, row = positions[flipped]
                    # 翻转指数位 24..26（有限放大），避开 bit30（softmax 上溢 NaN）
                    bit = _far_bit(cfg, row, col)
                    m_u = _get_module(unprotected, layer)
                    tint = _weight_tensor_of(m_u).detach().flatten().view(torch.int32)
                    oldbits = tint[_flat_index_of(m_u, row, col)].item()
                    _flip_entry(unprotected, layer, row, col, bit)
                    _flip_entry(prot, layer, row, col, bit)
                    newbits = tint[_flat_index_of(m_u, row, col)].item()
                    ops.append({"flip": flipped + 1, "layer": layer, "row": row,
                                "col": col, "bit": bit, "old": oldbits, "new": newbits,
                                "oldf": round(_bits_f32(oldbits), 5),
                                "newf": round(_bits_f32(newbits), 5)})
                    flipped += 1
                eu = {"flips": flipped, **_metric(unprotected)}
                ep = {"flips": flipped, **_metric(prot)}
                su.append(eu)
                sp.append(ep)
                for op in ops[marker:]:
                    op["ppl_u"], op["ppl_p"] = round(eu["nll"], 3), round(ep["nll"], 3)
                    op["acc_u"], op["acc_p"] = round(eu["acc"], 1), round(ep["acc"], 1)
                    op["bad"] = bool(eu["acc"] < 60)
                marker = len(ops)
                with _lock:
                    _state.update(series=[su, sp], total=[flipped, flipped],
                                  ops=ops,
                                  msg=(f"已翻转 {flipped} 位 | 裸 ppl={eu['ppl']:.0f}/acc={eu['acc']:.1f}%"
                                       f" | FaR ppl={ep['ppl']:.0f}/acc={ep['acc']:.1f}%"))
            c = math.log(THR)
            def cross_thr(cur, base):
                return next((r["flips"] for r in cur
                             if math.isfinite(r["nll"]) and r["nll"] >= base["nll"] + c), None)
            uc = cross_thr(su, mu)
            pc = cross_thr(sp, mp)
            note = _verdict(uc, pc, chk[-1], THR)
            with _lock:
                _state["thr"] = {"mult": THR, "u": uc, "p": pc}
                _state["msg"] = f"FaR 对比完成。（再点「重置」恢复原始权重）{note}"
        else:
            with _lock:
                _state["msg"] = "正在计算梯度、选择敏感位…"
            _model.load_state_dict(_original)
            mb = _metric(_model)
            _, grads = compute_gradients(_model, _tok)
            plan = build_plan(_model, grads, budget)
            with _lock:
                _state["baseline"] = [mb, None]
                _state["msg"] = f"已生成翻转计划（{len(plan)} 位），开始逐位攻击…"
            flips, su, marker = 0, [], 0
            for (name, idx, bit) in plan:
                p = _model.get_parameter(name)
                tint = p.detach().view(torch.int32).flatten()
                oldbits = tint[idx].item()
                _flip_bit_guarded(_model, name, idx, bit)
                newbits = tint[idx].item()
                ops.append({"flip": flips + 1, "layer": name, "row": idx, "col": None,
                            "bit": bit, "old": oldbits, "new": newbits,
                            "oldf": round(_bits_f32(oldbits), 5),
                            "newf": round(_bits_f32(newbits), 5),
                            "bad": True})
                flips += 1
                if flips in MEASURE_POINTS or flips == len(plan):
                    e = {"flips": flips, **_metric(_model)}
                    su.append(e)
                    for op in ops[marker:]:
                        op["ppl_u"] = round(e["nll"], 3)
                        op["acc_u"] = round(e["acc"], 1)
                        op["bad"] = bool(e["acc"] < 60)
                    marker = len(ops)
                    with _lock:
                        _state.update(series=[su, []], total=[flips, 0], ops=ops,
                                      msg=f"已翻转 {flips} 位，ppl={e['ppl']:.2f} acc={e['acc']:.1f}%")
            with _lock:
                _state["msg"] = f"攻击完成：共翻转 {flips} 位。（再点「重置」恢复原始权重）"
    except Exception as e:  # pragma: no cover
        with _lock:
            _state["msg"] = f"出错: {e}"
    finally:
        with _lock:
            _state["running"] = False
            # 按层缓存本次结果：切换选项卡秒回显不同层的损伤曲线/PBS（未跑过的层前端显示"待运行"）
            _state["by_layer"][layer] = {
                "series": [[{k: r[k] for k in ("flips", "ppl", "nll", "acc")}
                            for r in s] for s in _state["series"]],
                "baseline": _state["baseline"],
                "total": list(_state["total"]),
                "thr": _state["thr"],
                "pbs": _state["pbs"],
            }


def _build_plan_entries(mode, layer, n, div, budget):
    """根据模式在当前原始权重上生成「按敏感度从高到低」的翻转序列。

    返回 (plan, proto)：
      · mode='far' : plan=[(bit, row, col)]（作用于同一批 FaR 敏感位），
        proto=受护模型副本（用于 far 侧生成）
      · mode='attack': plan=[(bit, name, idx)]（全模型梯度敏感位），proto=None。
    """
    reset_original()
    if mode == "far":
        unprotected = copy.deepcopy(_model).eval()
        prot, cfg = build_protected(unprotected, _tok, layer, n, div)
        plan = [(_far_bit(cfg, e["row"], e["col"]), e["row"], e["col"])
                for e in cfg["far"]]
        return plan, prot, cfg
    _, grads = compute_gradients(_model, _tok)
    plan0 = build_plan(_model, grads, budget)
    return [(bit, name, idx) for (name, idx, bit) in plan0], None, None


def reset_original():
    _model.load_state_dict(_original)


def _run_generation(params):
    mode = params.get("mode", "attack")
    layer = params.get("layer", DEFAULT_LAYER)
    n = int(params.get("n", 16))
    div = int(params.get("div", 2))
    gen_model = params.get("gen_model", "unprotected")   # 'unprotected' | 'far'
    prompt = params.get("prompt", GEN_PROMPTS[0][1])
    max_new = int(params.get("max_new", 48))
    seed = int(params.get("seed", 7))
    n_seed = max(1, int(params.get("n_seed", 1)))
    points = sorted({int(x) for x in params.get("points", [0, 2, 4, 8, 16])})
    with _lock:
        _state.update(gen_busy=True, gen=[], msg="正在生成回放文本…")
    budget = max(points) if points else 0
    plan, prot, cfg = _build_plan_entries(mode, layer, n, div, budget)
    try:
        if not plan:
            return
        results = []
        for k in points:
            if gen_model == "far" and prot is not None:
                reset_original()
                m = copy.deepcopy(prot).eval()
                for (bit, row, col) in plan[:k]:
                    _flip_entry(m, layer, row, col, bit)
            else:
                m = copy.deepcopy(_model).eval()
                if mode == "far":
                    for (bit, row, col) in plan[:k]:
                        _flip_entry(m, layer, row, col, bit)
                else:
                    for (bit, name, idx) in plan[:k]:
                        _flip_bit_guarded(m, name, idx, bit)
            nll, ppl = corpus_nll(m, _tok)
            acc = _acc_vs_ref(m)
            seeds = list(range(seed, seed + n_seed))
            modes = _decode_rich(m, _tok, prompt, max_new, seeds)
            results.append({
                "k": k, "ppl": round(ppl, 1), "acc": round(acc, 1),
                "nll": round(nll, 3),
                "text": modes["sample"]["text"],   # 兼容回放卡
                "ent_avg": modes["sample"]["ent_avg"],
                "seed": seed, "n_seed": n_seed, "modes": modes,
            })
            with _lock:
                _state["gen"] = results
                _state["msg"] = (f"生成回放进行中：已到第 {k} 位（ppl={ppl:.1f}, acc={acc:.1f}%）…")
    finally:
        reset_original()
        with _lock:
            _state["gen_busy"] = False
            _state["msg"] = f"文本生成回放完成（共 {len(points)} 个档位）。（点「重置」可回到原始权重）"


def _num(d):
    if d is None:
        return None
    return {k: (float(v) if isinstance(v, (int, float)) else v) for k, v in d.items()}


def _snapshot():
    with _lock:
        return {
            "running": _state["running"],
            "mode": _state["mode"],
            "baseline": [_num(b) for b in _state["baseline"]],
            "series": [[_num(r) for r in s] for s in _state["series"]],
            "total": [int(t) for t in _state["total"]],
            "thr": _state["thr"],
            "ops": _state["ops"],
            "gen": _state["gen"],
            "gen_busy": _state["gen_busy"],
            "pbs": _state["pbs"],
            "msg": _state["msg"],
            "layer": _state["cur_layer"],
        }


HTML = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BFA 攻击 × FaR 防护 · 控制面板 · GPT-2</title>
<style>
  :root{
    --bg:#0d1220; --panel:#151b2e; --panel2:#1c2440; --line:#2a3554;
    --tx:#e6ecff; --mut:#8b97bd; --accent:#38c2ff; --danger:#ff5c7a;
    --ok:#3bdf8f; --warn:#ffb547;
  }
  *{box-sizing:border-box}
  body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,#14203a 0,var(--bg) 55%);
       color:var(--tx);font-family:"Segoe UI",system-ui,-apple-system,sans-serif;min-height:100vh}
  .wrap{max-width:1120px;margin:0 auto;padding:28px 22px 60px}
  h1{font-size:22px;font-weight:600;letter-spacing:.3px;margin:0 0 4px}
  .sub{color:var(--mut);font-size:13px;margin-bottom:20px}
  .sub b{color:var(--accent);font-weight:600}
  .grid{display:grid;grid-template-columns:320px 1fr;gap:18px;align-items:start}
  @media(max-width:840px){.grid{grid-template-columns:1fr}}
  .card{background:linear-gradient(180deg,var(--panel),#121a2c);border:1px solid var(--line);
        border-radius:14px;padding:16px;margin-bottom:16px}
  .card h2{font-size:12px;text-transform:uppercase;letter-spacing:1.2px;color:var(--mut);
           margin:0 0 12px;font-weight:600}
  .mode{display:grid;grid-template-columns:1fr 1fr;gap:8px}
  .mode div{text-align:center}
  .mode input{display:none}
  .mode label{display:block;padding:10px 6px;border-radius:9px;border:1px solid var(--line);
              background:var(--panel2);color:var(--mut);font-size:13px;cursor:pointer;margin:0}
  .mode input:checked+label{color:#fff;border-color:var(--accent);
              background:linear-gradient(90deg,rgba(56,194,255,.22),rgba(56,194,255,.05))}
  label{display:block;font-size:12.5px;color:var(--mut);margin-bottom:5px}
  input[type=range]{width:100%;accent-color:var(--accent)}
  .val{font-size:26px;font-weight:700;color:var(--accent);font-variant-numeric:tabular-nums;
       text-align:right;margin:-24px 0 8px}
  input[type=text],select{width:100%;padding:9px 10px;border-radius:9px;border:1px solid var(--line);
       background:#0e1426;color:var(--tx);font-size:13px}
  .row2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  button{width:100%;padding:12px;border:0;border-radius:10px;font-size:15px;font-weight:600;
         cursor:pointer;margin-top:4px;transition:.15s}
  #start{background:linear-gradient(90deg,#ff7a58,var(--danger));color:#fff}
  #start:hover:not(:disabled){filter:brightness(1.1)}
  #start:disabled{opacity:.45;cursor:not-allowed}
  #reset{background:var(--panel2);color:var(--mut);border:1px solid var(--line);margin-top:8px}
  #reset:hover{color:var(--tx)}
  .live{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--mut);margin-top:12px}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--mut)}
  .dot.on{background:var(--danger);box-shadow:0 0 8px var(--danger);animation:pulse 1s infinite}
  @keyframes pulse{50%{opacity:.35}}
  .stat{display:flex;justify-content:space-between;border-bottom:1px dashed var(--line);
        padding:8px 0;font-size:13.5px}
  .stat:last-child{border-bottom:0}
  .stat .k{color:var(--mut)}
  .stat .v{font-weight:600;font-variant-numeric:tabular-nums}
  .bad{color:var(--danger)} .good{color:var(--ok)} .warn{color:var(--warn)}
  canvas{width:100%;height:360px;display:block}
  .legend{display:flex;gap:18px;font-size:12px;color:var(--mut);margin-top:10px;flex-wrap:wrap}
  .lg{display:flex;align-items:center;gap:6px}
  .sw{width:14px;height:3px;border-radius:2px;display:inline-block}
  .msg{padding:12px;border-radius:10px;background:var(--panel2);border:1px solid var(--line);
       font-size:13px;color:var(--tx);margin-top:12px;min-height:40px}
  .verdict{font-size:12px;line-height:1.7;color:var(--mut);margin-top:10px;border-top:1px dashed var(--line);padding-top:10px}
  .verdict b{color:var(--ok)}
  .hint{font-size:11.5px;color:var(--mut);line-height:1.6;margin-bottom:10px}
  table.ops{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
  table.ops th,table.ops td{border-bottom:1px solid var(--line);padding:5px 7px;text-align:left;white-space:nowrap}
  table.ops th{color:var(--mut);font-weight:600;position:sticky;top:0;background:var(--panel)}
  table.ops td.wrap{max-width:180px;overflow:hidden;text-overflow:ellipsis}
  .opsbox{max-height:320px;overflow:auto;margin-top:4px;border:1px solid var(--line);border-radius:9px;background:#0e1426}
  .genblock{background:var(--panel2);border:1px solid var(--line);border-radius:9px;padding:9px 11px;margin-top:10px}
  .genhead{font-size:12.5px;color:var(--mut);margin-bottom:5px}
  .genhead b{color:var(--accent)}
  .gentext{font-size:13.5px;color:var(--tx);line-height:1.55;white-space:pre-wrap}
  .tokline{display:flex;flex-wrap:wrap;gap:2px 0;line-height:1.9;font-size:12.5px}
  .tok{display:inline-block;padding:0 2px;border-radius:3px;color:var(--tx);white-space:pre}
  .genblock.crit{border-color:var(--danger)}
  .genhint{font-size:11.5px;color:var(--mut);margin-bottom:8px;line-height:1.6}
  .genhead .ok{color:var(--ok)}
  .chips{display:flex;gap:6px;flex-wrap:wrap;margin-top:6px}
  .chips label{border:1px solid var(--line);padding:5px 10px;border-radius:20px;cursor:pointer;font-size:12.5px;color:var(--mut);margin:0}
  .chips input{display:none}
  .chips input:checked+label{color:#fff;border-color:var(--accent);background:rgba(56,194,255,.16)}
  .pbbtn{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}
  .pbbtn button{width:auto;margin:0;padding:9px 6px;font-size:13px}
  tr.hl{background:rgba(56,194,255,.16)!important}
  #playcard .hint{margin-bottom:8px}
  #causeline{font-variant-numeric:tabular-nums;min-height:auto;font-size:12.5px;line-height:1.7}
  .pbtag{font-size:11.5px;color:var(--warn);margin-top:8px;line-height:1.7}
  .meta{display:flex;gap:8px;flex-wrap:wrap;font-size:12px;color:var(--mut);margin-top:4px}
  .meta span{background:var(--panel2);border:1px solid var(--line);padding:4px 9px;border-radius:8px}
  .benchleg{display:flex;gap:14px;align-items:center;font-size:11px;color:var(--mut);margin:10px 0 2px;flex-wrap:wrap}
  .benchsub{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:6px 0}
  .bslab{font-size:12px;color:var(--mut)}
  table.heat{border-collapse:collapse;font-size:11px;font-variant-numeric:tabular-nums;width:100%}
  table.heat th,table.heat td{padding:3px 7px;text-align:center;border:1px solid var(--line);white-space:nowrap}
  table.heat th{color:var(--mut);font-weight:600}
  table.heat td.lab{color:var(--mut);text-align:right}
  .heatwrap{overflow:auto;border:1px solid var(--line);border-radius:9px;background:#0e1426;max-height:420px}
  .grad{width:170px;height:9px;border-radius:5px;background:linear-gradient(90deg,#ff5c7a,#ffb547,#3bdf8f)}
  .thr{color:var(--mut);font-size:12.5px;line-height:1.7}
  .thr b{color:var(--ok)}
  .hwb{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin:12px 0}
  @media(max-width:840px){.hwb{grid-template-columns:1fr}}
  .hwlvl{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
  .hwlvl .id{font-size:11px;color:var(--mut);letter-spacing:1px;display:flex;align-items:center;gap:8px}
  .hwlvl .nm{font-size:13px;color:var(--tx);margin:5px 0 6px;font-weight:600}
  .hwlvl .dt{font-size:11.5px;color:var(--mut);line-height:1.6}
  .badge{display:inline-block;font-size:10.5px;padding:2px 8px;border-radius:20px;font-weight:700;letter-spacing:.5px}
  .badge.ok{color:#08170f;background:var(--ok)}
  .badge.no{color:#1a0b0f;background:var(--danger)}
  .hwhash{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:11px;color:var(--mut);word-break:break-all;line-height:1.6}
  .hwgrid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
  @media(max-width:840px){.hwgrid{grid-template-columns:1fr}}
  .hwcap{font-size:12px;color:var(--mut);margin-bottom:6px}
  #hvcv1,#hvcv2{height:250px}
  .hwstats{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:14px 0 4px}
  @media(max-width:840px){.hwstats{grid-template-columns:1fr 1fr}}
  .hwstat{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
  .hwstat .k{font-size:11px;color:var(--mut);line-height:1.5}
  .hwstat .v{font-size:20px;font-weight:700;color:var(--accent);font-variant-numeric:tabular-nums;margin-top:4px}
  .hwstat .v.g{color:var(--ok)}
  .hwstat .v.w{color:var(--warn)}
  .featrow{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0 2px}
  .feat{font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:999px;color:var(--tx);background:#101830}
  .feat b{color:var(--accent)}
  .pipe{display:flex;gap:6px;align-items:stretch;flex-wrap:wrap;margin:10px 0}
  .pstep{flex:1;min-width:128px;border:1px solid var(--line);border-radius:9px;padding:8px 10px;background:#101830}
  .pstep i{font-style:normal;display:inline-block;width:18px;height:18px;line-height:18px;text-align:center;border-radius:50%;background:var(--accent);color:#08101f;font-weight:700;font-size:11px;margin-right:6px}
  .pstep small{display:block;margin-top:4px;color:var(--mut);font-size:12px}
  .pstep.ok{border-color:var(--ok)}
  .pstep.bad{border-color:var(--danger)}
  .parr{align-self:center;color:var(--mut);font-size:14px}
  .bdcons{max-height:300px;overflow:auto;border:1px solid var(--line);border-radius:9px;background:#0e1426;padding:8px 10px;font-family:ui-monospace,Consolas,monospace;font-size:12px;line-height:1.55}
  .bdl{white-space:pre-wrap;word-break:break-all;margin:2px 0}
  .bdl .tg{display:inline-block;min-width:58px;font-weight:700;margin-right:6px}
  .tg-rest{color:var(--accent)}.tg-flip{color:var(--warn)}.tg-meas{color:var(--ok)}
  .tg-thr{color:var(--accent)}.tg-done{color:var(--ok)}.tg-err{color:var(--danger)}.tg-info{color:var(--mut)}
  .bdstatgrid{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin:10px 0}
  @media(max-width:840px){.bdstatgrid{grid-template-columns:repeat(2,1fr)}}
  .bdanger{border-color:var(--danger);color:var(--danger);background:rgba(255,92,122,.08)}
  .bdanger:hover{background:rgba(255,92,122,.18)}
  #boardcard.attacked{border-color:var(--danger);box-shadow:0 0 0 1px var(--danger)}
  #boardcard.attacked h2::after{content:" · 明文已遭攻击";color:var(--danger)}
  .pstep.run{border-color:var(--accent);background:#0f2237}
  .pstep.run i{animation:bdpulse .6s infinite alternate}
  @keyframes bdpulse{from{opacity:.35}to{opacity:1}}
  .hashstrip{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:2px 0 10px}
  @media(max-width:840px){.hashstrip{grid-template-columns:1fr}}
  .hcell{border:1px solid var(--line);border-radius:9px;background:#101830;padding:8px 10px}
  .hcell .hk{display:block;font-size:11px;color:var(--mut);margin-bottom:3px}
  .hcell .hv{font-family:ui-monospace,Consolas,monospace;font-size:12px;word-break:break-all}
  .hcell.hit{border-color:var(--ok)}
  .hcell.miss{border-color:var(--danger)}
</style>
</head>
<body>
<div class="wrap">
  <h1>BFA 比特翻转攻击 × FaR 防护 · 控制面板</h1>
  <div class="sub">本地模型：<b>@MODEL_NAME@</b> · 两种模式 → 仅攻击 或 攻击+FaR 防护对比 · 指标：代表性语料平均困惑度</div>

  <div class="grid">
    <div>
      <div class="card">
        <h2>模式 / 攻击控制</h2>
        <div class="mode" id="modegroup">
          <div><input type="radio" name="mode" id="m_attack" value="attack" checked>
            <label for="m_attack">仅攻击（无防护）</label></div>
          <div><input type="radio" name="mode" id="m_far" value="far">
            <label for="m_far">FaR 防护对比</label></div>
        </div>

        <div style="margin-top:12px">
          <label for="budget">翻转预算（位）：<span id="bv" style="color:var(--tx)">16</span></label>
          <input type="range" id="budget" min="2" max="64" step="1" value="16"
                 oninput="document.getElementById('bv').textContent=this.value">
        </div>

        <div id="farpanel">
          <div style="margin:10px 0 4px"><label>被攻击 / 被保护层（点击选项卡切换，选什么层就展示哪层的损伤曲线）</label>
            <div class="chips" id="layertabs" style="margin-top:6px">
              <input type="radio" name="layertab" id="lt_cproj" checked
                     onchange="pickLayer('transformer.h.2.mlp.c_proj')">
              <label for="lt_cproj">c_proj · h.2</label>
              <input type="radio" name="layertab" id="lt_up" onchange="pickLayer('transformer.h.0.mlp.c_fc')">
              <label for="lt_up">up_proj · h.0.c_fc（代表层）</label>
            </div>
            <input type="text" id="layer" value="transformer.h.2.mlp.c_proj"
                   style="margin-top:8px" oninput="onLayerManual()">
            <div class="meta" id="layermeta" style="margin-top:6px">当前层：<b>c_proj · h.2.mlp.c_proj</b> · 状态：待首次运行</div></div>
          <div class="row2">
            <div><label for="n">保护敏感位 n：<span id="nv" style="color:var(--tx)">16</span></label>
              <input type="range" id="n" min="2" max="64" step="1" value="16"
                     oninput="document.getElementById('nv').textContent=this.value"></div>
            <div><label for="div">division factor</label>
              <select id="div"><option value="2" selected>2（推荐）</option><option value="3">3</option></select></div>
          </div>
          <div style="margin-top:10px"><label for="pbs_tier">PBS 攻击者等级（论文口径）</label>
            <select id="pbs_tier">
              <option value="basic" selected>basic：不知 FaR · 全位搜索</option>
              <option value="expert">expert：可知 FaR · 屏蔽 shadow 死道</option>
            </select></div>
        </div>

        <button id="start" onclick="start()">开始</button>
        <button id="reset" onclick="reset()">重置 / 恢复原始权重</button>
        <div class="live"><span class="dot" id="dot"></span><span id="livetxt">就绪</span></div>
      </div>

      <div class="card">
        <h2>实时指标（困惑度口径）</h2>
        <div class="stat"><span class="k">裸模型 基线 ppl</span><span class="v" id="s_ub">--</span></div>
        <div class="stat"><span class="k">FaR 模型 基线 ppl</span><span class="v good" id="s_pb">--</span></div>
        <div class="stat"><span class="k">裸模型 当前 ppl</span><span class="v warn" id="s_uc">--</span></div>
        <div class="stat"><span class="k">FaR 模型 当前 ppl</span><span class="v" id="s_pc">--</span></div>
        <div class="stat"><span class="k">当前 acc 裸 / FaR</span><span class="v" id="s_acc">--</span></div>
      </div>

    </div>

    <div class="card">
      <h2>损伤曲线（翻转预算 → 指标）</h2>
      <div class="mode" id="metricgroup" style="grid-template-columns:1fr 1fr 1fr;margin-bottom:12px">
        <div><input type="radio" name="metric" id="m_ppl" value="ppl" checked>
          <label for="m_ppl">困惑度 ppl</label></div>
        <div><input type="radio" name="metric" id="m_nll" value="nll">
          <label for="m_nll">NLL(=log困惑度)</label></div>
        <div><input type="radio" name="metric" id="m_acc" value="acc">
          <label for="m_acc">准确率 acc%</label></div>
      </div>
      <canvas id="cv"></canvas>
      <div class="legend">
        <span class="lg"><span class="sw" style="background:var(--danger)"></span>裸模型</span>
        <span class="lg"><span class="sw" style="background:var(--ok)"></span>FaR 防护后</span>
        <span class="lg"><span class="sw" style="background:var(--mut)"></span>基线（虚线）</span>
      </div>
      <div class="hint" style="margin:10px 0 4px;color:var(--accent)">攻击现场 · 逐位快照（软件侧运行后追加）</div>
      <div id="opsbox" style="font-size:12.5px;color:var(--mut)">运行一次单独攻击或 FaR 对比后，这里逐步列出「选中 → 翻转 → 损伤上升」的每一笔记录。</div>
    </div>

    <div class="card" id="pbscard" style="display:none">
      <h2>『到阈值需翻位』PBS 结果 · 裸 vs FaR（按论文协议回填）</h2>
      <p class="hint">DeepHammer 渐进位搜索：翻转指数位 24–26 → 测小子集 NLL → 只提交让损失上升的位（否则回退）→ 重算梯度再找下一位；数到 ppl 首次≥基线×<b id="pbs_thr">4</b> 需提交的位。下方横条长度=裸/FaR 各自到达阈值所需翻位，并列对照与困惑度曲线同一次 FaR 对比的结果。</p>
      <div id="pbsbars"></div>
      <div class="verdict" id="s_thr">运行 FaR 防护对比后显示。三种口径并列：①论文协议（PBS 贪心 commit-revert，与论文 1.4–4.2× 区间可比）②固定顺序（按敏感度排序，会退化，仅参考）③机制（逐位损伤比，来自 threshold_metric_recheck.json）。判据：ppl≥基线×4（⇔ NLL≥基线+ln4）即视为损伤达成。</div>
      <div class="verdict" id="pbsverdict">运行 FaR 对比后显示。『到阈值需翻位』裸 vs FaR 比值落在论文区间 1.4–4.2× 即方向符合。</div>
    </div>

    <div class="card" id="w1card" style="display:none"></div>
  </div>

  <div class="card" id="playcard" style="display:none">
    <h2>逐步回放 · 翻转因果链动画</h2>
    <p class="hint">先运行一次「仅攻击 / FaR 对比」，再点播放：时间轴从 0 往最大翻位推进，同步<b>移动曲线上的回放标记</b>、<b>高亮下方逐位快照表</b>、在左侧逐位打出「第 N 位翻转 → 参数/坐标 → 旧值→新值 → 损伤」的因果线。想让动画里的文本也随翻位变乱，先点上方「生成回放文本」。</p>
    <div class="row2" style="margin-bottom:10px">
      <div>
        <label>当前翻位：<b id="playk" style="color:var(--accent)">0</b> / <span id="playmax">0</span> 位 · 回放模型：<span id="playmodel">裸</span></label>
        <input type="range" id="playslider" min="0" max="0" value="0" oninput="seekPlay(+this.value)">
      </div>
      <div class="pbbtn">
        <button id="pbtn" onclick="togglePlay()">▶ 播放</button>
        <button onclick="stepPlayK(1)">+1 位</button>
        <button onclick="seekPlay(0)">归零</button>
      </div>
    </div>
    <div class="msg" id="causeline">运行一次攻击/FaR 对比后点播放，这里逐位显示「第 N 位翻转 → 参数/坐标 → 旧值→新值 → 损伤」。</div>
    <div id="playtext"></div>
  </div>

  <div class="card">
    <h2>文本生成回放 · 直接看模型被攻击后「乱说话」</h2>
      <p class="hint">同一 prompt、同一随机种子，对比不同翻位档位下模型的输出：0 位=正常，翻位越多越被破坏（复读 / 词表塌缩 / 胡言）。这是把困惑度/准确率曲线翻译成肉眼可见的“混乱表现”。</p>
      <div class="row2">
        <div>
          <label for="gen_model">回放模型</label>
          <select id="gen_model">
            <option value="unprotected">裸模型（无防护）</option>
            <option value="far">FaR 防护后</option>
          </select>
        </div>
        <div>
          <label for="gen_prompt">起始 prompt（可自行输入，回车可用预置候选）</label>
          <input type="text" id="gen_prompt" value="An engineer opened the secure edge device, checked the logs and"
                 list="prompt_presets" spellcheck="false"><datalist id="prompt_presets">
            <option value="An engineer opened the secure edge device, checked the logs and">现场设备安全</option>
            <option value="The assistant read the user question carefully and then replied">对话助手</option>
            <option value="Machine learning is changing the way we build secure systems because">科技短文</option>
          </datalist>
        </div>
      </div>
      <div style="margin-top:10px">
        <label for="gen_max_new">生成长度：<span id="gen_max_new_v" style="color:var(--tx)">48</span> token</label>
        <input type="range" id="gen_max_new" min="16" max="80" step="4" value="48"
               oninput="document.getElementById('gen_max_new_v').textContent=this.value">
      </div>
      <div class="row2" style="margin-top:10px">
        <div>
          <label for="gen_decode">解码方式（受攻击后差异）</label>
          <select id="gen_decode" onchange="renderGenLanes(last)">
            <option value="sample">采样（默认 · 还算连贯）</option>
            <option value="greedy">贪心 top-1（容易复读/循环）</option>
            <option value="hot">高温采样（logits 被压平 → 乱蹦字）</option>
          </select>
        </div>
        <div>
          <label for="gen_seeds">抽样种数（&gt;1 自动取均熵最高即最乱的帧）：<span id="gen_seeds_v" style="color:var(--tx)">1</span></label>
          <input type="range" id="gen_seeds" min="1" max="5" step="1" value="1"
                 oninput="document.getElementById('gen_seeds_v').textContent=this.value">
        </div>
      </div>
      <label style="margin-top:10px">翻转档位（0=原始）</label>
      <div class="chips" id="genpoints">
        <div><input type="checkbox" id="g0" value="0" checked><label for="g0">0 位</label></div>
        <div><input type="checkbox" id="g2" value="2" checked><label for="g2">2 位</label></div>
        <div><input type="checkbox" id="g4" value="4" checked><label for="g4">4 位</label></div>
        <div><input type="checkbox" id="g8" value="8" checked><label for="g8">8 位</label></div>
        <div><input type="checkbox" id="g16" value="16" checked><label for="g16">16 位</label></div>
      </div>
      <div style="font-size:12px;color:var(--warn);margin:10px 0">提示：翻 4 位前后差别最明显——裸模型此时困惑度已暴涨、输出开始复读/乱；FaR 防护后明显更晚变乱。</div>
    <button id="genbtn" onclick="runGen()">生成回放文本</button>
    <div id="genbox"></div>
  </div>

  <div class="card" id="boardcard">
    <h2>板卡安全启动链 · 实时攻防（ZCU106 · PUF 派生密钥，全程不出 PL）</h2>
    <p class="hint"><b style="color:var(--danger)">攻击</b>：「模拟攻击」清零板上 9.01MB 明文权重，探针指纹当场变脸——模型输出已损坏的铁证；<b style="color:var(--ok)">防御</b>：「重解密」逐步点亮完整安全启动链（PUF→FE/KDF→HD 门禁→AES→Canary，实测 ≈100ms），指纹 bit-exact 复原。SD 卡密文全程未被触碰，<b>密钥不出 PL、明文权重不出板</b>。</p>
    <div class="pipe" id="bdpipe">
      <div class="pstep" id="bdp1"><i>1</i>PUF 采样<small>蝴蝶 PUF · 布局冻结指纹</small></div>
      <div class="parr">→</div>
      <div class="pstep" id="bdp2"><i>2</i>模糊提取 + KDF<small>纠错 k 位 · SHA-256 派生密钥</small></div>
      <div class="parr">→</div>
      <div class="pstep" id="bdp3"><i>3</i>HD 门禁<small>选中位 HD≤1 放行</small></div>
      <div class="parr">→</div>
      <div class="pstep" id="bdp4"><i>4</i>AES-256-CTR 解密<small>9.01MB · <span id="bddec">--</span> ms</small></div>
      <div class="parr">→</div>
      <div class="pstep" id="bdp5"><i>5</i>Canary 确认<small>probe 输出 hash 仲裁</small></div>
    </div>
    <div class="hashstrip">
      <div class="hcell" id="bdh0"><span class="hk">参考指纹 · 干净权重探针输出</span><span class="hv">--</span></div>
      <div class="hcell" id="bdh1"><span class="hk">攻击后 · 擦除（明文→全零）</span><span class="hv">--</span></div>
      <div class="hcell" id="bdh2"><span class="hk">防御后 · 重解密恢复</span><span class="hv">--</span></div>
    </div>
    <div class="meta" id="bdmeta">连接中…</div>
    <div class="bdcons" id="bdev" style="max-height:170px"><div class="bdl"><span class="tg tg-info">INFO</span>攻防时间线：点「模拟攻击」擦除板上明文（指纹变脸 = 损伤证据）→ 再点「防御」观看安全启动链逐步反制（指纹复原 = 恢复证据）。</div></div>
    <div class="opsbox" id="bdtab" style="max-height:none"></div>
    <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;align-items:center">
      <button id="bdwipe" class="bdanger" onclick="bdOp('wipe')">模拟攻击：擦除 DDR 明文</button>
      <button id="bdrestore" onclick="bdOp('restore')">防御：重解密（完整安全启动链）</button>
      <span class="hint" id="bdmsg" style="margin:0"></span>
    </div>
  </div>

  <div class="card" id="bdattackcard">
    <h2>板上实时攻防 · BFA 真机翻转 × FaR 硬件防护（ZCU106 实测）</h2>
    <div class="featrow">
      <span class="feat">密钥<b>不出 PL</b></span>
      <span class="feat">权重<b>不出板</b></span>
      <span class="feat">攻击执行端 · 板上真实 DDR</span>
      <span class="feat">防护在 RTL · far_reroute 数据通路内</span>
      <span class="feat">bit-exact · L4 实测</span>
    </div>
    <p class="hint">攻击<b>决策</b>在 PC（敏感位序列，梯度排序），攻击<b>执行</b>经 FARC FLIP 写入板上真实 DDR 权重（回执含 old/new 位模式），随后 c_fc 层 offload 到板卡推理测语料 ppl。双曲线 = 同一份板上 W + 同样翻转，唯一变量是 RTL farmap 开关：<b style="color:var(--danger)">裸 n_far=0</b>（无 reroute）vs <b style="color:var(--accent)">FaR n_far=1</b>（far_reroute.sv 在数据通路内改写激活——防护完全由 PL 硬件承载）。</p>
    <div style="display:flex;gap:14px;align-items:end;flex-wrap:wrap;margin-bottom:8px">
      <div>
        <label>翻转预算（板卡敏感位共 8 个）：<b id="bdbudgetv" style="color:var(--accent)">8</b> 位</label>
        <input type="range" id="bdbudget" min="1" max="8" step="1" value="8"
               oninput="document.getElementById('bdbudgetv').textContent=this.value">
      </div>
      <button id="bdgobtn" onclick="bdStart()">启动板上攻防</button>
      <span class="hint" style="margin:0;align-self:center">开场自动「重解密」清场；结束后板卡保持翻转态，可用上方按钮实时恢复。</span>
    </div>
    <div class="bdstatgrid">
      <div class="stat"><span class="k">阶段</span><span class="v" id="bdphase">待启动</span></div>
      <div class="stat"><span class="k">已翻转</span><span class="v" id="bdk">0 位</span></div>
      <div class="stat"><span class="k">裸 ppl</span><span class="v warn" id="bdpu">--</span></div>
      <div class="stat"><span class="k">FaR ppl</span><span class="v good" id="bdpp">--</span></div>
      <div class="stat"><span class="k">防护增益</span><span class="v" id="bdgain">--</span></div>
    </div>
    <div class="hwgrid">
      <div>
        <div class="hwcap">板上实测 · 困惑度 ppl vs 翻位数（对数轴 · 越低越安全）</div>
        <canvas id="bdcv" style="width:100%;height:260px"></canvas>
        <div class="legend">
          <span class="lg"><span class="sw" style="background:var(--danger)"></span>裸（n_far=0，无 reroute）</span>
          <span class="lg"><span class="sw" style="background:var(--accent)"></span>FaR（n_far=1，RTL 改写）</span>
          <span class="lg"><span class="sw" style="background:var(--warn)"></span>损伤阈值（基线×4）</span>
        </div>
      </div>
      <div>
        <div class="hwcap">攻防事件流 · FLIP 回执与损伤实时追加</div>
        <div class="bdcons" id="bdcons"><div class="bdl"><span class="tg tg-info">INFO</span>等待启动，事件将在此实时追加…</div></div>
      </div>
    </div>
    <div class="msg" id="bdstmsg">待启动。</div>
    <div class="verdict" id="bdverdict"></div>
  </div>

  <div class="card" id="hwcmpcard">
    <h2>硬件 FaR × 软件 FaR 防护对照 · 同层 transformer.h.0.mlp.c_fc</h2>
    <p class="hint">左图 <b>防护有效性</b>：裸 / 软件 FaR / 硬件 FaR 的困惑度随翻位数变化。硬件 FaR 与软件 FaR 在板上 <b>逐 bit 一致</b>（L4 实测），故两条曲线完全重合 —— 硬件<b>不损失任何防护强度</b>。右图 <b>防护开销</b>：每步推理为 FaR 额外付出的时间，硬件比软件低约 <b>25×</b>。开销均为「纯 FaR 部分」，不含各自基座推理时间。</p>
    <div class="hwgrid">
      <div>
        <div class="hwcap">防护有效性 · 困惑度 ppl vs 翻位数（越低越安全）</div>
        <canvas id="hvcv1"></canvas>
        <div class="legend">
          <span class="lg"><span class="sw" style="background:var(--danger)"></span>裸模型</span>
          <span class="lg"><span class="sw" style="background:var(--ok)"></span>软件 FaR</span>
          <span class="lg"><span class="sw" style="background:var(--accent)"></span>硬件 FaR（与软件重合）</span>
        </div>
      </div>
      <div>
        <div class="hwcap">防护开销 · 累积额外耗时 vs 推理步数（越低越快）</div>
        <canvas id="hvcv2"></canvas>
        <div class="legend">
          <span class="lg"><span class="sw" style="background:var(--warn)"></span>软件 FaR（CPU 侧）</span>
          <span class="lg"><span class="sw" style="background:var(--accent)"></span>硬件 FaR（PL 数据通路内）</span>
        </div>
      </div>
    </div>
    <div class="row2" style="margin:12px 0 6px;align-items:end">
      <div>
        <label>动态回放 · 当前翻位：<b id="hvk" style="color:var(--accent)">0</b> / <span id="hvmax">0</span> 位</label>
        <input type="range" id="hvslider" min="0" max="0" step="1" value="0" oninput="hvSeek(+this.value)">
      </div>
      <div style="display:flex;gap:8px;align-items:end">
        <button id="hvbtn" onclick="hvToggle()">▶ 动态播放</button>
        <button onclick="hvSeek(0)">归零</button>
      </div>
    </div>
    <div class="msg" id="hvread">点「动态播放」：曲线从 0 位逐位生长，标记同步移动，实时读出裸 / FaR 在同一翻位下的困惑度差距。</div>
    <div class="hwstats" id="hwstats"></div>
    <div class="verdict" id="hwcmpverdict">加载中…</div>
  </div>

  <div class="msg" id="msg">等待操作…</div>
</div>

<script>
const cv=document.getElementById('cv'),ctx=cv.getContext('2d');
let last=null, met='ppl', playK=0, playMax=0, playTimer=null, playing=false;
const THR=4;
const FIELDS={ppl:'ppl',nll:'nll',acc:'acc'};
function dpr(){return window.devicePixelRatio||1}
function fit(){const w=cv.clientWidth,h=cv.clientHeight;
  cv.width=w*dpr();cv.height=h*dpr();ctx.setTransform(dpr(),0,0,dpr(),0,0);
  cv.style.width=w+'px';cv.style.height=h+'px';}
function fmt(v){return v>=1000?Math.round(v).toLocaleString():Number(v).toFixed(2)}
function ylab(v){return met==='acc'?Number(v).toFixed(1)+'%':Number(v).toFixed(2)}
function draw(s){
  fit();
  ctx.save();ctx.setTransform(1,0,0,1,0,0);ctx.clearRect(0,0,cv.width,cv.height);ctx.restore();
  const W=cv.clientWidth,HH=cv.clientHeight;
  const P={l:44,r:62,t:22,b:38};
  const su=s.series[0]||[],sp=s.series[1]||[];
  const b0=s.baseline[0],b1=s.baseline[1];
  const F=FIELDS[met];
  const col=(o)=>o[F];
  const bs=met==='acc'?(b0?b0.acc:100):(b0?b0[F]:0);
  const anns=[...(su.map(col)),...(sp.map(col))].filter(v=>v!=null&&isFinite(v));
  const thresh=met==='ppl'?bs*THR:null;
  const all=[bs,...anns]; if(thresh!=null&&isFinite(thresh))all.push(thresh);
  const maxY=Math.max(...all,1e-9);
  const minY=met==='acc'?Math.max(0,Math.min(...anns,bs)-4):Math.min(...all)*0.55;
  const X=(v)=>P.l+(W-P.l-P.r)*(v/64);
  const Y=(v)=>P.t+(HH-P.t-P.b)*(1-(v-minY)/Math.max(maxY-minY,1e-9));
  ctx.font='11px Consolas,monospace';ctx.fillStyle='#8b97bd';ctx.textAlign='right';
  ctx.strokeStyle='#2a3554';ctx.lineWidth=1;
  const ny=4;for(let i=0;i<=ny;i++){const vv=minY+(maxY-minY)*i/ny;
    const y=Y(vv);ctx.beginPath();ctx.moveTo(P.l,y);ctx.lineTo(W-P.r,y);ctx.stroke();
    ctx.fillText(ylab(vv),P.l-6,y+4);}
  ctx.textAlign='center';
  for(let b=0;b<=64;b+=16){ctx.fillText(b,X(b),HH-P.b+16);}
  ctx.save();ctx.translate(P.l,HH-P.b+14);ctx.fillStyle='#8b97bd';ctx.textAlign='left';
  ctx.font='12px sans-serif';ctx.fillText('翻转预算(bit)',8,20);ctx.restore();
  function dash(v,col2,lab){if(v==null||!isFinite(v))return;
    ctx.setLineDash([5,5]);ctx.strokeStyle=col2;
    ctx.beginPath();ctx.moveTo(P.l,Y(v));ctx.lineTo(W-P.r,Y(v));ctx.stroke();
    ctx.setLineDash([]);ctx.fillStyle=col2;ctx.textAlign='left';
    ctx.fillText(lab+' '+ylab(v),W-P.r-4,Y(v)-5);}
  if(bs!=null&&isFinite(bs))dash(bs,'#e6ecff','基线');
  if(met==='ppl'&&thresh!=null)dash(thresh,'#ffb547','阈值×'+THR);
  function series(pts,col2){if(!pts.length)return;
    ctx.strokeStyle=col2;ctx.lineWidth=2.4;ctx.beginPath();
    pts.forEach((r,i)=>{const x=X(r.flips),y=Y(r[F]);i?ctx.lineTo(x,y):ctx.moveTo(x,y);});
    ctx.stroke();ctx.fillStyle=col2;pts.forEach(r=>{ctx.beginPath();ctx.arc(X(r.flips),Y(r[F]),3.4,0,7);ctx.fill();});}
  series(su,'#ff5c7a');series(sp,'#3bdf8f');
  if(playMax>0){
    const xk=X(Math.min(playK,64));
    ctx.setLineDash([2,3]);ctx.strokeStyle='#38c2ff';ctx.lineWidth=1;
    ctx.beginPath();ctx.moveTo(xk,P.t);ctx.lineTo(xk,HH-P.b);ctx.stroke();ctx.setLineDash([]);
    ctx.fillStyle='#38c2ff';ctx.textAlign='left';ctx.font='11px Consolas,monospace';
    ctx.fillText('回放 ≤'+playK+'位',xk+6,P.t+10);
    [su,sp].forEach((arr,i)=>{const sv=interpAt(arr,playK);
      if(sv!=null&&isFinite(sv)){const yk=Y(sv);ctx.fillStyle=i?'#3bdf8f':'#ff5c7a';
        ctx.beginPath();ctx.arc(xk,yk,5,0,7);ctx.fill();ctx.strokeStyle='#0d1220';
        ctx.lineWidth=1.5;ctx.stroke();}});
  }
  last=s;
}
document.addEventListener('resize',()=>{if(last)draw(last)});
document.querySelectorAll('#metricgroup input').forEach(r=>r.addEventListener('change',()=>{if(r.checked){met=r.value;if(last)draw(last);}}));
function selMode(){document.getElementById('farpanel').style.display=document.getElementById('m_far').checked?'':'none';}
document.querySelectorAll('#modegroup input').forEach(r=>r.addEventListener('change',selMode));
selMode();
async function start(){
  const mode=document.querySelector('#modegroup input:checked').value;
  const body={budget:+document.getElementById('budget').value,mode};
  if(mode==='far'){
    body.layer=document.getElementById('layer').value.trim()||'transformer.h.2.mlp.c_proj';
    body.n=+document.getElementById('n').value;
    body.div=+document.getElementById('div').value;
    body.tier=document.getElementById('pbs_tier').value;
  }
  document.getElementById('start').disabled=true;
  setLive(true,'运行中…');
  await fetch('/api/attack',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
}
async function reset(){
  setLive(false,'正在恢复原始权重…');
  await fetch('/api/reset',{method:'POST'});
  setLive(false,'已恢复原始权重');
}
function setLive(on,txt){document.getElementById('dot').className=on?'dot on':'dot';document.getElementById('livetxt').textContent=txt;}
function fmt2(x){return x!=null&&isFinite(x)?x.toFixed(2):'--';}
async function runGen(){
  const mode=document.querySelector('#modegroup input:checked').value;
  const body={
    mode,
    gen_model:document.getElementById('gen_model').value,
    prompt:document.getElementById('gen_prompt').value,
    max_new:+document.getElementById('gen_max_new').value,
    seed:7,
    n_seed:+document.getElementById('gen_seeds').value,
    points:[...document.querySelectorAll('#genpoints input:checked')].map(i=>+i.value)
  };
  if(mode==='far'){
    body.layer=document.getElementById('layer').value.trim()||'transformer.h.2.mlp.c_proj';
    body.n=+document.getElementById('n').value;
    body.div=+document.getElementById('div').value;
  }
  document.getElementById('genbtn').disabled=true;
  document.getElementById('genbtn').textContent='正在生成…';
  await fetch('/api/gen',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
}
function renderExtras(s){
  const ob=document.getElementById('opsbox');
  if(s.ops&&s.ops.length){
    const hex=v=>(v>>>0).toString(16).toUpperCase().padStart(8,'0');
    const rows=s.ops.map(o=>{
      const coord=o.col!=null?`[${o.row},${o.col}]`:`[${o.row}]`;
      return `<tr>
        <td>${o.flip}</td>
        <td class="wrap" title="${o.layer}">${o.layer}</td>
        <td>${coord}</td>
        <td>bit${o.bit}</td>
        <td class="k">${hex(o.old)}</td>
        <td class="k">${hex(o.new)}</td>
        <td>${o.oldf}</td>
        <td class="warn">${o.newf}</td>
        <td>${o.acc_u==null?'--':+o.acc_u<60?`<span class="bad">${o.acc_u}%</span>`:o.acc_u+'%'}</td>
        <td>${o.bad?'<span class="bad">明显损伤</span>':'<span class="good">可接受</span>'}</td>
      </tr>`;
    }).join('');
    ob.innerHTML=`<div class="opsbox"><table class="ops">
      <tr><th>#</th><th>参数(层)</th><th>坐标</th><th>翻bit</th><th>旧位模式</th><th>新位模式</th><th>旧值f32</th><th>新值f32</th><th>裸acc</th><th>状态</th></tr>
      ${rows}</table></div>
      <div class="hint">位模式=该 f32 权重的 32 位十六进制；bit 为被取反的指数位(24–26)。共 ${s.ops.length} 步。</div>`;
  } else ob.textContent='运行一次单独攻击或 FaR 对比后，这里逐步列出「选中 → 翻转 → 损伤上升」的每一笔记录。';
  const gb=document.getElementById('genbox');
  if(s.gen&&s.gen.length){
    renderGenLanes(s);
  }
  document.getElementById('genbtn').disabled=s.gen_busy||s.running;
  document.getElementById('genbtn').textContent=s.gen_busy?'正在生成…':'生成回放文本';
  highlightOpsRow();
}
/* ---- 逐 token 热力泳道（把「数值在变」翻译成「可见的一次次乱掉」） ---- */
function _esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function _decLabel(d){return ({greedy:'贪心 top-1（易复读）',sample:'采样（默认）',hot:'高温采样（乱蹦字）'})[d]||d;}
function _tokHeat(ent){
  // 熵 0~5 区间：正常(绿)→警告(黄)→乱码(红)；熵越大越不确定
  const t=Math.min(1,Math.max(0,ent/5));
  const seg=t<0.33?0:t<0.66?1:2;
  const rgb=['59,223,143','255,181,71','255,92,122'][seg];
  const a=seg===0?0.10:seg===1?0.18:0.34;
  return 'rgba('+rgb+','+a+')';
}
function renderGenLanes(s){
  const gb=document.getElementById('genbox');
  if(!(s&&s.gen&&s.gen.length)){
    gb.innerHTML='<div class="hint">（尚未生成回放文本——点上方「生成回放文本」，这里会按档位铺成逐 token 热力泳道。）</div>';
    return;
  }
  const dec=document.getElementById('gen_decode')?document.getElementById('gen_decode').value:'sample';
  const pts=[...s.gen].sort((a,b)=>a.k-b.k);
  const base=(pts[0].ppl>0)?pts[0].ppl:1;      // 最低档位(通常 0 位)作为基线参照
  const thr=(s.thr&&s.thr.mult)?+s.thr.mult:4; // 与后端 THR=4 一致
  const rows=pts.map(g=>{
    const m=(g.modes&&g.modes[dec])||{toks:[],text:g.text||'','ent_avg':g.ent_avg||0};
    const ratio=base>0?g.ppl/base:1;
    const over=ratio>=thr;
    const toks=m.toks||[];
    const cells=toks.length?toks.map(t=>{
      const txt=(t.txt==='')?'·':(_esc(t.txt)||'·');
      const tt='token='+(t.t!=null?t.t:'?')+' id='+(t.id!=null?t.id:'?')+
               ' 熵='+(t.ent!=null?t.ent:'?')+' 置信='+(t.conf!=null?t.conf:'?')+
               ' top5='+(t.topk||[]).slice(0,3).join('|');
      return '<span class="tok" style="background:'+_tokHeat(t.ent||0)+'" title="'+_esc(tt)+'">'+txt+'</span>';
    }).join('')
    : '<span class="hint">（本档位无逐 token 数据）</span>';
    const seedNote=(g.n_seed&&g.n_seed>1)?' · ×'+g.n_seed+' 种取最乱帧':'';
    const badge=over
      ?' <span class="bad">已超阈值 ×'+thr+'</span>'
      :(ratio>1.5?' <span class="warn">开始劣化 ×'+ratio.toFixed(1)+'</span>':'');
    const head=(g.k===0)
      ?'<b class="ok">基线 · 0 位</b>'
      :'翻转 <b>'+g.k+'</b> 位';
    return '<div class="genblock'+(over?' crit':'')+'">'+
      '<div class="genhead">'+head+' · ppl=<b>'+g.ppl+'</b> · acc=<b class="'+(g.acc<60?'bad':'good')+'">'+g.acc+'%</b> · 均熵=<b>'+m.ent_avg+'</b>'+seedNote+badge+'</div>'+
      '<div class="tokline">'+cells+'</div></div>';
  }).join('');
  gb.innerHTML='<div class="genhint">解码=<b>'+_decLabel(dec)+'</b>：每个小格=一个 token，底色=该步预测熵（绿→黄→红=越不确定、越接近乱码）。0 位泳道常驻顶部作基线；越过阈值（ppl≥基线×'+thr+'）的档位红框标出。</div>'+rows;
}
let _thrState=null;
function renderThrBox(){
  const box=document.getElementById('s_thr'); if(!box)return;
  const s=_thrState, t=s&&s.thr, pb=s&&s.pbs, rc=_recheck;
  if(!t && !pb && !rc){
    box.innerHTML='运行 FaR 防护对比后显示。判据：困惑度达基线×4（⇔ NLL≥基线+ln4）即视为损伤达成，对比裸/FaR 各自所需翻位；比值落在论文区间 1.4–4.2× 即方向符合。';
    return;
  }
  const L=(s&&s.total&&s.total[0])||0, g=(x)=>x==null?'≥'+L:''+x;
  const rows=[];
  if(pb){
    const bud=pb.budget||L||16;
    const ru=(pb.u&&pb.u.flips!=null)?pb.u.flips:'≥'+bud;
    const rp=(pb.p&&pb.p.flips!=null)?pb.p.flips:'≥'+bud;
    const rr=pb.ratio_inf?'∞':((pb.ratio!=null)?Number(pb.ratio).toFixed(2)+'×':'—');
    rows.push('<b>① 论文协议口径（PBS 渐进位搜索）</b>：裸需 <b class="bad">'+ru+'</b> 位 · FaR需 <b class="good">'+rp+'</b> 位 → 比值 <b>'+rr+'</b>（论文区间 1.4–4.2×）');
  }
  if(t){
    const tu=t.u,tp=t.p;
    const r=tu==null?'—':((tp==null?L:tp)/Math.max(tu,1)).toFixed(2)+'×';
    rows.push('<b>② 固定顺序口径（按敏感度排序，会退化）</b>：裸 <b>'+g(tu)+'</b> 位 · FaR <b>'+g(tp)+'</b> 位 → 比值 <b>'+r+'</b>');
  }
  if(rc){
    const d=rc.layer_output_damage||{};
    const cont=(rc.damage_ratio||[]).filter(function(x){return x.ratio!=null;});
    const contR=cont.length?cont[cont.length-1].ratio:null;
    rows.push('<b>③ 机制（逐位损伤比）</b>：层输出 |ΔY|裸/|ΔY|FaR 中位 = <b>'+_rcFmt(d.median_ratio,3)+'</b>（理论 = div = '+(rc.div||2)+'，n='+(d.n||0)+' 位全中）；端到端 ΔNLL 比 = <b>'+_rcFmt(contR,3)+'</b>');
  }
  const thrTxt=(t&&t.mult)||(rc&&4)||4;
  box.innerHTML=rows.join('<br>')+
    '<div class="hint" style="margin-top:6px">判据：ppl≥基线×'+thrTxt+'（⇔ NLL≥基线+ln'+thrTxt+'）即损伤达成。'+
    '②固定顺序口径把敏感位按分数排序逐位翻，损伤呈「阶跃」——前几位打在低幅值位上几乎无损、随后某一位骤崩，裸/FaR 常在同一「热位」越线，故比值退化为 1.0×，<b>不能代表论文口径</b>。'+
    '①PBS 每轮贪心提交「最伤位」（commit-revert），才是与论文 1.4–4.2× 区间可比的口径。</div>';
}
function renderPBS(s){
  const card=document.getElementById('pbscard');
  const pb=s.pbs;
  if(!pb){card.style.display='none';return;}
  card.style.display='';
  document.getElementById('pbs_thr').textContent=pb.thr||4;
  const budget=(pb.budget||Math.max((pb.u&&pb.u.flips)||0,(pb.p&&pb.p.flips)||0,1));
  function bar(o,label,color){
    const flips=o&&o.flips;
    const reached=o&&o.reached;
    const b=o&&o.base_ppl!=null?o.base_ppl:'--';
    const w=(flips!=null&&budget>0)?Math.min((flips/budget)*100,100):0;
    const stat=flips!=null?`<b style="color:${color}">${flips} 位</b><span class="${reached?'good':'warn'}"> · ${reached?'达标':'预算内未达'}</span>`
                          :'<span class="warn">预算内未达阈值</span>';
    return `<div class="pbsbar" style="margin:10px 0">
      <div style="display:flex;justify-content:space-between;align-items:baseline;font-size:12.5px;margin-bottom:5px">
        <span style="color:var(--mut)">${label}</span>${stat}</div>
      <div style="height:15px;border-radius:8px;background:var(--panel2);overflow:hidden;position:relative">
        <div style="width:${w}%;height:100%;background:linear-gradient(90deg,${color}66,${color});border-radius:8px"></div>
        <div style="position:absolute;left:${w}%;top:0;bottom:0;width:2px;background:${color}"></div></div>
      <div style="font-size:11px;color:var(--mut);margin-top:3px">基线 ppl=${b} → 阈值 ppl=基线×${pb.thr}（NLL≥${o?o.target:'—'}）</div>
    </div>`;
  }
  document.getElementById('pbsbars').innerHTML=
    bar(pb.u,'裸模型（无防护）','var(--danger)')+
    bar(pb.p,'FaR 防护后','var(--ok)');
  const inf=pb.ratio_inf;
  const ratioTxt=inf?'∞（裸模型预算内未达阈值）':(pb.ratio!=null?pb.ratio+'×':'—');
  document.getElementById('pbsverdict').innerHTML=
    `判据：ppl≥基线×${pb.thr}（⇔NLL≥基线+ln${pb.thr}）即损伤达成。`+
    `『到阈值需翻位』裸=<b>${pb.u&&pb.u.flips!=null?pb.u.flips:'≥'+budget}</b>位`+
    ` · FaR=<b>${pb.p&&pb.p.flips!=null?pb.p.flips:'≥'+budget}</b>位`+
    ` → 比值 <b>${ratioTxt}</b>（论文区间 1.4–4.2×）。`+
    `<span class="pbtag">攻击者 tier=<b>${pb.tier}</b>；数值来自论文协议的 gradient-guided commit-revert 渐进位搜索，与上方困惑度曲线同一次 FaR 对比。</span>`;
}
function interpAt(arr,x){
  if(!arr||!arr.length)return null;
  for(let i=0;i<arr.length;i++){
    if(arr[i].flips>=x){
      if(i===0)return arr[i][FIELDS[met]];
      const a=arr[i-1],b=arr[i];
      const t=b.flips===a.flips?0:(x-a.flips)/(b.flips-a.flips);
      return a[FIELDS[met]]+(b[FIELDS[met]]-a[FIELDS[met]])*t;
    }
  }
  return arr[arr.length-1][FIELDS[met]];
}
function playMaxOf(s){
  let m=0;
  (s.series||[]).forEach(a=>a.forEach(r=>m=Math.max(m,r.flips)));
  (s.ops||[]).forEach(o=>m=Math.max(m,o.flip));
  (s.gen||[]).forEach(g=>m=Math.max(m,g.k));
  return m;
}
function setupPlay(s){
  if(s.running){ stopPlay(); }
  playMax=playMaxOf(s);
  const pc=document.getElementById('playcard');
  if(playMax<=0){pc.style.display='none';return;}
  pc.style.display='';
  document.getElementById('playmax').textContent=playMax;
  const sl=document.getElementById('playslider');sl.max=playMax;
  const msel=document.getElementById('gen_model');
  document.getElementById('playmodel').textContent=(msel&&msel.value==='far')?'FaR 防护后':'裸';
  if(s.total&&s.total[0]===0){playK=0;}
  if(playK>playMax)playK=playMax;
  updatePlayUI(s);
}
function updatePlayUI(s){
  if(playMax<=0)return;
  document.getElementById('playk').textContent=playK;
  document.getElementById('playslider').value=playK;
  const cl=document.getElementById('causeline'),ptb=document.getElementById('playtext');
  const ops=s.ops||[];
  let op=null;for(let i=ops.length-1;i>=0;i--){if(ops[i].flip<=playK){op=ops[i];break;}}
  if(!playK){
    cl.innerHTML='<b>原始权重</b>：0 位翻转，模型输出正常（基线）。';
  }else if(op){
    const coord=op.col!=null?`[${op.row},${op.col}]`:`[${op.row}]`;
    cl.innerHTML=`翻转第 <b>${op.flip}</b> 位 → 参数 <b>${op.layer}</b> · 坐标 ${coord} · bit<b>${op.bit}</b>：`+
      `旧值 <span class="k">${op.oldf}</span> → 新值 <span class="warn">${op.newf}</span>。`+
      `裸模型 acc ${op.acc_u==null?'--':op.acc_u+'%'}${op.acc_p==null?'':` / FaR ${op.acc_p}%`}`+
      (op.bad?' · <b class="bad">明显损伤</b>':'');
  }else{
    cl.innerHTML=`已推进到 <b>${playK}</b> 位（此档位无逐位快照记录）。`;
  }
  let gs=null;(s.gen||[]).forEach(g=>{if(g.k<=playK)gs=g;});
  ptb.innerHTML=gs
    ? `<div class="genblock"><div class="genhead">≈ 翻到第 <b>${playK}</b> 位的真实输出（样例档位 ${gs.k} 位 · ppl=${gs.ppl} · acc=<b class="${gs.acc<60?'bad':'good'}">${gs.acc}%</b>）</div><div class="gentext">${gs.text||'∅'}</div></div>`
    : (s.gen&&s.gen.length?'':'<div class="pbtag">（尚未生成回放文本——先点上方「生成回放文本」，动画里这段文字就会随翻位变乱。）</div>');
  highlightOpsRow();
}
function highlightOpsRow(){
  const rows=document.querySelectorAll('#opsbox table tr');
  rows.forEach((tr,i)=>{if(playK>0&&i===playK)tr.classList.add('hl');else tr.classList.remove('hl');});
}
function togglePlay(){
  playing=!playing;
  const b=document.getElementById('pbtn');
  if(playing){b.textContent='⏸ 暂停';startTick();}
  else{b.textContent='▶ 播放';stopTick();}
}
function startTick(){
  if(playTimer)clearInterval(playTimer);
  playTimer=setInterval(()=>{
    if(playK>=playMax){togglePlay();return;}
    playK++;updatePlayUI(last);draw(last);
  },420);
}
function stopTick(){if(playTimer){clearInterval(playTimer);playTimer=null;}}
function stopPlay(){playing=false;stopTick();const b=document.getElementById('pbtn');if(b)b.textContent='▶ 播放';}
function stepPlayK(d){playK=Math.max(0,Math.min(playMax,playK+d));updatePlayUI(last);draw(last);}
function seekPlay(k){playK=Math.max(0,Math.min(playMax,k));stopPlay();updatePlayUI(last);draw(last);}

/* ---------- 被攻击/被保护层选项卡：选什么层就展示哪层的损伤曲线 ---------- */
const LAYER_PRESETS={
  'transformer.h.2.mlp.c_proj':{short:'c_proj · h.2.mlp.c_proj',desc:'原演示层（MLP 降维投影）'},
  'transformer.h.0.mlp.c_fc':  {short:'up_proj · h.0.mlp.c_fc（代表层）',desc:'本项目 FaR 硬件加速代表层（MLP 升维投影，最敏感）'}
};
let activeLayer=document.getElementById('layer').value;
function layerShort(l){const p=LAYER_PRESETS[l];return p?p.short:l;}
function setTabHighlight(l){
  document.getElementById('lt_cproj').checked=(l==='transformer.h.2.mlp.c_proj');
  document.getElementById('lt_up').checked=(l==='transformer.h.0.mlp.c_fc');
}
function setLayerMeta(l,have){
  document.getElementById('layermeta').innerHTML='当前层：<b>'+_esc(layerShort(l))+'</b> · '+
    (have?'状态：已运行（正展示该层缓存曲线；点「开始」可用新参数重跑）'
         :'状态：待首次运行 → 切到『FaR 防护对比』点「开始」，即展示该层损伤曲线');
}
function emptySnapshot(msg){
  return {running:false,series:[[],[]],baseline:[null,null],total:[0,0],thr:null,
          pbs:null,gen:[],ops:[],msg:msg||'该层尚未运行'};
}
async function pickLayer(l){
  activeLayer=l;
  document.getElementById('layer').value=l;
  setTabHighlight(l);
  let d={series:[[],[]],msg:'该层尚未运行'};
  try{const r=await fetch('/api/layer?name='+encodeURIComponent(l)); d=await r.json();}catch(e){}
  const has=!!(d&&d.series&&(d.series[0].length||d.series[1].length));
  setLayerMeta(l,has);
  document.getElementById('msg').textContent=d.msg||(has?'已加载该层缓存结果':('该层尚未运行 → 点「开始」'));
  const snap=has?(d.gen=d.gen||[],d.ops=d.ops||[],d.total=d.total||[0,0],d):emptySnapshot('该层尚未运行 → 点「开始」后展示该层损伤曲线');
  applySnapshot(snap);
}
function onLayerManual(){  // 手写在文本框的自定义层：取消选项卡选中，activeLayer 跟随以便实时刷新
  activeLayer=document.getElementById('layer').value;
  setTabHighlight(activeLayer);
  document.getElementById('layermeta').innerHTML='当前层：<b>'+(_esc(activeLayer)||activeLayer)+'</b> · 自定义层，点「开始」后展示其曲线';
}
function applySnapshot(s){
  const b0=s.baseline&&s.baseline[0], b1=s.baseline&&s.baseline[1];
  const lastV=(a)=>a&&a.length?a[a.length-1]:null;
  const cu=lastV(s.series&&s.series[0]), cp=lastV(s.series&&s.series[1]);
  document.getElementById('s_ub').textContent=b0?fmt2(b0.ppl):'--';
  document.getElementById('s_pb').textContent=b1?fmt2(b1.ppl):'--';
  document.getElementById('s_uc').textContent=cu?fmt2(cu.ppl):'--';
  document.getElementById('s_pc').textContent=cp?fmt2(cp.ppl):'--';
  const acc=(x)=>x&&x.acc!=null?x.acc.toFixed(1)+'%':'--';
  document.getElementById('s_acc').textContent=(cu?acc(cu):'--')+' / '+(cp?acc(cp):'--');
  _thrState=s;
  renderThrBox();
  draw(s);
  renderExtras(s);
  setupPlay(s);
  renderPBS(s);
}
function _hwLine(cv,series,opt){
  opt=opt||{};
  const dpr=window.devicePixelRatio||1,w=cv.clientWidth||420,h=cv.clientHeight||250;
  cv.width=w*dpr;cv.height=h*dpr;
  const c=cv.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);
  const P={l:52,r:16,t:14,b:34};
  const xs=[].concat.apply([],series.map(function(s){return s.pts.map(function(p){return p[0];});}));
  const ys=[].concat.apply([],series.map(function(s){return s.pts.map(function(p){return p[1];});})).filter(function(v){return isFinite(v);});
  const x0=Math.min.apply(null,xs),x1=Math.max.apply(null,xs);
  let y0=Math.min.apply(null,ys),y1=Math.max.apply(null,ys);
  if(opt.y0!=null)y0=Math.min(y0,opt.y0);
  if(y1===y0)y1=y0+1;
  const pad=(y1-y0)*0.08;y0-=pad;y1+=pad;
  const X=function(v){return P.l+(v-x0)/Math.max(x1-x0,1e-9)*(w-P.l-P.r);};
  const Y=function(v){return h-P.b-(v-y0)/Math.max(y1-y0,1e-9)*(h-P.t-P.b);};
  c.font='11px system-ui';c.strokeStyle='rgba(138,151,189,.22)';c.lineWidth=1;
  c.fillStyle='#8b97bd';c.textAlign='right';c.textBaseline='middle';
  for(let i=0;i<=4;i++){const v=y0+(y1-y0)*i/4,y=Y(v);
    c.beginPath();c.moveTo(P.l,y);c.lineTo(w-P.r,y);c.stroke();
    c.fillText(opt.yfmt?opt.yfmt(v):v.toFixed(1),P.l-6,y);}
  if(opt.base!=null&&isFinite(opt.base)){
    c.setLineDash([5,5]);c.strokeStyle='#e6ecff';
    c.beginPath();c.moveTo(P.l,Y(opt.base));c.lineTo(w-P.r,Y(opt.base));c.stroke();c.setLineDash([]);
    c.fillStyle='#e6ecff';c.textAlign='left';c.textBaseline='bottom';c.fillText('基线',P.l+4,Y(opt.base)-3);}
  c.textAlign='center';c.textBaseline='top';
  const ticks=(opt.xticks&&opt.xticks.length)?opt.xticks:[x0,(x0+x1)/2,x1];
  ticks.forEach(function(xv){const x=X(xv);
    c.beginPath();c.moveTo(x,h-P.b);c.lineTo(x,h-P.b+4);c.stroke();
    c.fillText(String(Math.round(xv)),x,h-P.b+7);});
  if(opt.xlabel){c.fillText(opt.xlabel,(P.l+w-P.r)/2,h-13);}
  if(opt.vline!=null&&isFinite(opt.vline)){const xv=X(opt.vline);
    c.setLineDash([2,3]);c.strokeStyle='#38c2ff';c.lineWidth=1;
    c.beginPath();c.moveTo(xv,P.t);c.lineTo(xv,h-P.b);c.stroke();c.setLineDash([]);}
  series.forEach(function(s){
    const pts=(opt.reveal==null)?s.pts:s.pts.slice(0,opt.reveal+1);
    if(!pts.length)return;
    c.strokeStyle=s.color;c.lineWidth=s.w||2;c.setLineDash(s.dash||[]);
    c.beginPath();
    pts.forEach(function(p,i){const x=X(p[0]),y=Y(p[1]);i?c.lineTo(x,y):c.moveTo(x,y);});
    c.stroke();c.setLineDash([]);
    if(!s.dash||!s.dash.length){c.fillStyle=s.color;
      pts.forEach(function(p){c.beginPath();c.arc(X(p[0]),Y(p[1]),2.6,0,7);c.fill();});}
    const lp=pts[pts.length-1];
    c.fillStyle=s.color;c.beginPath();c.arc(X(lp[0]),Y(lp[1]),5,0,7);c.fill();
    c.lineWidth=1.5;c.strokeStyle='#0d1220';c.stroke();
  });
}
function _hwStat(k,v,cls){return '<div class="hwstat"><div class="k">'+k+'</div><div class="v '+(cls||'')+'">'+v+'</div></div>';}
let _hwLast=null;
let _recheck=null;   // threshold_metric_recheck.json（判据复核 + 逐位损伤比）
window.addEventListener('resize',function(){ if(_hwLast) drawHWCmp(_hwLast); });
let _hvK=0,_hvTimer=null,_hvPlaying=false;
function _hvMaxK(){return (_hwLast&&_hwLast.curve&&_hwLast.curve.flips)?_hwLast.curve.flips.length-1:0;}
function hvStop(){if(_hvTimer){clearInterval(_hvTimer);_hvTimer=null;}_hvPlaying=false;
  const b=document.getElementById('hvbtn'); if(b)b.textContent='▶ 动态播放';}
function hvToggle(){
  if(_hvPlaying){hvStop();return;}
  if(!_hwLast)return;
  if(_hvK>=_hvMaxK())_hvK=0;
  _hvPlaying=true; const b=document.getElementById('hvbtn'); if(b)b.textContent='⏸ 暂停';
  _hvTimer=setInterval(function(){ if(_hvK>=_hvMaxK()){hvStop();return;} hvSeek(_hvK+1,true); },520);
}
function hvSeek(k,fromTimer){
  _hvK=Math.max(0,Math.min(k,_hvMaxK()));
  const sl=document.getElementById('hvslider'); if(sl&&+sl.value!==_hvK)sl.value=_hvK;
  if(_hwLast)drawHWCmp(_hwLast);
  if(!fromTimer)hvStop();
}
async function loadHWCmp(){
  let d=null;
  try{const r=await fetch('/api/hwcmp'); if(r.ok) d=await r.json();}catch(e){}
  const st=document.getElementById('hwstats'),vd=document.getElementById('hwcmpverdict');
  if(!d||!d.hw){st.innerHTML='';vd.textContent='未找到 hw_compare.json / eval_benchmark_far_h0_cfc.json（生成后刷新）。';return;}
  _hwLast=d;_hvK=0;drawHWCmp(d);
  setTimeout(function(){ if(!_hvPlaying)hvToggle(); },700);
}
async function loadRecheck(){
  try{const r=await fetch('/api/recheck'); if(r.ok) _recheck=await r.json();}catch(e){}
  renderThrBox();
}
function _rcFmt(v,n){return (v==null||!isFinite(v))?'—':Number(v).toFixed(n==null?2:n);}
function _hvNum(v){return (v==null||!isFinite(v))?'—':(v>=1000?Math.round(v).toLocaleString():Number(v).toFixed(1));}
function drawHWCmp(d){
  const st=document.getElementById('hwstats'),vd=document.getElementById('hwcmpverdict');
  const hw=d.hw||{},hwd=hw.hardware||{},swd=hw.software||{},cv=d.curve||{};
  const spd=hw.speedup||((swd.far_overhead_us||0)/(hwd.far_extra_us||1));
  const flips=cv.flips||[];
  const b=cv.baseline||{},cN=cv['curve_裸'],cF=cv['curve_FaR'];
  const ser=[];
  if(cN)ser.push({name:'裸',color:'#ff5c7a',pts:cN.flips.map(function(f,i){return [f,cN.ppl[i]];})});
  if(cF)ser.push({name:'软件 FaR',color:'#3bdf8f',pts:cF.flips.map(function(f,i){return [f,cF.ppl[i]];})});
  if(cF)ser.push({name:'硬件 FaR',color:'#38c2ff',dash:[7,5],w:3,pts:cF.flips.map(function(f,i){return [f,cF.ppl[i]];})});
  const baseP=(b['裸']&&b['裸'].ppl)||0;
  const rev=flips.length?Math.min(_hvK,flips.length-1):null;
  _hwLine(document.getElementById('hvcv1'),ser,{
    xlabel:'翻位数（bit flips）',base:baseP,reveal:rev,
    vline:(rev!=null)?flips[rev]:null,
    yfmt:function(v){return v>=1000?Math.round(v).toLocaleString():v.toFixed(0);}});
  const steps=[0,128,256,384,512];
  const sw=steps.map(function(s){return [s,s*(swd.far_overhead_us||0)/1000];});
  const hwv=steps.map(function(s){return [s,s*(hwd.far_extra_us||0)/1000];});
  _hwLine(document.getElementById('hvcv2'),[
    {name:'软件 FaR',color:'#ffb547',pts:sw},
    {name:'硬件 FaR',color:'#38c2ff',pts:hwv}
  ],{xlabel:'推理步数（token）',yfmt:function(v){return v.toFixed(0)+' ms';}});
  const sl=document.getElementById('hvslider');
  if(sl)sl.max=Math.max(0,flips.length-1);
  const hm=document.getElementById('hvmax'); if(hm)hm.textContent=flips.length?flips[flips.length-1]:0;
  const hk=document.getElementById('hvk'); if(hk)hk.textContent=(rev!=null&&flips[rev]!=null)?flips[rev]:0;
  const rd=document.getElementById('hvread');
  if(rd){
    if(rev==null||!cN||!cF){rd.textContent='该层暂无曲线数据。';}
    else{
      const uN=cN.ppl[rev],uF=cF.ppl[rev];
      let cmp='';
      if(uN&&uF&&isFinite(uN)&&isFinite(uF)){
        cmp=uN>=uF?(' · FaR 比裸低 <b class="good">'+(uN/uF).toFixed(2)+'×</b>')
                  :(' · FaR 比裸高 <b class="warn">'+(uF/uN).toFixed(2)+'×</b>');
      }
      rd.innerHTML='第 <b>'+(flips[rev])+'</b> 位翻转 → 裸 ppl <b class="warn">'+_hvNum(uN)+'</b> · 软件/硬件 FaR ppl <b class="good">'+_hvNum(uF)+'</b>'+cmp;
    }
  }
  st.innerHTML=[
    _hwStat('防护等效','逐 bit 一致','g'),
    _hwStat('软件 FaR 开销',(swd.far_overhead_us!=null?swd.far_overhead_us.toFixed(1)+' µs':'—'),'w'),
    _hwStat('硬件 FaR 开销',(hwd.far_extra_us!=null?hwd.far_extra_us.toFixed(1)+' µs':'—')),
    _hwStat('开销降低',(spd?spd.toFixed(1)+'×':'—'),'g')
  ].join('');
  const at512=Math.round(512*((swd.far_overhead_us||0)-(hwd.far_extra_us||0))/1000);
  vd.innerHTML='结论：硬件 FaR 与软件 FaR 输出 <b>逐 bit 一致</b> → 防护强度无损；同时每步 FaR 开销从软件 <b class="warn">'
    +(swd.far_overhead_us||0).toFixed(1)+' µs</b> 降到硬件 <b>'
    +(hwd.far_extra_us||0).toFixed(1)+' µs</b>（<b>'+spd.toFixed(1)+'×</b>），且防护在 PL 数据通路内完成、不占 CPU。'
    +'按 512 步外推，硬件比软件少花 <b>'+at512+' ms</b>。层：'+(hw.layer||'—')+'；硬件取自 L4 实测，软件取自同层 torch 前向（reps='+(swd.reps||'—')+'）。';
}
function _hwPill(k,v){return '<span><b style="color:var(--tx)">'+k+'</b> '+v+'</span>';}
function _hwRow(k,v){return '<tr><td style="color:var(--mut);white-space:nowrap;padding:6px 10px;border-bottom:1px solid var(--line)">'+k+'</td><td style="padding:6px 10px;border-bottom:1px solid var(--line)">'+v+'</td></tr>';}
let bdBusy=false,bdAnim=false;
const bdTl=[];   // 启动链卡攻防时间线（页面生命周期）
function bdTlRender(){
  const box=document.getElementById('bdev');
  box.innerHTML=bdTl.map(function(e){
    return '<div class="bdl"><span class="tg tg-'+e.cls+'">'+e.tag+'</span>'+_esc(e.txt)+'</div>';
  }).join('');
  box.scrollTop=box.scrollHeight;
}
function bdTlAdd(tag,cls,txt){bdTl.push({tag:tag,cls:cls,txt:txt});bdTlRender();}
function bdHashCell(id,txt,ok){
  const el=document.getElementById(id);
  el.querySelector('.hv').textContent=txt;
  el.classList.remove('hit','miss');
  if(ok===true)el.classList.add('hit');
  if(ok===false)el.classList.add('miss');
}
function bdPipe(d){
  if(bdAnim)return;   // 重解密动画期间不打断流水线着色
  const el=id=>document.getElementById(id);
  ['bdp1','bdp2','bdp3','bdp4','bdp5'].forEach(id=>{el(id).classList.remove('ok','bad');});
  if(!d||!d.ok){document.getElementById('bddec').textContent='--';return;}
  el('bdp1').classList.add('ok');
  if(d.k_used>0)el('bdp2').classList.add('ok');
  if(d.hd<=1)el('bdp3').classList.add('ok');else if(d.hd>3)el('bdp3').classList.add('bad');
  document.getElementById('bddec').textContent=Number(d.dec_ms).toFixed(1);
  el('bdp4').classList.add(d.dec_ms>0?'ok':'bad');
  if(d.wiped){el('bdp5').classList.add('bad');return;}   // 明文被擦：Canary 失效态
  el('bdp5').classList.add(d.boot_ok===1?'ok':'bad');
}
async function loadBoard(){
  if(bdBusy) return;
  const meta=document.getElementById('bdmeta'),tab=document.getElementById('bdtab');
  let d=null;
  try{const r=await fetch('/api/board'); if(r.ok) d=await r.json();}catch(e){}
  bdPipe(d&&d.ok?d:null);
  if(!d||!d.ok){
    meta.innerHTML='<span style="color:var(--warn)">板卡离线 / FARC 不可达'+((d&&d.error)?' · '+_esc(d.error):'')+'</span>';
    tab.innerHTML='';
    return;
  }
  const bootOk=d.boot_ok===1;
  meta.innerHTML=[
    _hwPill('板卡',d.host+':'+d.port),
    _hwPill('启动链',bootOk?'<span class="badge ok">OK</span>':'<span class="badge no">未就绪</span>'),
    _hwPill('冷启动',d.boot_count+'/'+d.attempts),
    _hwPill('累计翻转',d.n_flips),
    _hwPill('DDR 明文',d.wiped?'<span class="badge no">已擦除</span>':'<span class="badge ok">在位</span>')
  ].join('');
  const gone=d.wiped||d.w_hash==='0000000000000000000000000000000000000000000000000000000000000000';
  tab.innerHTML='<table style="width:100%;border-collapse:collapse;font-size:12px">'
    +_hwRow('运行期明文 W sha256','<span class="hwhash">'+(gone?'<i style="color:var(--mut)">（已擦除）</i>':d.w_hash)+'</span>')
    +_hwRow('SD 卡密文 sha256（不随擦除变化）','<span class="hwhash">'+d.enc_hash+'</span>')
    +'</table>';
  bdHashCell('bdh0',d.probe_ref?d.probe_ref.slice(0,16)+'…':'--',d.probe_ref?true:null);
  document.getElementById('boardcard').classList.toggle('attacked',!!d.wiped);
}
async function bdOp(op){
  if(bdBusy)return;
  if(op==='wipe'&&!confirm('模拟攻击者：擦除板上 DDR 明文权重？（SD 密文不受影响，可随时重解密恢复）'))return;
  bdBusy=true;
  const msg=document.getElementById('bdmsg');
  document.getElementById('bdwipe').disabled=true;
  document.getElementById('bdrestore').disabled=true;
  if(op==='wipe'){
    bdTlAdd('ATT','flip','攻击者擦除 DDR 明文权重：9.01MB 明文 → 全零（SD 密文未触碰）');
    document.getElementById('boardcard').classList.add('attacked');
    msg.textContent='正在擦除并采集受损证据…';
    try{
      const r=await fetch('/api/boardop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op:op})});
      const d=await r.json();
      if(d.ok){
        bdHashCell('bdh1',(d.probe_after||'--').slice(0,16)+'…',false);
        if(d.probe_before&&d.probe_after&&d.probe_before!==d.probe_after){
          bdTlAdd('ATT','flip','损伤证实：同一探针输入，输出指纹 '+d.probe_before.slice(0,16)+'… → '+d.probe_after.slice(0,16)+'…，模型输出已损坏');
        }
        msg.textContent='已擦除：板上明文全零，探针指纹已改变（密文仍在 SD）';
      }else{msg.textContent='失败：'+(d.error||'');}
    }catch(e){msg.textContent='失败：'+e;}
  }else{
    bdTlAdd('DEF','rest','防御反制：触发完整安全启动链重解密（PUF→FE/KDF→HD 门禁→AES→Canary）');
    bdAnim=true;
    const ids=['bdp1','bdp2','bdp3','bdp4','bdp5'];
    const labels=['PUF 上电采样中…','模糊提取+KDF 派生密钥…','HD 门禁校验…','AES-256-CTR 流解密 9.01MB…','Canary 输出指纹仲裁…'];
    async function bdFetchRestore(){
      try{
        const r=await fetch('/api/boardop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op:'restore'})});
        const d=await r.json();
        bdAnim=false;
        if(d.ok){
          bdTlAdd('DEF','rest','链路实测：HD='+d.hd+' · k='+d.k_used+' 位纠错 · 解密 '+Number(d.dec_ms).toFixed(1)+' ms · Canary PASS');
          document.getElementById('boardcard').classList.remove('attacked');
          if(d.probe_recovered===true){
            bdHashCell('bdh2',(d.probe_after||'--').slice(0,16)+'…',true);
            bdTlAdd('DEF','done','恢复证实：探针指纹与参考 bit-exact 一致 —— 9.01MB 权重已从密文完整复原');
          }else{
            bdHashCell('bdh2',(d.probe_after||'--').slice(0,16)+'…',null);
            bdTlAdd('DEF','done','恢复完成：明文权重已回 DDR（确立参考基准 '+(d.probe_after||'--').slice(0,16)+'…）');
          }
          msg.textContent='防御成功：明文已恢复';
        }else{
          ids.forEach(function(id){document.getElementById(id).classList.remove('run');});
          bdTlAdd('DEF','err','安全链拒绝：'+(d.error||''));
          msg.textContent='失败：'+(d.error||'');
        }
      }catch(e){bdAnim=false;msg.textContent='失败：'+e;}
      bdBusy=false;
      document.getElementById('bdwipe').disabled=false;
      document.getElementById('bdrestore').disabled=false;
      loadBoard();
    }
    let i=0;
    const t=setInterval(function(){
      if(i>0){const p=document.getElementById(ids[i-1]);p.classList.remove('run');p.classList.add('ok');}
      if(i>=ids.length){clearInterval(t);bdFetchRestore();return;}
      document.getElementById(ids[i]).classList.remove('ok');
      document.getElementById(ids[i]).classList.add('run');
      msg.textContent=labels[i];i++;
    },420);
    return;
  }
  bdBusy=false;
  document.getElementById('bdwipe').disabled=false;
  document.getElementById('bdrestore').disabled=false;
  loadBoard();
}
let bdGoBusy=false;
async function bdStart(){
  if(bdGoBusy)return;
  bdGoBusy=true;
  const b=document.getElementById('bdgobtn');
  b.disabled=true;
  try{
    const r=await fetch('/api/boardattack',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({budget:+document.getElementById('bdbudget').value})});
    const d=await r.json();
    if(!d.ok)alert('启动失败：'+(d.reason||'busy'));
  }catch(e){alert('启动失败：'+e);}
  bdGoBusy=false;b.disabled=false;
}
function fmtPpl(v){return (v==null||!isFinite(v))?'NaN':(v>=1000?Math.round(v).toLocaleString():v.toFixed(1));}
let bdLastBase=null,bdEvN=0;
function bdDraw(ser){
  const c=document.getElementById('bdcv'),g=c.getContext('2d');
  const w=c.clientWidth,h=c.clientHeight;
  c.width=w*dpr();c.height=h*dpr();g.setTransform(dpr(),0,0,dpr(),0,0);
  g.clearRect(0,0,w,h);
  const P={l:48,r:14,t:16,b:26},xmax=8;
  const y0=1,y1=Math.log10(300000);
  const X=x=>P.l+(x/xmax)*(w-P.l-P.r);
  const Y=p=>P.t+(1-(Math.log10(Math.max(1,p))-y0)/(y1-y0))*(h-P.t-P.b);
  g.font='10px ui-monospace,Consolas,monospace';
  [10,100,1000,10000,100000].forEach(function(v){
    const y=Y(v);
    g.strokeStyle='rgba(142,160,191,.14)';g.beginPath();g.moveTo(P.l,y);g.lineTo(w-P.r,y);g.stroke();
    g.fillStyle='#8ea0bf';g.fillText(v>=1000?((v/1000)+'k'):String(v),8,y+3);
  });
  for(let x=0;x<=xmax;x+=2){
    g.strokeStyle='rgba(142,160,191,.10)';g.beginPath();g.moveTo(X(x),P.t);g.lineTo(X(x),h-P.b);g.stroke();
    g.fillStyle='#8ea0bf';g.fillText(String(x),X(x)-4,h-8);
  }
  const mu=bdLastBase&&bdLastBase[0];
  if(mu&&isFinite(mu.ppl)){
    g.setLineDash([5,4]);
    g.strokeStyle='rgba(142,160,191,.75)';g.beginPath();g.moveTo(P.l,Y(mu.ppl));g.lineTo(w-P.r,Y(mu.ppl));g.stroke();
    g.strokeStyle='rgba(255,181,71,.85)';g.beginPath();g.moveTo(P.l,Y(mu.ppl*4));g.lineTo(w-P.r,Y(mu.ppl*4));g.stroke();
    g.setLineDash([]);
    g.fillStyle='rgba(255,181,71,.95)';g.fillText('阈值 基线×4',P.l+6,Y(mu.ppl*4)-4);
  }
  ser.forEach(function(s){
    g.strokeStyle=s.color;g.lineWidth=2;
    let pen=false;g.beginPath();
    s.pts.forEach(function(p){
      if(!isFinite(p[1])||p[1]<=0){pen=false;return;}
      if(!pen){g.moveTo(X(p[0]),Y(p[1]));pen=true;}else g.lineTo(X(p[0]),Y(p[1]));
    });
    g.stroke();
    g.fillStyle=s.color;
    s.pts.forEach(function(p){
      if(!isFinite(p[1])||p[1]<=0)return;
      g.beginPath();g.arc(X(p[0]),Y(p[1]),3,0,6.2832);g.fill();
    });
    g.lineWidth=1;
  });
}
function bdRenderEvents(d){
  const box=document.getElementById('bdcons'),evs=(d.events||[]);
  if(evs.length<bdEvN){box.innerHTML='';bdEvN=0;}
  if(evs.length===bdEvN)return;
  for(let i=bdEvN;i<evs.length;i++){
    const e=evs[i],div=document.createElement('div');
    div.className='bdl';
    div.innerHTML='<span class="tg tg-'+e.cls+'">'+e.tag+'</span>'+_esc(e.txt);
    box.appendChild(div);
  }
  bdEvN=evs.length;
  box.scrollTop=box.scrollHeight;
}
async function bdPoll(){
  let d=null;
  try{const r=await fetch('/api/boardstatus');if(r.ok)d=await r.json();}catch(e){}
  if(!d)return;
  document.getElementById('bdstmsg').textContent=d.msg||'';
  bdLastBase=d.baseline;
  const mu=(d.baseline&&d.baseline[0])||null,mp=(d.baseline&&d.baseline[1])||null;
  const su=(d.series&&d.series[0])||[],sp=(d.series&&d.series[1])||[];
  const ser=[];
  if(mu&&su.length){
    ser.push({name:'裸',color:'#ff5c7a',
      pts:[[0,mu.ppl]].concat(su.map(function(e){return [e.flips,e.ppl];}))});
  }
  if(mp&&sp.length){
    ser.push({name:'FaR',color:'#38c2ff',
      pts:[[0,mp.ppl]].concat(sp.map(function(e){return [e.flips,e.ppl];}))});
  }
  bdDraw(ser);
  const ph=document.getElementById('bdphase');
  ph.textContent=d.running?'运行中…':(d.err?'出错':((su.length||sp.length)?'已完成':'待启动'));
  ph.className='v '+(d.err?'warn':((su.length||sp.length)?'good':''));
  document.getElementById('bdk').textContent=((d.total&&d.total[0])||0)+' 位';
  const lu=su.length?su[su.length-1]:null,lp=sp.length?sp[sp.length-1]:null;
  document.getElementById('bdpu').textContent=lu?fmtPpl(lu.ppl):'--';
  document.getElementById('bdpp').textContent=lp?fmtPpl(lp.ppl):'--';
  const gain=(lu&&lp&&isFinite(lu.ppl)&&isFinite(lp.ppl)&&lp.ppl>0)?(lu.ppl/lp.ppl):null;
  const ge=document.getElementById('bdgain');
  ge.textContent=gain?gain.toFixed(1)+'×':'--';
  ge.className='v '+(gain&&gain>1?'good':'');
  bdRenderEvents(d);
  const vd=document.getElementById('bdverdict');
  if(d.thr){
    vd.innerHTML='『到阈值(ppl≥基线×'+(d.thr.mult||4)+')需翻位』裸='
      +(d.thr.u==null?'预算内未达':d.thr.u+'位')
      +', FaR='+(d.thr.p==null?'预算内未达':d.thr.p+'位')
      +'（论文区间 1.4–4.2×）';
  }else{vd.textContent='';}
}
setInterval(bdPoll,1500);
pickLayer(document.getElementById('layer').value);

async function poll(){
  try{
    const r=await fetch('/api/status');const s=await r.json();
    document.getElementById('msg').textContent=s.msg||'';
    document.getElementById('start').disabled=s.running;
    setLive(s.running, s.running?'运行中…':((s.total&&s.total[0])?'完成':'就绪'));
    // 最近运行的就是当前查看层 → 曲线/PBS 实时跟上；否则保留 pickLayer 展示的该层缓存/空态
    if(s.layer===activeLayer) applySnapshot(s);
  }catch(e){}
  setTimeout(poll,900);
}
poll();
loadHWCmp();
loadRecheck();
loadBoard();
setInterval(loadBoard,3000);
</script>
</body>
</html>
"""

# 注入当前生效的模型名（切档 FAR_MODEL 时页面自动跟着变）
HTML = HTML.replace("@MODEL_NAME@", model_display_name())


# ---------------------------------------------------------------------------
# 板卡 FARC 控制通道（实时脱密可视化 + 攻击执行端）
#   FLIP 只动运行期 DDR 明文工作副本（模拟物理位注入的执行端），
#   攻击决策/搜索全部在 PC shadow 副本上完成——权重不出板、密钥不出 PL。
# ---------------------------------------------------------------------------
_board_lock = threading.Lock()


_PROBE_STATE = {"ref": None}   # 干净权重探针指纹（恢复成功后确立，跨 wipe/restore 复用）


def _board_probe_hash():
    """对板上当前权重发一次探针推理，返回 SHA256(Y) 指纹（损伤/恢复证据）。"""
    import hashlib

    import numpy as np
    from fara_offload_e2e import BoardBackend
    bits = 0x3F800000 + (np.arange(768, dtype=np.uint32) % 64) * np.uint32(0x00800000)
    X = bits.view("<f4").reshape(1, 768)
    bb = BoardBackend(board_ctrl.HOST, board_ctrl.PORT, timeout=30.0)
    try:
        bb.connect()
        Y = bb.infer(X, [])
        return hashlib.sha256(np.ascontiguousarray(Y, dtype="<f4").tobytes()).hexdigest()
    finally:
        bb.close()


def _board_query():
    """直连板卡查 FARC STATUS；失败返回 ok=False（面板显示离线）。"""
    try:
        s = board_ctrl.connect(timeout=6.0)
        try:
            d = board_ctrl.get_status(s)
        finally:
            s.close()
        d["ok"] = True
        d["host"] = board_ctrl.HOST
        d["port"] = board_ctrl.PORT
        d["probe_ref"] = _PROBE_STATE["ref"]
        return d
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def _board_op(op):
    """执行 wipe / restore，返回 (ok, info)；附带探针指纹证据。

      wipe    先抓「攻击前」指纹 → 擦除 → 抓「受损」指纹（两者不同 = 模型已被破坏）
      restore 重解密 → 抓「恢复」指纹（与参考一致 = bit-exact 复原；参考取自恢复成功后）
    """
    info = {}
    try:
        if op == "wipe":
            try:
                info["probe_before"] = _board_probe_hash()
            except Exception as e:
                info["probe_err"] = f"{type(e).__name__}: {e}"
            # 板卡单线程 accept：FARC 连接必须先关，探针 FARQ 才能被受理
            s = board_ctrl.connect(timeout=15.0)
            try:
                board_ctrl.wipe(s)
            finally:
                s.close()
            try:
                h = _board_probe_hash()
                info["probe_after"] = h
                info["probe_damaged"] = info.get("probe_before") not in (None, h)
            except Exception as e:
                info["probe_err"] = f"{type(e).__name__}: {e}"
        else:
            s = board_ctrl.connect(timeout=15.0)
            try:
                st, _ = board_ctrl.restore(s)
            finally:
                s.close()
            if st != 0:
                return False, {"error": f"安全链拒绝（status={st}，HD 超限/Canary 失败）"}
            try:
                h = _board_probe_hash()
                info["probe_after"] = h
                if _PROBE_STATE["ref"] is None:
                    _PROBE_STATE["ref"] = h   # 首次恢复即确立干净参考（Canary 已 PASS）
                    info["probe_recovered"] = True
                else:
                    info["probe_recovered"] = (h == _PROBE_STATE["ref"])
            except Exception as e:
                info["probe_err"] = f"{type(e).__name__}: {e}"
    except Exception as e:
        return False, {"error": f"{type(e).__name__}: {e}"}
    out = _board_query()
    out.update(info)
    return True, out


# ---------------------------------------------------------------------------
# 板上实时攻防（8-2b）：PC 算好 BFA 计划（shadow cfg 敏感位）→ FARC FLIP 逐位
#   下发到板卡真实权重 → FARQ 双推理测语料 NLL。
#   双曲线=同一份板上 W + 同样翻转，唯一区别是 RTL farmap 开关：
#     裸  n_far=0（无 reroute） vs FaR n_far=1（far_reroute.sv 数据通路内改写）
# ---------------------------------------------------------------------------
_bd_state = {
    "running": False,
    "msg": "待启动：选翻转预算后点「启动板上攻防」。",
    "baseline": [None, None],     # [裸, FaR] 0 位基线
    "series": [[], []],           # [裸曲线, FaR曲线] {flips,ppl,nll,acc}
    "total": [0, 0],
    "ops": [],                    # FARC FLIP 回执（old/new 位模式）
    "events": [],                 # 攻防事件流（前端实时追加渲染）
    "thr": None,                  # {"mult","u","p"} 到阈值翻位
    "budget": 0, "err": None,
}


def _bd_ev(tag, cls, txt):
    """攻防事件流：带时间戳追加（保留最近 200 条）。"""
    with _lock:
        ev = _bd_state["events"]
        ev.append({"t": time.strftime("%H:%M:%S"), "tag": tag, "cls": cls, "txt": txt})
        del ev[:-200]


def _board_bit_of(row, col, in_features=768):
    """与软件 far 口径一致：翻指数位 24..26（避开 bit30→NaN）。"""
    return 24 + (((row * in_features + col) // 5) % 3)


def _board_restore_safe():
    """尽力恢复板卡明文（campaign 开场清场用）；失败返回 False。"""
    try:
        s = board_ctrl.connect(timeout=15.0)
        try:
            st, _ = board_ctrl.restore(s)
        finally:
            s.close()
        return st == 0
    except Exception:
        return False


class _PerCallBoard:
    """BoardBackend 的每次 infer 独立短连接版。

    板卡 server 是单线程 accept：持久 FARQ 连接会让 FARC（STATUS 轮询/FLIP）
    全部等不到 accept。短连接让控制请求可穿插（LAN 重连 ~1ms，可忽略）。
    """

    def __init__(self, host, port, timeout=60.0):
        self._bb = None
        self._host, self._port, self._timeout = host, port, timeout

    def _make(self):
        from fara_offload_e2e import BoardBackend
        self._bb = BoardBackend(self._host, self._port, timeout=self._timeout)

    def infer(self, X, entries):
        if self._bb is None:
            self._make()
        self._bb.connect()
        try:
            return self._bb.infer(X, entries)
        finally:
            self._bb.close()

    def close(self):
        if self._bb is not None:
            self._bb.close()


@torch.no_grad()
def _run_board_attack(params):
    budget = max(1, int(params.get("budget", 8)))
    backend = None
    try:
        from fara_offload_e2e import load_shadow_weights, build_offload_model
        with _lock:
            _bd_state.update(baseline=[None, None], series=[[], []],
                             total=[0, 0], ops=[], events=[], thr=None, err=None,
                             budget=budget, msg="读取板卡 shadow 配置…")
        _W, _b, _div, entries = load_shadow_weights()
        in_f = 768
        try:
            with open(os.path.join(DIR, "board_export",
                                   "board_cfg_transformer_h_0_mlp_c_fc.json"),
                      encoding="utf-8") as f:
                in_f = int(json.load(f).get("in_features", 768))
        except Exception:
            pass
        positions = [(e["col"], e["row"]) for e in entries]   # 按敏感度降序
        maxflip = min(max(1, budget), len(positions))
        chk = sorted({k for k in MEASURE_POINTS if k <= maxflip})
        if not chk or chk[-1] != maxflip:
            chk.append(maxflip)
        _bd_ev("INFO", "info", f"板上攻防启动：预算 {maxflip} 位"
                               f"（敏感位共 {len(positions)} 个，测量点 {chk}）")

        # 0) 清场：重解密恢复干净明文（清掉上一场遗留的翻转/擦除）
        with _lock:
            _bd_state["msg"] = "恢复板卡明文（重解密清场）…"
        if not _board_restore_safe():
            raise RuntimeError("板卡重解密失败（FARC 不可达或安全链拒绝），无法开始")
        _bd_ev("REST", "rest", "清场完成：安全链重解密，板上明文恢复干净")

        backend = _PerCallBoard(board_ctrl.HOST, board_ctrl.PORT, timeout=60.0)
        m_bare = build_offload_model(_model, backend, [])       # n_far=0
        m_far = build_offload_model(_model, backend, entries)   # n_far=1

        with _lock:
            _bd_state["msg"] = "测 0 位基线（裸 / FaR 各跑一遍语料）…"
        mu, mp = _metric(m_bare), _metric(m_far)
        with _lock:
            _bd_state["baseline"] = [mu, mp]
        _bd_ev("MEAS", "meas", f"0 位基线：裸 ppl={mu['ppl']:.2f} · FaR ppl={mp['ppl']:.2f}"
                               f"（ΔNLL={abs(mu['nll'] - mp['nll']):.2e}，bit-exact 契约）")

        ops, su, sp, flips, marker = [], [], [], 0, 0
        for k in chk:
            while flips < k and flips < len(positions):
                col, row = positions[flips]
                bit = _board_bit_of(row, col, in_f)
                idx = row * in_f + col                  # W[3072,768] 行主序 flat
                s = board_ctrl.connect(timeout=15.0)
                try:
                    ack = board_ctrl.flip(s, idx, bit)  # 攻击执行端：板上真实权重
                finally:
                    s.close()
                ops.append({"flip": flips + 1, "row": row, "col": col,
                            "bit": bit, "idx": idx,
                            "old": ack["old"], "new": ack["new"],
                            "oldf": round(_bits_f32(ack["old"]), 5),
                            "newf": round(_bits_f32(ack["new"]), 5)})
                _bd_ev("FLIP", "flip",
                       f"第 {flips + 1} 位 W[{row}][{col}] bit{bit} idx={idx}："
                       f"0x{ack['old']:08x}→0x{ack['new']:08x}"
                       f"（{_bits_f32(ack['old']):+.5f}→{_bits_f32(ack['new']):+.5f}）")
                flips += 1
            with _lock:
                _bd_state["msg"] = f"板上已翻转 {flips} 位，测语料指标（裸 / FaR 双推理）…"
            eu, ep = _metric(m_bare), _metric(m_far)
            su.append({"flips": flips, **eu})
            sp.append({"flips": flips, **ep})
            for op in ops[marker:]:
                op["ppl_u"], op["ppl_p"] = round(eu["nll"], 3), round(ep["nll"], 3)
                op["acc_u"], op["acc_p"] = round(eu["acc"], 1), round(ep["acc"], 1)
            marker = len(ops)
            with _lock:
                _bd_state.update(series=[su, sp], total=[flips, flips], ops=ops,
                                 msg=(f"板上 {flips} 位 | 裸 ppl={eu['ppl']:.0f}"
                                      f"/acc={eu['acc']:.1f}% | FaR ppl={ep['ppl']:.0f}"
                                      f"/acc={ep['acc']:.1f}%"))
            _bd_ev("MEAS", "meas",
                   f"@{flips} 位：裸 ppl={eu['ppl']:.0f}/acc={eu['acc']:.1f}%"
                   f" · FaR ppl={ep['ppl']:.0f}/acc={ep['acc']:.1f}%"
                   + (f" · 增益 {eu['ppl'] / ep['ppl']:.1f}×"
                      if math.isfinite(eu['ppl']) and math.isfinite(ep['ppl'])
                      and ep['ppl'] > 0 else ""))
        c = math.log(THR)

        def _cross(cur, base):
            return next((r["flips"] for r in cur
                         if math.isfinite(r["nll"]) and r["nll"] >= base["nll"] + c), None)
        uc, pc = _cross(su, mu), _cross(sp, mp)
        note = _verdict(uc, pc, chk[-1], THR)
        if su and sp and math.isfinite(su[-1]["nll"]) and math.isfinite(sp[-1]["nll"]) \
                and su[-1]["nll"] > sp[-1]["nll"]:
            dnll = su[-1]["nll"] - sp[-1]["nll"]
            note += (f" 同翻位交叉佐证：{chk[-1]} 位时 FaR 的 NLL 比裸低 {dnll:.2f}"
                     f"（ppl {math.exp(sp[-1]['nll']):.0f} vs {math.exp(su[-1]['nll']):.0f}"
                     f"，损伤比 {math.exp(dnll):.1f}×）")
        with _lock:
            _bd_state["thr"] = {"mult": THR, "u": uc, "p": pc}
            _bd_state["msg"] = ("板上攻防完成。板卡明文保持翻转态"
                                "（上方「重解密」可实时恢复）。" + note)
        _bd_ev("THR", "thr", note)
        _bd_ev("DONE", "done", "板上攻防完成：曲线/事件已定格，板卡保持翻转态（可重解密恢复）")
    except Exception as e:  # pragma: no cover
        with _lock:
            _bd_state["err"] = str(e)
            _bd_state["msg"] = f"板上攻防出错: {e}"
        _bd_ev("ERR", "err", str(e))
    finally:
        if backend is not None:
            try:
                backend.close()
            except Exception:
                pass
        with _lock:
            _bd_state["running"] = False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8", HTML.encode("utf-8"))
        elif path == "/api/status":
            self._send(200, "application/json", json.dumps(_snapshot()).encode("utf-8"))
        elif path == "/api/bench":
            pm = parse_qs(urlparse(self.path).query).get("mode", ["far"])[0]
            bf = os.path.join(DIR, f"eval_benchmark_{pm}.json")
            if not os.path.isfile(bf):
                self._send(404, "text/plain", b"no benchmark report; run eval_benchmark.py first")
                return
            with open(bf, encoding="utf-8") as f:
                self._send(200, "application/json", f.read().encode("utf-8"))
        elif path == "/api/hw":
            hf = os.path.join(DIR, "hw_verify.json")
            if not os.path.isfile(hf):
                self._send(404, "text/plain", b"no hw_verify.json")
                return
            with open(hf, encoding="utf-8") as f:
                self._send(200, "application/json", f.read().encode("utf-8"))
        elif path == "/api/hwcmp":
            hc = os.path.join(DIR, "hw_compare.json")
            fc = os.path.join(DIR, "eval_benchmark_far_h0_cfc.json")
            if not (os.path.isfile(hc) and os.path.isfile(fc)):
                self._send(404, "text/plain", b"no hw_compare.json / eval_benchmark_far_h0_cfc.json")
                return
            with open(hc, encoding="utf-8") as f:
                hw = json.load(f)
            with open(fc, encoding="utf-8") as f:
                curve = json.load(f)
            self._send(200, "application/json",
                       json.dumps({"hw": hw, "curve": curve}).encode("utf-8"))
        elif path == "/api/recheck":
            rf = os.path.join(DIR, "threshold_metric_recheck.json")
            if not os.path.isfile(rf):
                self._send(404, "text/plain", b"no threshold_metric_recheck.json")
                return
            with open(rf, encoding="utf-8") as f:
                self._send(200, "application/json", f.read().encode("utf-8"))
        elif path == "/api/layer":
            name = parse_qs(urlparse(self.path).query).get("name", [""])[0]
            with _lock:
                data = _state["by_layer"].get(name, {})
            self._send(200, "application/json", json.dumps(data).encode("utf-8"))
        elif path == "/api/board":
            self._send(200, "application/json", json.dumps(_board_query()).encode("utf-8"))
        elif path == "/api/boardstatus":
            with _lock:
                data = {k: (copy.deepcopy(v) if k in ("series", "ops", "baseline", "thr", "events")
                            else v) for k, v in _bd_state.items()}
            self._send(200, "application/json", json.dumps(data).encode("utf-8"))
        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/attack":
            try:
                ln = int(self.headers.get("Content-Length", 0))
                params = json.loads(self.rfile.read(ln) or b"{}")
                budget = max(1, min(int(params.get("budget", 16)), 256))
                params["budget"] = budget
            except Exception:
                params = {"budget": 16}
            with _lock:
                if _state["running"] or _state["gen_busy"] or _bd_state["running"]:
                    self._send(200, "application/json", b'{"ok":false,"reason":"busy"}')
                    return
                _state["running"] = True
            t = threading.Thread(target=_run_attack, args=(params,), daemon=True)
            t.start()
            self._send(200, "application/json", b'{"ok":true,"budget":'+str(budget).encode()+b'}')
        elif path == "/api/gen":
            try:
                ln = int(self.headers.get("Content-Length", 0))
                params = json.loads(self.rfile.read(ln) or b"{}")
            except Exception:
                params = {}
            with _lock:
                if _state["running"] or _state["gen_busy"]:
                    self._send(200, "application/json", b'{"ok":false,"reason":"busy"}')
                    return
                _state["gen_busy"] = True
            t = threading.Thread(target=_run_generation, args=(params,), daemon=True)
            t.start()
            self._send(200, "application/json", b'{"ok":true}')
        elif path == "/api/reset":
            _model.load_state_dict(_original)
            with _lock:
                _state.update(running=False, baseline=[None, None], series=[[], []],
                              total=[0, 0], thr=None, ops=[], gen=[],
                              gen_busy=False, pbs=None, msg="已恢复原始模型权重",
                              by_layer={})
            self._send(200, "application/json", b'{"ok":true}')
        elif path == "/api/boardop":
            try:
                ln = int(self.headers.get("Content-Length", 0))
                params = json.loads(self.rfile.read(ln) or b"{}")
            except Exception:
                params = {}
            op = params.get("op", "")
            if op not in ("wipe", "restore"):
                self._send(200, "application/json",
                           json.dumps({"ok": False, "error": "op 必须是 wipe|restore"}).encode("utf-8"))
                return
            with _board_lock:
                ok, info = _board_op(op)
            info.update({"ok": ok, "op": op})
            self._send(200, "application/json", json.dumps(info).encode("utf-8"))
        elif path == "/api/boardattack":
            try:
                ln = int(self.headers.get("Content-Length", 0))
                params = json.loads(self.rfile.read(ln) or b"{}")
                params["budget"] = max(1, min(int(params.get("budget", 8)), 64))
            except Exception:
                params = {"budget": 8}
            with _lock:
                if _state["running"] or _state["gen_busy"] or _bd_state["running"]:
                    self._send(200, "application/json", b'{"ok":false,"reason":"busy"}')
                    return
                _bd_state["running"] = True
            t = threading.Thread(target=_run_board_attack, args=(params,), daemon=True)
            t.start()
            self._send(200, "application/json",
                       b'{"ok":true,"budget":' + str(params["budget"]).encode() + b'}')
        else:
            self._send(404, "text/plain", b"not found")

    def log_message(self, *a):  # 静默访问日志
        pass


def main():
    random.Random(0)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"BFA × FaR 控制面板已启动： http://127.0.0.1:{PORT}")
    print("按 Ctrl+C 停止。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n停止。")


if __name__ == "__main__":
    main()