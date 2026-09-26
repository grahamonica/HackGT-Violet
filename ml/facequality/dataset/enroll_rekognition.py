"""Enroll selected references into one Rekognition collection.

For each identity with status ok:
  1. CreateUser  UserId = identity_id (e.g. celeba_1234)
  2. IndexFaces  on each reference crop, ExternalImageId = image_id
     (if Rekognition finds no face, the next backup candidate is tried and
     the failed image stays in the query pool)
  3. AssociateFaces  the indexed FaceIds with the User

Idempotent: existing users, already-indexed faces (matched by
ExternalImageId), and existing associations are reused, never duplicated.
Results are appended to labels/enrollment_aws.jsonl; the latest record per
identity is the source of truth for which images are enrollment images.
"""

from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import pandas as pd
from botocore.exceptions import ClientError
from tqdm import tqdm

from .aws import (
    RateLimiter,
    call_with_retry,
    ensure_collection,
    error_code,
    list_user_ids,
    make_client,
    paginate,
)
from .utils import Config, JsonlWriter, iter_jsonl, log, log_failure, read_csv

PRICE_PER_CALL_USD = 0.001  # approx. Rekognition image API price, first 1M/month


def confirm_cost(cfg: Config, calls: int, yes: bool) -> bool:
    limit = int(cfg.aws.get("confirm_calls_above", 0) or 0)
    if limit and calls > limit and not yes:
        log.error("Refusing to make ~%d Rekognition calls (> aws.confirm_calls_above=%d). "
                  "Rerun with --dry-run to inspect or --yes to proceed.", calls, limit)
        return False
    return True


def load_enrollment_state(cfg: Config) -> dict[str, dict]:
    """Latest enrollment record per identity_id."""
    state: dict[str, dict] = {}
    for rec in iter_jsonl(cfg.paths.enrollment_aws):
        state[rec["identity_id"]] = rec
    return state


def enrolled_image_ids(state: dict[str, dict]) -> set[str]:
    return {f["image_id"] for rec in state.values() for f in rec.get("faces", [])}


def _token(*parts: str) -> str:
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:64]


def _selection_slots(row: pd.Series, n: int) -> tuple[list[tuple[str, str]], list[str]]:
    slots = [(row[f"enroll_image_{k}"], row[f"enroll_role_{k}"]) for k in range(1, n + 1)
             if isinstance(row.get(f"enroll_image_{k}"), str)]
    backups = row["backups"].split() if isinstance(row.get("backups"), str) else []
    return slots, backups


