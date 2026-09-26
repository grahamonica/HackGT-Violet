"""Label every query crop with SearchUsersByImage.

Queries come from work/queries.csv (make_queries) for identities whose
enrollment is done, minus any image actually enrolled. Each call sends the
final stored crop bytes (clean or degraded)
with a very low UserMatchThreshold and QualityFilter=NONE so that
low-confidence, poor-quality, and ambiguous outcomes are all kept.

Every final outcome (ok / no_face) is appended to labels/rekognition_raw.jsonl
with the full response. Transient failures are retried with backoff; images
that still fail go to labels/failures.jsonl and are retried on the next run.
Already-labeled images are always skipped, so interrupting is safe.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import pandas as pd
from botocore.exceptions import ClientError
from tqdm import tqdm

from .aws import RETRY_COUNTS, RateLimiter, call_with_retry, error_code, list_user_ids, make_client, strip_meta
from .enroll_rekognition import PRICE_PER_CALL_USD, confirm_cost, enrolled_image_ids, load_enrollment_state
from .utils import Config, JsonlWriter, iter_jsonl, log, log_failure, read_csv

FINAL_STATUSES = ("ok", "no_face")


def query_pool(cfg: Config) -> pd.DataFrame:
    """Query images (one row each) for identities whose enrollment is done."""
    paths = cfg.paths
    state = load_enrollment_state(cfg)
    enrolled_ids = {i for i, r in state.items() if r.get("status") == "done"}
    enrolled_imgs = enrolled_image_ids({i: state[i] for i in enrolled_ids})
    q = read_csv(paths.work / "queries.csv")
    # A query can only have become an enrollment image if IndexFaces fell back to a backup.
    return q[q.identity_id.isin(enrolled_ids) & ~q.image_id.isin(enrolled_imgs)]


def labeled_image_ids(cfg: Config) -> set[str]:
    return {r["image_id"] for r in iter_jsonl(cfg.paths.rekognition_raw) if r.get("status") in FINAL_STATUSES}


def _is_no_face(e: ClientError) -> bool:
    msg = e.response.get("Error", {}).get("Message", "").lower()
    return error_code(e) == "InvalidParameterException" and "face" in msg


def _label_one(cfg, client, limiter, row, gallery_size) -> dict:
    a = cfg.aws
    params = {
        "CollectionId": a.collection_id,
        "UserMatchThreshold": float(a.search_user_match_threshold),
        "MaxUsers": int(a.search_max_users),
        "QualityFilter": a.search_quality_filter,
    }
    rec = {
        "image_id": row.image_id,
        "identity_id": row.identity_id,
        "crop_path": row.crop_path,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "region": a.region,
        "gallery_size": gallery_size,
        "request": params,
    }
    image = cfg.paths.abs(row.crop_path).read_bytes()
    try:
        resp = call_with_retry(cfg, limiter, client.search_users_by_image, Image={"Bytes": image}, **params)
        rec.update(status="ok", response=strip_meta(resp))
    except ClientError as e:
        if not _is_no_face(e):
            raise
        rec.update(status="no_face", response=None, error=e.response.get("Error", {}).get("Message"))
    return rec


def label(cfg: Config, dry_run: bool = False, yes: bool = False) -> None:
    paths = cfg.paths
    pool = query_pool(cfg)
    done = labeled_image_ids(cfg)
    todo = pool[~pool.image_id.isin(done)].sort_values("image_id")
    log.info("Label: %d query images, %d already labeled, %d to label", len(pool), len(pool) - len(todo), len(todo))
    if dry_run:
        log.info("[dry-run] would make %d SearchUsersByImage calls (~$%.2f)", len(todo), len(todo) * PRICE_PER_CALL_USD)
        return
    if todo.empty or not confirm_cost(cfg, len(todo), yes):
        return

    client = make_client(cfg)
    limiter = RateLimiter(float(cfg.aws.max_requests_per_second))
    gallery_size = len(list_user_ids(cfg, client, limiter))
    log.info("Gallery size: %d users in %s", gallery_size, cfg.aws.collection_id)

    counts = {"ok": 0, "no_face": 0, "error": 0}
    with JsonlWriter(paths.rekognition_raw) as out, JsonlWriter(paths.failures) as fails, \
            ThreadPoolExecutor(int(cfg.aws.max_workers)) as ex:
        futs = {ex.submit(_label_one, cfg, client, limiter, r, gallery_size): r for r in todo.itertuples()}
        bar = tqdm(as_completed(futs), total=len(futs), desc="label", unit="img")
        for fut in bar:
            r = futs[fut]
            try:
                rec = fut.result()
                out.write(rec)
                counts[rec["status"]] += 1
            except Exception as e:  # noqa: BLE001 - logged; retried on next run
                counts["error"] += 1
                log_failure(fails, "label", r.image_id, f"{type(e).__name__}: {e}", identity_id=r.identity_id)
            bar.set_postfix(counts, refresh=False)
    log.info("Label done: %s", counts)
    log.info("Transient retries (throttling etc.): %s", dict(RETRY_COUNTS) or "none")
