"""MobileFaceNet (ArcFace), in the BN-folded form of InsightFace's released ONNX
model (`buffalo_s/w600k_mbf.onnx`, trained on WebFace600K).

Adapted from insightface `recognition/arcface_torch/backbones/mobilefacenet.py`
(MIT; originally from cavaface). Every conv's BatchNorm is folded into the
conv bias. The released model's embedding head differs from the current
insightface source (no GDC): conv_sep -> 1x1 conv to 64 channels -> PReLU ->
flatten -> Linear(64*7*7, 512) -> BatchNorm1d.

Input: [B, 3, 112, 112] RGB normalized to [-1, 1]. Output: 512-d embedding
(not L2-normalized).
"""

from __future__ import annotations

import torch
from torch import nn


class ConvBlock(nn.Sequential):
    """conv (+ folded BN) + PReLU."""

    def __init__(self, in_c: int, out_c: int, kernel: int = 1, stride: int = 1, padding: int = 0, groups: int = 1):
        super().__init__(nn.Conv2d(in_c, out_c, kernel, stride, padding, groups=groups, bias=True), nn.PReLU(out_c))


class DepthWise(nn.Module):
    def __init__(self, in_c: int, out_c: int, residual: bool = False, stride: int = 2, groups: int = 1):
        super().__init__()
        self.residual = residual
        self.layers = nn.Sequential(
            ConvBlock(in_c, groups, 1),
            ConvBlock(groups, groups, 3, stride, 1, groups=groups),
            nn.Conv2d(groups, out_c, 1, bias=True),  # linear bottleneck (folded BN, no activation)
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.layers(x) if self.residual else self.layers(x)


class Residual(nn.Sequential):
    def __init__(self, c: int, num_block: int, groups: int):
        super().__init__(*[DepthWise(c, c, residual=True, stride=1, groups=groups) for _ in range(num_block)])


class MobileFaceNet(nn.Module):
    def __init__(self, num_features: int = 512, blocks: tuple[int, int, int, int] = (1, 4, 6, 2), scale: int = 2):
        super().__init__()
        c1, c2 = 64 * scale, 128 * scale
        assert blocks[0] == 1, "released model uses a single depthwise conv block first"
        self.layers = nn.ModuleList(
            [
                ConvBlock(3, c1, 3, 2, 1),
                ConvBlock(c1, c1, 3, 1, 1, groups=64),
                DepthWise(c1, c1, stride=2, groups=128),
                Residual(c1, blocks[1], groups=128),
                DepthWise(c1, c2, stride=2, groups=256),
                Residual(c2, blocks[2], groups=256),
                DepthWise(c2, c2, stride=2, groups=512),
                Residual(c2, blocks[3], groups=256),
            ]
        )
        self.conv_sep = ConvBlock(c2, 512, 1)
        self.embed_conv = ConvBlock(512, 64, 1)
        self.fc = nn.Linear(64 * 7 * 7, num_features)
        self.features = nn.BatchNorm1d(num_features, eps=1e-5)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for layer in self.layers:
            x = layer(x)
        x = self.embed_conv(self.conv_sep(x))
        return self.features(self.fc(torch.flatten(x, 1)))

    def stages(self) -> list[list[nn.Module]]:
        """Shallow-to-deep module groups; fine-tuning unfreezes the last N."""
        layers = list(self.layers)
        return [
            layers[0:4],
            layers[4:6],
            layers[6:8] + [self.conv_sep, self.embed_conv, self.fc, self.features],
        ]


def mobilefacenet() -> MobileFaceNet:
    return MobileFaceNet()
