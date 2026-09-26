# Violet face-quality models

Predict, from a single face image, **how well AWS Rekognition will identify
it**. The score is in [0, 1]; higher means Rekognition is more likely to return
the right person with high confidence. Use it to pick the best frames before
calling Rekognition.

Latest results and the recommended model: [`RESULTS.md`](RESULTS.md).

Trained on the dataset built by `ml/facequality/dataset` (see its
[README](../dataset/README.md)). This code reads only the contract files
`dataset/queries.csv` + `dataset/dataset_info.json` and the `crop_path` images.

## Models

Three pretrained face-recognition backbones, each trained two ways (6 models):

| backbone | params | pretrained weights | role |
|---|---|---|---|
| `mbf` MobileFaceNet | ~2 M | InsightFace `buffalo_s/w600k_mbf` (WebFace600K) | efficiency-first |
| `edgeface_s` EdgeFace-S (γ=0.5) | 3.65 M | Idiap `EdgeFace-S-GAMMA` | edge middle ground |
| `r50` ArcFace iResNet-50 | ~44 M | InsightFace `buffalo_l/w600k_r50` (WebFace600K) | accuracy-first |

- **`frozen`**: backbone fixed, only the quality head trains (on cached embeddings).
- **`finetune`**: head + the last N backbone stages train end to end
  (backbone LR = `lr * backbone_lr_mult`; frozen stages keep BatchNorm statistics fixed).

```
aligned face (0-255 RGB, 112x112) → [/127.5 − 1] → backbone → 512-d embedding (not L2-normalized)
                                                               ⊕ log(interocular distance, px)
                                        → BatchNorm → Linear → ReLU → Dropout → Linear → logit
quality = sigmoid(logit)
```

The embedding is taken *before* L2 normalization because its norm carries
quality information. The interocular distance tells the head the face's real
resolution, which alignment to 112x112 otherwise hides.

### Input contract (also for on-device use)

1. Get the 5 landmarks — left eye, right eye, nose tip, left mouth corner,
   right mouth corner (image left/right) — in pixels of the image Rekognition
   would receive. Training uses CelebA's annotations; a deployment would use a
   face detector's 5 points, which are noisier (fine-tuning trains with
   landmark jitter partly for this reason).
2. Align with `align.align_face` (similarity transform onto the ArcFace
   112x112 template; faces needing more than 2x shrinking are area-downsampled
   first). A reimplementation must match this.
3. Feed the aligned RGB face as 0-255 floats plus `align.interocular_px` of
   the landmarks. Normalization is inside the model.

### Target

Rekognition's similarity for the true identity is extremely compressed near
100 (median ≈ 99.994), so it is trained in "nines":

```
y = clip(log10(100 / (100 − true_similarity)), 0, 6) / 6      # 99 → 2/6, 99.99 → 4/6
y = 0  if the true identity is not in the top 5, or Rekognition found no face
```

Alternatives via `data.target`: `similarity` (true_similarity / 100) and
`correct_only` (top-1 similarity / 100 if top-1 is correct, else 0). Rows with
`aws_status` other than `ok`/`no_face`, or `landmarks_in_crop = 0`, are excluded.

Loss: `bce` (binary cross-entropy with soft targets, default) or `huber` on the sigmoid output.

### Metrics

Model selection uses **val** only (early stopping on val Spearman); **test** is
used once by `evaluate.py`.

- `spearman` — rank correlation between prediction and target
- `auroc_correct` — how well the score separates Rekognition top-1 correct from wrong
- `erc_auc_20` — error-versus-reject: Rekognition's top-1 error after discarding the
  lowest-scoring 0–20% of queries, averaged (lower is better).
  `erc_auc_20_oracle_target` is the same when ranking by the target itself.
- Everything is also reported for clean vs degraded queries and per degradation type.

## Setup

Uses the shared `violet-ml` environment (`ml/environment.yml`: PyTorch, timm,
OpenCV, onnx/onnxruntime). CUDA is used when available (`device: auto`), CPU otherwise.

Without conda (e.g. notebook services or cloud images that already ship PyTorch):

```bash
pip install timm==1.0.30 opencv-python-headless pandas pyyaml   # training
pip install onnx onnxruntime huggingface_hub                     # prepare_weights only
```

`timm` is pinned because EdgeFace's checkpoint keys depend on its EdgeNeXt code;
a mismatch fails loudly at load time rather than training on wrong weights.

Download and convert the pretrained weights once (needs internet; ~420 MB
download, ~200 MB kept):

```bash
python -m ml.facequality.training.prepare_weights
```

The InsightFace models are converted from their released ONNX files to PyTorch
and checked against onnxruntime. `weights/MANIFEST.json` records sources and
checksums. **All pretrained weights are for non-commercial research only**
(InsightFace model license; EdgeFace CC BY-NC-SA 4.0), as is CelebA.

## Running

All commands run from the repo root.

```bash
# one model
python -m ml.facequality.training.train --backbone r50 --mode frozen
python -m ml.facequality.training.train --backbone mbf --mode finetune --set train.lr=1e-4 train.unfreeze_stages=2

# hyperparameter sweep (configs/sweep.yaml): list, then run all or by index
python -m ml.facequality.training.sweep --list
python -m ml.facequality.training.sweep --all --mode frozen
python -m ml.facequality.training.sweep --index 0 1 2          # any subset, e.g. one index per GPU/job

# compare runs on val, then evaluate the chosen ones on test
python -m ml.facequality.training.evaluate --summary ml/facequality/training/runs/sweep1
python -m ml.facequality.training.evaluate --run ml/facequality/training/runs/sweep1/r50/frozen/<id>-s0
```

