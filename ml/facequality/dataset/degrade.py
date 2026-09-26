"""Geometry-preserving synthetic quality degradations.

Every function maps an HxWx3 uint8 BGR image to an HxWx3 uint8 image of the
SAME size and pixel grid: no resizing, cropping, rotation, warping, or
translation, so crop-relative landmarks stay valid. Blur strengths scale with
the face width (in crop pixels) so a severity means roughly the same thing for
small and large faces; the other degradations use absolute settings.

Parameters are drawn deterministically: `sample_params` jitters the
configured base value for (type, severity) with an RNG seeded from the dataset
seed and the image id, and every drawn value is recorded.
"""

from __future__ import annotations

import cv2
import numpy as np

DEGRADATIONS = ("gaussian_blur", "motion_blur", "darken", "low_contrast", "jpeg", "noise")
SEVERITIES = ("light", "medium", "strong")


def sample_params(dtype: str, severity: str, spec: dict, jitter: float, face_w: float, rng: np.random.Generator) -> dict:
    """Concrete parameters for one degradation, recorded verbatim in the dataset."""
    base = {k: v[SEVERITIES.index(severity)] for k, v in spec[dtype].items()}
    j = lambda v: float(v) * float(rng.uniform(1 - jitter, 1 + jitter))  # noqa: E731
    if dtype == "gaussian_blur":
        return {"sigma_px": max(0.3, j(base["sigma_frac_face"]) * face_w)}
    if dtype == "motion_blur":
        return {"length_px": max(3, int(round(j(base["length_frac_face"]) * face_w))),
                "angle_deg": float(rng.uniform(0, 180))}
    if dtype == "darken":
        return {"linear_gain": j(base["linear_gain"])}
    if dtype == "low_contrast":
        return {"alpha": min(1.0, j(base["alpha"]))}
    if dtype == "jpeg":
        return {"quality": int(np.clip(round(j(base["quality"])), 2, 95))}
    if dtype == "noise":
        return {"sigma": j(base["sigma"]), "noise_seed": int(rng.integers(2**31))}
    raise ValueError(f"unknown degradation {dtype!r}")


def _gaussian_blur(img: np.ndarray, sigma_px: float) -> np.ndarray:
    return cv2.GaussianBlur(img, (0, 0), sigmaX=sigma_px, borderType=cv2.BORDER_REFLECT_101)


def _motion_blur(img: np.ndarray, length_px: int, angle_deg: float) -> np.ndarray:
    # Line kernel of the given length and angle (the kernel is drawn; the image is only filtered).
    size = length_px | 1
    c = (size - 1) / 2
    dx, dy = np.cos(np.radians(angle_deg)) * c, np.sin(np.radians(angle_deg)) * c
    k = np.zeros((size, size), np.float32)
    cv2.line(k, (int(round(c - dx)), int(round(c - dy))), (int(round(c + dx)), int(round(c + dy))), 1.0, 1, cv2.LINE_AA)
    k /= max(k.sum(), 1e-6)
    return cv2.filter2D(img, -1, k, borderType=cv2.BORDER_REFLECT_101)


def _darken(img: np.ndarray, linear_gain: float) -> np.ndarray:
    # Underexposure: scale intensity in (approximately) linear light, then re-encode.
    lin = (img.astype(np.float32) / 255.0) ** 2.2
    return np.clip(((lin * linear_gain) ** (1 / 2.2)) * 255.0 + 0.5, 0, 255).astype(np.uint8)


def _low_contrast(img: np.ndarray, alpha: float) -> np.ndarray:
    f = img.astype(np.float32)
    mean = f.mean(axis=(0, 1), keepdims=True)
    return np.clip(mean + alpha * (f - mean) + 0.5, 0, 255).astype(np.uint8)


def _noise(img: np.ndarray, sigma: float, noise_seed: int) -> np.ndarray:
    n = np.random.default_rng(noise_seed).normal(0.0, sigma, img.shape).astype(np.float32)
    return np.clip(img.astype(np.float32) + n + 0.5, 0, 255).astype(np.uint8)


def apply(img: np.ndarray, dtype: str, params: dict) -> tuple[np.ndarray, int | None]:
    """Return (degraded image, jpeg quality to save with or None for the default)."""
    if dtype == "gaussian_blur":
        out = _gaussian_blur(img, params["sigma_px"])
    elif dtype == "motion_blur":
        out = _motion_blur(img, params["length_px"], params["angle_deg"])
    elif dtype == "darken":
        out = _darken(img, params["linear_gain"])
    elif dtype == "low_contrast":
        out = _low_contrast(img, params["alpha"])
    elif dtype == "jpeg":
        out = img  # the degradation IS the save quality; pixels are unchanged until encoding
    elif dtype == "noise":
        out = _noise(img, params["sigma"], params["noise_seed"])
    else:
        raise ValueError(f"unknown degradation {dtype!r}")
    if out.shape != img.shape:
        raise AssertionError(f"{dtype} changed image shape {img.shape} -> {out.shape}")
    return out, (params["quality"] if dtype == "jpeg" else None)
