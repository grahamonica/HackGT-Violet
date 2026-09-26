"""Identity filtering, capping, and identity-disjoint split assignment.

Order of operations (per the spec):
  1. group images by identity
  2. keep identities with >= min_images_per_identity images
  3. deterministic seeded shuffle of the eligible list
  4. optionally cap to the first max_identities and/or the shortest prefix
     whose expected query count (images - enrollment, capped at
     max_queries_per_identity) totals >= target_queries
  5. assign splits by position in the shuffled order

Splits are assigned by position using a seeded repeating pattern whose block
length exactly realizes the configured fractions (e.g. 14/3/3 per block of 20
for 0.70/0.15/0.15). Because both the shuffle and the pattern only depend on
the seed and the eligible set, raising max_identities later only *adds*
identities: every previously selected identity keeps its split.
"""

from __future__ import annotations

import math
import random
from fractions import Fraction

import pandas as pd

from .utils import Config, log, read_csv, write_csv_atomic, write_json_atomic

SPLITS = ("train", "val", "test")


def split_pattern(fractions: dict[str, float], seed: int, max_block: int = 100) -> list[str]:
    total = sum(fractions.values())
    if abs(total - 1.0) > 1e-6:
        raise ValueError(f"split fractions must sum to 1, got {total}")
    fr = {k: Fraction(v).limit_denominator(max_block) for k, v in fractions.items()}
    block = math.lcm(*(f.denominator for f in fr.values()))
    counts = {k: int(round(fractions[k] * block)) for k in SPLITS}
    counts["train"] += block - sum(counts.values())
    pattern = [k for k in SPLITS for _ in range(counts[k])]
    random.Random(f"{seed}-split-pattern").shuffle(pattern)
    return pattern


def select_identities(cfg: Config, max_identities: int | None = None, target_queries: int | None = None) -> pd.DataFrame:
    src = read_csv(cfg.paths.source_images)
    sel = cfg.selection
    counts = src.groupby("identity_id").agg(
        source_dataset=("source_dataset", "first"),
        source_identity_id=("source_identity_id", "first"),
        num_images=("image_id", "size"),
    )
    n_source = len(counts)
    eligible = sorted(counts.index[counts["num_images"] >= sel.min_images_per_identity])
    n_eligible = len(eligible)

    rng = random.Random(cfg.random_seed)
    rng.shuffle(eligible)

    # Expected queries per identity: images minus enrollment, capped so a few
    # large identities cannot dominate the query set.
    per_cap = sel.get("max_queries_per_identity")
    exp_q = counts["num_images"] - int(cfg.enrollment.num_images)
    counts["expected_queries"] = exp_q if per_cap is None else exp_q.clip(upper=int(per_cap))

    # Selection = shortest prefix of the seeded order satisfying the limits.
    # A CLI override replaces both config limits.
    if max_identities is not None or target_queries is not None:
        cap, target = max_identities, target_queries
    else:
        cap, target = sel.get("max_identities"), sel.get("target_queries")
    if cap is not None:
        eligible = eligible[: int(cap)]
    if target is not None:
        cum = counts.loc[eligible, "expected_queries"].cumsum().to_numpy()
        eligible = eligible[: int((cum < int(target)).sum()) + 1]

    pattern = split_pattern(
        {"train": cfg.splits.train_fraction, "val": cfg.splits.val_fraction, "test": cfg.splits.test_fraction},
        cfg.random_seed,
    )
    out = counts.loc[eligible].reset_index()
    out.insert(1, "split", [pattern[i % len(pattern)] for i in range(len(out))])
    out.insert(0, "order", range(len(out)))  # position in the seeded shuffle

    write_csv_atomic(out, cfg.paths.splits)
    log.info(
        "Identities: %d source, %d eligible (>= %d images), %d selected: %d images, ~%d queries (%s)",
        n_source,
        n_eligible,
        sel.min_images_per_identity,
        len(out),
        int(out.num_images.sum()),
        int(out.expected_queries.sum()),
        ", ".join(f"{s}={int((out.split == s).sum())}" for s in SPLITS),
    )
    write_json_atomic(
        {"source": n_source, "eligible": n_eligible, "selected": len(out)}, cfg.paths.work / "identity_counts.json"
    )
    return out
