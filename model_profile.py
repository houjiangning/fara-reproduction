"""模型档案：把 BFA×FaR 框架从「仅 GPT-2」推广到任意因果语言模型（内置 Qwen2.5-3B）。

为什么能换模型：本框架的攻击/防护/评测核心逻辑只依赖两件事——
  1) 模型前向得到 logits（用于困惑度/一致率/余弦）
  2) 对存储在 .W / .weight 的参数做 **fp32 位翻转**（BFA）
这两件事与具体模型架构无关。真正绑定模型的只有 3 处，全部收拢到本模块：
  ① 模型/分词器怎么加载        -> load_causal_model()
  ② 攻击/防护默认打在哪个敏感层 -> default_layer()（GPT-2 用 h.2.mlp.c_proj；
                                  Qwen2/Llama 风格用 model.layers.3.mlp.down_proj）
  ③ 逐层余弦要数多少层          -> layer_count(model)（hidden_states = num_hidden_layers+1）

切换模型：设环境变量 FAR_MODEL 为档案名（gpt2 / qwen2.5-3b），
或覆盖 FAR_NAME_OR_PATH 指到本机已部署模型的本地路径 / HF 名称。
FAR_DEVICE=cpu（默认）或 cuda。
"""
import os

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

# ---------------------------------------------------------------- 模型档案表

PROFILES = {
    "gpt2": {
        "model_name": "GPT-2 small (124M)",
        "name_or_path": os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "gpt2-local"),
        "dtype": "float32",
        "layer_style": "gpt2",               # transformer.h.{idx}.mlp.c_proj
        "default_layer_idx": 2,
    },
    "qwen2.5-3b": {
        "model_name": "Qwen2.5-3B",
        # 在你的那台电脑上若部署的是对话版，改成 "Qwen/Qwen2.5-3B-Instruct"；
        # 若你已把模型下到本地目录（如 D:/qwen2.5-3b），改成该绝对路径更稳。
        "name_or_path": "Qwen/Qwen2.5-3B",
        "dtype": "float32",                  # fp32 加载，才能做 fp32 位翻转
        "layer_style": "qwen2",              # model.layers.{idx}.mlp.down_proj
        "default_layer_idx": 3,
    },
}

_LAYER_TEMPLATES = {
    "gpt2": "transformer.h.{idx}.mlp.c_proj",     # GPT-2 c_proj 是 MLP 的输出投影
    "qwen2": "model.layers.{idx}.mlp.down_proj",  # Qwen2/Llama 风格：down_proj 对应 c_proj
}


def get_profile(name=None):
    key = (name or os.environ.get("FAR_MODEL", "gpt2")).strip()
    if key not in PROFILES:
        raise SystemExit(f"[model_profile] 未知模型档案: {key!r}，可用 {list(PROFILES)}"
                         "（或设 FAR_MODEL=xxx 或 FAR_NAME_OR_PATH=本地路径）")
    return PROFILES[key]


def model_display_name(name=None):
    return get_profile(name)["model_name"]


def default_layer(name=None):
    """该档案默认的敏感层，BFA/FaR 默认打在这一层。"""
    p = get_profile(name)
    return _LAYER_TEMPLATES[p["layer_style"]].format(idx=p["default_layer_idx"])


def layer_count(model):
    """逐层余弦的层数 = embed + 每 block = num_hidden_layers + 1（HF 约定）。"""
    cfg = getattr(model, "config", None)
    nl = getattr(cfg, "num_hidden_layers", 12)
    return nl + 1


def load_causal_model(name=None):
    """用 HuggingFace Auto 接口以 fp32 加载因果语言模型（便于 fp32 位翻转）。"""
    p = get_profile(name)
    nop = os.environ.get("FAR_NAME_OR_PATH") or p["name_or_path"]
    dev = os.environ.get("FAR_DEVICE", "cpu")
    dtype = torch.float32 if p["dtype"] == "float32" else getattr(torch, p["dtype"])

    kwargs = {"torch_dtype": dtype}
    if dev != "cpu":
        kwargs["device_map"] = "auto"        # GPU 时用加速在多设备上铺开
    model = AutoModelForCausalLM.from_pretrained(nop, **kwargs)
    tok = AutoTokenizer.from_pretrained(nop)
    if getattr(tok, "pad_token", None) is None:
        tok.pad_token = tok.eos_token          # 批量滑动窗口需要 pad_token
    model = model.eval().to(dev)
    print(f"[model_profile] {p['model_name']} <- from_pretrained({nop})"
          f" dtype={dtype} device={dev}")
    return model, tok


def print_profile(name=None):
    p = get_profile(name)
    print(f"[model_profile] 档案 {p['model_name']}: {p['name_or_path']}")
    print(f"[model_profile] 默认敏感层 = {default_layer(name)}")
    print(f"[model_profile] 切换: 设 FAR_MODEL=gpt2|qwen2.5-3b，"
          "FAR_NAME_OR_PATH=本地路径，FAR_DEVICE=cpu|cuda")


if __name__ == "__main__":
    print_profile()
    print_profile("qwen2.5-3b")