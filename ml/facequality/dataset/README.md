# Violet face-quality dataset builder

Builds a reproducible, identity-aware dataset for studying **how useful a face
crop is for AWS Rekognition identity matching**. From CelebA's original
in-the-wild photos it produces face crops (bbox + margin), crop-relative
5-point landmarks, identity-disjoint splits, automatically chosen clean
enrollment references, a query set where about half the images are
synthetically degraded, and raw Rekognition search results for every query.

It does **not** align faces, define a training target, or build a model.
Downstream code aligns from crop + landmarks however its model needs. See the
repo-root `SCHEMA.md` for the exact output contract.

## Setup

```bash
conda env create -f ml/environment.yml     # Python 3.11, CUDA 12.6 PyTorch
conda activate violet-ml
```

AWS credentials use normal boto3 resolution. The simplest option is to copy
`.env.example` to `ml/facequality/dataset/.env` and fill in
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. You can also use an AWS profile
(`aws.profile` in the config) or environment variables. The region and
collection are set in `configs/dataset.yaml`. **Never commit `.env` or keys.**
The IAM principal needs `rekognition:CreateCollection, DescribeCollection,
CreateUser, ListUsers, IndexFaces, ListFaces, AssociateFaces,
SearchUsersByImage`.

### CelebA

CelebA is **not** redistributed here. It must be obtained and used under its
own terms (non-commercial research only):
<https://mmlab.ie.cuhk.edu.hk/projects/CelebA.html>. The `prepare` stage
fetches the small annotation files from the Hugging Face mirrors named in
`source.celeba` (`identity_repo`, `wild_repo`). The original photos (~9.7 GB
across three zips) are **never downloaded whole**: `preprocess` range-reads
only the photos of sampled identities into
`data/raw/celeba_in_the_wild/img_celeba/`.

## Running

All commands run from the repo root:

```bash
# 1. Everything local: annotations, sample, fetch + crop, references, queries, assemble, report
python -m ml.facequality.dataset.build_dataset all --skip-aws

# 2. See what AWS would do and roughly what it would cost
python -m ml.facequality.dataset.build_dataset enroll --dry-run
python -m ml.facequality.dataset.build_dataset label --dry-run

# 3. Run AWS stages, then rebuild outputs + report
python -m ml.facequality.dataset.build_dataset enroll
python -m ml.facequality.dataset.build_dataset label
python -m ml.facequality.dataset.build_dataset assemble
python -m ml.facequality.dataset.build_dataset report
```

Or run `all` to do every stage in order. Options:

| flag | effect |
|---|---|
| `--max-identities N` | cap identities after filtering (overrides config; handy for a quick test) |
| `--target-queries N` | take identities in seeded order until expected queries reach N (overrides config) |
| `--dry-run` | AWS stages print planned calls + cost, make no calls |
| `--skip-aws` | with `all`: skip `enroll` and `label` |
| `--yes` | allow AWS runs above `aws.confirm_calls_above` (default 2000 calls) |
| `--workers N` | preprocessing / query-building threads |

Open `data/report/preview.html` in a browser to see the contact sheet.

### Growing the dataset

The config samples identities until about `target_queries: 10000` queries,
with at most `max_queries_per_identity: 20` per identity (about 570 identities).
To grow, raise `target_queries` and rerun `all`. Identities are shuffled once
with the seed and then taken as a prefix. Splits are assigned by position using a
seeded pattern, so **growing only adds identities**: nobody changes split, and
finished crops, enrollments and labels are all reused.

Top-1 correctness depends on how many people are enrolled. Each label records
`aws_gallery_size`. After growing, earlier labels were made against a smaller
gallery. If that matters for your target, relabel them by removing their rows
from `labels/rekognition_raw.jsonl` (the collection itself is reused).

## How it works

