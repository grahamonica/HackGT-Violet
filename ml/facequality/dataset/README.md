# Violet face-quality dataset builder

Builds a reproducible, identity-aware dataset for studying **how useful a face
crop is for AWS Rekognition identity matching**. It produces standardized crops,
identity-disjoint splits, automatically chosen enrollment references, and raw
Rekognition search results for every other image.

It does **not** define a training target or a model. See [SCHEMA.md](SCHEMA.md)
for the exact output contract that downstream code should use.

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
<https://mmlab.ie.cuhk.edu.hk/projects/CelebA.html>. On first run, the
`prepare` stage fetches the aligned images and annotation files from the
Hugging Face mirror named in `source.celeba.hf_repo` into `data/raw/celeba/`.
To use a manual download instead, place the same files there.

## Running

All commands run from the repo root:

```bash
# 1. Everything local: download, split, crop, pick references, assemble, report
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
| `--max-identities N` | cap identities after filtering (overrides config) |
| `--dry-run` | AWS stages print planned calls + cost, make no calls |
| `--skip-aws` | with `all`: skip `enroll` and `label` |
| `--yes` | allow AWS runs above `aws.confirm_calls_above` (default 2000 calls) |
| `--workers N` | preprocessing threads |

Open `data/report/preview.html` in a browser to see the contact sheet.

### Growing the dataset

The config defaults to `max_identities: 30`. To grow, raise it (or pass
`--max-identities 300`) and rerun `all`. Identities are shuffled once with the
seed and then taken as a prefix. Splits are assigned by position using a
seeded pattern, so **growing only adds identities**: nobody changes split, and
finished crops, enrollments and labels are all reused.

Top-1 correctness depends on how many people are enrolled. Each label records
`aws_gallery_size`. After growing, earlier labels were made against a smaller
gallery. If that matters for your target, relabel them by removing their rows
from `labels/rekognition_raw.jsonl` (the collection itself is reused).

## How it works

| stage | what it does | output |
|---|---|---|
| `prepare` | source adapter → generic per-image table (ids, landmarks, original bbox) | `work/source_images.csv`, `manifests/celeba_attributes.csv` |
| `split` | keep identities with ≥ `min_images_per_identity`, seeded shuffle, cap, assign train/val/test **by identity** | `manifests/splits.csv` |
| `preprocess` | similarity-warp each image onto the ArcFace 5-point template using the source landmarks (no detector); compute pose proxies, sharpness, brightness, contrast | `crops/…`, `work/preprocessing.csv` |
| `select` | per identity: gate on size/exposure/roll/framing, rank by within-identity quality, pick frontal + left + right (yaw proxy), else best distinct fallbacks | `work/enrollment_selection.csv` |
| `enroll` | one collection; `CreateUser(celeba_<id>)`, `IndexFaces` on references (backup candidates if no face is indexed), `AssociateFaces` | `labels/enrollment_aws.jsonl` |
| `label` | `SearchUsersByImage` on every non-enrollment crop (`QualityFilter=NONE`, threshold 0, `MaxUsers=5`) | `labels/rekognition_raw.jsonl` |
| `assemble` | builds the contract files from the above, with no AWS calls | `dataset/queries.csv`, `manifests/*.csv`, `dataset_info.json` |
| `report` | counts, accuracy, similarity distributions, HTML contact sheet | `report/` |

Design notes:

- **No face detector.** CelebA ships 5-point landmarks for every aligned
  image, and the crops are warped from those. A future source without
  landmarks would add a detector in its adapter. Everything after `prepare`
  only needs the generic columns.
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
  landmarks, …) and register it in `build_dataset.SOURCES`.

## What gets committed

Code, `configs/`, `SCHEMA.md`, `examples/`, `.env.example`, and this README.
Everything under `data/` (images, crops, labels) is gitignored.
