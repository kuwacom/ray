"""テクスチャの書き出し (生成スクリプトが共通で使う)"""

from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

import numpy as np


def write_png(path: Path, rgba: np.ndarray) -> None:
    """RGBA 8bit の配列 (高さ x 幅 x 4) を、外部のライブラリなしで PNG にする"""
    h, w, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].astype(np.uint8).tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def write_mcmeta(path: Path, blur: bool = True, clamp: bool = True) -> None:
    """テクスチャの隣に置く .mcmeta (補間と端の扱い)"""
    path.with_name(path.name + ".mcmeta").write_text(
        json.dumps({"texture": {"blur": blur, "clamp": clamp}}, indent=2) + "\n", encoding="utf-8")
