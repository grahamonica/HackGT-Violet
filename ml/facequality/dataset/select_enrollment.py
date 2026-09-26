"""Automatic, deterministic enrollment/reference selection.

Per identity, from successfully preprocessed images:
  1. gate "sufficiently good" candidates (face size, exposure, roll, yaw <= side
     range max, framing)
  2. score quality as a weighted sum of within-identity percentile ranks
     (sharpness, original face size, exposure), so it is scale-free
  3. pick roles in order:
       frontal: best quality with |yaw| <= frontal_max_abs_yaw
                (else the smallest |yaw| candidate)
       left:    best quality with yaw_proxy in -side_yaw_range
       right:   best quality with yaw_proxy in +side_yaw_range
     then fill any missing slots with the best remaining quality ("fallback").
     Every pick must be >= min_dhash_distance from the ones already chosen.
  4. keep a ranked list of backups; enroll_rekognition uses them if
     Rekognition cannot index a chosen reference.

Identities with fewer than num_images + min_query_images usable crops get
status too_few_images and are skipped by later stages.

No downstream Violet model is involved. Ties break on image_id.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from .utils import Config, hamming, log, read_csv, write_csv_atomic

NUM_BACKUPS = 5


def _quality(g: pd.DataFrame, w: dict) -> pd.Series:
    face_px = np.minimum(g.orig_face_w, g.orig_face_h)
    exposure = -(g.brightness - 128.0).abs()
    ranks = {
        "sharpness": g.sharpness.rank(pct=True),
        "face_size": face_px.rank(pct=True),
        "exposure": exposure.rank(pct=True),
    }
    return sum(float(w.get(k, 0.0)) * v for k, v in ranks.items())


def _select_for_identity(g: pd.DataFrame, e) -> tuple[list[tuple[str, str]], list[str]]:
    g = g.copy()
    g["quality"] = _quality(g, dict(e.quality_weights))
    g["h"] = g.dhash.map(lambda s: int(s, 16))
    g = g.sort_values(["quality", "image_id"], ascending=[False, True])

    lo, hi = e.brightness_range
    good = g[
        (np.minimum(g.orig_face_w, g.orig_face_h) >= e.min_orig_face_px)
        & g.brightness.between(lo, hi)
        & (g.roll_deg.abs() <= e.max_abs_roll_deg)
        & (g.yaw_proxy.abs() <= e.side_yaw_range[1])
        & (g.out_of_frame_frac <= e.max_out_of_frame)
    ]

    chosen: list[tuple[str, str]] = []
    hashes: list[int] = []

    def distinct(r) -> bool:
        return all(hamming(r.h, h) >= e.min_dhash_distance for h in hashes)

    def take(cands: pd.DataFrame, role: str) -> None:
        taken = {c for c, _ in chosen}
        for r in cands.itertuples():
            if r.image_id not in taken and distinct(r):
                chosen.append((r.image_id, role))
                hashes.append(r.h)
                return

    yaw = good.yaw_proxy
    s_lo, s_hi = e.side_yaw_range
    frontal = good[yaw.abs() <= e.frontal_max_abs_yaw]
    if frontal.empty:
        frontal = good.assign(a=yaw.abs()).sort_values(["a", "image_id"])
    take(frontal, "frontal")
    take(good[yaw.between(-s_hi, -s_lo)], "left")
    take(good[yaw.between(s_lo, s_hi)], "right")
    for pool in (good, g):  # fallback: best remaining good, then anything detectable
        while len(chosen) < e.num_images and len(chosen) < len(g):
            before = len(chosen)
            take(pool, "fallback")
            if len(chosen) == before:
                break
    if len(chosen) < e.num_images:  # near-duplicates everywhere: drop the distinctness rule
        taken = {c for c, _ in chosen}
        for r in g.itertuples():
            if len(chosen) >= e.num_images:
                break
            if r.image_id not in taken:
                chosen.append((r.image_id, "fallback"))

    taken = {c for c, _ in chosen}
    backups = [i for i in good.image_id if i not in taken][:NUM_BACKUPS]
    return chosen[: e.num_images], backups


def select(cfg: Config) -> pd.DataFrame:
    paths = cfg.paths
    e = cfg.enrollment
    splits = read_csv(paths.splits)
    pre = read_csv(paths.preprocessing)
    src = read_csv(paths.source_images, usecols=["image_id", "orig_face_w", "orig_face_h"])
    pre = pre[pre.preprocess_status == "ok"].merge(src, on="image_id")

    need = e.num_images + e.min_query_images
    rows = []
    for ident in splits.itertuples():
        g = pre[pre.identity_id == ident.identity_id]
        row = {"identity_id": ident.identity_id, "split": ident.split, "num_usable": len(g)}
        if len(g) < need:
            row["status"] = "too_few_images"
        else:
            chosen, backups = _select_for_identity(g, e)
            row["status"] = "ok"
            for k, (img, role) in enumerate(chosen, 1):
                row[f"enroll_image_{k}"] = img
                row[f"enroll_role_{k}"] = role
            row["backups"] = " ".join(backups)
        rows.append(row)

    df = pd.DataFrame(rows)
    write_csv_atomic(df, paths.enrollment_selection)
    ok = df[df.status == "ok"]
    roles = pd.concat([ok[f"enroll_role_{k}"] for k in range(1, e.num_images + 1)]).value_counts().to_dict()
    log.info("Enrollment: %d identities selected, %d too_few_images; roles %s",
             len(ok), int((df.status != "ok").sum()), roles)
    return df
