"""Config loading, dotted overrides, resolved paths, logging and device helpers."""

from __future__ import annotations

import copy
import hashlib
import json
import logging
import os
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
import yaml

MODELS_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = MODELS_DIR / "configs" / "default.yaml"

log = logging.getLogger("fiqa.training")


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )
    for noisy in ("urllib3", "huggingface_hub", "PIL"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


@dataclass
class Paths:
    data: Path  # dataset DATA_ROOT (see SCHEMA.md)
    weights: Path  # pretrained backbone weights (prepare_weights.py)
    runs: Path  # training outputs
    cache: Path  # cached frozen features

    @property
    def queries(self) -> Path:
        return self.data / "dataset" / "queries.csv"

    @property
    def dataset_info(self) -> Path:
        return self.data / "dataset" / "dataset_info.json"


def _resolve(value: str, env: str) -> Path:
    p = Path(os.environ.get(env) or value)
    return p if p.is_absolute() else (MODELS_DIR / p).resolve()


def resolve_paths(cfg: dict) -> Paths:
    p = cfg["paths"]
    return Paths(
        data=_resolve(p["data_dir"], "VIOLET_FIQA_DATA_DIR"),
        weights=_resolve(p["weights_dir"], "VIOLET_FIQA_WEIGHTS_DIR"),
        runs=_resolve(p["runs_dir"], "VIOLET_FIQA_RUNS_DIR"),
        cache=_resolve(p["cache_dir"], "VIOLET_FIQA_CACHE_DIR"),
    )


def deep_merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def set_dotted(cfg: dict, key: str, value: Any) -> None:
    node = cfg
    *parents, leaf = key.split(".")
    for part in parents:
        node = node.setdefault(part, {})
    node[leaf] = value


def parse_overrides(items: list[str] | None) -> dict[str, Any]:
    """`["train.lr=3e-4", "model.head_hidden=64"]` -> {key: yaml-parsed value}."""
    out = {}
    for item in items or []:
        key, sep, raw = item.partition("=")
        if not sep:
            raise ValueError(f"Override must look like key=value, got {item!r}")
        out[key.strip()] = yaml.safe_load(raw)
    return out


def load_config(path: str | os.PathLike | None = None) -> dict:
    with open(Path(path or DEFAULT_CONFIG), encoding="utf-8") as f:
        return yaml.safe_load(f)


def run_config(base: dict, backbone: str, mode: str, overrides: dict[str, Any] | None = None) -> dict:
    """Resolve the config for one run: base, then `modes.<mode>`, then overrides."""
    if mode not in base["modes"]:
        raise ValueError(f"Unknown mode {mode!r}; expected one of {list(base['modes'])}")
    cfg = deep_merge({k: v for k, v in base.items() if k != "modes"}, base["modes"][mode])
    cfg["backbone"] = backbone
    cfg["mode"] = mode
    for k, v in (overrides or {}).items():
        set_dotted(cfg, k, v)
    return cfg


def config_hash(obj: Any) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, default=str).encode()).hexdigest()[:12]


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def get_device(name: str = "auto") -> torch.device:
    if name == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    return torch.device(name)
