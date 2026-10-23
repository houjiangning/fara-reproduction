"""离线严格评测器 —— 按论文级评测规范量化 BFA 攻击 / FaR 防护。

规范落地（对应需求清单）：
  1. 固定评测语料  内置英文(硬件安全/端侧LLM/技术通用) + 中文(技术文档)，
                   流程内固定不更换；也支持 --corpus-file 替换/增补。
  2. 语料规模      若干独立文本段，抽样单位 = 文档。若全部选中实际 token
                   数仍不足 10 万，会**如实报告**，绝不注水。（本机无法联通
                   WikiText-2，故以内置语料替代；可后补 --corpus-file。）
  3. 滑动窗口      512 token 窗口、stride 256 滑动切分；长文本分段计算后
                   按 token 数加权平均（总NLL/总token数 → exp 得 PPL）。
  4. 多次重复      因 PPL/NLL/Top-1/KL 为 teacher-forcing 确定性指标，换随机
                   种子假报±std 无意义；改为**语料 bootstrap 重采样**（有放回
                   抽 boot 组文档子集），报告 PPL 均值±标准差，反映换样本集的真实稳健性。
  5. 报告基线      先用未翻转模型测基线 PPL 作统一参照。

附加指标（固定语料子集上、随机种子无关、纵向对比）：
  · Top-1 token 一致率(% ) + "第几个 token 开始崩"（首个不一致窗口位置）
  · 预测分布 KL 散度（候选||参考）
  · 逐层余弦相似度（13 层：embed + 12 block），从哪层开始明显偏离 → 定位翻转层

用法：
  python eval_benchmark.py --mode attack --budget 16 --lang english
  python eval_benchmark.py --mode far --layer transformer.h.2.mlp.c_proj --n 16 --div 2 --lang english
  python eval_benchmark.py --mode attack --boot 5 --frac 0.7 --corpus-file my.txt

输出：屏幕汇总表 + eval_benchmark_<mode>.csv/.json（可被 attack_dashboard 加载展示）。
"""
import argparse
import copy
import csv
import json
import math
import os
import random
import statistics

import torch
import torch.nn.functional as F

from eval_perplexity import load
from bfa_attack import compute_gradients, build_plan, flip_bit
from far_defense import build_protected, _flip_entry
from model_profile import default_layer, layer_count

DIR = os.path.dirname(os.path.abspath(__file__))

MAX_LEN = 512     # 滑动窗口宽（token，GPT-2 上下文 1024 内安全）
STRIDE = 256      # 滑动步长
MEASURE = (1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64)   # 逐档采样点

# ------------------------------------------------------------------ 内建语料
# 说明：当前演示引擎为 GPT-2（纯英文），对中文无语言能力，中文段 PPL 会失真，
# 因此默认 --lang english；中文段保留供 --lang all/chinese 作结构展示并提示局限。

