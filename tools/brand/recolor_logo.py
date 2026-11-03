"""Recolour the HoTH logo from the original coral/teal/cream art to the Meta-like blue theme.

Deterministic, shape-preserving: every pixel is modelled as a blend between the paper colour and
ONE ink colour (coral shield or teal leaves; they never touch), so anti-aliased edges map to the
same blend of the new colours and leave no fringe. The paper/ink texture is kept by adding the
pixel's luminance residual (pixel minus its ideal blend) back on top of the new blend.

Reads only the saved originals in this folder, so re-running never recolours an already-blue
image. Writes:
  ios/HoTH/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png  (1024x1024 RGB, no alpha)
  ios/HoTH/Resources/Assets.xcassets/hoth_logo.imageset/hoth_logo.png (384x384 RGBA, squircle alpha kept)

Run from the repo root:
  uv run --with pillow --with numpy python tools/brand/recolor_logo.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

BRAND_DIR = Path(__file__).resolve().parent
REPO_ROOT = BRAND_DIR.parents[1]
ASSETS = REPO_ROOT / "ios/HoTH/Resources/Assets.xcassets"

ORIGINAL_ICON = BRAND_DIR / "logo_original_coral.png"
ORIGINAL_MARK = BRAND_DIR / "hoth_logo_original_coral.png"
OUTPUT_ICON = ASSETS / "AppIcon.appiconset/AppIcon.png"
OUTPUT_MARK = ASSETS / "hoth_logo.imageset/hoth_logo.png"

# New palette (sRGB 0-255).
NEW_PAPER = np.array([0xF5, 0xF7, 0xFA], dtype=np.float64)   # cool grey-white
NEW_SHIELD = np.array([0x08, 0x66, 0xFF], dtype=np.float64)  # theme accent
NEW_LEAVES = np.array([0x36, 0xC5, 0xF0], dtype=np.float64)  # light complementary cyan

# Paper fibres carry a faint warm tint that reads as a few % "ink"; below this knee the fraction
# fades to 0 so the grain stays grey instead of turning into blue specks. Real edges pass through.
FLECK_KNEE = (0.04, 0.14)

# How much of the original luminance texture to carry over, per layer.
PAPER_TEXTURE = 0.8
INK_TEXTURE = 1.0


def _luma(rgb: np.ndarray) -> np.ndarray:
    return rgb @ np.array([0.299, 0.587, 0.114])


def sample_anchors(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Median paper, coral and teal colours from strict, unambiguous pixel masks."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    paper = np.median(rgb[:96, :96].reshape(-1, 3), axis=0)
    coral_mask = (r - b) > 150
    teal_mask = ((g - r) > 45) & ((b - r) > 45)
    if coral_mask.sum() < 1000 or teal_mask.sum() < 500:
        raise ValueError("anchor masks too small: is this the original coral logo?")
    return paper, np.median(rgb[coral_mask], axis=0), np.median(rgb[teal_mask], axis=0)


def _blend_fraction(rgb: np.ndarray, paper: np.ndarray, ink: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Fraction t in [0, 1] of `ink` over `paper` per pixel, and the distance to that ideal blend."""
    axis = ink - paper
    t = np.clip(((rgb - paper) @ axis) / (axis @ axis), 0.0, 1.0)
    ideal = paper + t[..., None] * axis
    return t, np.linalg.norm(rgb - ideal, axis=-1)


def recolor(rgb: np.ndarray, anchors: tuple[np.ndarray, np.ndarray, np.ndarray]) -> np.ndarray:
    paper, coral, teal = anchors
    t_coral, err_coral = _blend_fraction(rgb, paper, coral)
    t_teal, err_teal = _blend_fraction(rgb, paper, teal)
    is_teal = err_teal < err_coral

    t = np.where(is_teal, t_teal, t_coral)
    low, high = FLECK_KNEE
    ramp = np.clip((t - low) / (high - low), 0.0, 1.0)
    t = t * ramp * ramp * (3 - 2 * ramp)  # smoothstep knee; t >= high is unchanged
    old_ink = np.where(is_teal[..., None], teal, coral)
    new_ink = np.where(is_teal[..., None], NEW_LEAVES, NEW_SHIELD)

    old_ideal = paper + t[..., None] * (old_ink - paper)
    new_ideal = NEW_PAPER + t[..., None] * (new_ink - NEW_PAPER)

    # Texture: luminance residual only (drops the warm tint of the paper grain), weighted by layer.
    residual = _luma(rgb - old_ideal)
    texture_gain = PAPER_TEXTURE + t * (INK_TEXTURE - PAPER_TEXTURE)
    out = new_ideal + (residual * texture_gain)[..., None]
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def main() -> None:
    icon = Image.open(ORIGINAL_ICON).convert("RGB")
    icon_rgb = np.asarray(icon, dtype=np.float64)
    anchors = sample_anchors(icon_rgb)
    print("anchors paper/coral/teal:", [a.round().astype(int).tolist() for a in anchors])

    new_icon = Image.fromarray(recolor(icon_rgb, anchors), mode="RGB")
    assert new_icon.mode == "RGB" and new_icon.size == icon.size
    new_icon.save(OUTPUT_ICON, optimize=True)

    mark = Image.open(ORIGINAL_MARK).convert("RGBA")
    mark_rgba = np.asarray(mark, dtype=np.float64)
    new_mark_rgb = recolor(mark_rgba[..., :3], anchors)
    alpha = np.asarray(mark)[..., 3:4]
    new_mark = Image.fromarray(np.concatenate([new_mark_rgb, alpha], axis=-1), mode="RGBA")
    assert new_mark.size == mark.size
    new_mark.save(OUTPUT_MARK, optimize=True)
    print(f"wrote {OUTPUT_ICON.relative_to(REPO_ROOT)} {new_icon.size} and {OUTPUT_MARK.relative_to(REPO_ROOT)} {new_mark.size}")


if __name__ == "__main__":
    main()
