# Results — sweep1 (2026-09-26)

**Recommended model: MobileFaceNet, fine-tuned** (`sweep1/mbf/finetune/d867b328-s0`).
Best or tied-best on every test metric, and by far the smallest/fastest backbone.

## Setup

- Dataset `config_hash 54729ce9d82a` (2026-09-26): 570 CelebA identities, split by
  identity into 399 train / 85 val / 86 test (7,034 / 1,430 / 1,524 usable queries).
  Rekognition gallery: 570 users, face model version 7.
- The dataset is **modified from plain CelebA**: crops come from the original
  in-the-wild photos (not the aligned set), and about half the queries are
  synthetically degraded (blur, motion blur, darkening, low contrast, JPEG, noise at
  three severities). Labels are Rekognition's results on exactly those crops,
  degraded ones included. Details: `ml/facequality/dataset/README.md`.
- Target: "nines" of Rekognition's true-identity similarity (see README).
- Sweep: 144 frozen configs (48 per backbone) + 18 fine-tune configs (6 per backbone),
  1 seed. Best config per backbone × mode chosen on **val** Spearman; each evaluated
  **once** on test. Trained on Kaggle (2× T4, ~50 min total).

## Test results

Rekognition's top-1 error on the test queries with no filtering: **4.1%** (62 / 1,524).
"Error after rejecting X%" = top-1 error on the queries left after discarding the X%
the model scores lowest (lower is better).

| backbone | mode | Spearman | AUROC (top-1 correct) | err @ reject 5% | 10% | 20% |
|---|---|---|---|---|---|---|
| **mbf** | **finetune** | **0.627** | **0.786** | **2.76%** | **2.55%** | 2.46% |
| edgeface_s | finetune | 0.601 | 0.759 | 2.83% | 2.77% | 2.38% |
| r50 | finetune | 0.599 | 0.747 | 2.90% | 2.70% | 2.70% |
| mbf | frozen | 0.493 | 0.736 | 2.83% | 2.55% | 2.38% |
| r50 | frozen | 0.361 | 0.683 | 3.11% | 2.84% | 2.54% |
| edgeface_s | frozen | 0.277 | 0.671 | 2.90% | 2.70% | 2.62% |

Ranking perfectly by the target itself would give ≈0.5% mean error over 0–20%
rejection, so there is substantial headroom. Spearman standard error ≈ 0.026:
differences among the fine-tuned models are within noise.

Selected configurations:

| run | lr | unfreeze | head | loss | best epoch / run |
|---|---|---|---|---|---|
| mbf/finetune/d867b328-s0 | 1e-4 | 2 stages | 128, dropout 0.2 | bce | 3 / 9 |
| edgeface_s/finetune/4612058c-s0 | 1e-3 | 2 | 128, 0.2 | bce | 0 / 6 |
| r50/finetune/4612058c-s0 | 1e-3 | 2 | 128, 0.2 | bce | 10 / 16 |
| mbf/frozen/08c4f576-s0 | 3e-3, wd 1e-2 | 0 | 256, 0.3 | huber | 3 / 24 |
| r50/frozen/b81654dc-s0 | 3e-3 | 0 | 256, 0.3 | huber | 51 / 72 |
| edgeface_s/frozen/9da8fc09-s0 | 3e-4 | 0 | 256, 0.0 | huber | 11 / 32 |

## Findings

- **Fine-tuning beats a frozen backbone clearly on ranking** (Spearman 0.60–0.63 vs
  0.28–0.49; val showed the same gap across all configs). On the reject-X% error
  alone the six models are close.
- **Bigger is not better here.** MobileFaceNet (~0.45 GFLOPs) matches or beats
  iResNet-50 (~6 GFLOPs). Frozen, MobileFaceNet's embedding is also the most
  quality-informative of the three.
- **Not just a degradation detector.** On clean queries only, the fine-tuned models
  keep Spearman ≈ 0.44–0.50 (AUROC 0.68–0.75). Strongest on blur and JPEG; weak on
  low contrast and noise, which barely affect Rekognition.
- **Fine-tuning overfits fast.** Most fine-tune runs peaked within 1–4 epochs while
  training loss kept falling, and val-based selection flattered r50 (val 0.68 → test
  0.60). The limit is data: only ~250 Rekognition failures in train.

## Next improvements (by expected impact)

1. More identities (more failures to learn from; also tighter val/test estimates).
2. Lower fine-tune LR (~3e-5) and stronger regularization; 3 seeds per config.
3. On-device validation with detector landmarks instead of CelebA annotations.

## Reproduce

With the same dataset (`config_hash 54729ce9d82a`) and weights (`weights/MANIFEST.json`):

```bash
python -m ml.facequality.training.prepare_weights
python -m ml.facequality.training.sweep --all --mode frozen
python -m ml.facequality.training.sweep --all --mode finetune
python -m ml.facequality.training.evaluate --summary ml/facequality/training/runs/sweep1
python -m ml.facequality.training.evaluate --run <best run per backbone × mode from summary.csv>
```

Seed 0 throughout. GPU kernels are not bit-deterministic, so expect small
differences (the val-selected configs may change where scores are within noise).

## Artifacts

Runs are not in git. `best.pt` for the recommended model is 13 MB and needs the
pretrained `weights/mbf_w600k.pt` (from `prepare_weights`) to rebuild; load with
`evaluate.load_run(run_dir, device)`. Reproduced locally from the Kaggle download:
test predictions match to ≤0.006 (rank correlation 0.99997).
