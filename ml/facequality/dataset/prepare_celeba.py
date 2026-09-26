"""CelebA (in-the-wild) source adapter.

Annotations (small text files, fetched if missing):
  identity_CelebA.txt          filename -> identity
  list_bbox_celeba.txt         face bbox, original-image coordinates
  list_landmarks_celeba.txt    5 points, original-image coordinates
  list_eval_partition.txt      which mirror zip holds each file
  list_attr_celeba.txt         40 binary attributes (optional metadata)

Images are the original `img_celeba` photos, stored in three zips on the
Hugging Face mirror (celebA_{train,val,test}.zip, ~9.7 GB total). They are never
downloaded whole: `materialize` range-reads only the files of selected
identities (about one HTTP request per image).

Generic source columns written to work/source_images.csv (adding another
source means emitting these same columns):
    image_id, identity_id, source_dataset, source_identity_id, session_id,
    source_image_path, bbox_x, bbox_y, bbox_w, bbox_h, lm_{0..4}_{x,y}
All coordinates are original-image pixels.
"""

from __future__ import annotations

import json
import struct
import threading
import zipfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd
from tqdm import tqdm

from .utils import BBOX_COLS, LANDMARK_COLS, Config, log, write_csv_atomic, write_json_atomic

SOURCE = "celeba"
PARTITION_ZIPS = {0: "celebA_train.zip", 1: "celebA_val.zip", 2: "celebA_test.zip"}
_LOCAL_HEADER = struct.Struct("<4s5H3I2H")  # zip local file header, 30 bytes


def _c(cfg: Config):
    return cfg.source.celeba


def _p(cfg: Config, rel: str) -> Path:
    return cfg.paths.data / rel


def download_annotations(cfg: Config) -> None:
    """Fetch the small annotation files if missing (never the image zips)."""
    from huggingface_hub import hf_hub_download

    c = _c(cfg)
    for key, repo, repo_path in (
        ("identity_file", c.identity_repo, "identity_CelebA.txt"),
        ("attr_file", c.identity_repo, "list_attr_celeba.txt"),
        ("bbox_file", c.wild_repo, "data/list_bbox_celeba.txt"),
        ("landmarks_file", c.wild_repo, "data/list_landmarks_celeba.txt"),
        ("partition_file", c.wild_repo, "data/list_eval_partition.txt"),
    ):
        dst = _p(cfg, c[key])
        if dst.exists():
            continue
        log.info("Downloading %s from hf://datasets/%s", repo_path, repo)
        got = Path(hf_hub_download(repo, repo_path, repo_type="dataset", local_dir=dst.parent / ".hf"))
        dst.parent.mkdir(parents=True, exist_ok=True)
        got.replace(dst)


def _table(path: Path, names: list[str]) -> pd.DataFrame:
    return pd.read_csv(path, sep=r"\s+", skiprows=2, header=None, names=names)


def load_annotations(cfg: Config) -> tuple[pd.DataFrame, pd.DataFrame]:
    c = _c(cfg)
    ident = pd.read_csv(_p(cfg, c.identity_file), sep=r"\s+", header=None, names=["file", "source_identity_id"], dtype=str)
    bbox = _table(_p(cfg, c.bbox_file), ["file", *BBOX_COLS])
    lms = _table(_p(cfg, c.landmarks_file), ["file", *LANDMARK_COLS])
    part = pd.read_csv(_p(cfg, c.partition_file), sep=r"\s+", header=None, names=["file", "partition"])

    # Join by filename (the mirror's loader script pairs rows positionally, which is wrong for val/test).
    df = ident.merge(bbox, on="file").merge(lms, on="file").merge(part, on="file")
    stem = df["file"].str.rsplit(".", n=1).str[0]
    df["image_id"] = f"{SOURCE}_" + stem
    df["identity_id"] = f"{SOURCE}_" + df["source_identity_id"]
    df["source_dataset"] = SOURCE
    df["session_id"] = pd.NA
    df["source_image_path"] = (Path(c.images_dir).as_posix() + "/") + df["file"]
    cols = ["image_id", "identity_id", "source_dataset", "source_identity_id", "session_id",
            "source_image_path", *BBOX_COLS, *LANDMARK_COLS, "partition"]
    df = df[cols].sort_values("image_id").reset_index(drop=True)

    with open(_p(cfg, c.attr_file), encoding="utf-8") as f:
        f.readline()
        attr_names = f.readline().split()
    attrs = _table(_p(cfg, c.attr_file), ["file", *attr_names])
    attrs["image_id"] = f"{SOURCE}_" + attrs["file"].str.rsplit(".", n=1).str[0]
    attrs = attrs[["image_id", *attr_names]].copy()
    attrs[attr_names] = (attrs[attr_names] > 0).astype(int)  # CelebA uses -1/1
    return df, attrs.sort_values("image_id").reset_index(drop=True)


