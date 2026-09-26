"""CelebA source adapter.

Fetches CelebA (if missing) and converts it into the generic per-image source
table (`work/source_images.csv`) consumed by every later stage. Adding a new
source (e.g. Meta glasses footage) means writing another adapter that emits
the same columns; nothing downstream is CelebA-specific.

Generic source columns:
    image_id, identity_id, source_dataset, source_identity_id, session_id,
    source_image_path, lm_{0..4}_{x,y}, orig_face_w, orig_face_h
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import pandas as pd

from .utils import Config, log, write_csv_atomic

SOURCE = "celeba"
ANNOTATION_KEYS = ("identity_file", "landmarks_file", "bbox_file", "attr_file")
LANDMARK_COLS = [f"lm_{i}_{a}" for i in range(5) for a in ("x", "y")]


def _c(cfg: Config):
    return cfg.source.celeba


def _data_path(cfg: Config, rel: str) -> Path:
    return cfg.paths.data / rel


def download(cfg: Config) -> None:
    """Fetch missing CelebA files (annotations + image zip) from the Hugging Face mirror.

    The zip is NOT extracted here; `materialize` extracts only the images of
    selected identities, so a 10k-image dataset never unpacks all 200k files.
    """
    c = _c(cfg)
    raw_dir = _data_path(cfg, c.raw_dir)
    raw_dir.mkdir(parents=True, exist_ok=True)
    wanted = [Path(c[k]).name for k in ANNOTATION_KEYS] + [c.images_zip]
    missing = [f for f in wanted if not (raw_dir / f).exists()]
    if missing:
        from huggingface_hub import hf_hub_download

        log.info("Downloading %s from hf://datasets/%s", missing, c.hf_repo)
        for f in missing:
            hf_hub_download(repo_id=c.hf_repo, repo_type="dataset", filename=f, local_dir=raw_dir)


def materialize(cfg: Config, source_image_paths: list[str]) -> None:
    """Ensure these source images (paths relative to DATA_ROOT) exist on disk."""
    c = _c(cfg)
    missing = [p for p in source_image_paths if not cfg.paths.abs(p).exists()]
    if not missing:
        return
    raw_dir = _data_path(cfg, c.raw_dir)
    prefix = Path(c.raw_dir).as_posix() + "/"
    log.info("Extracting %d images from %s", len(missing), c.images_zip)
    with zipfile.ZipFile(raw_dir / c.images_zip) as z:
        # Zip members are "img_align_celeba/<file>", relative to raw_dir.
        z.extractall(raw_dir, members=[p[len(prefix):] for p in missing])


def load_annotations(cfg: Config) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Return (source_images, attributes) tables in the generic schema."""
    c = _c(cfg)
    ident = pd.read_csv(
        _data_path(cfg, c.identity_file), sep=r"\s+", header=None, names=["file", "source_identity_id"], dtype=str
    )
    lms = pd.read_csv(_data_path(cfg, c.landmarks_file), sep=r"\s+", skiprows=2, header=None, names=["file", *LANDMARK_COLS])
    bbox = pd.read_csv(
        _data_path(cfg, c.bbox_file), sep=r"\s+", skiprows=2, header=None, names=["file", "x", "y", "orig_face_w", "orig_face_h"]
    )
    with open(_data_path(cfg, c.attr_file), encoding="utf-8") as f:
        f.readline()
        attr_names = f.readline().split()
    attrs = pd.read_csv(_data_path(cfg, c.attr_file), sep=r"\s+", skiprows=2, header=None, names=["file", *attr_names])

    df = ident.merge(lms, on="file", how="left").merge(bbox[["file", "orig_face_w", "orig_face_h"]], on="file", how="left")
    stem = df["file"].str.rsplit(".", n=1).str[0]
    df["image_id"] = f"{SOURCE}_" + stem
    df["identity_id"] = f"{SOURCE}_" + df["source_identity_id"]
    df["source_dataset"] = SOURCE
    df["session_id"] = pd.NA
    df["source_image_path"] = (Path(c.images_dir).as_posix() + "/") + df["file"]
    cols = ["image_id", "identity_id", "source_dataset", "source_identity_id", "session_id", "source_image_path", *LANDMARK_COLS, "orig_face_w", "orig_face_h"]
    df = df[cols].sort_values("image_id").reset_index(drop=True)

    attrs["image_id"] = f"{SOURCE}_" + attrs["file"].str.rsplit(".", n=1).str[0]
    attrs = attrs[["image_id", *attr_names]].copy()
    attrs[attr_names] = (attrs[attr_names] > 0).astype(int)  # CelebA uses -1/1
    return df, attrs.sort_values("image_id").reset_index(drop=True)


def prepare(cfg: Config) -> pd.DataFrame:
    download(cfg)
    src, attrs = load_annotations(cfg)
    n_missing_lm = int(src[LANDMARK_COLS].isna().any(axis=1).sum())
    if n_missing_lm:
        log.warning("%d images have no landmarks; they will fail preprocessing", n_missing_lm)
    write_csv_atomic(src, cfg.paths.source_images)
    write_csv_atomic(attrs, cfg.paths.manifests / "celeba_attributes.csv")
    log.info(
        "CelebA: %d images, %d identities -> %s",
        len(src),
        src["identity_id"].nunique(),
        cfg.paths.rel(cfg.paths.source_images),
    )
    return src
