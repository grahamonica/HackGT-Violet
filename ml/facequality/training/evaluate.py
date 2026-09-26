"""Evaluate trained runs, and summarize a directory of runs.

    # test-set metrics for chosen runs (writes <run>/test_metrics.json + test_predictions.csv)
    python -m ml.facequality.training.evaluate --run runs/r50-frozen-... [--split test]

    # val-metric table over all finished runs under a directory (for picking configs)
    python -m ml.facequality.training.evaluate --summary runs/sweep1
"""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

import pandas as pd
import torch
import yaml

from .config import get_device, resolve_paths, setup_logging
from .data import load_queries, split_frame
from .features import predict
from .metrics import evaluate_predictions
from .model import QualityModel
from .train import PREDICTION_COLS, save_json

log = logging.getLogger("fiqa.training")


def load_run(run_dir: Path, device: torch.device) -> tuple[QualityModel, dict]:
    """Rebuild a trained model: pretrained backbone + the run's trained weights."""
    run_dir = Path(run_dir)
    with open(run_dir / "config.yaml", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    ck = torch.load(run_dir / "best.pt", map_location="cpu", weights_only=False)
    model = QualityModel(ck["backbone"], cfg["model"], resolve_paths(cfg).weights)
    model.set_trainable_stages(int(ck["unfreeze_stages"]))
    missing, unexpected = model.load_state_dict(ck["model"], strict=False)
    expected = set(model.trainable_state_dict())
    if unexpected or (expected - set(ck["model"])):
        raise RuntimeError(f"{run_dir}: checkpoint does not match model (unexpected={unexpected[:5]}, missing={sorted(expected - set(ck['model']))[:5]})")
    return model.to(device).eval(), cfg


def evaluate_run(run_dir: Path, split: str, device: torch.device) -> dict:
    model, cfg = load_run(run_dir, device)
    df = split_frame(load_queries(resolve_paths(cfg), cfg["data"]), split)
    scores = predict(model, df, resolve_paths(cfg), cfg, device)
    metrics = evaluate_predictions(scores, df)
    preds = df[PREDICTION_COLS].copy()
    preds["pred"] = scores
    preds.to_csv(Path(run_dir) / f"{split}_predictions.csv", index=False)
    save_json(metrics, Path(run_dir) / f"{split}_metrics.json")
    a = metrics["all"]
    log.info("%s [%s] spearman %.4f  auroc %.4f  erc_auc_20 %.4f (oracle %.4f)", Path(run_dir).name, split, a["spearman"], a["auroc_correct"], a["erc_auc_20"], a["erc_auc_20_oracle_target"])
    return metrics


def summarize(root: Path) -> pd.DataFrame:
    rows = []
    for mpath in sorted(Path(root).rglob("metrics.json")):
        m = json.loads(mpath.read_text(encoding="utf-8"))
        if "val" not in m:
            continue
        cfg = yaml.safe_load((mpath.parent / "config.yaml").read_text(encoding="utf-8"))
        v = m["val"]
        rows.append(
            {
                "run": mpath.parent.relative_to(root).as_posix(),
                "backbone": m["backbone"],
                "mode": m["mode"],
                "seed": cfg["seed"],
                "lr": cfg["train"]["lr"],
                "wd": cfg["train"]["weight_decay"],
                "loss": cfg["train"]["loss"],
                "hidden": cfg["model"]["head_hidden"],
                "dropout": cfg["model"]["head_dropout"],
                "unfreeze": cfg["train"]["unfreeze_stages"],
                "best_epoch": m["best_epoch"],
                "val_spearman": v["all"]["spearman"],
                "val_auroc": v["all"]["auroc_correct"],
                "val_erc_auc_20": v["all"].get("erc_auc_20"),
                "val_spearman_clean": v.get("clean", {}).get("spearman"),
            }
        )
    return pd.DataFrame(rows).sort_values(["backbone", "mode", "val_spearman"], ascending=[True, True, False]) if rows else pd.DataFrame()


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--run", nargs="+", type=Path, help="run directories to evaluate")
    g.add_argument("--summary", type=Path, help="directory of runs to tabulate (val metrics)")
    ap.add_argument("--split", default="test", choices=["train", "val", "test"])
    ap.add_argument("--device", default="auto")
    args = ap.parse_args(argv)
    setup_logging()

    if args.summary:
        df = summarize(args.summary)
        if df.empty:
            log.warning("no finished runs under %s", args.summary)
            return
        df.to_csv(args.summary / "summary.csv", index=False)
        with pd.option_context("display.max_rows", 200, "display.width", 200, "display.float_format", "{:.4f}".format):
            print(df.to_string(index=False))
        return
    device = get_device(args.device)
    for run_dir in args.run:
        evaluate_run(run_dir, args.split, device)


if __name__ == "__main__":
    main()
