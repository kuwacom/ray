"""
雲のノイズテクスチャ (shaders/textures/cloud_*.dat, Iris の customTexture で読む生データ) を生成する

- cloud_shape.dat   128^3 RG8    r = Perlin-Worley (Schneider 2015 の考え方), g = Worley fbm (もこもこした塊)
- cloud_detail.dat   64^3 RGBA8  r = 高周波 Worley fbm (縁の浸食), gba = curl ノイズ (0.5 が 0)
- cloud_noise2d.dat 512^2 RGBA8  r = 積雲のセル (大), g = なめらかな fbm, b = 積雲のセル (中), a = 細かいセル (小さな積雲・高積雲・巻積雲)

すべて周期境界 (繰り返し参照で継ぎ目なし)。格子点の乱数を周期で巻き戻す Perlin / Worley を numpy で自前実装している。
2D の各チャンネルはヒストグラムを平坦化し、シェーダー側で「値 > 1 - 被覆率」とすると空に占める割合がそのまま被覆率になるようにする。
生データの並びは x (s) が最速、次に y (t)、最後に z (r)。シェーダーは 3D を (ワールド x, 高度, ワールド z) で引く。

使い方: uv run tools/gen_cloud_noise.py
"""

from __future__ import annotations

import itertools
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "shaders" / "textures"
SEED = 20261019
# raw テクスチャはバイリニア + 繰り返しで読む (Iris の raw の既定は clamp なので mcmeta で上書きする)
MCMETA = '{\n  "texture": {\n    "blur": true,\n    "clamp": false\n  }\n}\n'


def grid(size: int, dim: int) -> list[np.ndarray]:
    """[0,1) の格子座標 (配列の軸は z, y, x の順。戻り値は x, y, z の順)"""
    axis = (np.arange(size, dtype=np.float32) + 0.5) / size
    mesh = np.meshgrid(*([axis] * dim), indexing="ij")
    return list(reversed(mesh))


def perlin(coords: list[np.ndarray], freqs: tuple[int, ...], rng: np.random.Generator) -> np.ndarray:
    """周期 Perlin 勾配ノイズ。coords は周期 1 の座標 (範囲外も可)、freqs は軸ごとの格子数。戻り値はおよそ [-1, 1]"""
    dim = len(coords)
    grads = rng.normal(size=tuple(reversed(freqs)) + (dim,)).astype(np.float32)
    grads /= np.linalg.norm(grads, axis=-1, keepdims=True)
    p = [c * f for c, f in zip(coords, freqs)]
    i0 = [np.floor(v).astype(np.int64) for v in p]
    fr = [v - i for v, i in zip(p, i0)]
    fade = [f * f * f * (f * (f * 6.0 - 15.0) + 10.0) for f in fr]
    out = np.zeros_like(coords[0], dtype=np.float32)
    for corner in itertools.product((0, 1), repeat=dim):
        idx = tuple((i0[a] + corner[a]) % freqs[a] for a in reversed(range(dim)))
        g = grads[idx]
        dot = sum(g[..., a] * (fr[a] - corner[a]) for a in range(dim))
        w = np.ones_like(out)
        for a in range(dim):
            w *= fade[a] if corner[a] else 1.0 - fade[a]
        out += w * dot
    return out * (1.5 if dim == 3 else 1.414)


def worley(coords: list[np.ndarray], freq: int, rng: np.random.Generator) -> np.ndarray:
    """周期 Worley (F1, セル単位の距離)。1 から引くと特徴点で 1、セル境界で 0 になる"""
    dim = len(coords)
    points = rng.random(size=(freq,) * dim + (dim,)).astype(np.float32)
    p = [c * freq for c in coords]
    i0 = [np.floor(v).astype(np.int64) for v in p]
    fr = [v - i for v, i in zip(p, i0)]
    best = np.full_like(coords[0], 1e9, dtype=np.float32)
    for off in itertools.product((-1, 0, 1), repeat=dim):
        idx = tuple((i0[a] + off[a]) % freq for a in reversed(range(dim)))
        fp = points[idx]
        d2 = sum((off[a] + fp[..., a] - fr[a]) ** 2 for a in range(dim))
        best = np.minimum(best, d2)
    return np.sqrt(best)


def worley_fbm(coords: list[np.ndarray], base: int, rng: np.random.Generator) -> np.ndarray:
    """反転 Worley の 3 オクターブ和 (0.625 / 0.25 / 0.125)。[0,1]"""
    out = np.zeros_like(coords[0], dtype=np.float32)
    for k, w in enumerate((0.625, 0.25, 0.125)):
        out += w * np.clip(1.0 - worley(coords, base << k, rng), 0.0, 1.0)
    return out


def perlin_fbm(coords: list[np.ndarray], base: tuple[int, ...], octaves: int, rng: np.random.Generator) -> np.ndarray:
    out = np.zeros_like(coords[0], dtype=np.float32)
    amp, total = 1.0, 0.0
    for k in range(octaves):
        out += amp * perlin(coords, tuple(f << k for f in base), rng)
        total += amp
        amp *= 0.5
    return out / total


def normalize(x: np.ndarray, lo: float = 0.5, hi: float = 99.5) -> np.ndarray:
    a, b = np.percentile(x, [lo, hi])
    return np.clip((x - a) / (b - a), 0.0, 1.0)


