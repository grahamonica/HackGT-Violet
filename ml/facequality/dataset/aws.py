"""Rekognition client construction, rate limiting, and retry with backoff.

Credentials use normal boto3 resolution. If `aws.env_file` exists (default
ml/facequality/dataset/.env) it is loaded into the environment first, without
overriding variables that are already set. Never commit that file.
"""

from __future__ import annotations

import random
import threading
import time
from typing import Any, Callable, TypeVar

from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError, ConnectionError as BotoConnectionError

from .utils import Config, log

T = TypeVar("T")

RETRYABLE_CODES = {
    "ThrottlingException",
    "ProvisionedThroughputExceededException",
    "LimitExceededException",
    "ServiceUnavailableException",
    "InternalServerError",
    "RequestTimeout",
    "RequestTimeoutException",
    "ConflictException",  # user briefly busy (e.g. UPDATING) during association
}


def make_client(cfg: Config):
    import boto3
    from dotenv import load_dotenv

    a = cfg.aws
    env_file = cfg.paths.root / a.get("env_file", ".env")
    if env_file.exists():
        load_dotenv(env_file, override=False)
    session = boto3.Session(profile_name=a.get("profile"), region_name=a.region)
    if session.get_credentials() is None:
        raise RuntimeError(
            "No AWS credentials found. Put AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in "
            f"{env_file} or configure an AWS profile."
        )
    # We do our own retries (below) so botocore's are kept minimal.
    boto_cfg = BotoConfig(retries={"total_max_attempts": 1}, max_pool_connections=max(10, int(a.max_workers) * 2))
    return session.client("rekognition", config=boto_cfg)


class RateLimiter:
    """Simple thread-safe limiter: at most `rate` call starts per second."""

    def __init__(self, rate: float):
        self.interval = 1.0 / rate if rate and rate > 0 else 0.0
        self._next = time.monotonic()
        self._lock = threading.Lock()

    def wait(self) -> None:
        if not self.interval:
            return
        with self._lock:
            now = time.monotonic()
            t = max(now, self._next)
            self._next = t + self.interval
        if t > now:
            time.sleep(t - now)


def error_code(e: Exception) -> str | None:
    return e.response.get("Error", {}).get("Code") if isinstance(e, ClientError) else None


def call_with_retry(
    cfg: Config, limiter: RateLimiter, fn: Callable[..., T], *, no_retry: frozenset[str] = frozenset(), **kwargs: Any
) -> T:
    a = cfg.aws
    attempts = int(a.max_attempts)
    for attempt in range(1, attempts + 1):
        limiter.wait()
        try:
            return fn(**kwargs)
        except (ClientError, BotoConnectionError, BotoCoreError) as e:
            code = error_code(e)
            transient = (code in RETRYABLE_CODES and code not in no_retry) if isinstance(e, ClientError) else True
            if not transient or attempt == attempts:
                raise
            delay = min(float(a.backoff_max_seconds), float(a.backoff_base_seconds) * 2 ** (attempt - 1))
            delay *= 0.5 + random.random()  # jitter
            log.debug("%s on %s (attempt %d/%d); retrying in %.1fs", code or type(e).__name__, fn.__name__, attempt, attempts, delay)
            time.sleep(delay)
    raise AssertionError("unreachable")


def paginate(cfg: Config, limiter: RateLimiter, fn: Callable[..., dict], key: str, **kwargs: Any) -> list[dict]:
    items: list[dict] = []
    token = None
    while True:
        resp = call_with_retry(cfg, limiter, fn, **kwargs, **({"NextToken": token} if token else {}))
        items.extend(resp.get(key, []))
        token = resp.get("NextToken")
        if not token:
            return items


def ensure_collection(cfg: Config, client, limiter: RateLimiter) -> None:
    cid = cfg.aws.collection_id
    try:
        call_with_retry(cfg, limiter, client.describe_collection, CollectionId=cid)
    except ClientError as e:
        if error_code(e) != "ResourceNotFoundException":
            raise
        log.info("Creating Rekognition collection %s in %s", cid, cfg.aws.region)
        call_with_retry(cfg, limiter, client.create_collection, CollectionId=cid)


def list_user_ids(cfg: Config, client, limiter: RateLimiter) -> set[str]:
    users = paginate(cfg, limiter, client.list_users, "Users", CollectionId=cfg.aws.collection_id, MaxResults=500)
    return {u["UserId"] for u in users}


def strip_meta(resp: dict) -> dict:
    return {k: v for k, v in resp.items() if k != "ResponseMetadata"}
