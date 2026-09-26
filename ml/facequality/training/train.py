"""Train one quality model: a backbone in `frozen` (head only, on cached
features) or `finetune` (head + last N backbone stages, end to end) mode.

Model selection uses the val split only (early stopping on val Spearman).
The test split is touched by `evaluate.py`, never here.

    python -m ml.facequality.training.train --backbone r50 --mode frozen
    python -m ml.facequality.training.train --backbone mbf --mode finetune --set train.lr=1e-4
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
import yaml

from .backbones import BACKBONES
from .config import (
    config_hash,
    get_device,
    load_config,
    parse_overrides,
    resolve_paths,
    run_config,
    seed_everything,
    setup_logging,
)
from .data import FaceQualityDataset, load_dataset_info, load_queries, split_frame
from .features import Progress, cached_embeddings, make_loader, predict
from .metrics import evaluate_predictions, spearman
from .model import QualityModel

log = logging.getLogger("fiqa.training")

PREDICTION_COLS = ["image_id", "identity_id", "split", "augmentation_type", "augmentation_severity", "y", "correct", "interocular"]


def loss_fn(logits: torch.Tensor, y: torch.Tensor, train_cfg: dict) -> torch.Tensor:
    if train_cfg["loss"] == "bce":
        return F.binary_cross_entropy_with_logits(logits.float(), y)
    if train_cfg["loss"] == "huber":
        return F.huber_loss(torch.sigmoid(logits.float()), y, delta=float(train_cfg["huber_delta"]))
    raise ValueError(f"Unknown loss {train_cfg['loss']!r}")


def warmup_cosine(optimizer: torch.optim.Optimizer, warmup_steps: int, total_steps: int) -> torch.optim.lr_scheduler.LambdaLR:
    def factor(step: int) -> float:
        if step < warmup_steps:
            return (step + 1) / warmup_steps
        progress = (step - warmup_steps) / max(1, total_steps - warmup_steps)
        return 0.5 * (1.0 + math.cos(math.pi * min(1.0, progress)))

    return torch.optim.lr_scheduler.LambdaLR(optimizer, factor)


def make_optimizer(model: QualityModel, train_cfg: dict) -> torch.optim.Optimizer:
    lr, wd = float(train_cfg["lr"]), float(train_cfg["weight_decay"])
    groups = [{"params": list(model.head.parameters()), "lr": lr}]
    backbone_params = [p for p in model.backbone.parameters() if p.requires_grad]
    if backbone_params:
        groups.append({"params": backbone_params, "lr": lr * float(train_cfg["backbone_lr_mult"])})
    return torch.optim.AdamW(groups, weight_decay=wd)


def save_json(obj, path: Path) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, default=float), encoding="utf-8")
    tmp.replace(path)


def train_run(cfg: dict, run_dir: Path, resume: bool = True) -> dict:
    """Train one configuration into `run_dir`. Returns the val metrics."""
    run_dir.mkdir(parents=True, exist_ok=True)
    paths = resolve_paths(cfg)
    tc = cfg["train"]
    seed_everything(int(cfg["seed"]))
    device = get_device(cfg.get("device", "auto"))
    n_unfreeze = int(tc["unfreeze_stages"])
    log.info("run %s: backbone=%s mode=%s unfreeze=%d device=%s", run_dir.name, cfg["backbone"], cfg["mode"], n_unfreeze, device)

    with open(run_dir / "config.yaml", "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False)

    q = load_queries(paths, cfg["data"])
    train_df, val_df = split_frame(q, "train"), split_frame(q, "val")
    log.info("train %d rows / %d identities; val %d rows / %d identities", len(train_df), train_df.identity_id.nunique(), len(val_df), val_df.identity_id.nunique())

    model = QualityModel(cfg["backbone"], cfg["model"], paths.weights)
    model.set_trainable_stages(n_unfreeze)
    model.to(device)

    if n_unfreeze == 0:
        # Frozen backbone: train the head on cached embeddings.
        tr_feats = torch.from_numpy(cached_embeddings(model, train_df, paths, cfg, device, "train")).to(device)
        va_feats_np = cached_embeddings(model, val_df, paths, cfg, device, "val")
        tr_io = torch.tensor(train_df["interocular"].to_numpy(np.float32)).to(device)
        tr_y = torch.tensor(train_df["y"].to_numpy(np.float32)).to(device)
        bs = int(tc["batch_size"])
        steps_per_epoch = math.ceil(len(train_df) / bs)
        gen = torch.Generator(device="cpu").manual_seed(int(cfg["seed"]))

        def train_batches(epoch: int):
            perm = torch.randperm(len(train_df), generator=gen).to(device)
            for i in range(0, len(perm), bs):
                idx = perm[i : i + bs]
                if len(idx) < 2:  # BatchNorm needs >1 sample
                    continue
                yield model.head_forward(tr_feats[idx], tr_io[idx]), tr_y[idx]

        def val_scores() -> np.ndarray:
            return predict(model, val_df, paths, cfg, device, feats=va_feats_np)

        use_amp = False
    else:
        train_ds = FaceQualityDataset(train_df, paths, cfg["align"], augment=True, seed=int(cfg["seed"]))
        bs = int(tc["batch_size"])
        loader = make_loader(train_ds, bs, int(cfg["data"]["num_workers"]), device, shuffle=True, seed=int(cfg["seed"]))
        steps_per_epoch = len(loader)
        use_amp = bool(tc.get("amp", True)) and device.type == "cuda"

        def train_batches(epoch: int):
            train_ds.set_epoch(epoch)
            progress = Progress(f"epoch {epoch} train", len(train_ds))
            for images, io, y, _idx in loader:
                progress.update(len(y))
                if len(y) < 2:
                    continue
                images, io, y = images.to(device, non_blocking=True), io.to(device), y.to(device)
                with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=use_amp):
                    logits = model(images, io)
                yield logits, y

        def val_scores() -> np.ndarray:
            with torch.autocast(device_type=device.type, dtype=torch.float16, enabled=use_amp):
                return predict(model, val_df, paths, cfg, device)

    optimizer = make_optimizer(model, tc)
    epochs = int(tc["epochs"])
    scheduler = warmup_cosine(optimizer, int(float(tc["warmup_epochs"]) * steps_per_epoch), epochs * steps_per_epoch)
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    state = {"epoch": 0, "best": -math.inf, "best_epoch": -1, "bad_epochs": 0, "history": []}
    last_path, best_path = run_dir / "last.pt", run_dir / "best.pt"
    if resume and last_path.exists():
        ck = torch.load(last_path, map_location=device, weights_only=False)
        if ck.get("config_hash") == config_hash(cfg):
            model.load_state_dict(ck["model"], strict=False)
            optimizer.load_state_dict(ck["optimizer"])
            scheduler.load_state_dict(ck["scheduler"])
            scaler.load_state_dict(ck["scaler"])
            state = ck["state"]
            log.info("resumed from epoch %d (best val spearman %.4f)", state["epoch"], state["best"])
        else:
            log.warning("last.pt was written with a different config; starting fresh")

    patience = int(tc["patience"])
    while state["epoch"] < epochs and state["bad_epochs"] < patience:
        epoch = state["epoch"]
        t0 = time.time()
        model.train()
        losses = []
        for logits, y in train_batches(epoch):
            loss = loss_fn(logits, y, tc)
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            scheduler.step()
            losses.append(loss.item())
        val_rho = spearman(val_scores(), val_df["y"].to_numpy())
        improved = val_rho > state["best"]
        if improved:
            state.update(best=val_rho, best_epoch=epoch, bad_epochs=0)
            torch.save(
                {"model": model.trainable_state_dict(), "backbone": cfg["backbone"], "unfreeze_stages": n_unfreeze, "config": cfg, "epoch": epoch},
                best_path,
            )
        else:
            state["bad_epochs"] += 1
        state["history"].append({"epoch": epoch, "train_loss": float(np.mean(losses)), "val_spearman": val_rho, "seconds": round(time.time() - t0, 1)})
        state["epoch"] = epoch + 1
        log.info("epoch %3d  loss %.4f  val spearman %.4f%s", epoch, np.mean(losses), val_rho, "  *" if improved else "")
        torch.save(
            {
                "model": model.trainable_state_dict(),
                "optimizer": optimizer.state_dict(),
                "scheduler": scheduler.state_dict(),
                "scaler": scaler.state_dict(),
                "state": state,
                "config_hash": config_hash(cfg),
            },
            last_path,
        )

    # Final val evaluation with the best checkpoint.
    model.load_state_dict(torch.load(best_path, map_location=device, weights_only=False)["model"], strict=False)
    scores = val_scores()
    val_metrics = evaluate_predictions(scores, val_df)
    preds = val_df[PREDICTION_COLS].copy()
    preds["pred"] = scores
    preds.to_csv(run_dir / "val_predictions.csv", index=False)
    info = load_dataset_info(paths)
    save_json(
        {
            "backbone": cfg["backbone"],
            "mode": cfg["mode"],
            "config_hash": config_hash(cfg),
            "dataset": {"config_hash": info.get("config_hash"), "created_at": info.get("created_at")},
            "best_epoch": state["best_epoch"],
            "epochs_run": state["epoch"],
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "history": state["history"],
            "val": val_metrics,
        },
        run_dir / "metrics.json",
    )
    last_path.unlink(missing_ok=True)  # optimizer state no longer needed
    a = val_metrics["all"]
    log.info("done: val spearman %.4f  auroc %.4f  erc_auc_20 %.4f", a["spearman"], a["auroc_correct"], a.get("erc_auc_20", float("nan")))
    return val_metrics


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=None, help="base config (default: configs/default.yaml)")
    ap.add_argument("--backbone", required=True, choices=list(BACKBONES))
    ap.add_argument("--mode", required=True, choices=["frozen", "finetune"])
    ap.add_argument("--set", nargs="*", default=[], metavar="KEY=VALUE", help="config overrides, e.g. train.lr=1e-4")
    ap.add_argument("--name", default=None, help="run directory name under runs_dir")
    ap.add_argument("--no-resume", action="store_true")
    args = ap.parse_args(argv)
    setup_logging()

    cfg = run_config(load_config(args.config), args.backbone, args.mode, parse_overrides(args.set))
    name = args.name or f"{args.backbone}-{args.mode}-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    train_run(cfg, resolve_paths(cfg).runs / name, resume=not args.no_resume)


if __name__ == "__main__":
    main()
