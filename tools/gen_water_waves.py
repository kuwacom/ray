"""
水面の波テクスチャ (shaders/textures/water_waves.dat, Iris の customTexture で読む生データ) を生成する

Tessendorf (2001) の FFT 海面を 1 枚の周期タイルに焼く。シェーダーはこのタイルを無理数比の倍率で何層も重ねる
- 128^2 x 64 フレーム RGBA8。r, g = 高さの勾配 (x, z), b = 高さ, a = 水平変位の発散 (Jacobian の 1 次の項。波頭で正)
- 空間も時間も周期境界 (x, z, 時間の 3 方向に繰り返して継ぎ目なし)
- スペクトルは平衡域 (Phillips の k^-4 の尾、傾きの分散が波数の対数あたり一定) に、対数波数の cos^2 窓を掛けた帯
  隣の層 (波数を WATER_LAYER_RATIO 倍した同じタイル) の窓と足すとちょうど 1 になるので、層を重ねると切れ目のない
  スペクトルになる。風速による最大の波 (Pierson-Moskowitz / JONSWAP のピーク) は層ごとの重みでシェーダーが付ける
- 方向分布は Longuet-Higgins の cos^2s(theta / 2) (風下 +x に偏り、風上へはほぼ進まない)
- 時間発展は深水の分散関係 omega = sqrt(g k)。ループさせるため omega を基本周波数の整数倍に丸める
  タイルの大きさ L の層では、ループの周期 T = TIME_HARMONIC_LO * sqrt(2 pi L / (N_LO g)) 秒 (シェーダーと同じ式)
  波数の比が s の 2 つの層は時間の比が sqrt(s) になり、どの層でも分散関係が保たれる
- 値は層の傾きの分散 <sx^2 + sz^2> = 1 で正規化し、ENCODE_* の範囲で 8 bit に詰める (シェーダーの WATER_TEX_* と揃える)

生データの並びは x (s) が最速、次に z (t)、最後に時間 (r)

使い方: uv run tools/gen_water_waves.py
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "shaders" / "textures"
SEED = 20261021
SIZE = 128
FRAMES = 64
# 層の倍率 (シェーダーの WATER_LAYER_RATIO と同じ)。窓の半幅 (対数) がこの比になる
LAYER_RATIO = 2.9
# 窓の中心の波数 (タイルあたりの波の数)。帯は BAND_CENTER / LAYER_RATIO .. BAND_CENTER * LAYER_RATIO (約 2.9 .. 24.7)
BAND_CENTER = 8.5
# 方向分布の鋭さ s。大きいほど波頭が風に直交して長く揃う
SPREAD = 12.0
# ループの基本周波数に対する、波数 N_LO の波の周波数の倍数 (小さいほどフレームの補間が楽で、分散関係の丸めが粗い)
TIME_HARMONIC_LO = 4.0
N_LO = 3.0
# 8 bit に詰める範囲 (正規化した値の +-)
ENCODE_SLOPE = 3.0
ENCODE_SIGMA = 4.0
MCMETA = '{\n  "texture": {\n    "blur": true,\n    "clamp": false\n  }\n}\n'


def spectrum(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    n = np.fft.fftfreq(SIZE, 1.0 / SIZE)
    # 配列の軸は (z, x)
    nz, nx = np.meshgrid(n, n, indexing="ij")
    nk = np.hypot(nx, nz)
    safe = np.maximum(nk, 1e-6)
    x = np.log(safe / BAND_CENTER) / math.log(LAYER_RATIO)
    window = np.where(np.abs(x) < 1.0, np.cos(0.5 * math.pi * x) ** 2, 0.0)
    theta = np.arctan2(nz, nx)
    spread = np.abs(np.cos(0.5 * theta)) ** (2.0 * SPREAD)
    power = np.where(nk > 0.5, safe ** -4.0, 0.0) * window * spread
    xi = (rng.standard_normal(nk.shape) + 1j * rng.standard_normal(nk.shape)) / math.sqrt(2.0)
    h0 = xi * np.sqrt(power)
    # 時間の周波数 (ループあたりの回数) を整数に丸める
    harmonic = np.round(TIME_HARMONIC_LO * np.sqrt(nk / N_LO))
    return nx, nz, h0, harmonic


def main() -> None:
    rng = np.random.default_rng(SEED)
    nx, nz, h0, harmonic = spectrum(rng)
    neg = (-np.arange(SIZE)) % SIZE
    h0_neg_conj = np.conj(h0[neg][:, neg])
    kx = 2.0 * math.pi * nx
    kz = 2.0 * math.pi * nz
    kk = np.hypot(kx, kz)

    fields = np.zeros((FRAMES, SIZE, SIZE, 4), np.float64)
    for f in range(FRAMES):
        phase = np.exp(-2j * math.pi * harmonic * f / FRAMES)
        h = h0 * phase + h0_neg_conj * np.conj(phase)
        fields[f, ..., 0] = np.fft.ifft2(1j * kx * h).real
        fields[f, ..., 1] = np.fft.ifft2(1j * kz * h).real
        fields[f, ..., 2] = np.fft.ifft2(h).real
        # 水平変位 D = -i k/|k| h の発散は |k| h。波頭を寄せる向き (x' = x - lambda D) で Jacobian = 1 - lambda |k| h
        fields[f, ..., 3] = np.fft.ifft2(kk * h).real

    slope_rms = math.sqrt(float(np.mean(fields[..., 0] ** 2 + fields[..., 1] ** 2)))
    fields /= slope_rms
    sigma_h = float(np.std(fields[..., 2]))
    sigma_j = float(np.std(fields[..., 3]))
    ranges = [ENCODE_SLOPE, ENCODE_SLOPE, ENCODE_SIGMA * sigma_h, ENCODE_SIGMA * sigma_j]
    clipped = [float(np.mean(np.abs(fields[..., c]) > ranges[c])) for c in range(4)]
    enc = np.stack([np.clip(np.round((fields[..., c] / ranges[c] * 0.5 + 0.5) * 255.0), 0, 255) for c in range(4)], axis=-1)
    data = enc.astype(np.uint8)

    path = OUT_DIR / "water_waves.dat"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(np.ascontiguousarray(data).tobytes())
    path.with_name(path.name + ".mcmeta").write_text(MCMETA, encoding="utf-8")
    print(f"wrote {path} ({data.shape}, {path.stat().st_size} bytes)")
    print(f"slope rms x {float(np.std(fields[..., 0])):.4f} z {float(np.std(fields[..., 1])):.4f}")
    # シェーダーの WATER_TEX_HEIGHT_RANGE / WATER_TEX_JACOBIAN_RANGE (タイルの長さ = 1, 傾きの分散 = 1 の単位)
    print(f"height range {ranges[2]:.6f} (sigma {sigma_h:.6f}) jacobian range {ranges[3]:.6f} (sigma {sigma_j:.6f})")
    print("clipped fraction", [round(c, 5) for c in clipped])


if __name__ == "__main__":
    main()