ENGLISH_CORPUS = [
    "Field programmable gate arrays, called FPGAs, offer hardware that can be "
    "reconfigured for different tasks after fabrication. They are widely used to "
    "accelerate deep neural networks at the edge because they balance performance "
    "and energy efficiency better than general purpose processors.",
    "Deploying large language models on embedded devices is becoming more common. "
    "However, protecting these models from hardware attacks is important, because "
    "a single flipped bit in the model weights can cause the system to produce "
    "incorrect or even harmful output.",
    "Bit flip attacks target the bits of stored neural network weights. An adversary "
    "with limited knowledge can still corrupt a model by locating the most sensitive "
    "weight positions through gradient information and toggling a few critical bits.",
    "Secure machine learning accelerators often store model weights in on chip memory. "
    "If that memory is vulnerable to fault injection, an attacker can alter the "
    "weights during inference and change the final predictions of a critical system.",
    "The performance of a language model is measured by how well it predicts the next "
    "token in a sequence. Perplexity is the exponential of the average negative log "
    "likelihood, so a lower value means the model is less surprised by real text.",
    "Hardware security primitives such as physically unclonable functions, called "
    "PUFs, exploit manufacturing variations to create unique device fingerprints. "
    "They are useful for secret key generation and device authentication at the edge.",
    "Dynamic reconfiguration lets an FPGA swap one region of logic while the rest "
    "keeps running. This is valuable for swapping between several protection levels "
    "of a secure inference core without stopping the whole system.",
    "A secure boot process verifies the integrity of the firmware and model before "
    "execution. If the hash check fails, the device refuses to run, preventing "
    "tampered weights from being loaded into the accelerator.",
    "An end to end design must consider both algorithmic vulnerabilities and physical "
    "attacks. Software fixes alone are rarely enough, so security logic is moved into "
    "the hardware data path to enforce stronger guarantees.",
    "The transformer architecture stacks attention and feed forward blocks. The "
    "feed forward layer often uses a gated activation, and its projection layers are "
    "highly sensitive because a small weight perturbation propagates through the "
    "residual stream to every subsequent token.",
    "Gradient guided bit flip attacks compute the score of each weight element as the "
    "product of its magnitude and its gradient. High scoring elements are flipped "
    "first, because they cause the largest change in the network output.",
    "Defenses against weight corruption include redundancy and sensitivity dilution. "
    "The goal is to make many bits share the responsibility, so no single flip can "
    "destroy the function of the model.",
    "Evaluation should use a fixed and representative corpus, and report a clean "
    "baseline before starting the attack. Every later measurement is compared "
    "against that baseline to show the degradation introduced by flipped bits.",
    "Sliding window evaluation splits long documents into overlapping windows of a "
    "fixed length. The average loss is weighted by the number of tokens, which is "
    "more robust than evaluating a short hand picked sentence.",
    "Token accuracy compares the most likely token predicted before and after an "
    "attack at every position. It reveals exactly which position first starts to "
    "produce a wrong prediction, which is more informative than a single aggregate "
    "score.",
    "The Kullback Leibler divergence measures how far the output probability "
    "distribution shifts after an attack. A larger divergence means the model has "
    "drifted further from its original careful behavior.",
    "Layer wise cosine similarity compares the activation of every transformer layer "
    "before and after corruption. The first layer where similarity drops points to "
    "where the flipped bit actually entered the computation.",
    "Hardware accelerators for language models must balance security overhead with "
    "speed. Monitoring blocks run in parallel with inference and switch the "
    "protection level when the input is judged to be more dangerous.",
    "Character injection attacks try to feed adversarial text that bypasses filters. "
    "A secure decoder validates input characters before embedding to stop malicious "
    "instructions from reaching the model.",
    "Trusted execution environments isolate sensitive computation from the operating "
    "system. This reduces the attack surface by keeping private keys and model "
    "weights inside a protected hardware boundary.",
    "The residual connections in a transformer let gradients flow easily during "
    "training, but they also spread the effect of a single weight error to every "
    "later token. This is why flipping one exponent bit can break fluency.",
    "End to end threat modeling ranks attackers by capability and motivation. A "
    "remote software attacker differs from a local adversary who can access the "
    "physical memory bus of a device.",
    "Energy efficient inference is critical for battery powered sensors. Quantized "
    "and pruned models run faster, but smaller numeric formats make the weights "
    "more sensitive to bit corruption.",
    "A secure inference engine should detect unexpected output patterns and reset "
    "its weight state. Recovery is triggered by a hardware state machine that "
    "monitors integrity signals during execution.",
    "Machine learning models are only as trustworthy as the data they are trained "
    "on and the hardware that runs them. Both training data poisoning and weight "
    "corruption must be handled by a layered defense.",
    "The margin of a fault defines how many flipped bits a model tolerates before "
    "meaningful degradation. A stronger defense increases that margin by reducing "
    "the sensitivity of each individual weight.",
    "Redundancy in hardware can use two or more copies of a computation. The outputs "
    "are compared by a voter, and a mismatch flags a possible fault before it "
    "reaches the application.",
    "Secure provisioning writes keys and certificates into hardware storage during "
    "manufacturing. Later requests are authenticated using these secrets, which "
    "never leave the secure enclave in plain text.",
]

