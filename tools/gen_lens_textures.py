"""
レンズ用テクスチャを生成する
- shaders/textures/lens_starburst.dat (RGBA8, 1024x256): 絞りの Fraunhofer 回折 (スターバースト) を極座標で焼いたもの
  絞り羽根 0 (円), 5, 6, 7, 8, 9, 10, 13 枚の 8 タイルを横に並べる。タイル内は
  x = 光条の中心からの角度 (半周期を鏡映, 0 = 光条の中心), y = log 半径 (Airy 半径の 0.25 .. 50 倍)
  値は中心の強度で割った強度の 1/4 乗 (8bit で 10 桁の範囲を持たせる)
  手順 (Hullin 2011 3.3 節): 絞り透過関数 -> 2D FFT のパワースペクトル -> 400-700nm を 5nm 刻みで
  λ に比例して拡大しながら重ね、CIE 1931 等色関数 -> 線形 sRGB で RGB に積分 (赤の光条が青より長くなる)
- shaders/textures/lens_dirt.png (RGBA8, 1024x512): 前玉の汚れ (ほこり, 水滴の跡, 指紋, 拭き跡, ヘイズ)。r = 濃さ

使い方: uv run tools/gen_lens_textures.py
"""
from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
TEX = ROOT / "shaders" / "textures"

BLADES = (0, 5, 6, 7, 8, 9, 10, 13)
TILE_W = 128
TILE_H = 256
GRID = 2048
APERTURE_RADIUS = 96.0
# 羽根の丸み (lib/post/camera.glsl の apertureShape と同じ式)
BLADE_ROUNDNESS = 0.15
R_MIN_AIRY = 0.25
R_MAX_AIRY = 50.0
LAMBDA_REF = 550.0


def lobe(lam: np.ndarray, mu: float, s1: float, s2: float) -> np.ndarray:
    s = np.where(lam < mu, s1, s2)
    return np.exp(-0.5 * ((lam - mu) / s) ** 2)


def cie_xyz(lam: np.ndarray) -> np.ndarray:
    # Wyman, Sloan, Shirley 2013 の多峰ガウス近似
    x = 1.056 * lobe(lam, 599.8, 37.9, 31.0) + 0.362 * lobe(lam, 442.0, 16.0, 26.7) - 0.065 * lobe(lam, 501.1, 20.4, 26.2)
    y = 0.821 * lobe(lam, 568.8, 46.9, 40.5) + 0.286 * lobe(lam, 530.9, 16.3, 31.1)
    z = 1.217 * lobe(lam, 437.0, 11.8, 36.0) + 0.681 * lobe(lam, 459.0, 26.0, 13.8)
    return np.stack([x, y, z], axis=-1)


XYZ_TO_SRGB = np.array([[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]])


def spectral_weights(lams: np.ndarray) -> np.ndarray:
    """波長ごとの線形 sRGB の重み (負は切り捨て、等エネルギー白が (1,1,1) になるよう正規化)"""
    rgb = np.clip(cie_xyz(lams) @ XYZ_TO_SRGB.T, 0.0, None)
    return rgb / rgb.sum(axis=0, keepdims=True)


def aperture_mask(blades: int, rng: np.random.Generator) -> np.ndarray:
    c = GRID / 2
    yy, xx = np.mgrid[0:GRID, 0:GRID].astype(np.float64)
    dx, dy = xx - c, yy - c
    r = np.hypot(dx, dy)
    theta = np.arctan2(dy, dx)
    if blades > 0:
        seg = 2.0 * np.pi / blades
        local = theta - seg * np.floor(theta / seg + 0.5)
        poly = np.cos(np.pi / blades) / np.cos(local)
        shape = poly + (1.0 - poly) * BLADE_ROUNDNESS
        # 羽根ごとのわずかな位置のばらつき (実物の絞りは完全な正多角形ではない)
        k = np.floor(theta / seg + 0.5).astype(int) % blades
        jitter = 1.0 + rng.normal(0.0, 0.004, blades)
        shape = shape * jitter[k]
    else:
        shape = np.ones_like(r)
    edge = APERTURE_RADIUS * shape
    mask = np.clip(edge - r + 0.5, 0.0, 1.0)
    # 絞り付近のほこり (小さな遮蔽)。広く薄い散乱ヘイズになる
    for _ in range(40):
        a = rng.uniform(0, 2 * np.pi)
        rr = APERTURE_RADIUS * np.sqrt(rng.uniform(0, 0.9))
        px, py = c + rr * np.cos(a), c + rr * np.sin(a)
        size = rng.uniform(0.6, 1.6)
        mask *= 1.0 - np.exp(-((xx - px) ** 2 + (yy - py) ** 2) / (size * size)) * 0.8
    return mask


