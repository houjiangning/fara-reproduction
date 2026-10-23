"""FaR / BFA 分析命令行工具（无需 Web 服务，替代 attack_dashboard 面板）。

完成与网页面板对等的功能：
  · 任务 attack —— 对裸 GPT-2 执行梯度引导 BFA：困惑度随翻转预算攀升
  · 任务 far    —— FaR 加固对比：同一批敏感位翻转，同时测「裸模型」与
                   「FaR 加固模型」两条曲线，并给『到阈值需翻位』判据

每任务输出三大件：
  · 控制台表格（ppl / NLL / 相对原模型 next-token acc）
  · PNG 图（可切换困惑度 / NLL / 准确率三条指标，含基线与阈值虚线）
  · CSV（护栏数据，便于进一步统计）

用法（在 fara-reproduction 目录）：
  python far_analysis.py attack --budget 16 --out attack.png
  python far_analysis.py far    --budget 16 --n 16 --div 2 --threshold 4 --out far.png
  python far_analysis.py far    --metric nll --no-live
  python far_analysis.py --help     # 不带子命令也会打印帮助，不会报错

运行默认会弹出**交互式动态折线图**：随翻位实时增长，按 1/2/3 切换
困惑度/NLL/准确率，q 退出；headless 环境请加 --no-live（仍可 --out 存图）。
"""
import argparse
import csv
import math
import os

import torch

from bfa_attack import (
    load, compute_gradients, build_plan, flip_bit, REFERENCE_CORPUS,
)
from far_defense import (
    build_protected, _flip_entry, corpus_nll, next_tok_acc, mean_kl,
)

DIR = os.path.dirname(os.path.abspath(__file__))
MEASURE_POINTS = (1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64)
FIELD_CN = {"ppl": "困惑度", "nll": "NLL", "acc": "acc%"}


class RefStore:
    """预存原模型对语料的参考预测（argmax + logprob），避免持有一份完整模型副本。"""

    def __init__(self, model, tok):
        self.xs, self.argmax, self.logprob = [], [], []
        with torch.no_grad():
            for text in REFERENCE_CORPUS:
                ids = tok(text, add_special_tokens=True)["input_ids"]
                if len(ids) <= 1:
                    continue
                x = torch.tensor([ids])
                lg = model(x).logits[:, :-1].float()
                self.xs.append(x)
                self.argmax.append(lg.argmax(dim=-1))
                self.logprob.append(lg.log_softmax(dim=-1))

    @torch.no_grad()
    def acc(self, model):
        hits = total = 0
        for x, rarg in zip(self.xs, self.argmax):
            cand = model(x).logits[:, :-1].argmax(dim=-1)
            hits += int((cand == rarg).sum().item())
            total += int(rarg.numel())
        return 100.0 * hits / max(total, 1)

    @torch.no_grad()
    def kl(self, model):
        kls = n = 0.0
        for x, rlog in zip(self.xs, self.logprob):
            clog = model(x).logits[:, :-1].float().log_softmax(dim=-1)
            cand = clog.exp()
            kls += float((cand * (clog - rlog)).sum().item())
            n += cand.shape[0] * cand.shape[1]
        return kls / max(n, 1)


def metric(model, tok, ref):
    nll, ppl = corpus_nll(model, tok)
    return {"ppl": ppl, "nll": nll, "acc": ref.acc(model)}


