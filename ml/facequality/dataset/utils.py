"""Shared helpers: config, paths, IO, alignment, and cheap image statistics."""

from __future__ import annotations

import csv
import hashlib
import json
import logging
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator

import cv2
import numpy as np
import pandas as pd
import yaml

SCHEMA_VERSION = 1
DATASET_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = DATASET_DIR / "configs" / "dataset.yaml"

log = logging.getLogger("fiqa")


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )
    # boto's own logging is very chatty at DEBUG.
    for noisy in ("botocore", "boto3", "urllib3"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


# ---------------------------------------------------------------------------
# Config + paths
# ---------------------------------------------------------------------------


@dataclass
class Paths:
    root: Path  # ml/facequality/dataset
    data: Path  # DATA_ROOT

    @property
    def raw(self) -> Path:
        return self.data / "raw"

    @property
    def crops(self) -> Path:
        return self.data / "crops"

    @property
    def manifests(self) -> Path:
        return self.data / "manifests"

    @property
    def work(self) -> Path:
        return self.data / "work"

    @property
    def labels(self) -> Path:
        return self.data / "labels"

    @property
    def dataset(self) -> Path:
        return self.data / "dataset"

    @property
    def report(self) -> Path:
        return self.data / "report"

    # Stage-internal intermediates
    @property
    def source_images(self) -> Path:
        return self.work / "source_images.csv"

    @property
    def splits(self) -> Path:
        return self.manifests / "splits.csv"

    @property
    def preprocessing(self) -> Path:
        return self.work / "preprocessing.csv"

    @property
    def enrollment_selection(self) -> Path:
        return self.work / "enrollment_selection.csv"

    @property
    def enrollment_aws(self) -> Path:
        return self.labels / "enrollment_aws.jsonl"

    @property
    def rekognition_raw(self) -> Path:
        return self.labels / "rekognition_raw.jsonl"

    @property
    def failures(self) -> Path:
        return self.labels / "failures.jsonl"

    def rel(self, p: Path) -> str:
        """Path relative to DATA_ROOT with forward slashes (manifest convention)."""
        return Path(p).resolve().relative_to(self.data.resolve()).as_posix()

    def abs(self, rel: str) -> Path:
        return self.data / rel

    def ensure(self) -> None:
        for d in (self.raw, self.crops, self.manifests, self.work, self.labels, self.dataset, self.report):
            d.mkdir(parents=True, exist_ok=True)


class Config(dict):
    """Plain dict with attribute-style nested access and resolved paths."""

    path: Path
    paths: Paths

    def __getattr__(self, key: str) -> Any:
        try:
            v = self[key]
        except KeyError as e:
            raise AttributeError(key) from e
        return Config(v) if isinstance(v, dict) and not isinstance(v, Config) else v

    def resolve(self, rel: str | os.PathLike) -> Path:
        """Resolve a config path relative to paths.root."""
        p = Path(rel)
        return p if p.is_absolute() else (self.paths.root / p).resolve()

    def hash(self) -> str:
        return hashlib.sha256(json.dumps(self, sort_keys=True, default=str).encode()).hexdigest()[:12]


def load_config(path: str | os.PathLike | None = None) -> Config:
    path = Path(path or DEFAULT_CONFIG).resolve()
    with open(path, encoding="utf-8") as f:
        cfg = Config(yaml.safe_load(f))
    cfg.path = path
    root = (path.parent / cfg["paths"]["root"]).resolve()
    data = Path(os.environ.get("VIOLET_FIQA_DATA_DIR") or (root / cfg["paths"]["data_dir"])).resolve()
    cfg.paths = Paths(root=root, data=data)
    return cfg


# ---------------------------------------------------------------------------
# Deterministic helpers
# ---------------------------------------------------------------------------


def stable_hash(*parts: Any) -> int:
    h = hashlib.sha256("|".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(h[:8], "big")


# ---------------------------------------------------------------------------
# CSV / JSONL IO
# ---------------------------------------------------------------------------


def write_csv_atomic(df: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    df.to_csv(tmp, index=False, lineterminator="\n")
    os.replace(tmp, path)


def read_csv(path: Path, **kw: Any) -> pd.DataFrame:
    # Identity/image ids must stay strings ("000123" must not become 123).
    dtype = {c: str for c in ("image_id", "identity_id", "source_identity_id", "session_id", "split", "dhash")}
    dtype.update(kw.pop("dtype", {}))
    return pd.read_csv(path, dtype=dtype, keep_default_na=True, **kw)


def write_json_atomic(obj: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, default=str)
    os.replace(tmp, path)


def iter_jsonl(path: Path) -> Iterator[dict]:
    """Yield records, tolerating a torn final line from an interrupted write."""
    if not path.exists():
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                log.warning("Skipping malformed line in %s", path.name)


class JsonlWriter:
    """Thread-safe append-only JSONL writer that flushes + fsyncs every record."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._f = open(path, "a", encoding="utf-8")
        self._lock = threading.Lock()

    def write(self, rec: dict) -> None:
        line = json.dumps(rec, default=str, separators=(",", ":"))
        with self._lock:
            self._f.write(line + "\n")
            self._f.flush()
            os.fsync(self._f.fileno())

    def close(self) -> None:
        self._f.close()

    def __enter__(self) -> "JsonlWriter":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


def log_failure(writer: JsonlWriter, stage: str, image_id: str | None, error: str, **extra: Any) -> None:
    writer.write({"stage": stage, "image_id": image_id, "error": error, **extra})


# ---------------------------------------------------------------------------
# Face geometry
# ---------------------------------------------------------------------------

# InsightFace / ArcFace 5-point template in a 112x112 frame:
# image-left eye, image-right eye, nose tip, image-left mouth corner, image-right mouth corner.
ARCFACE_TEMPLATE = np.array(
    [
        [38.2946, 51.6963],
        [73.5318, 51.5014],
        [56.0252, 71.7366],
        [41.5493, 92.3655],
        [70.7299, 92.2041],
    ],
    dtype=np.float32,
)


def crop_template(crop_size: int, face_scale: float) -> np.ndarray:
    """ArcFace template scaled so the 112 frame fills the central face_scale of the crop."""
    s = crop_size * face_scale / 112.0
    offset = crop_size * (1.0 - face_scale) / 2.0
    return ARCFACE_TEMPLATE * s + offset


def align_face(img: np.ndarray, landmarks: np.ndarray, crop_size: int, face_scale: float) -> tuple[np.ndarray, float]:
    """Similarity-warp img so its 5 landmarks match the template.

    Returns (crop, out_of_frame_frac).
    """
    dst = crop_template(crop_size, face_scale)
    M, _ = cv2.estimateAffinePartial2D(landmarks.astype(np.float32), dst, method=cv2.LMEDS)
    if M is None:
        raise ValueError("could not estimate similarity transform")
    crop = cv2.warpAffine(img, M, (crop_size, crop_size), flags=cv2.INTER_LINEAR, borderValue=(0, 0, 0))
    mask = cv2.warpAffine(
        np.full(img.shape[:2], 255, np.uint8), M, (crop_size, crop_size), flags=cv2.INTER_NEAREST, borderValue=0
    )
    return crop, float((mask == 0).mean())


def pose_proxies(lm: np.ndarray) -> dict[str, float]:
    """Cheap pose estimates from 5 landmarks (see SCHEMA.md for sign conventions).

    yaw_proxy:   horizontal nose offset from the eye midpoint, in interocular units,
                 measured after removing roll. >0 == face turned toward the image's right.
    pitch_proxy: where the nose sits between the eye line (0) and the mouth line (1),
                 minus 0.5 so a typical frontal face is near 0. >0 == looking down.
    roll_deg:    angle of the eye line.
    """
    le, re, nose, lm_, rm = lm
    d = re - le
    iod = float(np.hypot(*d))
    roll = float(np.degrees(np.arctan2(d[1], d[0])))
    c, s = np.cos(-np.radians(roll)), np.sin(-np.radians(roll))
    R = np.array([[c, -s], [s, c]])
    eye_mid = (le + re) / 2
    mouth_mid = (lm_ + rm) / 2
    n = R @ (nose - eye_mid)
    m = R @ (mouth_mid - eye_mid)
    yaw = n[0] / iod if iod > 0 else np.nan
    pitch = (n[1] / m[1] - 0.5) if m[1] > 0 else np.nan
    return {"yaw_proxy": float(yaw), "pitch_proxy": float(pitch), "roll_deg": roll, "interocular_px": iod}


def face_region_stats(img: np.ndarray, lm: np.ndarray) -> dict[str, float]:
    """Sharpness / brightness / contrast over a square box around the landmarks.

    Measured on the source image so the numbers do not depend on crop.mode.
    Box: centered on the landmark centroid, side 2x the larger of interocular
    and eye-to-mouth distance (roughly brows to chin).
    """
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    eye_mid, mouth_mid = (lm[0] + lm[1]) / 2, (lm[3] + lm[4]) / 2
    side = 2.0 * max(np.hypot(*(lm[1] - lm[0])), np.hypot(*(mouth_mid - eye_mid)))
    cx, cy = lm.mean(axis=0)
    h, w = gray.shape
    x0, x1 = int(max(0, cx - side / 2)), int(min(w, cx + side / 2))
    y0, y1 = int(max(0, cy - side / 2)), int(min(h, cy + side / 2))
    face = gray[y0:y1, x0:x1]
    return {
        "sharpness": float(cv2.Laplacian(face, cv2.CV_64F).var()),
        "brightness": float(face.mean()),
        "contrast": float(face.std()),
    }


def dhash(img: np.ndarray, size: int = 8) -> int:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    small = cv2.resize(gray, (size + 1, size), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return int("".join("1" if b else "0" for b in bits), 2)


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def chunked(it: Iterable, n: int) -> Iterator[list]:
    buf: list = []
    for x in it:
        buf.append(x)
        if len(buf) == n:
            yield buf
            buf = []
    if buf:
        yield buf
