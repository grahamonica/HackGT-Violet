"""Face crops + cheap per-image metadata.

No detector is run: every source provides 5-point landmarks (CelebA ships
them). crop.mode selects how the model/Rekognition input is produced:

  none   use the source image as-is (CelebA's aligned 178x218 images);
         crop_path == source_image_path and no new file is written
  align  similarity-warp onto the ArcFace 5-point template at crop_size,
         written to crops/<source>/<identity_id>/<image_id>.jpg

Mediocre faces are kept on purpose; only images whose file or landmarks are
unusable are logged as failures. Resumable: rows already in
work/preprocessing.csv whose crop exists are skipped.
"""

from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
import pandas as pd
from tqdm import tqdm

from .prepare_celeba import LANDMARK_COLS
from .sources import SOURCES
from .utils import (
    Config,
    JsonlWriter,
    align_face,
    dhash,
    face_region_stats,
    log,
    log_failure,
    pose_proxies,
    read_csv,
    write_csv_atomic,
)

CHECKPOINT_EVERY = 2000


def crop_rel_path(cfg: Config, row: pd.Series) -> str:
    if cfg.crop.mode == "none":
        return row.source_image_path
    return f"crops/{row.source_dataset}/{row.identity_id}/{row.image_id}.jpg"


def _process_one(cfg: Config, row: pd.Series) -> dict:
    paths = cfg.paths
    crop_cfg = cfg.crop
    out = {"image_id": row.image_id, "identity_id": row.identity_id, "crop_path": crop_rel_path(cfg, row)}
    lm = row[LANDMARK_COLS].to_numpy(dtype=np.float64).reshape(5, 2)
    if np.isnan(lm).any():
        raise ValueError("missing landmarks")
    img = cv2.imread(str(paths.abs(row.source_image_path)), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f"unreadable image {row.source_image_path}")

    if crop_cfg.mode == "none":
        crop, oof = img, 0.0
    elif crop_cfg.mode == "align":
        crop, oof = align_face(img, lm, crop_cfg.crop_size, crop_cfg.face_scale)
        dst = paths.abs(out["crop_path"])
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_suffix(".tmp.jpg")
        if not cv2.imwrite(str(tmp), crop, [cv2.IMWRITE_JPEG_QUALITY, int(crop_cfg.jpeg_quality)]):
            raise IOError(f"failed to write {dst}")
        os.replace(tmp, dst)
    else:
        raise ValueError(f"unknown crop.mode {crop_cfg.mode!r}")

    out.update(pose_proxies(lm))
    out.update(face_region_stats(img, lm))
    out["out_of_frame_frac"] = oof
    out["dhash"] = f"{dhash(crop):016x}"
    out["preprocess_status"] = "ok"
    return out


def preprocess(cfg: Config, workers: int | None = None) -> pd.DataFrame:
    paths = cfg.paths
    splits = read_csv(paths.splits)
    src = read_csv(paths.source_images)
    todo_src = src[src.identity_id.isin(set(splits.identity_id))]

    done = read_csv(paths.preprocessing) if paths.preprocessing.exists() else pd.DataFrame(columns=["image_id"])
    ok_done = done[done.get("preprocess_status", pd.Series(dtype=str)).eq("ok")]
    ok_done = ok_done[ok_done.crop_path.map(lambda p: paths.abs(p).exists())] if len(ok_done) else ok_done
    have = set(ok_done.image_id)
    todo = todo_src[~todo_src.image_id.isin(have)]
    log.info("Preprocess: %d images for %d identities, %d already done, %d to do",
             len(todo_src), len(splits), len(have), len(todo))

    for source, g in todo.groupby("source_dataset"):
        SOURCES[source].materialize(cfg, g.source_image_path.tolist())

    results: list[dict] = ok_done.to_dict("records")
    n_fail = 0

    def run(row: pd.Series) -> dict:
        try:
            return _process_one(cfg, row)
        except Exception as e:  # noqa: BLE001 - logged per image, never fatal
            return {"image_id": row.image_id, "identity_id": row.identity_id, "crop_path": crop_rel_path(cfg, row),
                    "preprocess_status": "failed", "error": str(e)}

    with JsonlWriter(paths.failures) as fails, ThreadPoolExecutor(workers or os.cpu_count()) as ex:
        rows = (r for _, r in todo.iterrows())
        for i, res in enumerate(tqdm(ex.map(run, rows), total=len(todo), desc="crops", unit="img"), 1):
            if res["preprocess_status"] == "failed":
                n_fail += 1
                log_failure(fails, "preprocess", res["image_id"], res.pop("error"))
            results.append(res)
            if i % CHECKPOINT_EVERY == 0:
                write_csv_atomic(pd.DataFrame(results), paths.preprocessing)

    df = pd.DataFrame(results)
    # Only keep rows for currently selected identities, in a stable order.
    df = df[df.image_id.isin(set(todo_src.image_id))].sort_values("image_id").reset_index(drop=True)
    write_csv_atomic(df, paths.preprocessing)
    log.info("Preprocess done: %d ok, %d failed this run", int((df.preprocess_status == "ok").sum()), n_fail)
    return df
