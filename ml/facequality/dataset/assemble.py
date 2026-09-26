"""Build the contract outputs described in SCHEMA.md from stage intermediates.

This is the only stage that writes manifests/{identities,images,enrollment}.csv,
dataset/queries.csv and dataset/dataset_info.json. It makes no AWS calls: all
Rekognition columns are derived from labels/rekognition_raw.jsonl, so it can
be rerun at any time (e.g. after a schema tweak) for free.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pandas as pd

from .enroll_rekognition import load_enrollment_state
from .label_rekognition import FINAL_STATUSES
from .utils import SCHEMA_VERSION, Config, iter_jsonl, log, read_csv, write_csv_atomic, write_json_atomic

PROVENANCE = ["image_id", "identity_id", "source_dataset", "source_identity_id", "session_id", "split",
              "crop_path", "source_image_path"]
IMAGE_META = ["yaw_proxy", "pitch_proxy", "roll_deg", "orig_face_w", "orig_face_h", "out_of_frame_frac",
              "sharpness", "brightness", "contrast"]
AWS_COLS = ["aws_status", "aws_gallery_size", "aws_num_faces", "aws_num_candidates",
            "aws_top1_id", "aws_top1_similarity", "aws_top2_id", "aws_top2_similarity",
            "aws_true_rank", "aws_true_similarity", "aws_best_wrong_id", "aws_best_wrong_similarity",
            "aws_correct_top1", "aws_true_returned",
            "aws_face_confidence", "aws_face_sharpness", "aws_face_brightness",
            "aws_face_yaw", "aws_face_pitch", "aws_face_roll", "aws_face_model_version"]
QUERY_COLS = PROVENANCE + IMAGE_META + AWS_COLS
INT_COLS = ["orig_face_w", "orig_face_h", "aws_gallery_size", "aws_num_faces", "aws_num_candidates",
            "aws_true_rank", "aws_correct_top1", "aws_true_returned", "num_images", "num_enrollment",
            "num_query", "aws_enrolled", "is_enrollment"]


def flatten_label(rec: dict, identity_id: str) -> dict:
    """One raw SearchUsersByImage record -> flat aws_* columns (missing == None)."""
    out: dict = {"aws_status": rec["status"], "aws_gallery_size": rec.get("gallery_size")}
    if rec["status"] == "no_face":
        return out | {"aws_num_faces": 0, "aws_num_candidates": 0, "aws_correct_top1": 0, "aws_true_returned": 0}

    resp = rec.get("response") or {}
    matches = sorted(resp.get("UserMatches", []), key=lambda m: -m["Similarity"])
    ids = [m["User"]["UserId"] for m in matches]
    sims = [float(m["Similarity"]) for m in matches]
    wrong = [(i, s) for i, s in zip(ids, sims) if i != identity_id]
    true_rank = ids.index(identity_id) + 1 if identity_id in ids else None

    searched = resp.get("SearchedFace") or {}
    fd = searched.get("FaceDetail") or {}
    quality, pose = fd.get("Quality") or {}, fd.get("Pose") or {}
    out.update(
        aws_num_faces=(1 if searched else 0) + len(resp.get("UnsearchedFaces", [])),
        aws_num_candidates=len(ids),
        aws_top1_id=ids[0] if ids else None,
        aws_top1_similarity=sims[0] if sims else None,
        aws_top2_id=ids[1] if len(ids) > 1 else None,
        aws_top2_similarity=sims[1] if len(sims) > 1 else None,
        aws_true_rank=true_rank,
        aws_true_similarity=sims[true_rank - 1] if true_rank else None,
        aws_best_wrong_id=wrong[0][0] if wrong else None,
        aws_best_wrong_similarity=wrong[0][1] if wrong else None,
        aws_correct_top1=int(bool(ids) and ids[0] == identity_id),
        aws_true_returned=int(true_rank is not None),
        aws_face_confidence=fd.get("Confidence"),
        aws_face_sharpness=quality.get("Sharpness"),
        aws_face_brightness=quality.get("Brightness"),
        aws_face_yaw=pose.get("Yaw"),
        aws_face_pitch=pose.get("Pitch"),
        aws_face_roll=pose.get("Roll"),
        aws_face_model_version=resp.get("FaceModelVersion"),
    )
    return out


def _latest_labels(cfg: Config) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for rec in iter_jsonl(cfg.paths.rekognition_raw):
        if rec.get("status") in FINAL_STATUSES:
            latest[rec["image_id"]] = rec
    return latest


def _label_errors(cfg: Config) -> set[str]:
    return {r["image_id"] for r in iter_jsonl(cfg.paths.failures) if r.get("stage") == "label" and r.get("image_id")}


def _as_int(df: pd.DataFrame) -> pd.DataFrame:
    for c in INT_COLS:
        if c in df:
            df[c] = pd.to_numeric(df[c], errors="coerce").astype("Int64")
    return df


def assemble(cfg: Config) -> pd.DataFrame:
    paths = cfg.paths
    n_enroll = int(cfg.enrollment.num_images)
    splits = read_csv(paths.splits)
    src = read_csv(paths.source_images)
    pre = read_csv(paths.preprocessing)
    sel = read_csv(paths.enrollment_selection)
    state = load_enrollment_state(cfg)

    # Enrollment images: what AWS actually has if enrolled, else the planned selection.
    enroll_rows, enroll_role = [], {}
    for r in sel.itertuples():
        rec = state.get(r.identity_id)
        enrolled = rec is not None and rec.get("status") == "done"
        if enrolled:
            faces = [(f["image_id"], f["role"], f["face_id"]) for f in rec["faces"]]
        elif r.status == "ok":
            faces = [(getattr(r, f"enroll_image_{k}"), getattr(r, f"enroll_role_{k}"), None)
                     for k in range(1, n_enroll + 1) if isinstance(getattr(r, f"enroll_image_{k}", None), str)]
        else:
            faces = []
        row = {"identity_id": r.identity_id, "split": r.split, "aws_user_id": r.identity_id if enrolled else None}
        for k in range(1, n_enroll + 1):
            img, role, fid = faces[k - 1] if k <= len(faces) else (None, None, None)
            row |= {f"enroll_image_{k}": img, f"enroll_role_{k}": role, f"aws_face_id_{k}": fid}
            if img:
                enroll_role[img] = role
        row["_enrolled"] = int(enrolled)
        enroll_rows.append(row)
    enrollment = pd.DataFrame(enroll_rows)

    # images.csv: every image of a selected identity.
    images = (pre.drop(columns=["identity_id"])
              .merge(src.drop(columns=[c for c in src if c.startswith("lm_")]), on="image_id")
              .merge(splits[["identity_id", "split"]], on="identity_id"))
    images["is_enrollment"] = images.image_id.isin(enroll_role).astype(int)
    images["enroll_role"] = images.image_id.map(enroll_role)
    ok_ids = set(sel.identity_id[sel.status == "ok"])
    write_csv_atomic(_as_int(images[PROVENANCE + IMAGE_META + ["is_enrollment", "enroll_role", "preprocess_status"]]
                             .sort_values("image_id")), paths.manifests / "images.csv")

    # queries.csv
    q = images[(images.preprocess_status == "ok") & (images.is_enrollment == 0) & images.identity_id.isin(ok_ids)]
    labels, errors = _latest_labels(cfg), _label_errors(cfg)
    flat = []
    for r in q.itertuples():
        if r.image_id in labels:
            flat.append(flatten_label(labels[r.image_id], r.identity_id))
        else:
            flat.append({"aws_status": "error" if r.image_id in errors else "pending"})
    aws = pd.DataFrame(flat, index=q.index).reindex(columns=AWS_COLS)
    queries = _as_int(pd.concat([q, aws], axis=1)[QUERY_COLS].sort_values("image_id").reset_index(drop=True))
    paths.dataset.mkdir(parents=True, exist_ok=True)
    write_csv_atomic(queries, paths.dataset / "queries.csv")

    # identities.csv / enrollment.csv
    n_q = queries.groupby("identity_id").size()
    n_e = images[images.is_enrollment == 1].groupby("identity_id").size()
    ids = splits.drop(columns=["order"]).merge(sel[["identity_id", "status"]], on="identity_id", how="left")
    ids["status"] = ids.status.fillna("pending")
    ids["num_enrollment"] = ids.identity_id.map(n_e).fillna(0)
    ids["num_query"] = ids.identity_id.map(n_q).fillna(0)
    ids = ids.merge(enrollment[["identity_id", "aws_user_id", "_enrolled"]], on="identity_id", how="left")
    ids = ids.rename(columns={"_enrolled": "aws_enrolled"})
    ids = ids[["identity_id", "source_dataset", "source_identity_id", "split", "status", "num_images",
               "num_enrollment", "num_query", "aws_user_id", "aws_enrolled"]]
    write_csv_atomic(_as_int(ids), paths.manifests / "identities.csv")
    enroll_cols = ["identity_id", "split", "aws_user_id"] + [f"{p}_{k}" for p in ("enroll_image", "enroll_role", "aws_face_id")
                                                             for k in range(1, n_enroll + 1)]
    write_csv_atomic(enrollment[enrollment.identity_id.isin(ok_ids)][enroll_cols], paths.manifests / "enrollment.csv")

    # dataset_info.json
    labeled = queries[queries.aws_status.isin(FINAL_STATUSES)]
    gallery = labeled.aws_gallery_size.dropna().unique().tolist()
    fmv = queries.aws_face_model_version.dropna().unique().tolist()
    info = {
        "schema_version": SCHEMA_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "config_hash": cfg.hash(),
        "random_seed": cfg.random_seed,
        "sources": sorted(images.source_dataset.unique().tolist()),
        "crop": ({"mode": "none", "note": "source images used as-is (CelebA aligned, 178x218)", "format": "jpeg"}
                 if cfg.crop.mode == "none" else
                 {"mode": "align", "size": int(cfg.crop.crop_size), "face_scale": float(cfg.crop.face_scale),
                  "template": "arcface_5pt_112", "format": "jpeg",
                  "tight_face_box_px": int(round(cfg.crop.crop_size * cfg.crop.face_scale))}),
        "aws": {"region": cfg.aws.region, "collection_id": cfg.aws.collection_id,
                "face_model_versions": fmv, "gallery_sizes": sorted(int(g) for g in gallery),
                "search_params": {"UserMatchThreshold": cfg.aws.search_user_match_threshold,
                                  "MaxUsers": cfg.aws.search_max_users,
                                  "QualityFilter": cfg.aws.search_quality_filter}},
        "counts": {
            s: {"identities": int(((ids.split == s) & (ids.status == "ok")).sum()),
                "queries": int((queries.split == s).sum()),
                "labeled": int((labeled.split == s).sum())}
            for s in ("train", "val", "test")
        },
        "aws_status_counts": queries.aws_status.value_counts().to_dict(),
    }
    write_json_atomic(info, paths.dataset / "dataset_info.json")
    if len(gallery) > 1:
        log.warning("Queries were labeled against different gallery sizes %s; see aws_gallery_size", gallery)
    log.info("Assembled: %d queries (%s) -> %s", len(queries), info["aws_status_counts"],
             paths.rel(paths.dataset / "queries.csv"))
    return queries
