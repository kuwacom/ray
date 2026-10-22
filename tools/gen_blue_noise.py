"""
ブルーノイズテクスチャ (shaders/textures/blue_noise.png, 128x128, RGBA 各チャンネル独立) を生成する

Ulichney 1993 の void-and-cluster 法を自前実装したもの。トーラス上のガウス核でエネルギーを測る。
使い方: uv run tools/gen_blue_noise.py
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "shaders" / "textures" / "blue_noise.png"
SIZE = 128
SIGMA = 1.9
INITIAL_DENSITY = 0.1


def torus_kernel(n: int, sigma: float) -> np.ndarray:
    d = np.minimum(np.arange(n), n - np.arange(n)).astype(np.float64)
    d2 = d[:, None] ** 2 + d[None, :] ** 2
    return np.exp(-d2 / (2.0 * sigma * sigma))


def void_and_cluster(n: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    kernel = torus_kernel(n, SIGMA)

    def splat(energy: np.ndarray, idx: int, sign: float) -> None:
        y, x = divmod(idx, n)
        energy += sign * np.roll(np.roll(kernel, y, axis=0), x, axis=1)

    mask = np.zeros((n, n), dtype=bool)
    ones = rng.choice(n * n, int(n * n * INITIAL_DENSITY), replace=False)
    mask.flat[ones] = True
    energy = np.real(np.fft.ifft2(np.fft.fft2(mask.astype(np.float64)) * np.fft.fft2(kernel)))

    # 初期パターンの整列: 最も密な 1 を最も疎な 0 へ移し、動かなくなるまで繰り返す
    while True:
        cluster = int(np.argmax(np.where(mask, energy, -np.inf)))
        mask.flat[cluster] = False
        splat(energy, cluster, -1.0)
        void = int(np.argmin(np.where(mask, np.inf, energy)))
        if void == cluster:
            mask.flat[cluster] = True
            splat(energy, cluster, 1.0)
            break
        mask.flat[void] = True
        splat(energy, void, 1.0)

    rank = np.zeros(n * n, dtype=np.int64)
    initial_mask = mask.copy()
    initial_energy = energy.copy()
    count = int(mask.sum())

    # 段階 1: 初期パターンの 1 を密な順に取り除いて順位を付ける
    m, e = mask.copy(), energy.copy()
    for r in range(count - 1, -1, -1):
        cluster = int(np.argmax(np.where(m, e, -np.inf)))
        m.flat[cluster] = False
        splat(e, cluster, -1.0)
        rank[cluster] = r

    # 段階 2: 最も疎な 0 を順に埋めて残りの順位を付ける
    m, e = initial_mask, initial_energy
    for r in range(count, n * n):
        void = int(np.argmin(np.where(m, np.inf, e)))
        m.flat[void] = True
        splat(e, void, 1.0)
        rank[void] = r

    return (rank.reshape(n, n) * 256 // (n * n)).astype(np.uint8)


def write_png(path: Path, rgba: np.ndarray) -> None:
    h, w, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main() -> None:
    channels = [void_and_cluster(SIZE, seed) for seed in (1, 2, 3, 4)]
    write_png(OUT, np.stack(channels, axis=-1))
    # 最近傍・繰り返しで参照する (texelFetch でも sampler でも同じ値になるように)
    OUT.with_name(OUT.name + ".mcmeta").write_text('{\n  "texture": {\n    "blur": false,\n    "clamp": false\n  }\n}\n', encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
