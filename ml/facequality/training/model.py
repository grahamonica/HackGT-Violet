"""QualityModel = pretrained face-recognition backbone + small MLP quality head.

    aligned face uint8-range RGB [B,3,112,112] ─ normalize ─ backbone ─ 512-d
                                                                      ⊕ log(interocular px)
                                                    ─ BN ─ MLP ─ logit (sigmoid = quality in [0,1])

Normalization is inside the model, so a deployed/exported model takes raw
0-255 pixels of the aligned face plus the interocular distance (in pixels of
the image the face was cropped from).
"""

from __future__ import annotations

import torch
from torch import nn

from .backbones import build_backbone, get_spec


class QualityHead(nn.Module):
    def __init__(self, in_dim: int, hidden: int, dropout: float):
        super().__init__()
        # BN on the input puts every backbone's embedding (whose scales differ
        # a lot) on a common footing without discarding its norm, which
        # carries quality information.
        self.net = nn.Sequential(
            nn.BatchNorm1d(in_dim),
            nn.Linear(in_dim, hidden),
            nn.ReLU(inplace=True),
            nn.Dropout(dropout),
            nn.Linear(hidden, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x).squeeze(-1)


class QualityModel(nn.Module):
    def __init__(self, backbone_name: str, model_cfg: dict, weights_dir=None):
        super().__init__()
        self.backbone_name = backbone_name
        self.side_features = bool(model_cfg.get("side_features", True))
        self.backbone = build_backbone(backbone_name, weights_dir)
        in_dim = get_spec(backbone_name).feat_dim + (1 if self.side_features else 0)
        self.head = QualityHead(in_dim, int(model_cfg["head_hidden"]), float(model_cfg["head_dropout"]))
        self._frozen: list[nn.Module] = []
        self._trainable_prefixes: list[str] = ["head."]

    # -- forward ---------------------------------------------------------------

    def embed(self, images: torch.Tensor) -> torch.Tensor:
        """Backbone embedding for raw 0-255 RGB aligned faces."""
        return self.backbone(images.float() / 127.5 - 1.0)

    def head_forward(self, feats: torch.Tensor, interocular: torch.Tensor) -> torch.Tensor:
        if self.side_features:
            side = torch.log(interocular.float().clamp_min(1.0)).reshape(-1, 1)
            feats = torch.cat([feats.float(), side], dim=1)
        return self.head(feats.float())

    def forward(self, images: torch.Tensor, interocular: torch.Tensor) -> torch.Tensor:
        """Returns logits; `torch.sigmoid(logits)` is the quality score."""
        return self.head_forward(self.embed(images), interocular)

    # -- freezing ----------------------------------------------------------------

    def set_trainable_stages(self, n: int) -> None:
        """Train the head plus the last `n` backbone stages; freeze the rest.

        Frozen modules are kept in eval mode (BatchNorm statistics fixed) even
        while the model is in train mode.
        """
        stages = self.backbone.stages()
        if not 0 <= n <= len(stages):
            raise ValueError(f"unfreeze_stages must be in [0, {len(stages)}] for {self.backbone_name}")
        trainable = [m for group in stages[len(stages) - n :] for m in group]
        for p in self.backbone.parameters():
            p.requires_grad_(False)
        for m in trainable:
            for p in m.parameters():
                p.requires_grad_(True)
        self._frozen = [m for group in stages[: len(stages) - n] for m in group]
        names = {id(m): name for name, m in self.backbone.named_modules()}
        self._trainable_prefixes = ["head."] + [f"backbone.{names[id(m)]}." for m in trainable]
        self.train(self.training)

    def train(self, mode: bool = True):
        super().train(mode)
        for m in self._frozen:
            m.eval()
        return self

    def trainable_state_dict(self) -> dict[str, torch.Tensor]:
        """Only what training changed (head + unfrozen stages incl. BN buffers).
        The rest is reproduced from the pretrained weights file."""
        return {k: v for k, v in self.state_dict().items() if any(k.startswith(p) for p in self._trainable_prefixes)}
