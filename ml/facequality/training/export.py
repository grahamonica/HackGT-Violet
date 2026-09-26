"""Export a trained run to Core ML (.mlpackage) for on-device use.

    python -m ml.facequality.training.export --run ml/facequality/training/runs/sweep1/mbf/finetune/d867b328-s0

Needs `coremltools`, which runs on macOS and Linux (e.g. WSL) but not native
Windows. Linux can convert but not execute Core ML models, so numeric parity
with PyTorch is checked on a Mac using the reference set written alongside.

Model interface (see README "Input contract"):
    inputs   face            image, RGB, 112x112, raw 0-255 (aligned with align.align_face)
             interocular_px  float32 [1], eye distance in pixels of the image sent to Rekognition
    output   quality         float32 [1], in [0, 1]

Writes to <out>/:
    <name>.mlpackage             the model
    <name>_reference/            test faces for parity checks (CelebA-derived; keep out of git)
        cases.json               crop file, landmarks, interocular, aligned file, PyTorch quality
        crops/, aligned/         crops and Python-aligned 112x112 faces (JPEG/PNG + PPM copies)
"""

from __future__ import annotations

import argparse
import json
import logging
import shutil
from pathlib import Path

import cv2
import numpy as np
import torch
from torch import nn

from .align import ARCFACE_TEMPLATE, align_face
from .config import MODELS_DIR, config_hash, resolve_paths, setup_logging
from .data import landmarks_array, load_image_rgb, load_queries, split_frame
from .evaluate import load_run

log = logging.getLogger("fiqa.training")


class ExportWrapper(nn.Module):
    """QualityModel with the sigmoid applied: (face 0-255, interocular px) -> quality."""

    def __init__(self, model: nn.Module):
        super().__init__()
        self.model = model

    def forward(self, face: torch.Tensor, interocular_px: torch.Tensor) -> torch.Tensor:
        return torch.sigmoid(self.model(face, interocular_px)).reshape(1)


def write_ppm(path: Path, rgb: np.ndarray) -> None:
    """Binary PPM (P6): trivially readable anywhere, e.g. by tests on Linux."""
    h, w = rgb.shape[:2]
    path.write_bytes(f"P6\n{w} {h}\n255\n".encode() + np.ascontiguousarray(rgb, dtype=np.uint8).tobytes())


