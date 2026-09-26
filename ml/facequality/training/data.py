"""Training data from the dataset contract: `dataset/queries.csv`
+ `dataset/dataset_info.json`, images loaded from `crop_path`.

Each sample is the crop aligned to the ArcFace template with its landmarks,
the interocular distance in crop pixels (face resolution), and the target.
"""

from __future__ import annotations

import json
import logging

import cv2
import numpy as np
import pandas as pd
import torch
from torch.utils.data import Dataset

from .align import align_face, random_similarity
from .config import Paths

log = logging.getLogger("fiqa.training")

SUPPORTED_SCHEMA_VERSIONS = {2}
LANDMARKS = ["left_eye", "right_eye", "nose", "left_mouth", "right_mouth"]
LANDMARK_COLS = [f"{p}_{a}" for p in LANDMARKS for a in ("x", "y")]
SPLITS = ("train", "val", "test")


def make_target(df: pd.DataFrame, kind: str, nines_cap: float = 6.0) -> np.ndarray:
    """Rekognition utility in [0, 1]. See `data.target` in configs/default.yaml.

    Missing similarity (true identity not in the top 5, or `no_face`) is 0.
    """
    if kind == "nines":
        sim = df["aws_true_similarity"].to_numpy(dtype=np.float64)
        miss = np.isnan(sim)
        gap = np.maximum(100.0 - np.nan_to_num(sim, nan=0.0), 1e-12)
        y = np.clip(np.log10(100.0 / gap), 0.0, nines_cap) / nines_cap
        y[miss] = 0.0
    elif kind == "similarity":
        y = df["aws_true_similarity"].fillna(0.0).to_numpy(dtype=np.float64) / 100.0
    elif kind == "correct_only":
        correct = df["aws_correct_top1"].fillna(0).to_numpy() == 1
        y = np.where(correct, df["aws_top1_similarity"].fillna(0.0).to_numpy(dtype=np.float64) / 100.0, 0.0)
    else:
        raise ValueError(f"Unknown target {kind!r}")
    return y.astype(np.float32)


def load_dataset_info(paths: Paths) -> dict:
    info = json.loads(paths.dataset_info.read_text(encoding="utf-8"))
    if info.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
        raise ValueError(f"Unsupported dataset schema_version {info.get('schema_version')}; expected {SUPPORTED_SCHEMA_VERSIONS}")
    return info


def load_queries(paths: Paths, data_cfg: dict) -> pd.DataFrame:
    """All usable query rows (every split), with `y`, `correct` and `interocular`."""
    load_dataset_info(paths)
    q = pd.read_csv(
        paths.queries,
        dtype={c: str for c in ("image_id", "source_image_id", "identity_id", "source_identity_id", "session_id", "split")},
    )
    n0 = len(q)
    q = q[q["aws_status"].isin(data_cfg["statuses"])]
    n_status = len(q)
    if data_cfg.get("require_landmarks_in_crop", True):
        q = q[q["landmarks_in_crop"] == 1]
    q = q.dropna(subset=LANDMARK_COLS).reset_index(drop=True)
    log.info(
        "queries: %d rows; %d after aws_status in %s; %d after landmark filter",
        n0, n_status, data_cfg["statuses"], len(q),
    )
    q["y"] = make_target(q, data_cfg["target"], float(data_cfg.get("nines_cap", 6.0)))
    q["correct"] = q["aws_correct_top1"].astype(float)
    lm = landmarks_array(q)
    q["interocular"] = np.linalg.norm(lm[:, 1] - lm[:, 0], axis=1)
    return q


def landmarks_array(df: pd.DataFrame) -> np.ndarray:
    """(N, 5, 2) crop-relative landmarks in LANDMARKS order."""
    return df[LANDMARK_COLS].to_numpy(dtype=np.float64).reshape(len(df), 5, 2)


def split_frame(q: pd.DataFrame, split: str) -> pd.DataFrame:
    df = q[q["split"] == split].reset_index(drop=True)
    if df.empty:
        raise ValueError(f"No usable rows in split {split!r}")
    return df


def load_image_rgb(path) -> np.ndarray:
    img = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if img is None:
        raise FileNotFoundError(f"Could not read image {path}")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


class FaceQualityDataset(Dataset):
    """Returns `(image uint8 [3,S,S] RGB, interocular px, target, row index)`.

    `augment=True` applies the config's landmark jitter and horizontal flip.
    """

    def __init__(self, df: pd.DataFrame, paths: Paths, align_cfg: dict, augment: bool = False, seed: int = 0):
        self.paths = paths
        self.crop_paths = df["crop_path"].tolist()
        self.landmarks = landmarks_array(df)
        self.interocular = df["interocular"].to_numpy(dtype=np.float32)
        self.y = df["y"].to_numpy(dtype=np.float32)
        self.size = int(align_cfg["size"])
        self.hflip = augment and bool(align_cfg.get("hflip", False))
        jitter = align_cfg.get("jitter") or {}
        self.jitter = jitter if augment and jitter.get("enabled", False) else None
        self.seed = seed
        self.epoch = 0

    def set_epoch(self, epoch: int) -> None:
        """Vary augmentation per epoch while staying reproducible across worker counts."""
        self.epoch = epoch

    def __len__(self) -> int:
        return len(self.y)

    def __getitem__(self, i: int):
        img = load_image_rgb(self.paths.data / self.crop_paths[i])
        perturb = None
        flip = False
        if self.jitter is not None or self.hflip:
            rng = np.random.default_rng((self.seed, self.epoch, i))
            if self.jitter is not None:
                j = self.jitter
                perturb = random_similarity(rng, self.size, float(j["shift_px"]), float(j["scale"]), float(j["rot_deg"]))
            flip = self.hflip and rng.random() < 0.5
        face = align_face(img, self.landmarks[i], self.size, perturb)
        if flip:
            face = face[:, ::-1]
        face = torch.from_numpy(np.ascontiguousarray(face.transpose(2, 0, 1)))
        return face, torch.tensor(self.interocular[i]), torch.tensor(self.y[i]), i
