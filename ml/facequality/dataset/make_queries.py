"""Choose each identity's query images and assign synthetic degradations.

Per identity (all randomness seeded by dataset seed + identity/image id):
  1. pool = clean crops that are not selected enrollment references
  2. keep at most max_queries_per_identity of them (seeded shuffle)
  3. degrade round(degrade_fraction * n) of the kept queries, but always leave
     at least min_clean_per_identity clean
  4. degradation types are dealt from a per-identity shuffled cycle of all
     types (so type is balanced within, and independent of, identity);
     severity and exact parameters are drawn per image

At most one degradation per query. Degradations never change geometry (see
degrade.py); every written file's size is checked against the clean crop.
Clean queries reuse the clean crop file; degraded ones are written next to it
as <image_id>__<type>-<severity>.jpg. Resumable: existing files are reused
because assignments and parameters are deterministic.

Output: work/queries.csv
"""

from __future__ import annotations

import json
import os
import random
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
import pandas as pd
from tqdm import tqdm

from . import degrade
from .preprocess_faces import crop_metadata, save_jpeg
from .utils import CROP_LANDMARK_COLS, Config, log, read_csv, stable_hash, write_csv_atomic


def _plan(cfg: Config, pre: pd.DataFrame, sel: pd.DataFrame) -> pd.DataFrame:
    qc = cfg.queries
    n_enroll = int(cfg.enrollment.num_images)
    types = list(qc.types)
    sevs = list(qc.severities)
    ok_ids = sel.identity_id[sel.status == "ok"]
    enroll = {getattr(r, f"enroll_image_{k}") for r in sel.itertuples() for k in range(1, n_enroll + 1)
              if isinstance(getattr(r, f"enroll_image_{k}", None), str)}
    cap = cfg.selection.get("max_queries_per_identity")
    rows = []
    for ident in sorted(ok_ids):
        rng = random.Random(f"{cfg.random_seed}-queries-{ident}")
        pool = sorted(pre.image_id[(pre.identity_id == ident) & ~pre.image_id.isin(enroll)])
        rng.shuffle(pool)
        if cap is not None:
            pool = pool[: int(cap)]
        n = len(pool)
        n_deg = min(int(round(float(qc.degrade_fraction) * n)), max(0, n - int(qc.min_clean_per_identity)))
        order = pool[:]
        rng.shuffle(order)
        deck = types[:]
        rng.shuffle(deck)
        assigned = {img: (deck[k % len(deck)], rng.choice(sevs)) for k, img in enumerate(order[:n_deg])}
        for img in sorted(pool):
            t, s = assigned.get(img, ("none", None))
            rows.append({"image_id": img, "identity_id": ident, "augmentation_type": t, "augmentation_severity": s})
    return pd.DataFrame(rows)


def make_queries(cfg: Config, workers: int | None = None) -> pd.DataFrame:
    paths = cfg.paths
    qc = cfg.queries
    pre = read_csv(paths.preprocessing)
    pre = pre[pre.preprocess_status == "ok"]
    sel = read_csv(paths.enrollment_selection)
    plan = _plan(cfg, pre, sel).merge(pre, on=["image_id", "identity_id"], how="left")
    spec = {k: dict(v) for k, v in qc.params.items()}

    def build(r) -> dict:
        out = {"image_id": r.image_id, "source_image_id": r.image_id, "identity_id": r.identity_id,
               "clean_crop_path": r.crop_path, "augmentation_type": r.augmentation_type,
               "augmentation_severity": r.augmentation_severity}
        clean = cv2.imread(str(paths.abs(r.crop_path)), cv2.IMREAD_COLOR)
        if clean is None:
            raise ValueError(f"unreadable clean crop {r.crop_path}")
        lm = np.array([getattr(r, c) for c in CROP_LANDMARK_COLS], dtype=np.float64).reshape(5, 2)
        if r.augmentation_type == "none":
            out.update(crop_path=r.crop_path, augmentation_applied=0, augmentation_params=None)
            final = clean
        else:
            rng = np.random.default_rng(stable_hash(cfg.random_seed, "degrade", r.image_id))
            params = degrade.sample_params(r.augmentation_type, r.augmentation_severity, spec,
                                           float(qc.param_jitter), float(r.face_w), rng)
            rel = r.crop_path[: -len(".jpg")] + f"__{r.augmentation_type}-{r.augmentation_severity}.jpg"
            dst = paths.abs(rel)
            if not dst.exists():
                img, quality = degrade.apply(clean, r.augmentation_type, params)
                save_jpeg(img, dst, quality or cfg.crop.jpeg_quality)
            final = cv2.imread(str(dst), cv2.IMREAD_COLOR)
            if final is None or final.shape != clean.shape:
                raise AssertionError(f"degraded crop {rel} does not match clean crop geometry")
            out.update(crop_path=rel, augmentation_applied=1, augmentation_params=json.dumps(params, sort_keys=True))
        out.update(crop_metadata(final, lm))  # stats describe the stored (final) crop
        return out

    with ThreadPoolExecutor(workers or os.cpu_count()) as ex:
        rows = list(tqdm(ex.map(build, plan.itertuples()), total=len(plan), desc="queries", unit="img"))
    df = pd.DataFrame(rows).sort_values("image_id").reset_index(drop=True)
    write_csv_atomic(df, paths.work / "queries.csv")
    counts = df.augmentation_type.value_counts().to_dict()
    log.info("Queries: %d for %d identities; degraded %.1f%%; types %s",
             len(df), df.identity_id.nunique(), 100 * df.augmentation_applied.mean(), counts)
    return df