def write_reference_set(model: nn.Module, cfg: dict, out_dir: Path, n: int, seed: int = 0) -> list[dict]:
    """Test-split faces, half clean and half degraded, with Python-side alignment and scores."""
    paths = resolve_paths(cfg)
    test = split_frame(load_queries(paths, cfg["data"]), "test")
    rng = np.random.default_rng(seed)
    picks = []
    for applied in (0, 1):
        pool = test.index[test["augmentation_applied"] == applied].to_numpy()
        picks += list(rng.choice(pool, size=min(n // 2, len(pool)), replace=False))
    rows = test.loc[sorted(picks)]

    shutil.rmtree(out_dir, ignore_errors=True)
    (out_dir / "crops").mkdir(parents=True)
    (out_dir / "aligned").mkdir(parents=True)
    lms = landmarks_array(rows)
    size = int(cfg["align"]["size"])
    cases = []
    for (_, row), lm in zip(rows.iterrows(), lms):
        crop_src = paths.data / row["crop_path"]
        crop_name = f"{row['image_id']}{crop_src.suffix}"
        shutil.copy2(crop_src, out_dir / "crops" / crop_name)
        crop = load_image_rgb(crop_src)
        write_ppm(out_dir / "crops" / f"{row['image_id']}.ppm", crop)
        face = align_face(crop, lm, size)
        cv2.imwrite(str(out_dir / "aligned" / f"{row['image_id']}.png"), cv2.cvtColor(face, cv2.COLOR_RGB2BGR))
        write_ppm(out_dir / "aligned" / f"{row['image_id']}.ppm", face)
        with torch.no_grad():
            x = torch.from_numpy(np.ascontiguousarray(face.transpose(2, 0, 1)))[None].float()
            io = torch.tensor([float(row["interocular"])])
            quality = float(torch.sigmoid(model(x, io))[0])
        cases.append(
            {
                "image_id": row["image_id"],
                "identity_id": row["identity_id"],  # = Rekognition UserId in the dataset's collection
                "crop": f"crops/{crop_name}",
                "crop_ppm": f"crops/{row['image_id']}.ppm",
                "aligned": f"aligned/{row['image_id']}.png",
                "aligned_ppm": f"aligned/{row['image_id']}.ppm",
                "landmarks": lm.round(3).tolist(),  # left eye, right eye, nose, left mouth, right mouth (crop px)
                "interocular_px": float(row["interocular"]),
                "quality": quality,
                "augmentation": row["augmentation_type"],
            }
        )
    (out_dir / "cases.json").write_text(json.dumps({"size": size, "template": ARCFACE_TEMPLATE.tolist(), "cases": cases}, indent=2))
    return cases


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", type=Path, required=True, help="run directory (with best.pt and config.yaml)")
    ap.add_argument("--name", default="FaceQuality", help="model name (file and Swift class name)")
    ap.add_argument("--out", type=Path, default=MODELS_DIR / "exports")
    ap.add_argument("--precision", choices=["float16", "float32"], default="float16")
    ap.add_argument("--reference", type=int, default=24, help="reference faces for parity checks (0 = none)")
    args = ap.parse_args(argv)
    setup_logging()

    # coremltools logs every graph pass at INFO, and on Linux warns at import
    # that it can't run models (expected: we only convert here).
    logging.getLogger("coremltools").setLevel(logging.ERROR)
    import coremltools as ct  # imported here: only needed for export

    model, cfg = load_run(args.run, torch.device("cpu"))
    size = int(cfg["align"]["size"])
    wrapper = ExportWrapper(model).eval()
    example = (torch.full((1, 3, size, size), 128.0), torch.tensor([60.0]))
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
        drift = (traced(*example) - wrapper(*example)).abs().item()
    log.info("traced model matches eager PyTorch (|diff| %.2e)", drift)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="face", shape=(1, 3, size, size), color_layout=ct.colorlayout.RGB, scale=1.0, bias=[0.0, 0.0, 0.0]),
            ct.TensorType(name="interocular_px", shape=(1,), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="quality", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32,
    )
    mlmodel.short_description = "Predicts how well AWS Rekognition will identify an aligned face (0-1)."
    mlmodel.license = "Non-commercial research only (InsightFace / EdgeFace pretrained weights; CelebA)."
    mlmodel.input_description["face"] = f"RGB face aligned to the ArcFace {size}x{size} template, raw 0-255"
    mlmodel.input_description["interocular_px"] = "Eye-center distance in pixels of the image sent to Rekognition"
    mlmodel.output_description["quality"] = "Predicted Rekognition utility in [0, 1]"
    mlmodel.user_defined_metadata.update(
        {
            "run": args.run.as_posix().split("runs/")[-1],
            "backbone": cfg["backbone"],
            "config_hash": config_hash(cfg),
            "target": cfg["data"]["target"],
            "precision": args.precision,
            "arcface_template": json.dumps(ARCFACE_TEMPLATE.tolist()),
        }
    )

    args.out.mkdir(parents=True, exist_ok=True)
    package = args.out / f"{args.name}.mlpackage"
    shutil.rmtree(package, ignore_errors=True)
    mlmodel.save(str(package))

    # Structural check (Linux can't execute Core ML): reload and confirm the interface.
    spec = ct.models.MLModel(str(package), skip_model_load=True).get_spec()
    inputs = {i.name: i.type.WhichOneof("Type") for i in spec.description.input}
    outputs = {o.name: o.type.WhichOneof("Type") for o in spec.description.output}
    if inputs != {"face": "imageType", "interocular_px": "multiArrayType"} or outputs != {"quality": "multiArrayType"}:
        raise RuntimeError(f"unexpected Core ML interface: inputs={inputs} outputs={outputs}")
    size_mb = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6
    log.info("saved %s (%.1f MB, %s); interface ok: inputs %s, outputs %s", package, size_mb, args.precision, inputs, outputs)

    if args.reference:
        ref_dir = args.out / f"{args.name}_reference"
        cases = write_reference_set(model, cfg, ref_dir, args.reference)
        log.info("reference set: %d faces -> %s", len(cases), ref_dir)


if __name__ == "__main__":
    main()