Sweep indices are stable and finished runs are skipped, so a sweep can be split
up and simply re-launched after an interruption; fine-tuning also resumes from
`last.pt` within a run. For final numbers, re-run the chosen configs with a few
seeds (`--set seed=1`, …).

### On a new machine

1. **Code:** the `ml/` package (training only imports `ml.facequality.training`).
   Run commands from the directory that contains `ml/`.
2. **Dependencies:** `violet-ml`, or the pip lines above.
3. **Data:** `dataset/queries.csv`, `dataset/dataset_info.json` and the query images
   under `crops/`; point `VIOLET_FIQA_DATA_DIR` at the folder holding them (can be
   read-only).
4. **Weights:** run `prepare_weights` (needs internet once), or copy an existing
   `weights/` folder and point `VIOLET_FIQA_WEIGHTS_DIR` at it if the machine is offline.
5. **Outputs:** point `VIOLET_FIQA_RUNS_DIR` / `VIOLET_FIQA_CACHE_DIR` at writable
   storage that persists (notebook services often only keep one output folder).
6. **Run** the commands above. On multiple GPUs, start one `sweep --index ...` process
   per GPU with `CUDA_VISIBLE_DEVICES` set, splitting the indices from `sweep --list`.

In notebooks, run the commands as shell commands (`!python -m ...`) so their output
streams into the cell. On machines where the notebook has no internet, install
the dependencies and prepare the weights beforehand.

### Configuration

`configs/default.yaml` holds every setting; `modes.frozen` / `modes.finetune`
override it per mode, and `--set key=value` overrides anything per run.

Paths are relative to this directory, or set by environment variable:

| setting | env var | default |
|---|---|---|
| `paths.data_dir` | `VIOLET_FIQA_DATA_DIR` | `../dataset/data` (same variable the dataset builder uses) |
| `paths.weights_dir` | `VIOLET_FIQA_WEIGHTS_DIR` | `weights/` |
| `paths.runs_dir` | `VIOLET_FIQA_RUNS_DIR` | `runs/` |
| `paths.cache_dir` | `VIOLET_FIQA_CACHE_DIR` | `cache/` |

### Outputs (`runs/<name>/`)

| file | contents |
|---|---|
| `config.yaml` | fully resolved config of the run |
| `best.pt` | trained weights only (head + unfrozen stages); the rest comes from the pretrained file |
| `metrics.json` | per-epoch history + val metrics of the best epoch |
| `val_predictions.csv` | per-query val predictions |
| `test_metrics.json`, `test_predictions.csv` | written by `evaluate.py --run` |

Load a trained model with `evaluate.load_run(run_dir, device)`.

**Windows:** DataLoader workers re-import the main script, so when calling the
training functions from your own script, put the calls under
`if __name__ == "__main__":` (the CLIs already do). Each worker also costs ~3 GB
of memory; use `--set data.num_workers=2` on machines with limited RAM.

## Export to Core ML

```bash
python -m ml.facequality.training.export --run ml/facequality/training/runs/sweep1/mbf/finetune/d867b328-s0
```

Writes `exports/FaceQuality.mlpackage` (inputs `face`: RGB 112x112 image, raw
0-255, aligned as in the input contract; `interocular_px`: float32 [1];
output `quality`: float32 [1]) and `exports/FaceQuality_reference/`: test faces
with their crops, landmarks, Python-aligned images and PyTorch scores, for
checking an on-device implementation against this one.

Needs `coremltools` (macOS or Linux/WSL; not native Windows). In WSL or on a
Mac: `conda env create -f ml/environment.yml`, `conda activate violet-ml`,
`pip install coremltools`, then run the command above from the repo root
(tested with coremltools 9.0 and PyTorch 2.14; coremltools warns that it was
only tested up to PyTorch 2.7; the traced model is checked against PyTorch here,
and the Core ML output on a Mac, see below). Linux can convert
but not run Core ML models, so the script only checks the interface there;
numeric parity is checked on a Mac against the reference set. Default precision
is float16 (`--precision float32` to compare). `exports/` is gitignored; the
reference set contains CelebA faces and must stay out of git. The
`.mlpackage` itself is meant to be copied into the iOS package.

## Files

| file | role |
|---|---|
| `align.py` | 5-point ArcFace alignment, landmark jitter |
| `data.py` | contract loading, filtering, target, `Dataset` |
| `backbones/` | the three backbones (`stages()` defines unfreezing groups) |
| `model.py` | `QualityModel` (normalization + backbone + head), freezing |
| `features.py` | embedding extraction/caching, prediction |
| `metrics.py` | Spearman, AUROC, error-versus-reject |
| `train.py` / `sweep.py` / `evaluate.py` | CLIs |
| `prepare_weights.py` | pretrained weight download + ONNX conversion |
| `export.py` | Core ML export + reference set for on-device parity |

`weights/`, `runs/`, `cache/` and `exports/` are generated and gitignored.
