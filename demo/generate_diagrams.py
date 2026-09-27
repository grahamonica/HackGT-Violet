#!/usr/bin/env python3
"""Generate Violet's demo diagrams (SVG + PNG) from code.

    python3 demo/generate_diagrams.py            # writes SVGs and PNGs into demo/
    python3 demo/generate_diagrams.py --svg-only

Style follows style_guide.md: accent #9b82e8, deep accent #3b267a, ink #232324,
white background, 3 px corner radius, no gradients, no dot grid, Sansation for
headings and Mukta Malar Light for body text. Boxes carry a title only (the
diagrams support a spoken walkthrough); purple is kept for arrows, headings and
third-party pieces. The fonts in webapp/public/fonts are subset and embedded so
each SVG is self-contained.
"""
from __future__ import annotations

import base64
import io
import math
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape

from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(__file__).resolve().parent
FONT_DIR = ROOT / "webapp" / "public" / "fonts"

# ---------------------------------------------------------------- style tokens
ACCENT = "#9b82e8"
DEEP = "#3b267a"
INK = "#232324"
MUTED = "#696671"
SOFT = "#f1edfa"      # light tint of the accent: third-party services, devices and data
SOFTER = "#f7f6fa"    # barely-there tint for an application boundary
WHITE = "#ffffff"
LINE = "#d9d4e6"      # box outline
RADIUS = 3
HEADING = "Sansation"
BODY = "Mukta Malar"

FONT_FILES = {
    (HEADING, 400): FONT_DIR / "Sansation-Regular.ttf",
    (HEADING, 700): FONT_DIR / "Sansation-Bold.ttf",
    (BODY, 300): FONT_DIR / "MuktaMalar-Light.ttf",
}


# ------------------------------------------------------------ text measuring
class Metrics:
    """Advance-width text measurement from the real font files."""

    def __init__(self) -> None:
        self.fonts: dict[tuple[str, int], tuple[dict, dict, int]] = {}
        for key, path in FONT_FILES.items():
            font = TTFont(path)
            cmap = font.getBestCmap()
            hmtx = font["hmtx"].metrics
            self.fonts[key] = (cmap, hmtx, font["head"].unitsPerEm)

    def width(self, text: str, family: str, weight: int, size: float) -> float:
        cmap, hmtx, upm = self.fonts[(family, weight)]
        total = 0
        for ch in text:
            glyph = cmap.get(ord(ch)) or cmap.get(ord("?"))
            total += hmtx[glyph][0] if glyph in hmtx else upm * 0.5
        return total / upm * size

    def wrap(self, text: str, family: str, weight: int, size: float, max_width: float) -> list[str]:
        lines: list[str] = []
        for paragraph in text.split("\n"):
            words = paragraph.split(" ")
            line = ""
            for word in words:
                candidate = word if not line else f"{line} {word}"
                if line and self.width(candidate, family, weight, size) > max_width:
                    lines.append(line)
                    line = word
                else:
                    line = candidate
            lines.append(line)
        return lines


METRICS = Metrics()


def subset_font(path: Path, chars: set[str]) -> bytes:
    """Return a TTF containing only the glyphs needed for ``chars``."""
    font = TTFont(path)
    options = subset.Options()
    options.desubroutinize = True
    options.hinting = False
    options.layout_features = ["kern", "liga"]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text="".join(sorted(chars)) + " ?")
    subsetter.subset(font)
    buffer = io.BytesIO()
    font.save(buffer)
    return buffer.getvalue()


# ------------------------------------------------------------------ geometry
@dataclass
class Node:
    id: str
    x: float
    y: float
    w: float
    h: float

    @property
    def cx(self) -> float:
        return self.x + self.w / 2

    @property
    def cy(self) -> float:
        return self.y + self.h / 2

    @property
    def right(self) -> float:
        return self.x + self.w

    @property
    def bottom(self) -> float:
        return self.y + self.h

    def port(self, side: str, t: float = 0.5) -> tuple[float, float]:
        """A point on the node border. ``t`` slides along that side (0..1)."""
        if side == "left":
            return (self.x, self.y + self.h * t)
        if side == "right":
            return (self.right, self.y + self.h * t)
        if side == "top":
            return (self.x + self.w * t, self.y)
        if side == "bottom":
            return (self.x + self.w * t, self.bottom)
        raise ValueError(side)


