"""Download and prepare pretrained backbone weights (run once, with internet;
training itself only reads the local files).

- mbf, r50: InsightFace's released ONNX models (`buffalo_s/w600k_mbf.onnx`,
  `buffalo_l/w600k_r50.onnx`, both trained on WebFace600K), converted to
  PyTorch state dicts for the BN-folded definitions in `backbones/`. Each
  conversion is checked against onnxruntime on random inputs.
- edgeface_s: `Idiap/EdgeFace-S-GAMMA` from the Hugging Face Hub.

All weights are for non-commercial research use only (InsightFace model
license; EdgeFace CC BY-NC-SA 4.0).

    python -m ml.facequality.training.prepare_weights [--only mbf r50 edgeface_s]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import shutil
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import torch
from torch import nn

from .backbones import BACKBONES, build_backbone, get_spec, weights_path
from .config import load_config, resolve_paths, setup_logging

log = logging.getLogger("fiqa.training")

INSIGHTFACE_RELEASE = "https://github.com/deepinsight/insightface/releases/download/v0.7/{pack}.zip"
SOURCES = {
    "mbf": {"pack": "buffalo_s", "member": "w600k_mbf.onnx", "license": "InsightFace: non-commercial research only"},
    "r50": {"pack": "buffalo_l", "member": "w600k_r50.onnx", "license": "InsightFace: non-commercial research only"},
    "edgeface_s": {"hf_repo": "Idiap/EdgeFace-S-GAMMA", "hf_file": "edgeface_s_gamma_05.pt", "license": "CC BY-NC-SA 4.0"},
}
PARAM_MODULES = (nn.Conv2d, nn.PReLU, nn.BatchNorm2d, nn.BatchNorm1d, nn.Linear)
ONNX_OP_FOR = {nn.Conv2d: "Conv", nn.PReLU: "PRelu", nn.BatchNorm2d: "BatchNormalization", nn.BatchNorm1d: "BatchNormalization", nn.Linear: "Gemm"}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path) -> Path:
    if dest.exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    log.info("Downloading %s", url)
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    tmp.replace(dest)
    return dest


def extract_member(zip_path: Path, member: str, dest: Path) -> Path:
    with zipfile.ZipFile(zip_path) as z:
        name = next(n for n in z.namelist() if n.endswith(member))
        with z.open(name) as src, open(dest, "wb") as out:
            shutil.copyfileobj(src, out)
    return dest


def execution_order(model: nn.Module, size: int = 112) -> list[nn.Module]:
    """Parameterized leaf modules in the order the forward pass calls them."""
    order: list[nn.Module] = []
    hooks = [m.register_forward_hook(lambda mod, _i, _o: order.append(mod)) for m in model.modules() if isinstance(m, PARAM_MODULES)]
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, size, size))
    for h in hooks:
        h.remove()
    return order


def onnx_param_nodes(onnx_path: Path) -> list[tuple[str, list[np.ndarray], dict]]:
    import onnx
    from onnx import numpy_helper

    graph = onnx.load(str(onnx_path)).graph
    init = {t.name: numpy_helper.to_array(t) for t in graph.initializer}
    nodes = []
    for n in graph.node:
        if n.op_type in ("Conv", "PRelu", "BatchNormalization", "Gemm"):
            attrs = {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute}
            nodes.append((n.op_type, [init[x] for x in n.input if x in init], attrs))
    return nodes


def convert_onnx(model: nn.Module, onnx_path: Path) -> dict[str, torch.Tensor]:
    """Copy ONNX initializers into `model` by matching execution order + op type + shape."""
    modules = execution_order(model)
    nodes = onnx_param_nodes(onnx_path)
    if len(modules) != len(nodes):
        raise RuntimeError(f"Layer count mismatch: torch {len(modules)} vs onnx {len(nodes)}")
    for i, (mod, (op, arrs, attrs)) in enumerate(zip(modules, nodes)):
        if ONNX_OP_FOR[type(mod)] != op:
            raise RuntimeError(f"Layer {i}: torch {type(mod).__name__} vs onnx {op}")
        if isinstance(mod, nn.Conv2d):
            targets = [mod.weight, mod.bias]
        elif isinstance(mod, nn.PReLU):
            targets, arrs = [mod.weight], [arrs[0].reshape(-1)]
        elif isinstance(mod, (nn.BatchNorm2d, nn.BatchNorm1d)):
            targets = [mod.weight, mod.bias, mod.running_mean, mod.running_var]
            if abs(attrs.get("epsilon", 1e-5) - mod.eps) > 1e-7:
                raise RuntimeError(f"Layer {i}: BN eps {attrs.get('epsilon')} vs {mod.eps}")
        else:  # Gemm -> Linear (weight is [out, in] when transB=1)
            w = arrs[0] if attrs.get("transB", 0) == 1 else arrs[0].T
            targets, arrs = [mod.weight, mod.bias], [w, arrs[1]]
        if len(targets) != len(arrs):
            raise RuntimeError(f"Layer {i} ({op}): {len(arrs)} onnx tensors for {len(targets)} params")
        for t, a in zip(targets, arrs):
            if tuple(t.shape) != a.shape:
                raise RuntimeError(f"Layer {i} ({op}): shape {tuple(t.shape)} vs onnx {a.shape}")
            with torch.no_grad():
                t.copy_(torch.from_numpy(np.array(a, copy=True)).to(t.dtype))
    return model.state_dict()


def verify_against_onnx(model: nn.Module, onnx_path: Path, n: int = 4) -> float:
    """Worst-case cosine similarity between PyTorch and onnxruntime embeddings."""
    import onnxruntime as ort

    x = np.random.default_rng(0).uniform(-1, 1, size=(n, 3, 112, 112)).astype(np.float32)
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    ref = np.concatenate([sess.run(None, {sess.get_inputs()[0].name: x[i : i + 1]})[0] for i in range(n)])
    model.eval()
    with torch.no_grad():
        out = model(torch.from_numpy(x)).numpy()
    cos = (ref * out).sum(1) / (np.linalg.norm(ref, axis=1) * np.linalg.norm(out, axis=1))
    log.info("  onnx check: min cosine %.6f, max |diff| %.2e", cos.min(), np.abs(ref - out).max())
    return float(cos.min())


def prepare_insightface(name: str, weights_dir: Path, keep_downloads: bool) -> dict:
    src = SOURCES[name]
    url = INSIGHTFACE_RELEASE.format(pack=src["pack"])
    dl_dir = weights_dir / "_downloads"
    zip_path = download(url, dl_dir / f"{src['pack']}.zip")
    onnx_path = extract_member(zip_path, src["member"], dl_dir / src["member"])
    model = get_spec(name).build()
    state = convert_onnx(model, onnx_path)
    if verify_against_onnx(model, onnx_path) < 0.9999:
        raise RuntimeError(f"{name}: converted model does not match the ONNX reference")
    out = weights_path(name, weights_dir)
    torch.save(state, out)
    info = {"source": url, "member": src["member"], "onnx_sha256": sha256(onnx_path)}
    if not keep_downloads:
        zip_path.unlink(missing_ok=True)
        onnx_path.unlink(missing_ok=True)
    return info


def prepare_edgeface(name: str, weights_dir: Path) -> dict:
    from huggingface_hub import hf_hub_download

    src = SOURCES[name]
    cached = Path(hf_hub_download(src["hf_repo"], src["hf_file"]))
    out = weights_path(name, weights_dir)
    shutil.copyfile(cached, out)
    return {"source": f"hf://{src['hf_repo']}/{src['hf_file']}"}


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=None)
    ap.add_argument("--only", nargs="+", choices=list(BACKBONES), default=list(BACKBONES))
    ap.add_argument("--force", action="store_true", help="re-create weights that already exist")
    ap.add_argument("--keep-downloads", action="store_true", help="keep the InsightFace zips/ONNX files")
    args = ap.parse_args(argv)
    setup_logging()

    weights_dir = resolve_paths(load_config(args.config)).weights
    weights_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = weights_dir / "MANIFEST.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

    for name in args.only:
        out = weights_path(name, weights_dir)
        if out.exists() and not args.force:
            log.info("%s: %s exists, skipping (use --force to redo)", name, out.name)
            continue
        log.info("%s: preparing %s", name, out.name)
        info = prepare_edgeface(name, weights_dir) if name == "edgeface_s" else prepare_insightface(name, weights_dir, args.keep_downloads)
        # Round-trip through the normal loading path (strict key match).
        build_backbone(name, weights_dir)
        manifest[name] = {**info, "file": out.name, "sha256": sha256(out), "license": SOURCES[name]["license"]}
        manifest_path.write_text(json.dumps(manifest, indent=2))
        log.info("%s: ok -> %s", name, out)


if __name__ == "__main__":
    main()
