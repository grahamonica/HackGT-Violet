"""5-point similarity alignment onto the ArcFace 112x112 template.

This is the model's input contract: whatever produces the 5 landmarks
(CelebA annotations in training, a face detector on device), the face must be
warped exactly like this before it reaches the network.

Landmark order: left eye, right eye, nose, left mouth corner, right mouth
corner, where left/right are *image* left/right (CelebA's and ArcFace's order).
"""

from __future__ import annotations

import cv2
import numpy as np

# InsightFace's canonical 112x112 ArcFace template.
ARCFACE_TEMPLATE = np.array(
    [
        [38.2946, 51.6963],
        [73.5318, 51.5014],
        [56.0252, 71.7366],
        [41.5493, 92.3655],
        [70.7299, 92.2041],
    ],
    dtype=np.float64,
)


def similarity_transform(src: np.ndarray, dst: np.ndarray) -> np.ndarray:
    """Least-squares similarity (rotation, uniform scale, translation) mapping
    src -> dst (Umeyama, no reflection). Returns a 2x3 matrix."""
    src = np.asarray(src, dtype=np.float64)
    dst = np.asarray(dst, dtype=np.float64)
    mu_s, mu_d = src.mean(0), dst.mean(0)
    s_c, d_c = src - mu_s, dst - mu_d
    cov = d_c.T @ s_c / len(src)
    u, sig, vt = np.linalg.svd(cov)
    d = np.ones(2)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        d[1] = -1
    rot = u @ np.diag(d) @ vt
    scale = (sig * d).sum() / s_c.var(0).sum()
    m = np.zeros((2, 3))
    m[:, :2] = scale * rot
    m[:, 2] = mu_d - scale * rot @ mu_s
    return m


def template(size: int = 112) -> np.ndarray:
    return ARCFACE_TEMPLATE * (size / 112.0)


def random_similarity(rng: np.random.Generator, size: int, shift_px: float, scale: float, rot_deg: float) -> np.ndarray:
    """Small random similarity about the output center (3x3), for landmark-noise augmentation."""
    a = np.deg2rad(rng.uniform(-rot_deg, rot_deg))
    s = 1.0 + rng.uniform(-scale, scale)
    tx, ty = rng.uniform(-shift_px, shift_px, size=2)
    c = size / 2.0
    cos, sin = s * np.cos(a), s * np.sin(a)
    return np.array(
        [
            [cos, -sin, c - cos * c + sin * c + tx],
            [sin, cos, c - sin * c - cos * c + ty],
            [0.0, 0.0, 1.0],
        ]
    )


def align_face(
    image: np.ndarray,
    landmarks: np.ndarray,
    size: int = 112,
    perturb: np.ndarray | None = None,
) -> np.ndarray:
    """Warp `image` (HxWxC uint8) so `landmarks` (5x2, image pixels) land on
    the ArcFace template. `perturb` is an optional 3x3 applied in output space.

    Large faces are first area-downsampled so the warp itself never shrinks by
    more than 2x (plain bilinear warping of a big face aliases, which would
    distort exactly the blur/noise cues the quality model needs).
    """
    landmarks = np.asarray(landmarks, dtype=np.float64)
    dst = template(size)
    m = similarity_transform(landmarks, dst)
    scale = float(np.sqrt(abs(np.linalg.det(m[:, :2]))))
    if scale < 0.5:
        r = 2.0 * scale  # after resizing by r, the warp scale is exactly 0.5
        h, w = image.shape[:2]
        image = cv2.resize(image, (max(1, round(w * r)), max(1, round(h * r))), interpolation=cv2.INTER_AREA)
        # Use the actual per-axis resize factors (rounding) for the landmarks.
        landmarks = landmarks * np.array([image.shape[1] / w, image.shape[0] / h])
        m = similarity_transform(landmarks, dst)
    if perturb is not None:
        m = (perturb @ np.vstack([m, [0.0, 0.0, 1.0]]))[:2]
    return cv2.warpAffine(image, m, (size, size), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)


def interocular_px(landmarks: np.ndarray) -> float:
    """Eye-to-eye distance in the source image's pixels (face resolution)."""
    landmarks = np.asarray(landmarks, dtype=np.float64)
    return float(np.linalg.norm(landmarks[1] - landmarks[0]))
