"""Backbone registry. All backbones share one contract:

- input  [B, 3, 112, 112] RGB, ArcFace-aligned (see align.py), in [-1, 1]
- output [B, 512] embedding, before L2 normalization
- `stages()` returns shallow-to-deep module groups for partial unfreezing

Weights are local files produced by `prepare_weights.py`; nothing is fetched
at training time.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import torch
from torch import nn


@dataclass(frozen=True)
class BackboneSpec:
    build: Callable[[], nn.Module]
    weights_file: str
    feat_dim: int = 512


def _mbf() -> nn.Module:
    from .mobilefacenet import mobilefacenet

    return mobilefacenet()


def _edgeface_s() -> nn.Module:
    from .edgeface import edgeface_s

    return edgeface_s()


def _r50() -> nn.Module:
    from .iresnet import iresnet50

    return iresnet50()


BACKBONES: dict[str, BackboneSpec] = {
    "mbf": BackboneSpec(_mbf, "mbf_w600k.pt"),
    "edgeface_s": BackboneSpec(_edgeface_s, "edgeface_s_gamma_05.pt"),
    "r50": BackboneSpec(_r50, "r50_w600k.pt"),
}


def get_spec(name: str) -> BackboneSpec:
    if name not in BACKBONES:
        raise ValueError(f"Unknown backbone {name!r}; expected one of {list(BACKBONES)}")
    return BACKBONES[name]


def weights_path(name: str, weights_dir: Path) -> Path:
    return Path(weights_dir) / get_spec(name).weights_file


def build_backbone(name: str, weights_dir: Path | None = None) -> nn.Module:
    """Build a backbone; load pretrained weights (strictly) if `weights_dir` is given."""
    model = get_spec(name).build()
    if weights_dir is not None:
        path = weights_path(name, weights_dir)
        if not path.exists():
            raise FileNotFoundError(
                f"Missing weights {path}. Run `python -m ml.facequality.training.prepare_weights` first."
            )
        model.load_state_dict(torch.load(path, map_location="cpu", weights_only=True), strict=True)
    return model