def find_sensitive_bit(weight, in_features, row, col):
    """避开 bit30（softmax 上溢 NaN），用指数位 24..26 做有限放大。"""
    return 24 + (((row * in_features + col) // 5) % 3)


def fn_or_max(v, last):
    return "≥" + str(last) if v is None else str(v)


def threshold_verdict(series_u, series_p, base_u, base_p, thr, last):
    c = math.log(thr)
    def cross(cur, base):
        return next((r["flips"] for r in cur
                     if math.isfinite(r["nll"]) and r["nll"] >= base["nll"] + c), None)
    uc, pc = cross(series_u, base_u), cross(series_p, base_p)
    if uc:
        ratio = (pc if pc else last) / max(uc, 1)
    else:
        ratio = float("inf")
    ratio_txt = "∞(预算内未达)" if not math.isfinite(ratio) else f"{ratio:.2f}×"
    line = (f"『到阈值(ppl≥基线×{thr:.0f} ⇔ NLL≥基线+{c:.3f})需翻位』"
            f"裸={fn_or_max(uc, last)}位, FaR={fn_or_max(pc, last)}位  → 比值 {ratio_txt}（论文区间 1.4–4.2×）")
    return line, {"mult": thr, "u": uc, "p": pc, "ratio": ratio_txt}


def print_table(series_u, series_p, base_u, base_p):
    """控制台表格：ppl / NLL / acc。series_p 可为空列表表示无防护侧。"""
    rows = [("#flips", "裸 ppl", "裸 NLL", "裸 acc", "FaR ppl", "FaR NLL", "FaR acc")]
    for ru, rp in zip(series_u, series_p):
        def f(o, key, nd=1):
            return "--" if o is None or not math.isfinite(o[key]) else f"{o[key]:.{nd}f}{'%' if key=='acc' else ''}"
        rows.append((str(ru["flips"]), f(ru, "ppl", 0), f(ru, "nll"), f(ru, "acc"),
                     f(rp, "ppl", 0), f(rp, "nll"), f(rp, "acc")) if rp else
                    (str(ru["flips"]), f(ru, "ppl", 0), f(ru, "nll"), f(ru, "acc"),
                     "--", "--", "--"))
    if base_u is not None:
        print("  基线  裸: ppl=%.2f  NLL=%.4f  acc=%.1f%%" % (base_u["ppl"], base_u["nll"], base_u["acc"]))
    if base_p is not None:
        print("  基线  FaR: ppl=%.2f  NLL=%.4f  acc=%.1f%%  KL=%.4f"
              % (base_p["ppl"], base_p["nll"], base_p["acc"], base_p["kl"]))
    lens = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    fmt = "  ".join("{:<%d}" % l for l in lens)
    print("-" * (sum(lens) + 3 * (len(lens) - 1)))
    for r in rows:
        print(fmt.format(*r))


def dump_csv(path, series_u, series_p):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["flips", "u_ppl", "u_nll", "u_acc", "p_ppl", "p_nll", "p_acc"])
        for ru, rp in zip(series_u, series_p):
            w.writerow([ru["flips"], ru["ppl"], ru["nll"], ru["acc"],
                        rp["ppl"], rp["nll"], rp["acc"]] if rp else
                       [ru["flips"], ru["ppl"], ru["nll"], ru["acc"], "-", "-", "-"])
    print(f"[CSV] 已写出 {path}")


def plot_series(series_u, series_p, base_u, base_p, metric, thr, last, out):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:
        print(f"[plot] matplotlib 不可用，跳过画图：{e}")
        return
    fig, ax = plt.subplots(figsize=(9, 5), dpi=110)
    field = {"ppl": "ppl", "nll": "nll", "acc": "acc"}[metric]
    ylab = {"ppl": "Perplexity", "nll": "NLL (log perplexity)", "acc": "Next-token acc (%)"}[metric]
    for pts, col, lab in ((series_u, "#e0475c", "Unprotected"),
                          (series_p, "#2fb872", "FaR-protected")):
        if pts:
            ax.plot([r["flips"] for r in pts], [r[field] for r in pts], "-o", color=col, label=lab, lw=2.2, ms=4)
    # 基线与阈值虚线
    for base, col in ((base_u, "#e0475c"), (base_p, "#2fb872")):
        if base is not None:
            b = base[field] if metric != "acc" else base["acc"]
            ax.axhline(b, color=col, ls=":", alpha=0.7)
    if metric == "ppl":
        b = base_u["ppl"] if base_u else base_p["ppl"]
        ax.axhline(b * thr, color="#f6b01c", ls="--", alpha=0.9, label=f"damage threshold {thr:.0f}x")
    elif metric == "nll" and base_u is not None:
        ax.axhline(base_u["nll"] + math.log(thr), color="#f6b01c", ls="--", alpha=0.9, label=f"damage threshold +ln{thr:.0f}")
    ax.set_xlabel("bit-flip budget")
    ax.set_ylabel(ylab)
    is_acc = metric == "acc"
    if is_acc:
        ax.invert_yaxis()
    ax.set_title("BFA on GPT-2: unprotected vs FaR-protected (" + ylab + ")")
    ax.legend(fontsize=9)
    ax.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)
    print(f"[PNG] 已写出 {out}")


DEFAULT_LAYER = "transformer.h.2.mlp.c_proj"