def rounded_polyline(points: list[tuple[float, float]], radius: float = 10) -> str:
    """SVG path data for a polyline with rounded corners."""
    if len(points) < 2:
        return ""
    parts = [f"M {points[0][0]:.1f} {points[0][1]:.1f}"]
    for i in range(1, len(points) - 1):
        (x0, y0), (x1, y1), (x2, y2) = points[i - 1], points[i], points[i + 1]
        d1 = math.hypot(x1 - x0, y1 - y0)
        d2 = math.hypot(x2 - x1, y2 - y1)
        r = min(radius, d1 / 2, d2 / 2)
        if r <= 0.5:
            parts.append(f"L {x1:.1f} {y1:.1f}")
            continue
        ax = x1 + (x0 - x1) / d1 * r
        ay = y1 + (y0 - y1) / d1 * r
        bx = x1 + (x2 - x1) / d2 * r
        by = y1 + (y2 - y1) / d2 * r
        parts.append(f"L {ax:.1f} {ay:.1f} Q {x1:.1f} {y1:.1f} {bx:.1f} {by:.1f}")
    parts.append(f"L {points[-1][0]:.1f} {points[-1][1]:.1f}")
    return " ".join(parts)


def polyline_point(points: list[tuple[float, float]], fraction: float) -> tuple[float, float, bool]:
    """Point at ``fraction`` of the polyline length, plus whether that segment is horizontal."""
    lengths = [math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(points, points[1:])]
    target = sum(lengths) * fraction
    for (a, b), length in zip(zip(points, points[1:]), lengths):
        if target <= length or (a, b) == (points[-2], points[-1]):
            t = 0 if length == 0 else max(0.0, min(1.0, target / length))
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, abs(b[1] - a[1]) < 0.5)
        target -= length
    return (*points[-1], True)