CHINESE_CORPUS = [
    "现场可编程门阵列，简称FPGA，可以在制造完成后根据任务重新配置硬件逻辑，"
    "被广泛用于边缘端加速深度神经网络，在性能和功耗之间取得较好的折中。",
    "在对大语言模型的硬件攻击中，攻击者可能通过翻转存储权重中的若干比特来破坏模型，"
    "导致系统输出错误甚至有害的内容，因此需要硬件级的防护机制。",
    "比特翻转攻击通过梯度信息定位敏感权重，只需翻转少量关键比特即可显著改变模型的预测结果，"
    "这对安全关键系统构成直接威胁。",
    "安全推理加速器通常在片内存储模型权重，若该存储易受故障注入攻击，"
    "攻击者便可在推理期间篡改权重并改变最终输出。",
    "困惑度是负对数似然的指数，用来衡量语言模型对真实文本的惊讶程度，"
    "数值越低代表模型对给定语料越流畅。",
    "硬件安全原语物理不可克隆函数利用制造差异生成唯一指纹，常用于边缘设备的密钥生成与身份认证。",
    "动态可重构允许FPGA在不停止整体运行的情况下切换某区域的逻辑，"
    "适合在安全推理核心的不同防护等级之间动态切换。",
    "安全启动在运行前校验固件与模型的完整性，校验失败则拒绝加载，"
    "防止被篡改的权重进入加速器。",
    "端到端设计必须同时考虑算法漏洞与物理攻击，单纯依赖软件修复往往不够，"
    "需要将安全逻辑内嵌到硬件数据通路中以提供更强的保障。",
    "变压器架构堆叠注意力与前馈模块，其投射层对权重扰动高度敏感，"
    "因为单个权重扰动会沿残差流传播到后续所有令牌。",
]

# ------------------------------------------------------------------ 语料工具


def _tokenize_doc(tok, text):
    return tok(text, add_special_tokens=True)["input_ids"]


def _sliding_windows(ids, max_len=MAX_LEN, stride=STRIDE):
    """512 窗口、stride 256 滑动切分；返回若干 ≤max_len 的 id 序列。"""
    if len(ids) <= max_len + 1:
        return [ids]
    wins, start = [], 0
    while True:
        end = min(start + max_len, len(ids) - 1)
        wins.append(ids[start:end + 1])
        if end == len(ids) - 1:
            break
        start += stride
    return wins


