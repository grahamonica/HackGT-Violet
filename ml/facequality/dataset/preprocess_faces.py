"""Clean face crops + crop-relative landmarks + cheap per-image metadata.

For every image of a selected identity:
  1. fetch the original in-the-wild photo if needed (source adapter)
  2. expand the source bbox by crop.margin on every side, clamp to the image
  3. crop that region (no detector, no alignment, no resizing)
  4. convert the 5 source landmarks into crop-relative coordinates
  5. save the crop to crops/<source>/<identity_id>/<image_id>.jpg

These clean crops serve both enrollment and clean queries; degraded queries
are derived from them later (make_queries) without changing their geometry.
Resumable: rows already in work/preprocessing.csv whose crop exists are skipped.
"""

from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
import pandas as pd
from tqdm import tqdm

from .sources import SOURCES
from .utils import (
    BBOX_COLS,
    CROP_LANDMARK_COLS,
    LANDMARK_COLS,
    Config,
    JsonlWriter,
    dhash,
    face_region_stats,
    log,
    log_failure,
    margin_crop_box,
    pose_proxies,
    read_csv,
    write_csv_atomic,
)

CHECKPOINT_EVERY = 2000


def crop_rel_path(row) -> str:
    return f"crops/{row.source_dataset}/{row.identity_id}/{row.image_id}.jpg"


def save_jpeg(img: np.ndarray, dst, quality: int) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp.jpg")
    if not cv2.imwrite(str(tmp), img, [cv2.IMWRITE_JPEG_QUALITY, int(quality)]):
        raise IOError(f"failed to write {dst}")
    os.replace(tmp, dst)


def crop_metadata(crop: np.ndarray, lm_crop: np.ndarray) -> dict:
    """Metadata computed on a stored crop (clean or degraded)."""
    h, w = crop.shape[:2]
    inside = (lm_crop[:, 0] >= 0) & (lm_crop[:, 0] < w) & (lm_crop[:, 1] >= 0) & (lm_crop[:, 1] < h)
    return {
        "crop_width": w,
        "crop_height": h,
        "landmarks_in_crop": int(inside.all()),
        **face_region_stats(crop, lm_crop),
    }


def _process_one(cfg: Config, row) -> dict:
    paths = cfg.paths
    out = {"image_id": row.image_id, "identity_id": row.identity_id, "crop_path": crop_rel_path(row)}
    img = cv2.imread(str(paths.abs(row.source_image_path)), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f"unreadable image {row.source_image_path}")
    src_h, src_w = img.shape[:2]
    bbox = tuple(float(getattr(row, c)) for c in BBOX_COLS)
    x0, y0, x1, y1 = margin_crop_box(bbox, float(cfg.crop.margin), src_w, src_h)
    crop = img[y0:y1, x0:x1]

    lm_src = np.array([getattr(row, c) for c in LANDMARK_COLS], dtype=np.float64).reshape(5, 2)
    lm_crop = lm_src - np.array([x0, y0], dtype=np.float64)

    save_jpeg(crop, paths.abs(out["crop_path"]), cfg.crop.jpeg_quality)

    out.update({"source_width": src_w, "source_height": src_h,
                "crop_x0": x0, "crop_y0": y0,
                "face_w": bbox[2], "face_h": bbox[3]})
    out.update(dict(zip(CROP_LANDMARK_COLS, lm_crop.flatten().tolist())))
    out.update(pose_proxies(lm_crop))
    out.update(crop_metadata(crop, lm_crop))
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

    def run(row) -> dict:
        try:
            return _process_one(cfg, row)
        except Exception as e:  # noqa: BLE001 - logged per image, never fatal
            return {"image_id": row.image_id, "identity_id": row.identity_id, "crop_path": crop_rel_path(row),
                    "preprocess_status": "failed", "error": str(e)}

    with JsonlWriter(paths.failures) as fails, ThreadPoolExecutor(workers or os.cpu_count()) as ex:
        for i, res in enumerate(tqdm(ex.map(run, todo.itertuples()), total=len(todo), desc="crops", unit="img"), 1):
            if res["preprocess_status"] == "failed":
                n_fail += 1
                log_failure(fails, "preprocess", res["image_id"], res.pop("error"))
            results.append(res)
            if i % CHECKPOINT_EVERY == 0:
                write_csv_atomic(pd.DataFrame(results), paths.preprocessing)

    df = pd.DataFrame(results)
    df = df[df.image_id.isin(set(todo_src.image_id))].sort_values("image_id").reset_index(drop=True)
    write_csv_atomic(df, paths.preprocessing)
    log.info("Preprocess done: %d ok, %d failed this run", int((df.preprocess_status == "ok").sum()), n_fail)
    return df