class LivePlot:
    """交互式动态折线图（对齐网页版的实时感）。

    边跑边实时增长两条曲线；运行中按 1/2/3 切换 困惑度/NLL/准确率，
    按 q 或 Esc 关闭。headless 下自动退回「只出图」不弹窗。
    """

    _KEY = {"1": "ppl", "2": "nll", "3": "acc"}

    def __init__(self, metric, thr, base_u=None, base_p=None, out=None):
        self.metric = metric
        self.thr = thr
        self.base_u, self.base_p = base_u, base_p
        self.out = out
        self.su, self.sp = [], []
        self.interactive = False
        import matplotlib
        for bk in ("TkAgg", "QtAgg", "Qt5Agg", "GTK3Agg", "MacOSX"):
            try:
                matplotlib.use(bk, force=True)
                break
            except Exception:
                continue
        import matplotlib.pyplot as plt
        self._plt = plt
        self._fig = self._ax = None
        try:
            self._fig, self._ax = plt.subplots(figsize=(9, 5))
            self._fig.canvas.mpl_connect("key_press_event", self._onkey)
            self._ax.legend(fontsize=9)
            self._ax.grid(alpha=0.25)
            plt.ion()
            plt.show(block=False)
            self.interactive = True
        except Exception:
            self.interactive = False     # 无 GUI：仅走保存静态图路径
            self._fig = self._ax = None

    def add(self, e, side):
        (self.su if side == "u" else self.sp).append(e)
        if self.interactive:
            self.refresh()

    def _draw_lines(self, ax, field, ylab):
        ax.plot([r["flips"] for r in self.su], [r[field] for r in self.su],
                "-o", color="#e0475c", label="Unprotected", lw=2.2, ms=4)
        ax.plot([r["flips"] for r in self.sp], [r[field] for r in self.sp],
                "-o", color="#2fb872", label="FaR-protected", lw=2.2, ms=4)
        for base, col in ((self.base_u, "#e0475c"), (self.base_p, "#2fb872")):
            if base is not None:
                b = base[field] if self.metric != "acc" else base["acc"]
                ax.axhline(b, color=col, ls=":", alpha=0.7)
        if self.metric == "ppl":
            b = (self.base_u or self.base_p)["ppl"]
            ax.axhline(b * self.thr, color="#f6b01c", ls="--", label=f"threshold {self.thr:.0f}x")
        elif self.metric == "nll" and self.base_u is not None:
            ax.axhline(self.base_u["nll"] + math.log(self.thr), color="#f6b01c",
                       ls="--", label=f"threshold +ln{self.thr:.0f}")
        ax.set_xlabel("bit-flip budget")
        ax.set_ylabel(ylab)
        ax.set_title(f"BFA: unprotected vs FaR-protected ({ylab})   [1/2/3 切指标, q 退出]")
        if self.metric == "acc":
            ax.invert_yaxis()

    def refresh(self):
        if not self.interactive:
            return
        field = {"ppl": "ppl", "nll": "nll", "acc": "acc"}[self.metric]
        ylab = {"ppl": "Perplexity", "nll": "NLL (log perplexity)", "acc": "Next-token acc (%)"}[self.metric]
        self._ax.clear()
        self._draw_lines(self._ax, field, ylab)
        self._ax.legend(fontsize=9)
        self._ax.grid(alpha=0.25)
        self._fig.canvas.draw_idle()
        self._plt.pause(0.02)

    def _onkey(self, ev):
        if ev.key in self._KEY:
            self.metric = self._KEY[ev.key]
            self.refresh()
        elif ev.key in "qQ" or ev.key == "escape":
            self._plt.close(self._fig)

    def finish(self, su=None, sp=None):
        if su is not None:
            self.su = su
        if sp is not None:
            self.sp = sp
        if not self.interactive:
            # headless：仍可用 --out 保存一张静态图
            if self.out:
                plot_series(self.su, self.sp, self.base_u, self.base_p, self.metric,
                            self.thr, (self.su[-1]["flips"] if self.su else 0), self.out)
            return
        self.refresh()
        if self.out:
            self._fig.savefig(self.out)
            print(f"[PNG] 已保存 {self.out}")
        self._plt.show()   # 阻塞，供交互查看/另存/导出


# ------------------------------------------------------------------ 两个任务


def task_attack(args):
    model, tok = load()
    model = model.eval()
    ref = RefStore(model, tok)
    base = metric(model, tok, ref)
    base["kl"] = 0.0
    thr = args.threshold

    print("任务 attack —— 梯度引导 BFA（无防护）")
    print(f"  指标: ppl / NLL / 相对原模型 next-token acc；损伤阈值 ppl≥基线×{thr:.0f}")

    live = LivePlot(args.metric, thr, base, None, args.out) if args.live else None

    _, grads = compute_gradients(model, tok)
    plan = build_plan(model, grads, args.budget)
    series_u, flipped = [], 0
    for (name, idx, bit) in plan:
        flip_bit(model, name, idx, bit)
        flipped += 1
        if flipped in MEASURE_POINTS or flipped == len(plan):
            e = {"flips": flipped, **metric(model, tok, ref)}
            series_u.append(e)
            if live:
                live.add(e, "u")
    c = math.log(thr)
    uc = next((r["flips"] for r in series_u
               if math.isfinite(r["nll"]) and r["nll"] >= base["nll"] + c), None)
    print(f"  裸模型到阈值需翻位 = {fn_or_max(uc, flipped)} 位")
    print_table(series_u, [], base, None)
    if args.out:
        dump_csv(args.out.replace(".png", ".csv"), series_u, [])
    if live is None and args.out:
        plot_series(series_u, [], base, None, args.metric, thr, flipped, args.out)
    if live:
        live.finish(series_u, [])


