"""Lightweight sanity report + HTML contact sheet for a random identity sample.

Reads only the contract outputs (plus failure/count logs). Writes
report/report.json, report/report.md and report/preview.html.
"""

from __future__ import annotations

import html
import json
import random

import pandas as pd

from .utils import Config, iter_jsonl, log, read_csv, write_json_atomic

QUANTILES = [0.05, 0.25, 0.5, 0.75, 0.95]


def _dist(s: pd.Series) -> dict:
    s = s.dropna()
    if s.empty:
        return {"n": 0}
    return {"n": int(len(s)), "mean": round(float(s.mean()), 2),
            **{f"p{int(q * 100)}": round(float(s.quantile(q)), 2) for q in QUANTILES}}


def _hist(s: pd.Series, edges=(0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99, 100.01)) -> dict:
    c = pd.cut(s.dropna(), bins=list(edges), right=False).value_counts().sort_index()
    return {f"[{iv.left:g},{min(iv.right, 100):g})": int(n) for iv, n in c.items()}


def build_report(cfg: Config) -> dict:
    p = cfg.paths
    r = cfg.report
    ids = read_csv(p.manifests / "identities.csv")
    images = read_csv(p.manifests / "images.csv")
    q = read_csv(p.dataset / "queries.csv")
    counts = json.loads((p.work / "identity_counts.json").read_text())
    fails = list(iter_jsonl(p.failures))
    lab = q[q.aws_status == "ok"]
    labeled = q[q.aws_status.isin(["ok", "no_face"])]

    rep = {
        "identities": {
            "source": counts["source"],
            "eligible": counts["eligible"],
            "selected": counts["selected"],
            "usable": int((ids.status == "ok").sum()),
            "too_few_images": int((ids.status == "too_few_images").sum()),
            **{f"{s}": int(((ids.split == s) & (ids.status == "ok")).sum()) for s in ("train", "val", "test")},
        },
        "images": {
            "crops_ok": int((images.preprocess_status == "ok").sum()),
            "preprocess_failed": int((images.preprocess_status != "ok").sum()),
            "enrollment": int(images.is_enrollment.sum()),
            "queries": len(q),
            "queries_per_split": q.split.value_counts().to_dict(),
            "crops_per_split": images[images.preprocess_status == "ok"].split.value_counts().to_dict(),
        },
        "failures": {
            "preprocess": sum(f["stage"] == "preprocess" for f in fails),
            "enroll": sum(f["stage"].startswith("enroll") for f in fails),
            "label_calls_failed_ever": sum(f["stage"] == "label" for f in fails),
        },
        "aws_status": q.aws_status.value_counts().to_dict(),
        "rekognition": {},
    }
    if len(labeled):
        margin = lab.aws_top1_similarity - lab.aws_top2_similarity.fillna(0)
        rep["rekognition"] = {
            "labeled_queries": len(labeled),
            "gallery_sizes": sorted(labeled.aws_gallery_size.dropna().astype(int).unique().tolist()),
            "top1_accuracy": round(float(labeled.aws_correct_top1.mean()), 4),
            "true_identity_return_rate": round(float(labeled.aws_true_returned.mean()), 4),
            "no_face_rate": round(float((labeled.aws_status == "no_face").mean()), 4),
            "top1_accuracy_per_split": labeled.groupby("split").aws_correct_top1.mean().round(4).to_dict(),
            f"low_confidence_top1_lt_{r.low_similarity_threshold:g}": int((lab.aws_top1_similarity < r.low_similarity_threshold).sum()),
            f"ambiguous_top1_minus_top2_lt_{r.ambiguity_margin:g}": int((margin < r.ambiguity_margin).sum()),
            "true_similarity": _dist(lab.aws_true_similarity),
            "top1_similarity": _dist(lab.aws_top1_similarity),
            "best_wrong_similarity": _dist(lab.aws_best_wrong_similarity),
            "true_similarity_histogram": _hist(lab.aws_true_similarity),
        }
    write_json_atomic(rep, p.report / "report.json")
    (p.report / "report.md").write_text(_markdown(rep), encoding="utf-8")
    _preview(cfg, ids, images, q)
    log.info("Report written to %s (open preview.html for the contact sheet)", p.rel(p.report))
    return rep


