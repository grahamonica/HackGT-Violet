"""Face-quality dataset builder CLI.

    python -m ml.facequality.dataset.build_dataset <stage> [options]

Stages (in pipeline order):
    prepare     fetch/parse the source dataset into work/source_images.csv
    split       filter identities, cap, assign identity-disjoint splits
    preprocess  landmark-aligned crops + cheap image metadata
    select      choose enrollment references per identity
    enroll      create Rekognition users, index + associate references   [AWS]
    label       SearchUsersByImage for every query crop                    [AWS]
    assemble    write the SCHEMA.md contract outputs (no AWS calls)
    report      sanity report + HTML preview
    all         everything above, in order

Every stage is idempotent and resumable; rerunning skips finished work.
"""

from __future__ import annotations

import argparse
import sys
import time

from . import assemble, enroll_rekognition, label_rekognition, preprocess_faces, report, select_enrollment, splits
from .sources import SOURCES
from .utils import DEFAULT_CONFIG, Config, load_config, log, setup_logging

AWS_STAGES = {"enroll", "label"}
ORDER = ["prepare", "split", "preprocess", "select", "enroll", "label", "assemble", "report"]


def run_stage(stage: str, cfg: Config, args: argparse.Namespace) -> None:
    if stage == "prepare":
        SOURCES[cfg.source.type].prepare(cfg)
    elif stage == "split":
        splits.select_identities(cfg, args.max_identities, args.target_images)
    elif stage == "preprocess":
        preprocess_faces.preprocess(cfg, args.workers)
    elif stage == "select":
        select_enrollment.select(cfg)
    elif stage == "enroll":
        enroll_rekognition.enroll(cfg, dry_run=args.dry_run, yes=args.yes)
    elif stage == "label":
        label_rekognition.label(cfg, dry_run=args.dry_run, yes=args.yes)
    elif stage == "assemble":
        assemble.assemble(cfg)
    elif stage == "report":
        report.build_report(cfg)
    else:
        raise ValueError(stage)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="build_dataset", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", nargs="?", default="all", choices=ORDER + ["all"])
    ap.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to dataset.yaml")
    ap.add_argument("--max-identities", type=int, default=None,
                    help="cap selected identities after filtering (overrides config; only ever adds identities as it grows)")
    ap.add_argument("--target-images", type=int, default=None,
                    help="take identities in seeded order until their images total >= N (overrides config)")
    ap.add_argument("--dry-run", action="store_true", help="AWS stages: report what would be called and the cost, make no calls")
    ap.add_argument("--yes", action="store_true", help="allow AWS runs larger than aws.confirm_calls_above")
    ap.add_argument("--skip-aws", action="store_true", help="with 'all': skip enroll + label")
    ap.add_argument("--resume", action="store_true", help="accepted for clarity; every stage always resumes")
    ap.add_argument("--workers", type=int, default=None, help="threads for preprocessing (default: CPU count)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    setup_logging(args.verbose)
    cfg = load_config(args.config)
    cfg.paths.ensure()
    log.info("Config %s (hash %s); DATA_ROOT=%s", cfg.path.name, cfg.hash(), cfg.paths.data)

    stages = ORDER if args.stage == "all" else [args.stage]
    if args.skip_aws:
        stages = [s for s in stages if s not in AWS_STAGES]
    for stage in stages:
        t = time.time()
        log.info("=== %s ===", stage)
        run_stage(stage, cfg, args)
        log.info("=== %s done in %.1fs ===", stage, time.time() - t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
