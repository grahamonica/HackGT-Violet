"""Expand a sweep config into a fixed, indexed list of runs and execute some of
them. Indices are stable (filters never renumber), so they map directly onto
Slurm job-array task ids. Finished runs (metrics.json present) are skipped.

    python -m ml.facequality.training.sweep --list
    python -m ml.facequality.training.sweep --all --mode frozen
    python -m ml.facequality.training.sweep --index 17
"""

from __future__ import annotations

import argparse
import itertools
import logging
from dataclasses import dataclass
from pathlib import Path

import yaml

from .config import MODELS_DIR, config_hash, load_config, parse_overrides, resolve_paths, run_config, setup_logging

log = logging.getLogger("fiqa.training")
DEFAULT_SWEEP = MODELS_DIR / "configs" / "sweep.yaml"


@dataclass
class Run:
    index: int
    backbone: str
    mode: str
    seed: int
    overrides: dict

    @property
    def name(self) -> str:
        return f"{self.backbone}/{self.mode}/{config_hash(self.overrides)[:8]}-s{self.seed}"


def expand(sweep: dict) -> list[Run]:
    runs = []
    for mode, grid in sweep["modes"].items():
        keys = list(grid)
        for backbone in sweep["backbones"]:
            for values in itertools.product(*(grid[k] for k in keys)):
                for seed in sweep["seeds"]:
                    runs.append(Run(len(runs), backbone, mode, seed, {**dict(zip(keys, values)), "seed": seed}))
    return runs


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", type=Path, default=DEFAULT_SWEEP)
    what = ap.add_mutually_exclusive_group(required=True)
    what.add_argument("--list", action="store_true", help="print the indexed run list")
    what.add_argument("--all", action="store_true", help="run every (filtered) run sequentially")
    what.add_argument("--index", type=int, nargs="+", help="run these indices")
    ap.add_argument("--mode", choices=["frozen", "finetune"], help="filter")
    ap.add_argument("--backbone", help="filter")
    ap.add_argument("--set", nargs="*", default=[], metavar="KEY=VALUE", help="extra overrides for every run (e.g. device=cpu)")
    args = ap.parse_args(argv)
    setup_logging()

    sweep = yaml.safe_load(args.sweep.read_text(encoding="utf-8"))
    base = load_config(args.sweep.parent / sweep["base_config"])
    runs = expand(sweep)
    selected = [r for r in runs if (args.mode is None or r.mode == args.mode) and (args.backbone is None or r.backbone == args.backbone)]
    if args.index is not None:
        by_index = {r.index: r for r in runs}
        bad = [i for i in args.index if i not in by_index]
        if bad:
            raise SystemExit(f"indices out of range 0..{len(runs) - 1}: {bad}")
        selected = [by_index[i] for i in args.index]

    if args.list:
        for r in selected:
            print(f"{r.index:4d}  {r.name:40s}  {r.overrides}")
        print(f"{len(selected)} of {len(runs)} runs (indices 0-{len(runs) - 1})")
        return

    from .train import train_run  # deferred: --list doesn't need the training stack

    extra = parse_overrides(args.set)
    for r in selected:
        cfg = run_config(base, r.backbone, r.mode, {**r.overrides, **extra})
        run_dir = resolve_paths(cfg).runs / sweep["name"] / r.name
        if (run_dir / "metrics.json").exists():
            log.info("[%d] %s already finished, skipping", r.index, r.name)
            continue
        log.info("[%d/%d] %s %s", r.index, len(runs) - 1, r.name, r.overrides)
        train_run(cfg, run_dir)


if __name__ == "__main__":
    main()