def _markdown(rep: dict) -> str:
    lines = ["# Face-quality dataset sanity report", ""]
    for section, vals in rep.items():
        lines += [f"## {section}", ""]
        for k, v in vals.items():
            lines.append(f"- **{k}**: {json.dumps(v) if isinstance(v, (dict, list)) else v}")
        lines.append("")
    return "\n".join(lines)


def _preview(cfg: Config, ids: pd.DataFrame, images: pd.DataFrame, q: pd.DataFrame) -> None:
    r = cfg.report
    ok = sorted(ids.identity_id[ids.status == "ok"])
    sample = random.Random(cfg.random_seed).sample(ok, min(int(r.preview_identities), len(ok)))
    enroll = images[images.is_enrollment == 1]
    cards = []
    for ident in sorted(sample):
        meta = ids[ids.identity_id == ident].iloc[0]
        e = enroll[enroll.identity_id == ident]
        qq = q[q.identity_id == ident].sample(
            n=min(int(r.preview_queries_per_identity), int((q.identity_id == ident).sum())), random_state=cfg.random_seed
        ).sort_values("image_id")
        tiles = []
        for x in e.itertuples():
            tiles.append(_tile(x.crop_path, f"ENROLL · {x.enroll_role}", f"yaw {x.yaw_proxy:+.2f}", "enroll"))
        for x in qq.itertuples():
            if x.aws_status == "ok":
                cls = "hit" if x.aws_correct_top1 == 1 else "miss"
                true_sim = "—" if pd.isna(x.aws_true_similarity) else f"{x.aws_true_similarity:.1f}"
                top = "self" if x.aws_correct_top1 == 1 else x.aws_top1_id
                sub = f"top1 {top} {x.aws_top1_similarity:.1f} · true {true_sim}"
            else:
                cls, sub = "miss" if x.aws_status == "no_face" else "pending", x.aws_status
            tiles.append(_tile(x.crop_path, x.image_id, sub, cls))
        cards.append(
            f'<section><h2>{html.escape(ident)} <small>{meta.split} · {meta.num_query} queries</small></h2>'
            f'<div class="row">{"".join(tiles)}</div></section>'
        )
    doc = f"""<!doctype html><html><head><meta charset="utf-8"><title>FIQA dataset preview</title>
<style>
:root{{--bg:#fafafa;--fg:#222;--muted:#666;--card:#fff;--enroll:#3b6fd8;--hit:#2e9e5b;--miss:#d24a3a;--pending:#aaa}}
@media (prefers-color-scheme:dark){{:root{{--bg:#16181c;--fg:#e8e8e8;--muted:#999;--card:#20232a}}}}
body{{font:13px/1.4 system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:16px}}
section{{background:var(--card);border-radius:8px;padding:10px 12px;margin:0 0 12px}}
h2{{font-size:14px;margin:0 0 8px}} small{{color:var(--muted);font-weight:normal}}
.row{{display:flex;flex-wrap:wrap;gap:8px}} figure{{margin:0;width:128px}}
img{{width:128px;height:128px;border-radius:4px;border:3px solid var(--pending);display:block}}
.enroll img{{border-color:var(--enroll)}} .hit img{{border-color:var(--hit)}} .miss img{{border-color:var(--miss)}}
figcaption{{font-size:11px;color:var(--muted);word-break:break-all}}
</style></head><body>
<h1>FIQA dataset preview <small>blue = enrollment · green = top-1 correct · red = wrong / no face · grey = not labeled</small></h1>
{"".join(cards)}</body></html>"""
    (cfg.paths.report / "preview.html").write_text(doc, encoding="utf-8")


def _tile(crop_path: str, title: str, sub: str, cls: str) -> str:
    return (f'<figure class="{cls}"><img loading="lazy" src="../{html.escape(crop_path)}">'
            f"<figcaption><b>{html.escape(str(title))}</b><br>{html.escape(str(sub))}</figcaption></figure>")
