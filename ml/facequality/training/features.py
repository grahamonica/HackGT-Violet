"""Backbone embeddings for clean (non-augmented) aligned faces, with an on-disk
cache so frozen-backbone runs (and sweeps over their heads) extract only once."""

from __future__ import annotations

import logging
import time
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader

from .backbones import weights_path
from .config import Paths, config_hash
from .data import LANDMARK_COLS, FaceQualityDataset
from .model import QualityModel

log = logging.getLogger("fiqa.training")


LOADER_TIMEOUT_S = 300  # a dead worker raises instead of hanging forever


class Progress:
    """Logs `label: done/total (rate img/s, ETA)` at most every `interval` seconds."""

    def __init__(self, label: str, total: int, interval: float = 30.0):
        self.label, self.total, self.interval = label, total, interval
        self.done = 0
        self.start = self.last = time.time()

    def update(self, n: int) -> None:
        self.done += n
        now = time.time()
        if now - self.last >= self.interval or self.done >= self.total:
            self.last = now
            rate = self.done / max(now - self.start, 1e-6)
            eta = (self.total - self.done) / max(rate, 1e-6)
            log.info("  %s: %d/%d (%.0f img/s, ETA %.0fs)", self.label, self.done, self.total, rate, eta)


def make_loader(dataset, batch_size: int, num_workers: int, device: torch.device, shuffle: bool = False, seed: int = 0) -> DataLoader:
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        num_workers=num_workers,
        pin_memory=device.type == "cuda",
        drop_last=False,
        generator=torch.Generator().manual_seed(seed) if shuffle else None,
        persistent_workers=False,  # workers must see FaceQualityDataset.set_epoch
        timeout=LOADER_TIMEOUT_S if num_workers > 0 else 0,
    )


@torch.no_grad()
def compute_embeddings(
    model: QualityModel, df: pd.DataFrame, paths: Paths, align_cfg: dict, device: torch.device, batch_size: int = 256, num_workers: int = 4
) -> np.ndarray:
    was_training = model.training
    model.eval()
    loader = make_loader(FaceQualityDataset(df, paths, align_cfg, augment=False), batch_size, num_workers, device)
    progress = Progress("embeddings", len(df))
    chunks = []
    for images, _io, _y, _idx in loader:
        chunks.append(model.embed(images.to(device, non_blocking=True)).float().cpu().numpy())
        progress.update(len(images))
    model.train(was_training)
    return np.concatenate(chunks)


def cached_embeddings(
    model: QualityModel, df: pd.DataFrame, paths: Paths, cfg: dict, device: torch.device, tag: str
) -> np.ndarray:
    """Embeddings of the *pretrained* backbone, cached by backbone weights,
    alignment settings and the exact list of images."""
    wp = weights_path(model.backbone_name, paths.weights)
    stat = wp.stat()
    key = config_hash(
        {
            "backbone": model.backbone_name,
            "weights": [wp.name, stat.st_size, int(stat.st_mtime)],
            "align_size": cfg["align"]["size"],
            "images": df["crop_path"].tolist(),
            "landmarks": df[LANDMARK_COLS].round(3).to_numpy().tolist(),
        }
    )
    path = Path(paths.cache) / "features" / model.backbone_name / f"{tag}_{key}.npz"
    if path.exists():
        z = np.load(path, allow_pickle=False)
        if z["image_id"].tolist() == df["image_id"].tolist():
            log.info("features: loaded %s", path.name)
            return z["feats"]
    log.info("features: extracting %d %s embeddings with %s", len(df), tag, model.backbone_name)
    feats = compute_embeddings(model, df, paths, cfg["align"], device, int(cfg["train"]["batch_size"]), int(cfg["data"]["num_workers"]))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.stem + ".tmp.npz")
    np.savez(tmp, feats=feats, image_id=np.array(df["image_id"].tolist()))
    tmp.replace(path)
    return feats


@torch.no_grad()
def predict(
    model: QualityModel, df: pd.DataFrame, paths: Paths, cfg: dict, device: torch.device, feats: np.ndarray | None = None
) -> np.ndarray:
    """Quality scores in [0, 1]. Pass precomputed `feats` to skip the backbone."""
    was_training = model.training
    model.eval()
    if feats is None:
        feats = compute_embeddings(model, df, paths, cfg["align"], device, int(cfg["train"]["batch_size"]), int(cfg["data"]["num_workers"]))
    f = torch.from_numpy(feats).to(device)
    io = torch.tensor(df["interocular"].to_numpy(np.float32)).to(device)
    scores = torch.cat([torch.sigmoid(model.head_forward(f[i : i + 4096], io[i : i + 4096])) for i in range(0, len(f), 4096)])
    model.train(was_training)
    return scores.cpu().numpy()