def bilinear(img: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    x0 = np.clip(np.floor(x).astype(int), 0, img.shape[1] - 2)
    y0 = np.clip(np.floor(y).astype(int), 0, img.shape[0] - 2)
    fx, fy = x - x0, y - y0
    a = img[y0, x0] * (1 - fx) + img[y0, x0 + 1] * fx
    b = img[y0 + 1, x0] * (1 - fx) + img[y0 + 1, x0 + 1] * fx
    return a * (1 - fy) + b * fy


def bake_starburst_tile(blades: int, rng: np.random.Generator) -> np.ndarray:
    mask = aperture_mask(blades, rng)
    power = np.abs(np.fft.fftshift(np.fft.fft2(mask))) ** 2
    c = GRID / 2
    airy_px = 1.22 * GRID / (2.0 * APERTURE_RADIUS)
    peak = power[int(c), int(c)]

    if blades == 0:
        period = 2.0 * np.pi
        spikes = 1
    else:
        spikes = blades if blades % 2 == 0 else blades * 2
        period = 2.0 * np.pi / spikes
    v = (np.arange(TILE_H) + 0.5) / TILE_H
    radius_airy = R_MIN_AIRY * (R_MAX_AIRY / R_MIN_AIRY) ** v
    u = (np.arange(TILE_W) + 0.5) / TILE_W
    phi_local = u * period * 0.5

    lams = np.arange(400.0, 701.0, 5.0)
    weights = spectral_weights(lams)
    out = np.zeros((TILE_H, TILE_W, 3))
    # 全ての光条の向きと鏡映を平均する (ばらつきとほこりの斑を均す)
    copies = []
    for k in range(spikes if blades > 0 else 8):
        base = k * (period if blades > 0 else 2.0 * np.pi / 8)
        copies.append(base + phi_local)
        copies.append(base - phi_local)
    for li, lam in enumerate(lams):
        scale = LAMBDA_REF / lam
        rr = radius_airy[:, None] * airy_px * scale
        acc = np.zeros((TILE_H, TILE_W))
        for ang in copies:
            x = c + rr * np.cos(ang[None, :])
            y = c + rr * np.sin(ang[None, :])
            acc += bilinear(power, x, y)
        acc *= scale * scale / len(copies)
        out += acc[..., None] * weights[li][None, None, :]
    return out / peak


def write_png(path: Path, rgba: np.ndarray) -> None:
    h, w, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].astype(np.uint8).tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def write_mcmeta(path: Path, blur: bool, clamp: bool) -> None:
    path.with_name(path.name + ".mcmeta").write_text(
        json.dumps({"texture": {"blur": blur, "clamp": clamp}}, indent=2) + "\n", encoding="utf-8")


def gen_starburst() -> None:
    rng = np.random.default_rng(1234)
    tiles = []
    for b in BLADES:
        t = bake_starburst_tile(b, rng)
        tiles.append(t)
        print(f"starburst blades={b}: r=1 {t[int(TILE_H * 0.29), 0]}, r=10 {t[int(TILE_H * 0.69), 0]}")
    img = np.concatenate(tiles, axis=1)
    enc = np.clip(img, 0.0, 1.0) ** 0.25
    rgba = np.zeros((TILE_H, TILE_W * len(BLADES), 4), dtype=np.uint8)
    rgba[..., :3] = np.round(enc * 255.0).astype(np.uint8)
    rgba[..., 3] = 255
    path = TEX / "lens_starburst.dat"
    path.write_bytes(rgba.tobytes())
    write_mcmeta(path, True, True)
    print(f"wrote {path}")