def equalize(x: np.ndarray) -> np.ndarray:
    """順位で一様分布に写す (しきい値 = 面積の割合にする)"""
    flat = x.ravel()
    rank = np.empty(flat.size, dtype=np.float64)
    rank[np.argsort(flat, kind="stable")] = np.arange(flat.size)
    return (rank / (flat.size - 1)).reshape(x.shape).astype(np.float32)


def to_u8(x: np.ndarray) -> np.ndarray:
    return np.clip(np.round(x * 255.0), 0, 255).astype(np.uint8)


def write_raw(name: str, channels: list[np.ndarray]) -> None:
    data = np.stack([to_u8(c) for c in channels], axis=-1)
    path = OUT_DIR / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(np.ascontiguousarray(data).tobytes())
    path.with_name(path.name + ".mcmeta").write_text(MCMETA, encoding="utf-8")
    print(f"wrote {path} ({data.shape}, {path.stat().st_size} bytes)")


def gen_shape(rng: np.random.Generator) -> None:
    c = grid(128, 3)
    # Perlin の fbm を Worley の fbm で持ち上げる: Perlin のつながった塊に Worley の丸い縁が付く
    p = perlin_fbm(c, (4, 4, 4), 3, rng) * 0.5 + 0.5
    w = worley_fbm(c, 4, rng)
    pw = (p - (w - 1.0)) / (2.0 - w)
    billow = worley_fbm(c, 6, rng)
    write_raw("cloud_shape.dat", [normalize(pw), normalize(billow)])


def curl(potential: list[np.ndarray], size: int) -> list[np.ndarray]:
    """周期格子上のベクトルポテンシャルの回転 (中心差分)。配列の軸 0 = z, 1 = y, 2 = x"""
    px, py, pz = potential

    def d(f: np.ndarray, axis: int) -> np.ndarray:
        return (np.roll(f, -1, axis=axis) - np.roll(f, 1, axis=axis)) * (size * 0.5)

    cx = d(pz, 1) - d(py, 0)
    cy = d(px, 0) - d(pz, 2)
    cz = d(py, 2) - d(px, 1)
    return [cx, cy, cz]


def gen_detail(rng: np.random.Generator) -> None:
    size = 64
    c = grid(size, 3)
    erosion = normalize(worley_fbm(c, 4, rng))
    potential = [perlin_fbm(c, (2, 2, 2), 2, rng) for _ in range(3)]
    v = curl(potential, size)
    scale = np.percentile(np.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2), 99.0)
    v = [np.clip(x / scale, -1.0, 1.0) * 0.5 + 0.5 for x in v]
    write_raw("cloud_detail.dat", [erosion] + v)


def gen_noise2d(rng: np.random.Generator) -> None:
    size = 512
    c = grid(size, 2)

    # r: 積雲のセル。大小のセルを重ね、Perlin で輪郭をゆらす
    cells = sum(w * np.clip(1.0 - worley(c, f, rng), 0.0, 1.0) for f, w in ((8, 0.6), (16, 0.3), (32, 0.1)))
    cells = cells * 0.8 + (perlin_fbm(c, (4, 4), 2, rng) * 0.5 + 0.5) * 0.2

    # g: なめらかな fbm (層状の雲の濃淡・まとまり)
    smooth = perlin_fbm(c, (4, 4), 4, rng)

    # b: 巻雲の筋。x 方向に長い Perlin の稜線 (1 - |n|) を、ゆっくりした fbm で y 方向に曲げる (鉤状の巻雲)
    bend = perlin_fbm(c, (2, 2), 2, rng) * 0.06
    warped = [c[0], c[1] + bend]
    fibers = np.zeros_like(c[0])
    for k, (fx, fy, w) in enumerate(((2, 16, 0.55), (4, 32, 0.3), (8, 64, 0.15))):
        ridge = 1.0 - np.abs(perlin(warped, (fx, fy), rng))
        fibers += w * ridge ** (3.0 + k)
    clumps = perlin_fbm(c, (4, 4), 2, rng) * 0.5 + 0.5
    fibers *= 0.35 + 0.65 * clumps

    # a: 細かいセル (うろこ雲・いわし雲の粒)
    grains = 0.7 * np.clip(1.0 - worley(c, 32, rng), 0.0, 1.0) + 0.3 * np.clip(1.0 - worley(c, 64, rng), 0.0, 1.0)

    # b: 中くらいの積雲のセル (r の 8 と a の 32 の間の 18)。r / b / a を 1 回のフェッチで読み、積雲の大きさをべき乗則の分布にする。
    # 以前の巻雲の筋 (fibers) は巻雲を体積にしたので使わない。乱数の消費順を保つため fibers は計算したまま、別の乱数列で作る
    del fibers
    rng_mid = np.random.default_rng(SEED + 1)
    mids = 0.75 * np.clip(1.0 - worley(c, 18, rng_mid), 0.0, 1.0) + 0.25 * np.clip(1.0 - worley(c, 36, rng_mid), 0.0, 1.0)
    mids = mids * 0.85 + (perlin_fbm(c, (6, 6), 2, rng_mid) * 0.5 + 0.5) * 0.15

    write_raw("cloud_noise2d.dat", [equalize(cells), equalize(smooth), equalize(mids), equalize(grains)])


def main() -> None:
    rng = np.random.default_rng(SEED)
    gen_noise2d(rng)
    gen_detail(rng)
    gen_shape(rng)


if __name__ == "__main__":
    main()