def _enroll_identity(cfg, client, limiter, row, existing_users, faces_by_ext, crop_paths, stage_failures) -> dict:
    a = cfg.aws
    paths = cfg.paths
    uid = row.identity_id  # UserId == identity_id by contract
    cid = a.collection_id

    if uid not in existing_users:
        try:
            call_with_retry(cfg, limiter, client.create_user, no_retry=frozenset({"ConflictException"}),
                            CollectionId=cid, UserId=uid, ClientRequestToken=_token("create", cid, uid))
        except ClientError as e:
            if error_code(e) != "ConflictException":  # Conflict == already exists
                raise

    slots, backups = _selection_slots(row, int(cfg.enrollment.num_images))
    queue = list(backups)
    faces: list[dict] = []
    failed: list[dict] = []
    for image_id, role in slots:
        candidate: str | None = image_id
        while candidate is not None:
            face_id = faces_by_ext.get(candidate)
            if face_id is None:
                crop = paths.abs(crop_paths[candidate]).read_bytes()
                resp = call_with_retry(
                    cfg, limiter, client.index_faces,
                    CollectionId=cid, Image={"Bytes": crop}, ExternalImageId=candidate,
                    MaxFaces=1, QualityFilter=a.index_quality_filter, DetectionAttributes=["DEFAULT"],
                )
                recs = resp.get("FaceRecords", [])
                if recs:
                    face_id = recs[0]["Face"]["FaceId"]
                    faces_by_ext[candidate] = face_id
                else:
                    reasons = [r.get("Reasons") for r in resp.get("UnindexedFaces", [])]
                    failed.append({"image_id": candidate, "role": role, "reason": "no_face_indexed", "detail": reasons})
                    log_failure(stage_failures, "enroll_index", candidate, "no face indexed", reasons=reasons)
            if face_id is not None:
                faces.append({"image_id": candidate, "role": role, "face_id": face_id})
                break
            candidate = queue.pop(0) if queue else None
            role = "fallback"

    # Associate only faces not yet associated with this user.
    already = {f["FaceId"] for f in paginate(cfg, limiter, client.list_faces, "Faces", CollectionId=cid, UserId=uid)}
    to_assoc = [f["face_id"] for f in faces if f["face_id"] not in already]
    unsuccessful: list[dict] = []
    if to_assoc:
        resp = call_with_retry(
            cfg, limiter, client.associate_faces,
            CollectionId=cid, UserId=uid, FaceIds=to_assoc,
            UserMatchThreshold=float(a.associate_user_match_threshold),
            ClientRequestToken=_token("assoc", cid, uid, *sorted(to_assoc)),
        )
        unsuccessful = resp.get("UnsuccessfulFaceAssociations", [])
        for u in unsuccessful:
            log_failure(stage_failures, "enroll_associate", None, ",".join(u.get("Reasons", [])),
                        face_id=u.get("FaceId"), user_id=uid)
    bad = {u.get("FaceId") for u in unsuccessful}
    faces = [f for f in faces if f["face_id"] not in bad]

    return {
        "identity_id": uid,
        "aws_user_id": uid,
        "collection_id": cid,
        "region": a.region,
        "status": "done" if faces else "failed",
        "faces": faces,
        "failed": failed + [{"face_id": u.get("FaceId"), "reason": u.get("Reasons")} for u in unsuccessful],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def enroll(cfg: Config, dry_run: bool = False, yes: bool = False) -> None:
    paths = cfg.paths
    sel = read_csv(paths.enrollment_selection)
    splits = read_csv(paths.splits)[["identity_id", "source_dataset"]]
    sel = sel[sel.status == "ok"].merge(splits, on="identity_id")
    state = load_enrollment_state(cfg)
    todo = sel[~sel.identity_id.map(lambda i: state.get(i, {}).get("status") == "done")]
    n_faces = int(cfg.enrollment.num_images) * len(todo)
    log.info("Enroll: %d identities selected, %d already enrolled, %d to enroll (~%d IndexFaces calls)",
             len(sel), len(sel) - len(todo), len(todo), n_faces)
    calls = len(todo) * (3 + int(cfg.enrollment.num_images))  # create + index*n + list + associate
    if dry_run:
        log.info("[dry-run] would make ~%d Rekognition calls (~$%.2f IndexFaces cost) in %s / %s",
                 calls, n_faces * PRICE_PER_CALL_USD, cfg.aws.region, cfg.aws.collection_id)
        return
    if todo.empty or not confirm_cost(cfg, calls, yes):
        return

    client = make_client(cfg)
    limiter = RateLimiter(float(cfg.aws.max_requests_per_second))
    ensure_collection(cfg, client, limiter)
    existing_users = list_user_ids(cfg, client, limiter)
    all_faces = paginate(cfg, limiter, client.list_faces, "Faces", CollectionId=cfg.aws.collection_id, MaxResults=4096)
    faces_by_ext = {f["ExternalImageId"]: f["FaceId"] for f in all_faces if f.get("ExternalImageId")}
    log.info("Collection has %d users, %d faces", len(existing_users), len(all_faces))
    pre = read_csv(paths.preprocessing)
    crop_paths = dict(zip(pre.image_id, pre.crop_path))

    n_done = n_err = 0
    with JsonlWriter(paths.enrollment_aws) as out, JsonlWriter(paths.failures) as fails, \
            ThreadPoolExecutor(int(cfg.aws.max_workers)) as ex:
        futs = {ex.submit(_enroll_identity, cfg, client, limiter, r, existing_users, faces_by_ext, crop_paths, fails): r.identity_id
                for _, r in todo.iterrows()}
        for fut in tqdm(as_completed(futs), total=len(futs), desc="enroll", unit="id"):
            ident = futs[fut]
            try:
                rec = fut.result()
                out.write(rec)
                n_done += rec["status"] == "done"
            except Exception as e:  # noqa: BLE001 - logged; rerun resumes
                n_err += 1
                log_failure(fails, "enroll", None, f"{type(e).__name__}: {e}", identity_id=ident)
    log.info("Enroll done: %d enrolled, %d errors (see %s)", n_done, n_err, paths.rel(paths.failures))