def task_far(args):
    model, tok = load()
    model = model.eval()
    ref = RefStore(model, tok)
    unprotected = model
    prot, cfg = build_protected(model, tok, args.layer, args.n, args.div)
    thr = args.threshold

    base_u = metric(unprotected, tok, ref)
    base_p = metric(prot, tok, ref)
    base_p["kl"] = ref.kl(prot)

    print(f"任务 far —— FaR 加固对比（层 {cfg['layer']}，n={args.n}，div={args.div}）")
    print(f"  指标: ppl / NLL / 相对原模型 next-token acc；损伤阈值 ppl≥基线×{thr:.0f}")
    print(f"  基线 裸 ppl={base_u['ppl']:.2f}  acc={base_u['acc']:.1f}%  |  "
          f"FaR ppl={base_p['ppl']:.2f}  acc={base_p['acc']:.1f}%  KL={base_p['kl']:.4f}")

    live = LivePlot(args.metric, thr, base_u, base_p, args.out) if args.live else None

    positions = [(e["col"], e["row"]) for e in cfg["far"]]
    maxflip = min(args.budget, len(positions))
    chk = sorted({k for k in MEASURE_POINTS if k <= maxflip})
    if not chk or chk[-1] != maxflip:
        chk.append(maxflip)

    series_u, series_p, flipped = [], [], 0
    in_features = cfg["in_features"]
    for k in chk:
        while flipped < k and flipped < len(positions):
            col, row = positions[flipped]
            bit = find_sensitive_bit(None, in_features, row, col)
            _flip_entry(unprotected, args.layer, row, col, bit)
            _flip_entry(prot, args.layer, row, col, bit)
            flipped += 1
        eu = {"flips": flipped, **metric(unprotected, tok, ref)}
        ep = {"flips": flipped, **metric(prot, tok, ref)}
        series_u.append(eu)
        series_p.append(ep)
        if live:
            live.add(eu, "u")
            live.add(ep, "p")

    print_table(series_u, series_p, base_u, base_p)
    verdict, thr_info = threshold_verdict(series_u, series_p, base_u, base_p, thr, maxflip)
    print(verdict)
    if args.out:
        dump_csv(args.out.replace(".png", ".csv"), series_u, series_p)
    if live is None and args.out:
        plot_series(series_u, series_p, base_u, base_p, args.metric, thr, maxflip, args.out)
    if live:
        live.finish(series_u, series_p)


def main():
    ap = argparse.ArgumentParser(
        description="FaR/BFA 命令行分析（替代网页面板，含动态折线图）\n\n"
                    "用法：\n"
                    "  python far_analysis.py attack --budget 16 --out attack.png\n"
                    "  python far_analysis.py far    --budget 16 --n 16 --div 2 --out far.png\n"
                    "  python far_analysis.py far    --metric nll --no-live\n"
                    "运行后弹出交互图：按 1/2/3 切换 困惑度/NLL/准确率，q 退出。",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="task")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--budget", type=int, default=16)
    common.add_argument("--metric", choices=["ppl", "nll", "acc"], default="ppl",
                        help="曲线使用哪个指标（运行中也可按键切换）")
    common.add_argument("--threshold", type=float, default=4.0,
                        help="到阈值判据：ppl 达基线×THRESHOLD")
    common.add_argument("--out", default=None, help="另存 PNG 路径；同名自动再写一份 CSV")
    common.add_argument("--no-live", action="store_true",
                        help="不弹交互图（headless 用）；给了 --out 仍会存静态图")
    a = sub.add_parser("attack", parents=[common],
                       help="对裸 GPT-2 执行梯度引导 BFA")
    a.set_defaults(func=task_attack)
    f = sub.add_parser("far", parents=[common],
                       help="FaR 加固对比：同一批敏感位翻转，同画裸/FaR 两条曲线")
    f.add_argument("--layer", default=DEFAULT_LAYER)
    f.add_argument("--n", type=int, default=16)
    f.add_argument("--div", type=int, default=2, choices=[2, 3])
    f.set_defaults(func=task_far)
    ap.set_defaults(func=lambda a: ap.print_help())
    args = ap.parse_args()
    args.live = not getattr(args, "no_live", False)
    args.func(args)


if __name__ == "__main__":
    main()