def blur(img: np.ndarray, sigma: float) -> np.ndarray:
    h, w = img.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    k = np.exp(-2.0 * (np.pi * sigma) ** 2 * (fx * fx + fy * fy))
    return np.real(np.fft.ifft2(np.fft.fft2(img) * k))


def gen_dirt() -> None:
    rng = np.random.default_rng(99)
    w, h = 1024, 512
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    dirt = np.zeros((h, w))

    # ほこり: 前玉のほこりはピントが合わず、縁の少し明るい円盤になる
    for _ in range(260):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        rad = rng.lognormal(1.2, 0.55)
        d = np.hypot(xx - cx, yy - cy) / rad
        disc = np.clip(1.0 - d, 0.0, 1.0) ** 0.3 * (0.6 + 0.4 * np.exp(-((d - 0.85) / 0.12) ** 2))
        dirt += disc * rng.uniform(0.15, 0.6)
    # 水滴の跡: 大きく薄い斑で、乾いた縁が濃い
    for _ in range(9):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        rad = rng.uniform(12, 40)
        d = np.hypot((xx - cx) * rng.uniform(0.8, 1.2), yy - cy) / rad
        dirt += (np.exp(-((d - 1.0) / 0.12) ** 2) * 0.15 + np.clip(1.0 - d, 0, 1) * 0.1) * rng.uniform(0.3, 0.8)
    # 指紋: 楕円の同心の隆線を、ぼかした楕円で切り抜く
    for _ in range(3):
        cx, cy = rng.uniform(0.15, 0.85) * w, rng.uniform(0.15, 0.85) * h
        ang = rng.uniform(0, np.pi)
        ca, sa = np.cos(ang), np.sin(ang)
        px, py = (xx - cx) * ca + (yy - cy) * sa, -(xx - cx) * sa + (yy - cy) * ca
        e = np.hypot(px / 1.0, py / 1.35)
        # 隆線は細かく途切れ途切れにする (規則的な同心円は波紋に見える)
        ridge = 0.5 + 0.5 * np.cos(e * 1.6 + 1.2 * np.sin(px * 0.07) + 0.8 * np.sin(py * 0.05))
        breakup = np.clip(blur(rng.normal(0, 1, (h, w)), 3.0) * 4.0 + 0.5, 0.0, 1.0)
        env = np.exp(-(e / rng.uniform(45, 70)) ** 4)
        dirt += (ridge * breakup * 0.5 + 0.5) * env * 0.12
    # 拭き跡: 長く細い弧
    for _ in range(4):
        cx, cy = rng.uniform(-0.2, 1.2) * w, rng.uniform(-0.2, 1.2) * h
        rad = rng.uniform(250, 700)
        width = rng.uniform(2, 6)
        d = np.abs(np.hypot(xx - cx, yy - cy) - rad)
        dirt += np.exp(-(d / width) ** 2) * rng.uniform(0.02, 0.05)
    dirt = blur(dirt, 1.2)
    # 低周波のヘイズ (油膜の薄い曇り)
    haze = np.zeros((h, w))
    for octave in range(5):
        n = rng.normal(0, 1, (h, w))
        haze += blur(n, 64.0 / (2 ** octave)) * (0.5 ** octave)
    haze = (haze - haze.min()) / (haze.max() - haze.min())
    dirt = dirt + haze * 0.35
    dirt = np.clip(dirt / np.percentile(dirt, 99.7), 0.0, 1.0)

    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    v = np.round(dirt * 255.0).astype(np.uint8)
    rgba[..., 0] = v
    rgba[..., 1] = v
    rgba[..., 2] = v
    rgba[..., 3] = 255
    path = TEX / "lens_dirt.png"
    write_png(path, rgba[::-1])
    write_mcmeta(path, True, True)
    print(f"wrote {path} mean={dirt.mean():.3f}")


def main() -> None:
    import sys
    if "--dirt-only" not in sys.argv:
        gen_starburst()
    gen_dirt()


if __name__ == "__main__":
    main()