| stage | what it does | output |
|---|---|---|
| `prepare` | source adapter → generic per-image table (ids, original bbox, original landmarks) | `work/source_images.csv`, `manifests/celeba_attributes.csv` |
| `split` | keep identities with ≥ `min_images_per_identity`, seeded shuffle, take identities until the query budget is met, assign train/val/test **by identity** | `manifests/splits.csv` |
| `preprocess` | fetch sampled photos; crop bbox + `margin` (clamped); convert landmarks to crop coordinates; pose proxies, sharpness, brightness, contrast | `crops/…`, `work/preprocessing.csv` |
| `select` | per identity: gate on face size/exposure/roll/yaw/landmarks-in-crop, rank by within-identity quality, pick frontal + left + right (yaw proxy), else best distinct fallbacks. Always clean. | `work/enrollment_selection.csv` |
| `queries` | per identity: non-enrollment crops, capped at `max_queries_per_identity`; degrade about `degrade_fraction` of them (at least one clean kept) with one seeded, geometry-preserving degradation each | `crops/…__<type>-<severity>.jpg`, `work/queries.csv` |
| `enroll` | one collection; `CreateUser(celeba_<id>)`, `IndexFaces` on references (backup candidates if no face is indexed), `AssociateFaces` | `labels/enrollment_aws.jsonl` |
| `label` | `SearchUsersByImage` on every final query crop, clean or degraded (`QualityFilter=NONE`, threshold 0, `MaxUsers=5`) | `labels/rekognition_raw.jsonl` |
| `assemble` | builds the contract files from the above, with no AWS calls | `dataset/queries.csv`, `manifests/*.csv`, `dataset_info.json` |
| `report` | counts, accuracy, similarity distributions, HTML contact sheet | `report/` |

Design notes:

- **No face detector and no alignment.** CelebA ships a face bbox and 5-point
  landmarks for every in-the-wild photo. Crops are bbox + margin, and
  landmarks are exposed in crop coordinates for downstream alignment. A future
  source without annotations would add a detector in its adapter. Everything
  after `prepare` only needs the generic columns.
- **Degradations are pixel-value only.** Gaussian blur, motion blur,
  darkening, lower contrast, JPEG compression and additive noise never change
  crop size or the pixel grid (no resize, rotation, warp, translation or
  crop), so landmarks stay valid. This is asserted for every written file.
  Blur strength scales with face width. Parameters are seeded per image and
  stored in `augmentation_params`. Severity is never turned into a quality
  score; Rekognition remains the only teacher.
- **Enrollment is always clean**, matching the real scenario of good
  reference photos at enrollment and variable-quality queries later.
- **Mediocre faces are kept.** Only unreadable images or missing landmarks fail
  preprocessing. Rekognition's own "no face found" is recorded as a label
  (`aws_status = no_face`), not dropped.
- **The crop file is exactly what Rekognition sees**, so labels describe the
  model's input pixels.
- **Resumability and idempotency.** Crops that already exist are skipped.
  Labels are appended per call and fsynced, and already-labeled images are
  skipped. Existing users, faces (matched by `ExternalImageId`) and
  associations are reused. Transient AWS errors retry with exponential
  backoff and jitter, and calls are rate-limited (`aws.max_requests_per_second`).
- **Leakage.** Val/test identities are enrolled too, because Rekognition is the
  fixed system being measured. The identity-level split is what downstream
  code must respect.
- **More sources later.** Write another adapter that emits the generic columns
  (`source_dataset`, `identity_id`, `session_id`, `source_image_path`,
  bbox, landmarks, …) plus a `materialize` function, and register it in
  `sources.SOURCES`.
- **Archived runs.** `data/archive/aligned_v1/` holds the earlier run on
  aligned CelebA images (collection `violet-fiqa-training`). This run uses
  `violet-fiqa-wild`.

## What gets committed

Code, `configs/`, `examples/`, `.env.example`, and this README.
Everything under `data/` (images, crops, labels) is gitignored.
