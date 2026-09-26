"""Evaluation metrics (numpy/pandas only).

- spearman: rank correlation between predicted quality and the target
- auroc: how well quality separates Rekognition top-1 correct (1) from wrong (0)
- ERC (error-versus-reject): drop the lowest-quality fraction of queries, measure
  Rekognition's top-1 error on the rest. The standard FIQA evaluation; lower is
  better, and it directly answers "if we only send the frames the model likes,
  how often is Rekognition wrong?"
"""

from __future__ import annotations

import numpy as np
import pandas as pd

ERC_FRACTIONS = np.round(np.arange(0.0, 0.501, 0.01), 2)
ERC_REPORT = (0.0, 0.05, 0.1, 0.2, 0.3)


def spearman(a: np.ndarray, b: np.ndarray) -> float:
    a, b = pd.Series(a).rank().to_numpy(), pd.Series(b).rank().to_numpy()
    if a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def pearson(a: np.ndarray, b: np.ndarray) -> float:
    a, b = np.asarray(a, float), np.asarray(b, float)
    if a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def auroc(score: np.ndarray, label: np.ndarray) -> float:
    """P(score of a random positive > score of a random negative); ties count half."""
    score, label = np.asarray(score, float), np.asarray(label).astype(bool)
    n_pos, n_neg = label.sum(), (~label).sum()
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    ranks = pd.Series(score).rank().to_numpy()
    return float((ranks[label].sum() - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg))


def erc(score: np.ndarray, correct: np.ndarray, fractions: np.ndarray = ERC_FRACTIONS) -> np.ndarray:
    """Top-1 error after rejecting the lowest-scoring `f` of queries, per fraction."""
    order = np.argsort(np.asarray(score, float), kind="stable")
    wrong = 1.0 - np.asarray(correct, float)[order]
    n = len(wrong)
    # suffix_err[k] = error rate of the items remaining after rejecting k.
    suffix_sum = np.cumsum(wrong[::-1])[::-1]
    out = []
    for f in fractions:
        k = min(int(np.floor(f * n)), n - 1)
        out.append(suffix_sum[k] / (n - k))
    return np.array(out)


def erc_auc(score: np.ndarray, correct: np.ndarray, max_reject: float = 0.2) -> float:
    """Mean top-1 error over reject fractions in [0, max_reject]. Lower is better."""
    fr = ERC_FRACTIONS[ERC_FRACTIONS <= max_reject + 1e-9]
    return float(np.mean(erc(score, correct, fr)))


def _core(pred: np.ndarray, y: np.ndarray, correct: np.ndarray) -> dict:
    out = {
        "n": int(len(pred)),
        "spearman": spearman(pred, y),
        "pearson": pearson(pred, y),
        "auroc_correct": auroc(pred, correct),
        "top1_error": float(1.0 - np.mean(correct)),
    }
    if len(pred) > 1:
        out["erc_auc_20"] = erc_auc(pred, correct, 0.2)
        # Same curve for a perfect ranking (by the target itself): the best achievable.
        out["erc_auc_20_oracle_target"] = erc_auc(y, correct, 0.2)
        curve = erc(pred, correct, np.array(ERC_REPORT))
        out["erc"] = {f"reject_{int(f * 100)}": float(e) for f, e in zip(ERC_REPORT, curve)}
    return out


def evaluate_predictions(pred: np.ndarray, df: pd.DataFrame) -> dict:
    """Metrics overall, on clean vs degraded queries, and per degradation type."""
    pred = np.asarray(pred, float)
    y = df["y"].to_numpy(float)
    correct = df["correct"].to_numpy(float)
    res = {"all": _core(pred, y, correct)}
    if "augmentation_applied" in df:
        aug = df["augmentation_applied"].to_numpy() == 1
        for name, mask in (("clean", ~aug), ("degraded", aug)):
            if mask.sum() > 1:
                res[name] = _core(pred[mask], y[mask], correct[mask])
        res["by_augmentation_type"] = {
            t: _core(pred[m], y[m], correct[m])
            for t, m in ((t, (df["augmentation_type"] == t).to_numpy()) for t in sorted(df["augmentation_type"].dropna().unique()))
            if m.sum() > 1
        }
    return res