# ------------------------------------------------------------------- canvas
@dataclass
class Diagram:
    width: float
    height: float
    title: str
    subtitle: str = ""
    layers: dict[str, list[str]] = field(default_factory=lambda: {"zones": [], "edges": [], "nodes": [], "labels": []})
    nodes: dict[str, Node] = field(default_factory=dict)
    chars: set[str] = field(default_factory=set)
    _markers: dict[str, str] = field(default_factory=dict)

    # -- text -------------------------------------------------------------
    def text(self, x: float, y: float, content: str, *, family: str = BODY, weight: int = 300,
             size: float = 13, fill: str = INK, anchor: str = "start", layer: str = "labels",
             halo: bool = False) -> None:
        self.chars.update(content)
        style = f'font-family="{family}" font-weight="{weight}" font-size="{size}" fill="{fill}" text-anchor="{anchor}"'
        if halo:
            style += f' stroke="{WHITE}" stroke-width="4" stroke-linejoin="round" paint-order="stroke"'
        self.layers[layer].append(f'<text x="{x:.1f}" y="{y:.1f}" {style}>{escape(content)}</text>')

    def paragraph(self, x: float, y: float, content: str, *, max_width: float, family: str = BODY,
                  weight: int = 300, size: float = 13, fill: str = INK, anchor: str = "start",
                  line_height: float = 1.32, layer: str = "labels") -> float:
        """Wrapped text. Returns the y just below the last line."""
        lines = METRICS.wrap(content, family, weight, size, max_width)
        for i, line in enumerate(lines):
            self.text(x, y + i * size * line_height, line, family=family, weight=weight, size=size,
                      fill=fill, anchor=anchor, layer=layer)
        return y + len(lines) * size * line_height

    # -- nodes ------------------------------------------------------------
    def node(self, id: str, x: float, y: float, w: float, h: float, title: str, caption: str = "",
             *, kind: str = "owned", title_size: float = 17) -> Node:
        """A box with a title and, at most, one short caption line (3 px corner radius).

        kind: owned (white, light outline), external (soft tint, no outline),
        muted (white, outline, muted title) for notes and one-time steps.
        """
        node = Node(id, x, y, w, h)
        self.nodes[id] = node
        if kind == "external":
            box = f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{RADIUS}" fill="{SOFT}"/>'
        else:
            box = f'<rect x="{x + 0.5:.1f}" y="{y + 0.5:.1f}" width="{w - 1:.1f}" height="{h - 1:.1f}" rx="{RADIUS}" fill="{WHITE}" stroke="{LINE}" stroke-width="1"/>'
        self.layers["nodes"].append(box)
        title_fill = MUTED if kind == "muted" else INK
        lines = METRICS.wrap(title, HEADING, 700, title_size, w - 28)
        block = len(lines) * title_size * 1.2 + (16 if caption else 0)
        ty = y + (h - block) / 2 + title_size * 0.92
        for line in lines:
            self.text(node.cx, ty, line, family=HEADING, weight=700, size=title_size, fill=title_fill, anchor="middle", layer="nodes")
            ty += title_size * 1.2
        if caption:
            self.text(node.cx, ty + 4, caption, family=BODY, weight=300, size=12.5, fill=MUTED, anchor="middle", layer="nodes")
        return node

    def container(self, id: str, x: float, y: float, w: float, h: float, title: str, caption: str = "") -> Node:
        """A faint, borderless region that groups a stack of boxes. Edges may attach to its border."""
        node = Node(id, x, y, w, h)
        self.nodes[id] = node
        self.layers["zones"].append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{RADIUS}" fill="{SOFTER}"/>')
        self.text(x + w / 2, y + 34, title, family=HEADING, weight=700, size=19, fill=DEEP, anchor="middle", layer="zones")
        if caption:
            self.text(x + w / 2, y + 54, caption, size=12.5, fill=MUTED, anchor="middle", layer="zones")
        return node

    def heading(self, x: float, y: float, title: str, caption: str = "", anchor: str = "start") -> None:
        self.text(x, y, title, family=HEADING, weight=700, size=19, fill=DEEP, anchor=anchor)
        if caption:
            self.text(x, y + 20, caption, size=12.5, fill=MUTED, anchor=anchor)

    def actor(self, id: str, cx: float, cy: float, title: str, caption: str = "") -> Node:
        """A person: simple glyph plus a label, no box."""
        self.layers["nodes"].append(
            f'<circle cx="{cx:.1f}" cy="{cy - 22:.1f}" r="16" fill="{ACCENT}"/>'
            f'<path d="M {cx - 34:.1f} {cy + 30:.1f} a 34 34 0 0 1 68 0 z" fill="{ACCENT}"/>')
        self.text(cx, cy + 58, title, family=HEADING, weight=700, size=16, fill=INK, anchor="middle", layer="nodes")
        if caption:
            self.text(cx, cy + 77, caption, size=12.5, fill=MUTED, anchor="middle", layer="nodes")
        node = Node(id, cx - 40, cy - 40, 80, 80 + (46 if caption else 26))
        self.nodes[id] = node
        return node

    def legend(self, x: float, y: float, items: list[tuple[str, str]]) -> None:
        """Small key: [(kind, label), ...] laid out left to right."""
        for kind, label in items:
            if kind == "external":
                self.layers["labels"].append(f'<rect x="{x:.1f}" y="{y - 10:.1f}" width="16" height="14" rx="{RADIUS}" fill="{SOFT}"/>')
            else:
                self.layers["labels"].append(f'<rect x="{x + 0.5:.1f}" y="{y - 9.5:.1f}" width="15" height="13" rx="{RADIUS}" fill="{WHITE}" stroke="{LINE}"/>')
            self.text(x + 24, y + 1.5, label, size=12.5, fill=MUTED)
            x += 24 + METRICS.width(label, BODY, 300, 12.5) + 30

    # -- edges ------------------------------------------------------------
    def edge(self, src: str | tuple[float, float], dst: str | tuple[float, float], label: str = "", *,
             src_side: str = "right", dst_side: str = "left", src_t: float = 0.5, dst_t: float = 0.5,
             via: list[tuple[float, float]] | None = None, both: bool = False, dashed: bool = False,
             color: str = DEEP, label_at: float = 0.5, label_side: str = "auto", width: float = 1.5,
             elbow: str = "auto", label_width: float = 200) -> None:
        """An arrow between node borders (or raw points), routed orthogonally.

        Route: start port -> optional ``via`` waypoints -> end port. When only the two
        ports are given and they are not aligned, an elbow is inserted ("h" first or "v" first).
        """
        start = self.nodes[src].port(src_side, src_t) if isinstance(src, str) else src
        end = self.nodes[dst].port(dst_side, dst_t) if isinstance(dst, str) else dst
        points = [start]
        if via:
            points.extend(via)
        elif not (abs(start[0] - end[0]) < 0.5 or abs(start[1] - end[1]) < 0.5):
            mode = elbow if elbow != "auto" else ("h" if src_side in ("left", "right") else "v")
            if mode == "h":
                if dst_side in ("left", "right"):
                    mid = (start[0] + end[0]) / 2
                    points.extend([(mid, start[1]), (mid, end[1])])
                else:
                    points.append((end[0], start[1]))
            else:
                if dst_side in ("top", "bottom"):
                    mid = (start[1] + end[1]) / 2
                    points.extend([(start[0], mid), (end[0], mid)])
                else:
                    points.append((start[0], end[1]))
        points.append(end)
        marker = self._marker(color)
        attrs = f'fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" marker-end="url(#{marker})"'
        if both:
            attrs += f' marker-start="url(#{marker})"'
        if dashed:
            attrs += ' stroke-dasharray="5 5"'
        self.layers["edges"].append(f'<path d="{rounded_polyline(points)}" {attrs}/>')
        if label:
            lx, ly, horizontal = polyline_point(points, label_at)
            if label_side == "auto":
                label_side = "above" if horizontal else "right"
            self._edge_label(lx, ly, label, horizontal, label_side, label_width)

    def _edge_label(self, x: float, y: float, label: str, horizontal: bool, side: str, max_width: float) -> None:
        size = 12
        lines: list[str] = []
        for part in label.split("\n"):
            lines.extend(METRICS.wrap(part, BODY, 300, size, max_width))
        step = size * 1.3
        block = len(lines) * step
        if horizontal:
            anchor, x0 = "middle", x
            y0 = y - 8 - block + size * 0.95 if side == "above" else y + 8 + size * 0.9
        elif side == "center":
            anchor, x0 = "middle", x
            y0 = y - block / 2 + size * 0.9
        else:
            anchor = "start" if side == "right" else "end"
            x0 = x + 9 if side == "right" else x - 9
            y0 = y - block / 2 + size * 0.9
        for i, line in enumerate(lines):
            self.text(x0, y0 + i * step, line, size=size, fill=INK, anchor=anchor, halo=True)

    def _marker(self, color: str) -> str:
        key = "m" + color.strip("#")
        self._markers[key] = color
        return key

    # -- output -----------------------------------------------------------
    def svg(self) -> str:
        self.chars.update(self.title + self.subtitle)
        defs = [
            f'<marker id="{key}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            f'<path d="M 1 1 L 9 5 L 1 9 z" fill="{color}"/></marker>' for key, color in self._markers.items()]
        faces = []
        for (family, weight), path in FONT_FILES.items():
            data = base64.b64encode(subset_font(path, self.chars)).decode()
            faces.append(f"@font-face{{font-family:'{family}';font-weight:{weight};src:url(data:font/ttf;base64,{data}) format('truetype');}}")
        header = [
            f'<rect width="{self.width}" height="{self.height}" fill="{WHITE}"/>',
            f'<text x="56" y="62" font-family="{HEADING}" font-weight="700" font-size="30" fill="{INK}">{escape(self.title)}</text>',
        ]
        if self.subtitle:
            header.append(f'<text x="56" y="88" font-family="{BODY}" font-weight="300" font-size="15" fill="{MUTED}">{escape(self.subtitle)}</text>')
        body = "\n".join(header + self.layers["zones"] + self.layers["edges"] + self.layers["nodes"] + self.layers["labels"])
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.width}" height="{self.height}" '
                f'viewBox="0 0 {self.width} {self.height}" font-family="{BODY}">\n<style>{"".join(faces)}</style>\n'
                f'<defs>{"".join(defs)}</defs>\n{body}\n</svg>\n')