def prepare(cfg: Config) -> pd.DataFrame:
    download_annotations(cfg)
    src, attrs = load_annotations(cfg)
    bad = (src.bbox_w <= 0) | (src.bbox_h <= 0) | src[LANDMARK_COLS].isna().any(axis=1)
    if bad.any():
        log.warning("Dropping %d images with an empty bbox or missing landmarks", int(bad.sum()))
        src = src[~bad].reset_index(drop=True)
    write_csv_atomic(src, cfg.paths.source_images)
    write_csv_atomic(attrs, cfg.paths.manifests / "celeba_attributes.csv")
    log.info("CelebA in-the-wild: %d images, %d identities -> %s",
             len(src), src["identity_id"].nunique(), cfg.paths.rel(cfg.paths.source_images))
    return src


# ---------------------------------------------------------------------------
# Selective image fetching from the remote zips
# ---------------------------------------------------------------------------


def _remote(cfg: Config, zip_name: str) -> str:
    return f"datasets/{_c(cfg).wild_repo}/data/{zip_name}"


def _zip_index(cfg: Config, fs, zip_name: str) -> dict[str, list[int]]:
    """{filename: [header_offset, compress_size, compress_type]} for one remote zip (cached)."""
    cache = cfg.paths.work / f"zipindex_{zip_name}.json"
    if cache.exists():
        return json.loads(cache.read_text())
    log.info("Reading central directory of %s", zip_name)
    with fs.open(_remote(cfg, zip_name), "rb", block_size=1 << 20) as f:
        idx = {Path(i.filename).name: [i.header_offset, i.compress_size, i.compress_type]
               for i in zipfile.ZipFile(f).infolist() if not i.is_dir()}
    write_json_atomic(idx, cache)
    return idx


def _fetch_member(fs, remote: str, offset: int, csize: int, ctype: int) -> bytes:
    # Local header = 30 bytes + name + extra. Over-read 1 KiB so one request usually suffices.
    blob = fs.cat_file(remote, start=offset, end=offset + _LOCAL_HEADER.size + 1024 + csize)
    fields = _LOCAL_HEADER.unpack(blob[: _LOCAL_HEADER.size])
    if fields[0] != b"PK\x03\x04":
        raise ValueError("bad zip local header")
    start = _LOCAL_HEADER.size + fields[-2] + fields[-1]
    if start + csize > len(blob):
        blob = fs.cat_file(remote, start=offset, end=offset + start + csize)
    data = blob[start : start + csize]
    if ctype == zipfile.ZIP_STORED:
        return data
    if ctype == zipfile.ZIP_DEFLATED:
        return zlib.decompress(data, -15)
    raise ValueError(f"unsupported zip compression {ctype}")


def materialize(cfg: Config, source_image_paths: list[str], workers: int = 16) -> None:
    """Ensure these source images (paths relative to DATA_ROOT) exist on disk."""
    missing = sorted({p for p in source_image_paths if not cfg.paths.abs(p).exists()})
    if not missing:
        return
    from huggingface_hub import HfFileSystem

    src = pd.read_csv(cfg.paths.source_images, usecols=["source_image_path", "partition"])
    part = dict(zip(src.source_image_path, src.partition))
    fs = HfFileSystem()
    indexes = {z: _zip_index(cfg, fs, z) for z in {PARTITION_ZIPS[part[p]] for p in missing}}
    lock = threading.Lock()
    failed: list[str] = []

    def fetch(p: str) -> None:
        zip_name = PARTITION_ZIPS[part[p]]
        for attempt in range(4):
            try:
                data = _fetch_member(fs, _remote(cfg, zip_name), *indexes[zip_name][Path(p).name])
                dst = cfg.paths.abs(p)
                dst.parent.mkdir(parents=True, exist_ok=True)
                tmp = dst.with_suffix(".part")
                tmp.write_bytes(data)
                tmp.replace(dst)
                return
            except Exception:  # noqa: BLE001 - transient network errors; retried
                if attempt == 3:
                    with lock:
                        failed.append(p)

    log.info("Fetching %d in-the-wild images from hf://datasets/%s", len(missing), _c(cfg).wild_repo)
    with ThreadPoolExecutor(workers) as ex:
        list(tqdm(ex.map(fetch, missing), total=len(missing), desc="fetch", unit="img"))
    if failed:
        log.warning("%d images could not be fetched (they will fail preprocessing): %s", len(failed), failed[:5])
