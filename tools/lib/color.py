"""sRGB の区分曲線 (配列にも float にも使える)"""

from __future__ import annotations

import numpy as np


def srgb_to_linear(c):
    out = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return float(out) if np.ndim(c) == 0 else out


def linear_to_srgb(c, hi: float | None = None):
    """線形 -> sRGB。0 未満は 0 にする。hi を渡すとその値で打ち切る (LUT のように 1 を超える値を残したいときは None)"""
    c = np.clip(c, 0.0, hi)
    out = np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)
    return float(out) if np.ndim(c) == 0 else out
