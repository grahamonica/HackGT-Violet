"""IResNet-50 (ArcFace), in the BN-folded form of InsightFace's released ONNX
model (`buffalo_l/w600k_r50.onnx`, trained on WebFace600K).

Adapted from insightface `recognition/arcface_torch/backbones/iresnet.py`
(MIT). The export folds every BatchNorm that directly follows a conv into that
conv's bias, so those convs have `bias=True` and the BNs are gone; the
pre-activation `bn1` of each block, the final `bn2` and the `features` BN
cannot be folded and remain.

Input: [B, 3, 112, 112] RGB normalized to [-1, 1]. Output: 512-d embedding
(not L2-normalized).
"""

from __future__ import annotations

import torch
from torch import nn


class IBasicBlock(nn.Module):
    def __init__(self, inplanes: int, planes: int, stride: int = 1, downsample: nn.Module | None = None):
        super().__init__()
        self.bn1 = nn.BatchNorm2d(inplanes, eps=1e-5)
        self.conv1 = nn.Conv2d(inplanes, planes, 3, 1, 1, bias=True)
        self.prelu = nn.PReLU(planes)
        self.conv2 = nn.Conv2d(planes, planes, 3, stride, 1, bias=True)
        self.downsample = downsample

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Main path before the shortcut: same call order as upstream and the
        # ONNX graph (prepare_weights matches layers by execution order).
        out = self.conv2(self.prelu(self.conv1(self.bn1(x))))
        identity = x if self.downsample is None else self.downsample(x)
        return out + identity


class IResNet(nn.Module):
    fc_scale = 7 * 7

    def __init__(self, layers: tuple[int, int, int, int], num_features: int = 512):
        super().__init__()
        self.inplanes = 64
        self.conv1 = nn.Conv2d(3, 64, 3, 1, 1, bias=True)
        self.prelu = nn.PReLU(64)
        self.layer1 = self._make_layer(64, layers[0])
        self.layer2 = self._make_layer(128, layers[1])
        self.layer3 = self._make_layer(256, layers[2])
        self.layer4 = self._make_layer(512, layers[3])
        self.bn2 = nn.BatchNorm2d(512, eps=1e-5)
        self.fc = nn.Linear(512 * self.fc_scale, num_features)
        self.features = nn.BatchNorm1d(num_features, eps=1e-5)

    def _make_layer(self, planes: int, blocks: int) -> nn.Sequential:
        downsample = nn.Conv2d(self.inplanes, planes, 1, 2, bias=True)
        layers = [IBasicBlock(self.inplanes, planes, 2, downsample)]
        self.inplanes = planes
        layers += [IBasicBlock(planes, planes) for _ in range(1, blocks)]
        return nn.Sequential(*layers)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.prelu(self.conv1(x))
        x = self.layer4(self.layer3(self.layer2(self.layer1(x))))
        x = torch.flatten(self.bn2(x), 1)
        return self.features(self.fc(x))

    def stages(self) -> list[list[nn.Module]]:
        """Shallow-to-deep module groups; fine-tuning unfreezes the last N."""
        return [
            [self.conv1, self.prelu, self.layer1],
            [self.layer2],
            [self.layer3],
            [self.layer4, self.bn2, self.fc, self.features],
        ]


def iresnet50(num_features: int = 512) -> IResNet:
    return IResNet((3, 4, 14, 3), num_features)