# ----------------------------------------------------------------- rendering
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def render_png(svg_path: Path, png_path: Path, width: int, height: int, scale: int = 2) -> str:
    """Rasterize with headless Chrome (exact size, 2x) or fall back to Quick Look."""
    with tempfile.TemporaryDirectory() as tmp:
        html = Path(tmp) / "page.html"
        html.write_text("<!doctype html><html><head><meta charset='utf-8'><style>html,body{margin:0;background:#fff;overflow:hidden}"
                        "svg{display:block}</style></head><body>" + svg_path.read_text() + "</body></html>")
        if CHROME.exists():
            cmd = [str(CHROME), "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                   f"--user-data-dir={tmp}/profile", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                   f"--window-size={width},{height}", f"--screenshot={png_path}", "--timeout=15000", f"file://{html}"]
            try:
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            except subprocess.TimeoutExpired:
                pass
            if png_path.exists() and png_path.stat().st_size > 0:
                return "chrome"
        if shutil.which("qlmanage"):
            subprocess.run(["qlmanage", "-t", "-s", str(max(width, height) * scale), "-o", tmp, str(svg_path)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
            produced = Path(tmp) / (svg_path.name + ".png")
            if produced.exists():
                from PIL import Image
                image = Image.open(produced)
                s = image.width / max(width, height)
                image.crop((0, 0, round(width * s), round(height * s))).save(png_path)
                return "quicklook"
    return "none"


# ============================================================== architecture
BW, BH = 250, 64  # every box in the architecture diagram is this size


def architecture() -> Diagram:
    W, H = 1860, 940
    d = Diagram(W, H, "Violet system architecture",
                "The patient's glasses and iPhone app, the cloud services they use, the provider portal, and the offline ML pipeline.")

    R = [230, 326, 422, 518, 614]  # box rows shared by the app, the cloud column and the portal
    AX, AW, CX = 320, 340, 360      # app container and its cards (a 40 px channel on the left)
    GX = 880                        # cloud column
    PX0, PW0, PX = 1350, 340, 1390  # portal container and its cards
    TOP, CONT_H = 160, 550

    # -- containers -------------------------------------------------------
    d.container("app", AX, TOP, AW, CONT_H, "Patient iOS app", "Swift")
    d.container("portal", PX0, TOP, PW0, CONT_H, "Provider portal", "Next.js")

    # -- patient side -----------------------------------------------------
    d.actor("patient", 155, 250, "Patient", "wearing the glasses")
    d.node("glasses", 30, R[2], BW, BH, "Meta AI glasses", "Meta", kind="external")

    # -- app cards --------------------------------------------------------
    d.node("manager", CX, R[0], BW, BH, "Glasses manager")
    d.node("pipeline", CX, R[1], BW, BH, "Referent pipeline")
    d.node("enroll", CX, R[2], BW, BH, "Face enrollment")
    d.node("store", CX, R[3], BW, BH, "Local store + sync")
    d.node("speech", CX, R[4], BW, BH, "Speech")

    # -- cloud column -----------------------------------------------------
    d.node("gcal", GX, R[0], BW, BH, "Google Calendar", "Google", kind="external")
    d.node("rekognition", GX, R[1], BW, BH, "Rekognition", "AWS", kind="external")
    d.node("atlas", GX, R[3], BW, BH, "Atlas", "MongoDB", kind="external")
    d.node("elevenlabs", GX, R[4], BW, BH, "ElevenLabs", "text to speech", kind="external")

    # -- portal cards -----------------------------------------------------
    d.node("client", PX, R[0], BW, BH, "Portal client")
    d.node("idb", PX, R[1], BW, BH, "IndexedDB cache")
    d.node("api", PX, R[3], BW, BH, "API routes")

    # -- provider ---------------------------------------------------------
    d.actor("provider", 1780, 250, "Provider", "clinician or caregiver")

    # -- ML band ----------------------------------------------------------
    d.heading(56, 790, "ML pipeline", "offline, Python")
    BY = 830
    d.node("celeba", 40, BY, BW, BH, "CelebA photos", "research dataset", kind="external")
    d.node("dataset", 330, BY, BW, BH, "Dataset builder")
    d.node("training", 620, BY, BW, BH, "Training")
    d.node("export", 910, BY, BW, BH, "Core ML export")

    # -- edges: patient and glasses --------------------------------------
    d.edge("patient", "glasses", "says “Violet”", src_side="bottom", dst_side="top", label_side="left")
    d.edge("glasses", "manager", "voice + 5 s of video", src_side="right", dst_side="left", src_t=0.35,
           via=[(300, R[2] + BH * 0.35), (300, R[0] + BH / 2)], both=True, label_at=0.26, label_side="left", label_width=120)
    d.edge("speech", "glasses", "spoken answer", src_side="left", dst_side="right", dst_t=0.7,
           via=[(300, R[4] + BH / 2), (300, R[2] + BH * 0.7)], label_at=0.55, label_side="left", label_width=120)

    # -- edges: inside the app -------------------------------------------
    d.edge("manager", "pipeline", "frames", src_side="bottom", dst_side="top", label_side="right")
    d.edge("store", "enroll", "people", src_side="top", dst_side="bottom", label_side="right")
    d.edge("speech", "store", "recognition log", src_side="top", dst_side="bottom", label_side="right")
    d.edge("pipeline", "speech", "outcome", src_side="left", dst_side="left", src_t=0.7, dst_t=0.3,
           via=[(340, R[1] + BH * 0.7), (340, R[4] + BH * 0.3)], label_side="center")

    # -- edges: app to cloud ---------------------------------------------
    d.edge("pipeline", "rekognition", "best face crops", both=True)
    d.edge("enroll", "rekognition", "3 photos per person", src_side="right", dst_side="bottom",
           via=[(GX + BW / 2, R[2] + BH / 2)], label_at=0.3, label_side="above")
    d.edge("store", "atlas", "people + logs, every 60 s", both=True)
    d.edge("speech", "elevenlabs", "sentences to audio", both=True)

    # -- edges: portal ---------------------------------------------------
    d.edge("gcal", "client", "sign-in + events", both=True)
    d.edge("atlas", "api", "people + logs", both=True)
    d.edge("client", "idb", "cache", src_side="bottom", dst_side="top", both=True, label_side="right")
    d.edge("client", "api", "JSON, every 60 s", src_side="right", dst_side="right", src_t=0.7,
           via=[(1665, R[0] + BH * 0.7), (1665, R[3] + BH / 2)], both=True, label_at=0.5, label_side="left", label_width=110)
    d.edge("provider", "portal", src_side="left", dst_side="right", dst_t=(250 + 23 - TOP) / CONT_H, both=True)

    # -- edges: ML band --------------------------------------------------
    d.edge("celeba", "dataset")
    d.edge("dataset", "training", "labeled crops")
    d.edge("training", "export", "best model")
    d.edge("export", "app", "FaceQuality model, bundled into the app", src_side="top", dst_side="bottom",
           via=[(910 + BW / 2, 770), (AX + 165, 770)], dst_t=165 / AW, label_at=0.45, label_side="above", label_width=300)

    d.legend(1250, 866, [("owned", "built in this repository"), ("external", "third-party service, device or data")])
    return d


# ============================================================== patient flow
def patient_flow() -> Diagram:
    W, H = 1300, 1850
    d = Diagram(W, H, "Patient flow", "From a one-time setup to hearing who is in front of them.")
    MX, MW, SH = 480, 340, 64
    LX, RX, SW = 100, 950, 250
    # Two-way splits sit either side of the main column.
    BW, BL, BR = 300, 270, 730

    d.node("setup", MX, 140, MW, SH, "Set up the glasses once", kind="muted")
    d.node("people", MX, 236, MW, SH, "Add familiar people")
    d.node("phoneadd", LX, 236, SW, SH, "On the phone", "three photos each")
    d.node("portaladd", RX, 236, SW, SH, "Or in the provider portal")
    d.node("wear", MX, 332, MW, SH, "Wear the glasses")
    d.node("anytime", LX, 332, SW, SH, "Tap a person to hear their bio", "any time", kind="muted", title_size=15)

    # -- how they ask: capture button (fast path only) or the "Violet" wake word
    d.node("how", 510, 428, 280, SH, "How do they ask?", kind="muted")
    d.node("button", BL, 540, BW, SH + 8, "Press the capture button", "fast path: name only", title_size=16)
    d.node("wake", BR, 540, BW, SH + 8, "Say “Violet”", "a question may follow: “Violet, where does he study?”",
           title_size=16)
    d.node("chime", 510, 664, 280, SH, "A chime confirms", kind="muted")

    d.node("stream", MX, 760, MW, SH, "Glasses stream up to 5 s of video", "stops once it's sure")
    d.node("crops", MX, 856, MW, SH, "Phone picks the best face crops")
    d.node("rek", MX, 952, MW, SH, "Rekognition names the person", "AWS", kind="external")
    d.node("found", 520, 1048, 260, SH, "What did it find?", kind="muted")

    OY, OW = 1164, 280
    xs = [45 + i * (OW + 30) for i in range(4)]
    d.node("o1", xs[0], OY, OW, SH + 8, "“This is Jordan, your daughter.”", "identified", title_size=14.5)
    d.node("o2", xs[1], OY, OW, SH + 8, "“This is not one of your family members.”", "not recognized", title_size=14.5)
    d.node("o3", xs[2], OY, OW, SH + 8, "“I couldn't see anyone's face.”", "no face", title_size=14.5)
    d.node("o4", xs[3], OY, OW, SH + 8, "“I couldn't tell who this is, so I won't guess.”", "unsure", title_size=14.5)

    d.node("speak", MX, 1300, MW, SH, "Violet speaks through the glasses", "ElevenLabs voice, prefetched")
    d.node("phonespeaker", LX, 1300, SW, SH, "Or the phone speaker", "demo setting", kind="muted", title_size=15)

    # -- fast path ends here; the slow path answers a question asked after "Violet"
    d.node("ask", MX, 1396, MW, SH, "Identified, with a question after “Violet”?", kind="muted", title_size=15)
    d.node("fast", BL, 1508, BW, SH, "Done", "fast path")
    d.node("grok", BR, 1508, BW, SH, "Grok answers the question", "slow path: from bio and notes",
           kind="external", title_size=16)
    d.node("reply", BR, 1620, BW, SH, "Violet speaks the reply", "voiced while the name plays", title_size=16)

    d.node("log", MX, 1740, MW, SH, "Recognition log synced to Atlas")
    d.node("portal", RX, 1740, SW, SH, "Provider portal analytics")

    chain = ["setup", "people", "wear", "how"]
    for a, b in zip(chain, chain[1:]):
        d.edge(a, b, src_side="bottom", dst_side="top")
    d.edge("phoneadd", "people")
    d.edge("portaladd", "people", src_side="left", dst_side="right")
    for branch in ("button", "wake"):
        d.edge("how", branch, src_side="bottom", dst_side="top", elbow="v")
        d.edge(branch, "chime", src_side="bottom", dst_side="top", elbow="v")

    chain = ["chime", "stream", "crops", "rek", "found"]
    labels = {("crops", "rek"): "local FaceQuality model"}
    for a, b in zip(chain, chain[1:]):
        d.edge(a, b, labels.get((a, b), ""), src_side="bottom", dst_side="top", label_side="right")
    for o in ("o1", "o2", "o3", "o4"):
        d.edge("found", o, src_side="bottom", dst_side="top", elbow="v")
        d.edge(o, "speak", src_side="bottom", dst_side="top", elbow="v")
    d.edge("phonespeaker", "speak", dashed=True, color=MUTED)

    d.edge("speak", "ask", src_side="bottom", dst_side="top")
    d.edge("ask", "fast", "no", src_side="bottom", dst_side="top", elbow="v", label_at=0.85, label_side="left")
    d.edge("ask", "grok", "yes", src_side="bottom", dst_side="top", elbow="v", label_at=0.85, label_side="right")
    d.edge("grok", "reply", src_side="bottom", dst_side="top")
    d.edge("fast", "log", src_side="bottom", dst_side="top", elbow="v")
    d.edge("reply", "log", src_side="bottom", dst_side="top", elbow="v")
    d.edge("log", "portal", "within a minute")
    return d


# ============================================================= provider flow
def provider_flow() -> Diagram:
    W, H = 1300, 880
    d = Diagram(W, H, "Provider flow", "What a clinician or caregiver does in the portal, and where it goes.")
    MX, MW, SH = 480, 340, 64
    LX, RX, SW = 100, 950, 250
    Y = [140, 236, 332, 428, 524, 620]

    d.node("open", MX, Y[0], MW, SH, "Open the provider portal")
    d.node("connect", MX, Y[1], MW, SH, "Connect Google Calendar")
    d.node("gcal", RX, Y[1], SW, SH, "Google Calendar", "Google", kind="external")
    d.node("noconnect", LX, Y[1], SW, SH, "Not connected? Violet uses only", kind="muted", title_size=14.5)
    d.node("details", MX, Y[2], MW, SH, "Edit patient details")
    d.node("peopleedit", MX, Y[3], MW, SH, "Add or edit familiar people", "up to 10, three photos each")
    d.node("atlas", LX, Y[3], SW, SH, "Atlas", "MongoDB", kind="external")
    d.node("visits", MX, Y[4], MW, SH, "Schedule visits")
    d.node("analytics", MX, Y[5], MW, SH, "Read the analytics")
    d.node("phone", LX, Y[5], SW, SH, "Patient's phone", "recognition logs")

    PY, PW = 740, 280
    xs = [45 + i * (PW + 30) for i in range(4)]
    d.node("p1", xs[0], PY, PW, SH, "Weekly uses vs. visitors", title_size=15)
    d.node("p2", xs[1], PY, PW, SH, "Time of day", title_size=15)
    d.node("p3", xs[2], PY, PW, SH, "Recognition health", title_size=15)
    d.node("p4", xs[3], PY, PW, SH, "Memory by person", title_size=15)

    chain = ["open", "connect", "details", "peopleedit", "visits", "analytics"]
    for a, b in zip(chain, chain[1:]):
        d.edge(a, b, src_side="bottom", dst_side="top")
    d.edge("noconnect", "connect", dashed=True, color=MUTED)
    d.edge("connect", "gcal", "sign in, load events", both=True)
    d.edge("visits", "gcal", "add or edit events", src_side="right", dst_side="bottom",
           via=[(RX + SW / 2, Y[4] + SH / 2)], label_at=0.3, label_side="above")
    d.edge("peopleedit", "atlas", "phone syncs within 60 s", src_side="left", dst_side="right", label_width=130)
    d.edge("phone", "analytics", "through Atlas")
    for p in ("p1", "p2", "p3", "p4"):
        d.edge("analytics", p, src_side="bottom", dst_side="top", elbow="v")
    return d


# ======================================================================= main
def main(argv: list[str]) -> int:
    svg_only = "--svg-only" in argv
    diagrams = {
        "architecture": architecture,
        "user-flow-patient": patient_flow,
        "user-flow-provider": provider_flow,
    }
    for name, build in diagrams.items():
        diagram = build()
        svg_path = OUT / f"{name}.svg"
        svg_path.write_text(diagram.svg())
        line = f"{svg_path.relative_to(ROOT)}  {svg_path.stat().st_size // 1024} KB"
        if not svg_only:
            png_path = OUT / f"{name}.png"
            renderer = render_png(svg_path, png_path, int(diagram.width), int(diagram.height), scale=2)
            line += f"   -> {png_path.name} via {renderer}" if renderer != "none" else "   (PNG not rendered: no Chrome or Quick Look)"
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
