"""EdgeFace-S (gamma 0.5): timm EdgeNeXt-small with low-rank linear layers.

Adapted from https://github.com/otroshi/edgeface `backbones/timmfr.py`
(BSD 3-Clause, Copyright (c) 2024 Anjith George, Christophe Ecabert,
Hatef Otroshi Shahreza, Ketan Kotwal, Sebastien Marcel, Idiap Research
Institute). Pretrained weights: `Idiap/EdgeFace-S-GAMMA` on Hugging Face
(CC BY-NC-SA 4.0). Module names match the released checkpoint exactly.

Input: [B, 3, 112, 112] RGB normalized to [-1, 1]. Output: 512-d embedding
(not L2-normalized).
"""

from __future__ import annotations

import timm
import torch
from torch import nn


class LoRaLin(nn.Module):
    def __init__(self, in_features: int, out_features: int, rank: int, bias: bool = True):
        super().__init__()
        self.linear1 = nn.Linear(in_features, rank, bias=False)
        self.linear2 = nn.Linear(rank, out_features, bias=bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.linear2(self.linear1(x))


def replace_linear_with_lowrank(module: nn.Module, rank_ratio: float) -> None:
    # Same rule as upstream: only a direct child *named* "head" is skipped, so
    # the classifier (`head.fc`) is still replaced.
    for name, child in module.named_children():
        if isinstance(child, nn.Linear) and "head" not in name:
            rank = max(2, int(min(child.in_features, child.out_features) * rank_ratio))
            setattr(module, name, LoRaLin(child.in_features, child.out_features, rank, child.bias is not None))
        else:
            replace_linear_with_lowrank(child, rank_ratio)


class EdgeFace(nn.Module):
    def __init__(self, model_name: str = "edgenext_small", featdim: int = 512, rank_ratio: float = 0.5):
        super().__init__()
        self.model = timm.create_model(model_name, pretrained=False)
        self.model.reset_classifier(featdim)
        replace_linear_with_lowrank(self, rank_ratio)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.model(x)

    def stages(self) -> list[list[nn.Module]]:
        """Shallow-to-deep module groups; fine-tuning unfreezes the last N."""
        m = self.model
        return [
            [m.stem, m.stages[0]],
            [m.stages[1]],
            [m.stages[2]],
            [m.stages[3], m.norm_pre, m.head],
        ]


def edgeface_s() -> EdgeFace:
    return EdgeFace("edgenext_small", 512, rank_ratio=0.5)