def build_corpus(tok, lang="english", corpus_file=None):
    docs, tags, extra = [], [], []
    if corpus_file and os.path.isfile(corpus_file):
        with open(corpus_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if len(line) > 40:
                    extra.append(line)
        for t in extra:
            ids = _tokenize_doc(tok, t)
            if len(ids) > 2:
                docs.append(ids); tags.append(lang if lang in ("chinese",) else "english")
    for t in ENGLISH_CORPUS:
        if lang in ("english", "all"):
            ids = _tokenize_doc(tok, t)
            if len(ids) > 2:
                docs.append(ids); tags.append("english")
    for t in CHINESE_CORPUS:
        if lang in ("chinese", "all"):
            ids = _tokenize_doc(tok, t)
            if len(ids) > 2:
                docs.append(ids); tags.append("chinese")
    if lang not in ("english", "chinese", "all"):
        raise SystemExit(f"未知语料 {lang}（可选 english/chinese/all）")
    return docs, tags


def corpus_stats(tok, docs, tags):
    toks = sum(len(d) for d in docs)
    return toks, sum(1 for t in tags if t == "english"), sum(1 for t in tags if t == "chinese")


# ------------------------------------------------------------------ 评测核心


@torch.no_grad()
def window_ppl(model, tok, windows, batch=8):
    """滑动窗口批式前向，按 token 数加权平均 NLL → PPL。

    重叠区域被重复计入，与 HF 官方滑动窗口 PPL 口径一致，即"按 token 加权平均"。
    """
    total_nll, n = 0.0, 0
    for s in range(0, len(windows), batch):
        blob = windows[s:s + batch]
        mx = max(len(w) for w in blob)
        pad = torch.full((len(blob), mx), tok.eos_token_id, dtype=torch.long)
        mask = torch.zeros_like(pad)
        for i, w in enumerate(blob):
            pad[i, :len(w)] = torch.tensor(w)
            mask[i, :len(w)] = 1
        logits = model(pad, attention_mask=mask).logits
        sh = logits[:, :-1].contiguous()
        lab = pad[:, 1:].contiguous()
        m = mask[:, 1:].contiguous()
        loss = F.cross_entropy(sh.reshape(-1, sh.size(-1)), lab.reshape(-1),
                               reduction="none").reshape(pad.size(0), -1)
        total_nll += (loss * m).sum().item()
        n += int(m.sum().item())
    return total_nll / max(n, 1), n


@torch.no_grad()
def make_subsets(windows_by_doc, boot=3, frac=0.7):
    """预生成 boot 组文档子集（每组按 frac 比例抽样）。

    返回 [[文档窗口, ...], ...]。运行期所有模型共用同一组子集，
    使裸/FaR 基线与逐档指标处于**同一语料抽面**，可严格横向对比。
    """
    N = len(windows_by_doc)
    k = max(1, int(round(N * frac)))
    return [[random.choice(windows_by_doc) for _ in range(k)] for _ in range(boot)]


@torch.no_grad()
def subset_ppl(model, tok, subsets, batch=8):
    """在预生成子集上各算 PPL，返回 (mean_nll, std_nll, nll_list)。"""
    vals = []
    for ws in subsets:
        wins = [w for wl in ws for w in wl]
        nll, _ = window_ppl(model, tok, wins, batch)
        vals.append(nll)
    mean = statistics.mean(vals)
    std = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return mean, std, vals


@torch.no_grad()
def _forward_full(model, ids, with_hidden=False):
    out = model(torch.tensor([ids]), output_hidden_states=with_hidden)
    return out.logits, (out.hidden_states if with_hidden else None)


def subset_metrics(clean, attacked, tok, subset_ids, want_cos=True, n_layers=13):
    """固定语料子集上对比 clean 与 attacked：
    Top-1 一致率 + 平均一致前缀长 + KL + 逐层余弦(n_layers 层含 embed)。

    平均一致前缀长_p：对每个窗口，从开头数到第一个 argmax 与 clean 不同为止，
    求各窗口该长度的均值 —— 语义是"攻击后平均前多少 token 仍与干净模型一致，
    之后开始崩"。比单个"首个不一致位置"稳健，因为它常被任意一个位置噪声置 0。
    """
    total = hit = 0
    prefix_sum, prefix_n = 0, 0
    kls, nk = 0.0, 0
    cos_sum = [0.0] * n_layers
    cos_n = [0] * n_layers
    for ids in subset_ids:
        cl, ch = _forward_full(clean, ids, want_cos)
        al, ah = _forward_full(attacked, ids, want_cos)
        ca = cl[:, :-1].argmax(dim=-1)
        aa = al[:, :-1].argmax(dim=-1)
        eq = (ca == aa).reshape(-1).tolist()
        hit += sum(eq)
        total += len(eq)
        run = 0
        for v in eq:
            if v:
                run += 1
            else:
                break
        prefix_sum += run
        prefix_n += 1
        cla = cl[:, :-1].float().log_softmax(dim=-1)
        ala = al[:, :-1].float().log_softmax(dim=-1)
        cand = ala.exp()
        kls += float((cand * (ala - cla)).sum().item())
        nk += cand.size(1)
        if want_cos:
            L = ala.size(1)
            for li in range(min(len(ch), len(ah), n_layers)):
                c = ch[li][:, :L].reshape(-1, ch[li].size(-1)).float()
                a = ah[li][:, :L].reshape(-1, ah[li].size(-1)).float()
                cos_sum[li] += float(F.cosine_similarity(c, a, dim=1).mean().item())
                cos_n[li] += 1
    return {
        "top1": 100.0 * hit / max(total, 1),
        "prefix": (prefix_sum / prefix_n) if prefix_n else 0.0,
        "kl": kls / max(nk, 1),
        "layer_cos": [round(s / max(cn, 1), 5) for s, cn in zip(cos_sum, cos_n)] if want_cos
                     else [None] * n_layers,
    }


# ------------------------------------------------------------------ 攻击计划


def _far_bit(cfg, row, col):
    return 24 + (((row * cfg["in_features"] + col) // 5) % 3)


def make_plan(mode, model, tok, layer, n, div, budget):
    """构造翻转计划与受测模型原型。返回 (subjects, plan, cfg, budget)。
    subjects = [(名称, 模型副本, FaRcfg或None)]；裸=干净副本 / FaR=受护副本。"""
    if mode == "far":
        prot, cfg = build_protected(model, tok, layer, n, div)
        positions = [(e["col"], e["row"]) for e in cfg["far"]]
        budget = min(budget, len(positions))
        plan = [(_far_bit(cfg, row, col), row, col) for (col, row) in positions[:budget]]
        return [("裸", copy.deepcopy(model), None),
                ("FaR", prot, cfg)], plan, cfg, budget
    _, grads = compute_gradients(model, tok)
    plan0 = build_plan(model, grads, budget)
    plan = [(bit, name, idx) for (name, idx, bit) in plan0]
    return [("裸", copy.deepcopy(model), None)], plan, None, len(plan)


# ------------------------------------------------------------------ 主流程


def run_benchmark(args):
    random.seed(0)          # 全局 seed，保证 bootstrap 子集跨运行可复现
    torch.manual_seed(0)

    model, tok = load()
    model.eval()
    clean = copy.deepcopy(model).eval()
    layer = args.layer or default_layer()      # 未指定敏感层时，按模型档案取默认层
    NLAYERS = layer_count(clean)               # 逐层余弦层数 = num_hidden_layers+1

    docs, tags = build_corpus(tok, args.lang, args.corpus_file)
    if not docs:
        raise SystemExit("语料为空：请检查 --lang 或 --corpus-file")
    toks, n_en, n_zh = corpus_stats(tok, docs, tags)
    windows_by_doc = [_sliding_windows(d, args.max_len, args.stride) for d in docs]
    all_wins = [w for ws in windows_by_doc for w in ws]

    # 固定 bootstrap 子集(所有模型共用同一抽面)
    subsets = make_subsets(windows_by_doc, args.boot, args.frac)

    # 攻击计划 + 受测模型原型(裸=干净副本 / FaR=受护副本)
    model.load_state_dict({k: v.detach().clone() for k, v in clean.state_dict().items()})
    subjects, plan, cfg, budget = make_plan(
        args.mode, model, tok, layer, args.n, args.div, args.budget)
    subj_names = [s[0] for s in subjects]
    ref = clean  # Top-1/KL/余弦的参照(未攻击)

    # 固定语料子集(用于 Top-1/KL/逐层余弦，控制 CPU 成本)
    subset_ids = all_wins[:12] or all_wins[:2] or [d for d in docs[:1]]

    print("=" * 78)
    print("离线严格评测（论文级规范）— 固定语料 · 512窗口 · bootstrap ± std")
    print("=" * 78)
    print(f"语料：文档 {len(docs)} 段（英文 {n_en} / 中文 {n_zh}）; "
          f"段落 token {toks:,}；滑动后窗口 {len(all_wins):,} 个")
    if toks < 100_000:
        print(f"  [提示] 实际 token {toks:,} < 10 万 —— 本机无法联通 WikiText-2，"
              f"以内置语料替代；可用 --corpus-file 扩充后重跑。")
    if args.lang in ("chinese", "all") and n_zh > 0:
        print("  [提示] 默认引擎 GPT-2(纯英文) 对中文无语言能力，中文段 PPL 会失真；"
              "若换成 Qwen2.5-3B 等中文友好模型(FAR_MODEL=qwen2.5-3b)则中文段有效，"
              "正式结论仍建议与所选模型的语言能力匹配的 --lang。")
    print("-" * 78)

    # 基线（未翻转，用各主题自身模型；共用同一抽面）
    base_nll, base_ppl = {}, {}
    for sname, m, _ in subjects:
        mean, std, _ = subset_ppl(m, tok, subsets, args.batch)
        base_nll[sname], base_ppl[sname] = mean, math.exp(mean)
        print(f"  基线[{sname}] PPL = {base_ppl[sname]:.3f} ± {std:.4f}  "
              f"(NLL={mean:.4f}, boot={args.boot}, frac={args.frac})")
    print("=" * 78)

    chk = sorted({k for k in MEASURE if k <= budget})
    if not chk or chk[-1] != budget:
        chk.append(budget)

    print(" " * 6 + " | " + " | ".join(f"{s}: PPL(u±s)  top1%  前缀@  KL" for s in subj_names))
    print("-" * 78)

    curves = {s: {"nll": [], "std": [], "top1": [], "prefix": [], "kl": [], "cos": []}
              for s in subj_names}
    flipped = 0
    for k in chk:
        while flipped < k and flipped < len(plan):
            item = plan[flipped]
            if args.mode == "far":
                for sname, m, _ in subjects:
                    _flip_entry(m, layer, item[1], item[2], item[0])
            else:
                flip_bit(subjects[0][1], item[1], item[2], item[0])
            flipped += 1
        for sname, m, _ in subjects:
            mean, std, _ = subset_ppl(m, tok, subsets, args.batch)
            sm = subset_metrics(ref, m, tok, subset_ids, n_layers=NLAYERS)
            curves[sname]["nll"].append(mean)
            curves[sname]["std"].append(std)
            curves[sname]["top1"].append(sm["top1"])
            curves[sname]["prefix"].append(sm["prefix"])
            curves[sname]["kl"].append(sm["kl"])
            curves[sname]["cos"].append(sm["layer_cos"])
        cells = []
        for s in subj_names:
            cells.append(f"{math.exp(curves[s]['nll'][-1]):8.2f}±{curves[s]['std'][-1]:.2f} "
                         f"{curves[s]['top1'][-1]:5.1f} {curves[s]['prefix'][-1]:6.1f} "
                         f"{curves[s]['kl'][-1]:.4f}")
        print(f"{flipped:5d} | " + " | ".join(cells))
    print("-" * 78)

    for s in subj_names:
        ppls = [math.exp(x) for x in curves[s]["nll"]]
        cross = next((fl for fl, pm in zip(chk, ppls)
                      if math.isfinite(pm) and pm >= base_ppl[s] * args.threshold), None)
        print(f"  [{s}] 达到阈值(基线×{args.threshold})需翻位 = "
              f"{cross if cross is not None else '≥' + str(chk[-1])}")

    # 落盘
    json_path = os.path.join(DIR, f"eval_benchmark_{args.mode}.json")
    csv_path = os.path.join(DIR, f"eval_benchmark_{args.mode}.csv")
    out = {
        "mode": args.mode, "layer": cfg["layer"] if cfg else layer,
        "n": args.n, "div": args.div, "threshold": args.threshold, "lang": args.lang,
        "tokens": toks, "docs": len(docs), "windows": len(all_wins),
        "baseline": {s: {"ppl": round(base_ppl[s], 4), "nll": round(base_nll[s], 4)}
                     for s in subj_names},
        "subjects": subj_names, "flips": chk,
    }
    for s in subj_names:
        out[f"curve_{s}"] = {
            "flips": chk,
            "ppl": [round(math.exp(x), 3) for x in curves[s]["nll"]],
            "ppl_std": [round(x, 4) for x in curves[s]["std"]],
            "nll": [round(x, 4) for x in curves[s]["nll"]],
            "top1": [round(x, 2) for x in curves[s]["top1"]],
            "prefix": [round(x, 1) for x in curves[s]["prefix"]],
            "kl": [round(x, 5) for x in curves[s]["kl"]],
            "layer_cos": [list(map(float, x)) for x in curves[s]["cos"]],
        }
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["flips"] + [f"{s}::{x}" for s in subj_names
                                for x in ("ppl", "std", "top1%", "prefix@", "kl")])
        for i in range(len(chk)):
            row = [chk[i]]
            for s in subj_names:
                row += [round(math.exp(curves[s]["nll"][i]), 3),
                        round(curves[s]["std"][i], 4),
                        round(curves[s]["top1"][i], 2),
                        round(curves[s]["prefix"][i], 1),
                        round(curves[s]["kl"][i], 5)]
            w.writerow(row)
    print("=" * 78)
    print(f"[ok] CSV -> {csv_path}\n[ok] JSON -> {json_path}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="离线严格评测器（BFA × FaR）")
    ap.add_argument("--mode", choices=["attack", "far"], default="attack")
    ap.add_argument("--budget", type=int, default=16)
    ap.add_argument("--layer", default=None,
                    help="敏感层名；缺省时按模型档案取默认层"
                         "（gpt2=transformer.h.2.mlp.c_proj / qwen2.5-3b=model.layers.3.mlp.down_proj）")
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--div", type=int, default=2, choices=[2, 3])
    ap.add_argument("--lang", choices=["english", "chinese", "all"], default="english")
    ap.add_argument("--corpus-file", default=None, help="额外语料文件(.txt, 每行一段)")
    ap.add_argument("--boot", type=int, default=3, help="bootstrap 重采样组数")
    ap.add_argument("--frac", type=float, default=0.7, help="每组抽样文档比例")
    ap.add_argument("--max-len", type=int, default=MAX_LEN)
    ap.add_argument("--stride", type=int, default=STRIDE)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--threshold", type=float, default=4.0)
    args = ap.parse_args()
    raise SystemExit(run_benchmark(args) or 0)


if __name__ == "__main__":
    main()