"""
レンズ処方 (球面の列) から 2 回反射のゴースト光路を近軸 (ABCD 行列) で解き、
GLSL の定数表 shaders/lib/post/lens_ghosts.glsl を書き出す

手法: Lee & Eisemann 2013「Practical Real-Time Lens-Flare Rendering」の行列近似を自前で実装
- 光線の状態は (前玉での高さ h, 入射角 theta) の 1 次式。ゴーストごとにセンサー上の位置
  y = A h + B theta と、絞りを最初に通る高さ y_a = Aa h + Ba theta を求める
- ランタイムは y から h を逆算し、絞り (多角形) と前玉の縁 (円) の両方を通るかで形を決める
  光源の角度で 2 つの円がずれるので、ゴーストは光源の位置に応じて欠けた形に変わる
- 反射率はコーティング (単層 MgF2 / 3 層マルチ / 無し) を特性行列法で波長ごとに計算する
- 波長ごとの屈折率は (nd, Vd) から Cauchy 式で近似する

長さは有効焦点距離 1 に正規化する (ランタイムでは tan 単位のセンサー座標で使う)
設計 0-2 は公開されている代表的な設計 (Zemax サンプルのダブルガウス等) を基にした近似で、実在レンズの実測値ではない
設計 3-8 は特許の実施例の処方 (公称焦点距離に拡大した mm, 硝材は特許の (nd, vd))。有効半径は推定値
(surfaceandstop.com の推定)。照合の記録は docs/reference/techniques/vintage-lenses.md

使い方: uv run tools/gen_lens_ghosts.py
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "shaders" / "lib" / "post" / "lens_ghosts.glsl"

INF = float("inf")
# ABCD を評価する波長 (nm)。ランタイムは 2 次補間する
ABCD_WAVELENGTHS = (450.0, 550.0, 650.0)
# 反射率を評価する波長 (nm)。ランタイムは折れ線補間する
R_WAVELENGTHS = (420.0, 485.0, 550.0, 615.0, 680.0)
# 1 表あたりのゴースト数 (明るさと大きさで選んだ上位。品質設定で先頭から使う数を変える)
GHOSTS_PER_TABLE = 24
# 小さすぎるゴーストは点に収束して無限に明るくなるので、評価上の下限を置く (ランタイムの LENS_GHOST_MIN_SCALE と揃える)
MIN_SCALE = 0.03

# 硝材: (nd, Vd)
GLASSES = {
    "BK7": (1.5168, 64.17),
    "SK2": (1.6074, 56.65),
    "SK16": (1.6204, 60.32),
    "F2": (1.6200, 36.37),
    "F5": (1.6034, 38.03),
}


Glass = str | tuple[float, float] | None


def refractive_index(glass: Glass, wavelength_nm: float) -> float:
    if glass is None:
        return 1.0
    # 特許の処方は硝材名ではなく (nd, vd) で書かれているので、そのまま受け取る
    nd, vd = glass if isinstance(glass, tuple) else GLASSES[glass]
    lf, lc, ld = 0.4861, 0.6563, 0.5876
    b = (nd - 1.0) / vd / (1.0 / lf**2 - 1.0 / lc**2)
    a = nd - b / ld**2
    lum = wavelength_nm / 1000.0
    return a + b / lum**2


@dataclass
class Surface:
    radius: float
    thickness: float
    glass: Glass  # この面の後ろの媒質
    semi_diameter: float
    stop: bool = False
    # この面の後ろの媒質を 1 回通る時の光学的な厚さ (吸収。STF の ND ガラス)。ゴーストは主光路より 2 回多く通る
    absorb: float = 0.0


def S(r: float, t: float, g: Glass, sd: float, absorb: float = 0.0) -> Surface:
    return Surface(r, t, g, sd, False, absorb)


def STOP(t: float, sd: float) -> Surface:
    return Surface(INF, t, None, sd, True)


# 6 枚 4 群のダブルガウス (Biotar / Helios 44 型)。Zemax の Double Gauss サンプル (f=100, F/3 相当) に基づく
DESIGN_DG6 = [
    S(54.153253, 8.746658, "SK2", 29.0),
    S(152.52192, 0.5, None, 29.0),
    S(35.951466, 14.0, "SK16", 24.0),
    S(INF, 3.776966, "F5", 24.0),
    S(22.270355, 14.253059, None, 16.0),
    STOP(12.428129, 10.5),
    S(-25.685033, 3.776966, "F5", 13.0),
    S(INF, 10.833929, "SK16", 17.0),
    S(-36.980898, 0.5, None, 17.0),
    S(196.41707, 6.858175, "SK16", 18.0),
    S(-67.147884, 0.0, None, 18.0),
]

# 7 枚 6 群 (Super Takumar 50/1.4 / FD 50/1.4 / 近代の大口径標準の系統)。DG6 の後群を 2 枚に分けた近似
DESIGN_DG7 = [
    S(60.0, 7.5, "SK16", 31.0),
    S(240.0, 0.4, None, 31.0),
    S(33.5, 11.5, "SK16", 25.0),
    S(150.0, 3.2, "F5", 25.0),
    S(21.5, 13.0, None, 17.0),
    STOP(11.0, 11.0),
    S(-24.0, 3.2, "F5", 14.0),
    S(-150.0, 9.0, "SK16", 17.0),
    S(-33.0, 0.4, None, 17.0),
    S(320.0, 5.0, "SK16", 18.0),
    S(-110.0, 0.4, None, 18.0),
    S(130.0, 4.5, "SK16", 18.0),
    S(-260.0, 0.0, None, 18.0),
]

# Petzval 肖像レンズ (前群: 貼り合わせアクロマート, 後群: 分離した 2 枚)。古典的な配置の近似
DESIGN_PETZVAL = [
    S(56.0, 6.0, "BK7", 21.0),
    S(-45.0, 2.0, "F2", 21.0),
    S(-400.0, 20.0, None, 21.0),
    STOP(20.0, 14.0),
    S(110.0, 2.0, "F2", 16.0),
    S(38.0, 2.5, None, 16.0),
    S(44.0, 5.0, "BK7", 16.0),
    S(-140.0, 0.0, None, 16.0),
]

# ---- 特許の実施例 (mm, 面の後ろの媒質は (nd, vd))。最終面の間隔はバックフォーカスで、Lens() が近軸焦点に置き直す ----

# Zeiss Sonnar 50mm f/1.5 (Contax): US 2,186,621 Fig. 1 (先行技術として載った量産品の処方) を x0.5
DESIGN_SONNAR = [
    S(34.605, 4.665, (1.671, 47.2), 17),
    S(216.92, 0.19, None, 17),
    S(17.93, 5.905, (1.671, 47.2), 14.5),
    S(42.89, 3.525, (1.4892, 70.1), 14.5),
    S(-323.155, 0.95, (1.7394, 28.2), 14.5),
    S(11.755, 6.2484, None, 9.8),
    STOP(1.3716, 0.0),
    S(INF, 1.24, (1.5232, 50.9), 9.9),
    S(25.545, 9.905, (1.6578, 51.2), 9.9),
    S(-11.06, 2.285, (1.5894, 61.2), 9.9),
    S(-51.565, 22.4576, None, 11.6),
]

# Leica Summilux 35mm f/1.4 (初代): US 2,975,673 Table 1 を x35。屈折率は特許どおり e 線の値
DESIGN_SUMMILUX35 = [
    S(29.4598, 3.5, (1.72341, 50.1), 14.9),
    S(89.9115, 0.021, None, 14.9),
    S(13.447, 4.5395, (1.7899, 48), 11.65),
    S(30.2365, 1.309, (1.70444, 29.84), 11.65),
    S(8.932, 6.06112, None, 8.02),
    STOP(2.02038, 0.0),
    S(-56.2695, 1.939, (1.7899, 48), 8),
    S(-30.2365, 1.729, None, 7.56),
    S(-12.068, 1.309, (1.76167, 27.34), 9.4),
    S(-47.999, 4.599, (1.7899, 48), 9.4),
    S(-16.0125, 0.5985, None, 10.6),
    S(-700, 4.7985, (1.72056, 47.69), 12.9),
    S(-29.4595, 19.1415, None, 12.9),
]

# Canon 50mm f/1.2 (1956): US 2,836,102 Example 2 を x0.5
DESIGN_CANON50 = [
    S(47, 4.5, (1.6935, 53.5), 23.2),
    S(125.965, 0.105, None, 23),
    S(34.495, 4, (1.7173, 47.9), 21.3),
    S(60.17, 0.48, None, 21),
    S(25.48, 10.24, (1.6385, 55.5), 19),
    S(-160.85, 2.195, (1.7174, 29.5), 15.25),
    S(13.72, 6.45595, None, 11.5),
    STOP(4.19905, 0.0),
    S(-21.51, 1.065, (1.5174, 52.5), 11.5),
    S(38.37, 6.2, (1.6935, 53.5), 13),
    S(-36.43, 1.065, None, 13.7),
    S(90.79, 3.585, (1.6935, 53.5), 13.7),
    S(-47.145, 21.0723, None, 13.7),
]

# Zeiss Hologon 15mm f/8: US 3,661,447 Table I を x15。絞りは中央の両凸レンズの中 (ガラスの中) にある
DESIGN_HOLOGON = [
    S(11.64, 7.9785, (1.80518, 25.46), 11.45),
    S(3.843, 2.703, None, 3.82),
    S(5.6685, 3.8243, (1.713, 53.89), 3.83),
    Surface(INF, 3.8243, (1.713, 53.89), 0.0, True),
    S(-5.508, 2.4045, None, 3.83),
    S(-3.6285, 5.2365, (1.80518, 25.46), 3.6),
    S(-8.9835, 4.545, None, 8.84),
]

# Carl Zeiss Jena Flektogon 20mm f/4: DE 1,192,845 B 実施例 1 を x20。絞りは面 9 と 10 の間の中央に置いた
DESIGN_FLEKTOGON = [
    S(64.4, 5.39, (1.6935, 53.6), 29),
    S(144.68, 0.094, None, 29),
    S(23.81, 2.08, (1.6935, 53.6), 19),
    S(13.566, 5.862, None, 12),
    S(33.52, 1.892, (1.6935, 53.6), 13),
    S(10.402, 5.2, None, 8.6),
    S(126.04, 2.836, (1.62, 60.3), 10),
    S(17.02, 12.198, (1.55, 45.4), 10),
    S(INF, 0.236, None, 10),
    STOP(0.236, 0.0),
    S(14.534, 2.174, (1.728, 38), 5.9),
    S(8.52, 4.444, (1.61, 38), 5.9),
    S(-20.538, 1.75, None, 5.9),
    S(-15.356, 0.992, (1.678, 32.2), 5),
    S(8.464, 2.08, (1.516, 56.8), 5.6),
    S(29.786, 3.168, (1.678, 50.8), 5.9),
    S(-14.732, 36.13, None, 6.3),
]

# Minolta Fish-eye Rokkor 16mm f/2.8: US 3,589,798 Embodiment II を x16。内蔵フィルターは空気換算の間隔に置き換えた
DESIGN_FISHEYE16 = [
    S(121.331, 2.08, (1.6204, 60.3), 27),
    S(18.992, 7.8544, None, 16.8),
    S(39.6592, 1.92, (1.6176, 52.7), 15.5),
    S(16.7424, 7.6544, None, 12),
    S(-43.368, 1.6, (1.6205, 60.3), 12),
    S(67.2912, 7.5216, (1.7495, 34.9), 11.5),
    S(-51.664, 0.144, None, 10.7),
    S(34.7952, 7.592, (1.733, 28.2), 9.5),
    S(INF, 2.53335, None, 7.1),
    STOP(4.7696, 0.0),
    S(-27.32, 5.4096, (1.6214, 61.2), 7.3),
    S(-9.7264, 2.3696, (1.733, 28.2), 8.3),
    S(-21.4528, 0.144, None, 10.4),
    S(-129.21, 1.36, (1.74, 37.5), 11.5),
    S(25.8256, 6.32, (1.5688, 56), 12.6),
    S(-32.72, 0.144, None, 12.8),
    S(53.8352, 4.56, (1.5168, 64.2), 14.8),
    S(-56.5568, 36.3804, None, 15),
]

# ---- 第 2 弾 (#51)。非球面は近軸のゴースト計算には効かないので頂点の曲率半径だけ ----

# Nikon Gyogyotto 20mm f/8: US 5,949,588 Table 8 を x0.2。絞りは最後のレンズの直後
DESIGN_GYOGYOTTO = [
    S(INF, 3.0057, (1.62041, 60.14), 31.23),
    S(20.3317, 50.1331, None, 18.72),
    S(22.0347, 13.9901, (1.80518, 25.35), 6.31),
    S(9.8628, 3.5067, (1.67025, 57.53), 6.31),
    S(-82.2908, 0.0, None, 2.42),
    STOP(39.574, 0.0),
]

# Voigtländer Ultra Wide-Heliar 12mm f/5.6: JP 2001-124985 A 実施例 1 を x12
DESIGN_UWH12 = [
    S(23.496, 1.92, (1.7725, 49.6), 17),
    S(12.576, 6.6, None, 11.3),
    S(64.32, 1.8, (1.7725, 49.6), 12.6),
    S(10.716, 4.32, None, 8.5),
    S(86.712, 3.36, (1.80518, 25.5), 10),
    S(-39.804, 2.16, None, 10),
    S(12.612, 1.92, (1.84666, 23.8), 8),
    S(8.376, 2.04, None, 6.5),
    S(10.992, 5.52, (1.5168, 64.2), 6.9),
    S(-19.644, 0.6, None, 6.9),
    S(47.148, 3, (1.48749, 70.4), 5.1),
    S(-14.76, 0.96, None, 5.1),
    STOP(2.04, 0.0),
    S(-21.012, 2.28, (1.834, 37.3), 4.2),
    S(-9.132, 0.96, (1.71736, 29.5), 4.2),
    S(-83.7, 1.56, None, 4.9),
    S(-8.832, 1.2, (1.62004, 36.3), 5.2),
    S(1759.704, 4.32, (1.58913, 61.3), 8.2),
    S(-9.348, 13.56, None, 8.2),
]

# Canon New FD 14mm f/2.8L: JP S57-64716 A 実施例 1 を x14
DESIGN_FD14 = [
    S(42.0021, 3.0392, (1.6968, 55.5), 31.6),
    S(25.6158, 11.3023, None, 24.3),
    S(57.4921, 5.7142, (1.60311, 60.7), 24),
    S(51.1617, 0.1401, None, 20),
    S(30.7838, 1.6666, (1.6968, 55.5), 17.7),
    S(15.658, 6.9467, None, 14),
    S(41.61, 1.2745, (1.7725, 49.6), 12.5),
    S(18.165, 5.4761, None, 12),
    S(298.7348, 1.4706, (1.6968, 55.5), 10.5),
    S(13.1651, 9.3276, (1.59551, 39.2), 10.5),
    S(-48.7247, 2.479, None, 10),
    S(52.114, 8.4593, (1.54814, 45.8), 10),
    S(-10.7841, 1.4706, (1.7725, 49.6), 9.2),
    S(-14.1594, 0.9804, None, 9),
    S(-14.3835, 0.8823, (1.7725, 49.6), 8),
    S(-28.1648, 0.8823, None, 7.5),
    STOP(0.8823, 0.0),
    S(275.1497, 9.8178, (1.6668, 33), 7.8),
    S(-24.1873, 2.1708, (1.62004, 36.3), 8.8),
    S(65.2231, 0.6302, None, 7.55),
    S(-230.6686, 0.7843, (1.92286, 21.3), 7.55),
    S(29.9295, 5.4341, (1.48749, 70.1), 9.4),
    S(-18.6132, 0.098, None, 9.4),
    S(1429.6553, 2.8851, (1.804, 46.6), 10.2),
    S(-35.3076, 36.9862, None, 10.5),
]

# Minolta STF 135mm f/2.8 [T4.5]: JP H11-231209 A 実施例 1 (x1)
# L5 は ND ガラスの平凹レンズ。吸収は製品の T 値に合わせた 0.378 /mm x 開口の平均の厚さ 3.31 mm
DESIGN_STF135 = [
    S(75.063, 9, (1.60311, 60.74), 34),
    S(INF, 0.25, None, 34),
    S(37.102, 3, (1.72342, 37.99), 28),
    S(26.475, 16, (1.5168, 64.2), 23.7),
    S(104.186, 2.05, None, 21),
    S(678.979, 2, (1.61293, 36.96), 21),
    S(30.584, 14.397, None, 18.5),
    STOP(1.5, 0.0),
    S(INF, 0.3, (1.5069, 58.94), 15, absorb=1.25),
    S(20.731, 9.33, (1.50137, 56.46), 16),
    S(INF, 17.25, None, 16),
    S(97.643, 7.5, (1.58913, 61.11), 20),
    S(-47.53, 9.5, None, 20),
    S(-41.707, 1.8, (1.62041, 60.29), 18.5),
    S(-923.182, 46.8002, None, 18.5),
]

# Pentax FA 28mm f/2.8 Soft: US 5,822,132 Example 1 を x0.28
DESIGN_FA28SOFT = [
    S(378.2775, 2.916, (1.58913, 61.2), 18.97),
    S(-422.7849, 0.1009, None, 18.97),
    S(63.1135, 2.3308, (1.62041, 60.3), 15.75),
    S(13.9243, 19.4739, None, 11.92),
    S(23.5906, 10.7056, (1.7725, 49.6), 9.87),
    S(-47.595, 1.6245, None, 9.87),
    STOP(3.4407, 0.0),
    S(-23.6915, 1.9474, (1.7847, 26.2), 6.93),
    S(34.9723, 0.6458, None, 6.6),
    S(192.2364, 3.1178, (1.7725, 49.6), 6.6),
    S(-18.0512, 35.6281, None, 7.25),
]

# Canon 50mm f/0.95: JP S39-10178 実施例 1 (PhotonsToPhotos の転記) を 50mm に
DESIGN_CANON50F095 = [
    S(73.05, 5.85, (1.79952, 42.3), 30.25),
    S(290.85, 0.1, None, 30.25),
    S(46.15, 5.15, (1.67002, 47.2), 25.25),
    S(82, 0.1, None, 25.25),
    S(27.15, 12.2, (1.6935, 53.4), 21.5),
    S(-152.15, 3.15, (1.7552, 27.5), 21.5),
    S(15.1, 7.3, None, 12.9),
    STOP(4, 0.0),
    S(-23.1, 2, (1.5927, 35.4), 12.9),
    S(62.45, 7.25, (1.7859, 44.3), 14.65),
    S(-36.4, 0.1, None, 14.65),
    S(60.65, 5.8, (1.7859, 44.3), 17.25),
    S(-65.15, 19.7384, None, 17.25),
]

# 表番号 = 設計の順番 x 3 + コーティング。既存の表 (0-8) の番号と乱数の種を変えないよう、新しい設計は後ろに足す
DESIGNS = [
    ("dg6", DESIGN_DG6),
    ("dg7", DESIGN_DG7),
    ("petzval", DESIGN_PETZVAL),
    ("sonnar50", DESIGN_SONNAR),
    ("summilux35", DESIGN_SUMMILUX35),
    ("canon50", DESIGN_CANON50),
    ("hologon15", DESIGN_HOLOGON),
    ("flektogon20", DESIGN_FLEKTOGON),
    ("fisheye16", DESIGN_FISHEYE16),
    ("gyogyotto20", DESIGN_GYOGYOTTO),
    ("uwh12", DESIGN_UWH12),
    ("fd14", DESIGN_FD14),
    ("stf135", DESIGN_STF135),
    ("fa28soft", DESIGN_FA28SOFT),
    ("canon50f095", DESIGN_CANON50F095),
]
COATINGS = ["multi", "single", "none"]


def thin_film_reflectance(layers: list[tuple[float, float]], n0: float, ns: float, wl: float) -> float:
    """特性行列法の反射率 (垂直入射)。layers は入射側から (屈折率, 物理膜厚 nm)"""
    m = np.identity(2, dtype=complex)
    for n, d in layers:
        delta = 2.0 * math.pi * n * d / wl
        layer = np.array([[math.cos(delta), 1j * math.sin(delta) / n], [1j * n * math.sin(delta), math.cos(delta)]])
        m = m @ layer
    b, c = m @ np.array([1.0, ns])
    r = (n0 * b - c) / (n0 * b + c)
    return float(abs(r) ** 2)


def surface_reflectance(n1: float, n2: float, coating: str, design_wl: float, wl: float) -> float:
    if n1 > 1.0001 and n2 > 1.0001:
        # 貼り合わせ面 (ガラス同士) はコーティングしない
        return ((n1 - n2) / (n1 + n2)) ** 2
    ns = max(n1, n2)
    if coating == "none":
        return ((ns - 1.0) / (ns + 1.0)) ** 2
    if coating == "single":
        # MgF2 の 1/4 波長膜。設計波長で反射が最小になり、残る反射は青と赤 (アンバー / マゼンタ)
        layers = [(1.38, design_wl / (4.0 * 1.38))]
    else:
        # 1/4 - 1/2 - 1/4 の 3 層 (MgF2 / ZrO2 / 中屈折率膜 n=1.70)。広帯域で 0.5% 以下、残りは緑と紫に色付く
        layers = [
            (1.38, design_wl / (4.0 * 1.38)),
            (2.05, design_wl / (2.0 * 2.05)),
            (1.70, design_wl / (4.0 * 1.70)),
        ]
    return thin_film_reflectance(layers, 1.0, ns, wl)


class Lens:
    def __init__(self, surfaces: list[Surface]):
        self.surfaces = [Surface(s.radius, s.thickness, s.glass, s.semi_diameter, s.stop, s.absorb) for s in surfaces]
        self.z = []
        z = 0.0
        for s in self.surfaces:
            self.z.append(z)
            z += s.thickness
        self.stop_index = next(i for i, s in enumerate(self.surfaces) if s.stop)
        # 最終面の後ろの距離 (バックフォーカス) を 550nm の近軸焦点に合わせる
        bfl, efl = self._focus(550.0)
        self.surfaces[-1].thickness = bfl
        self.image_z = self.z[-1] + bfl
        self.efl = efl

    def n_after(self, i: int, wl: float) -> float:
        return refractive_index(self.surfaces[i].glass, wl)

    def n_before(self, i: int, wl: float) -> float:
        return 1.0 if i == 0 else refractive_index(self.surfaces[i - 1].glass, wl)

    def curvature(self, i: int) -> float:
        r = self.surfaces[i].radius
        return 0.0 if math.isinf(r) else 1.0 / r

    def _focus(self, wl: float) -> tuple[float, float]:
        y, u = 1.0, 0.0
        z = 0.0
        for i, s in enumerate(self.surfaces):
            y += u * (self.z[i] - z)
            z = self.z[i]
            if s.stop:
                continue
            n1, n2 = self.n_before(i, wl), self.n_after(i, wl)
            u = (n1 * u - y * self.curvature(i) * (n2 - n1)) / n2
        bfl = -y / u
        efl = -1.0 / u
        if bfl <= 0.0 or efl <= 0.0:
            raise ValueError(f"invalid design: bfl={bfl} efl={efl}")
        return bfl, efl

    def trace(self, events: list[tuple[int, str]], wl: float) -> tuple[np.ndarray, np.ndarray | None]:
        """
        events: (面の番号, 'refract' | 'reflect') の列。光線は 2 つの基底 (h=1,θ=0) と (h=0,θ=1) を同時に追う
        戻り値: センサー上の高さ [A, B] と、絞りを最初に通った高さ [Aa, Ba]
        """
        y = np.array([1.0, 0.0])
        u = np.array([0.0, 1.0])
        z = 0.0
        n = 1.0
        stop_hit = None
        for idx, kind in events:
            target = self.z[idx]
            if stop_hit is None:
                zs = self.z[self.stop_index]
                if min(z, target) <= zs <= max(z, target) and z != target:
                    stop_hit = y + u * (zs - z)
            y = y + u * (target - z)
            z = target
            c = self.curvature(idx)
            if kind == "reflect":
                u = -u - 2.0 * c * y
                continue
            # 進行方向で屈折の前後の媒質が入れ替わる (今いる媒質と反対側へ抜ける)
            n_fwd_before, n_fwd_after = self.n_before(idx, wl), self.n_after(idx, wl)
            n1 = n
            n2 = n_fwd_after if abs(n - n_fwd_before) < 1e-9 else n_fwd_before
            u = (n1 * u - y * c * (n2 - n1)) / n2
            n = n2
        if stop_hit is None:
            zs = self.z[self.stop_index]
            if min(z, self.image_z) <= zs <= max(z, self.image_z):
                stop_hit = y + u * (zs - z)
        y = y + u * (self.image_z - z)
        return y, stop_hit

    def refracting(self) -> list[int]:
        return [i for i, s in enumerate(self.surfaces) if not s.stop]

    def main_path(self) -> list[tuple[int, str]]:
        return [(i, "refract") for i in self.refracting()]

    def ghost_path(self, i: int, j: int) -> list[tuple[int, str]]:
        rs = self.refracting()
        ev = [(k, "refract") for k in rs if k < j]
        ev.append((j, "reflect"))
        ev += [(k, "refract") for k in reversed(rs) if i < k < j]
        ev.append((i, "reflect"))
        ev += [(k, "refract") for k in rs if k > i]
        return ev


def design_wavelengths(count: int, seed: int, coating: str) -> list[float]:
    # 面ごとにコーティングの設計波長を少しずつ変える (実レンズでも面ごとに膜が違い、ゴーストの色が揃わない)
    rng = np.random.default_rng(seed)
    # マルチコートは帯域が狭く、設計波長を外すと紫の端で反射が急に増えるので、ばらつきを小さくする
    lo, hi = (505.0, 525.0) if coating == "multi" else (490.0, 580.0)
    return [float(v) for v in rng.uniform(lo, hi, count)]


@dataclass
class Ghost:
    i: int
    j: int
    s: tuple[float, float, float]
    a: tuple[float, float, float]
    ka: tuple[float, float, float]
    kb: tuple[float, float, float]
    r: tuple[float, ...]
    score: float


def build_table(surfaces: list[Surface], coating: str, seed: int):
    lens = Lens(surfaces)
    f = lens.efl
    rs = lens.refracting()
    dwl = design_wavelengths(len(lens.surfaces), seed, coating)

    def media(k: int, wl: float) -> tuple[float, float]:
        return lens.n_before(k, wl), lens.n_after(k, wl)

    main = {}
    for wl in ABCD_WAVELENGTHS:
        y, ya = lens.trace(lens.main_path(), wl)
        main[wl] = (y, ya)
    b_main = main[550.0][0][1]
    ka_main = main[550.0][1][0]

    ghosts: list[Ghost] = []
    for ii in range(len(rs)):
        for jj in range(ii + 1, len(rs)):
            i, j = rs[ii], rs[jj]
            s_l, a_l, ka_l, kb_l = [], [], [], []
            for wl in ABCD_WAVELENGTHS:
                y, ya = lens.trace(lens.ghost_path(i, j), wl)
                bm = main[wl][0][1]
                # 長さは焦点距離 1 に正規化。センサー座標は主光路の像 (B_main θ) を基準にする
                # A と KA は長さ / 長さなので無次元のまま
                s_l.append(y[1] / bm)
                a_l.append(y[0])
                ka_l.append(ya[0])
                kb_l.append(ya[1] / bm)
            refl = []
            # 面 i と j の間の媒質は主光路より 2 回多く通る (吸収のある媒質だけ効く)
            absorb = math.exp(-2.0 * sum(lens.surfaces[k].absorb for k in range(i, j)))
            for wl in R_WAVELENGTHS:
                n1i, n2i = media(i, wl)
                n1j, n2j = media(j, wl)
                ri = surface_reflectance(n1i, n2i, coating, dwl[i], wl)
                rj = surface_reflectance(n1j, n2j, coating, dwl[j], wl)
                refl.append(ri * rj * absorb)
            a550 = abs(a_l[1])
            if a550 > 6.0:
                continue
            score = refl[2] / max(a550, MIN_SCALE * 3.0) ** 2
            ghosts.append(Ghost(i, j, tuple(s_l), tuple(a_l), tuple(ka_l), tuple(kb_l), tuple(refl), score))
    ghosts.sort(key=lambda g: -g.score)
    ghosts = ghosts[:GHOSTS_PER_TABLE]
    front = lens.surfaces[0].semi_diameter / f
    return ghosts, ka_main / 1.0, front, b_main / f


def fmt(v: float) -> str:
    return f"{v:.6g}" if abs(v) >= 1e-4 or v == 0.0 else f"{v:.4e}"


def vec(vals) -> str:
    return f"vec{len(vals)}(" + ", ".join(fmt(v) for v in vals) + ")"


def main() -> None:
    out = []
    out.append("/*")
    out.append(" * 自動生成: tools/gen_lens_ghosts.py (手で編集しない)")
    out.append(" * ゴースト (2 回反射の光路) の近軸パラメータ表。長さは焦点距離 1、センサー座標は tan 単位")
    out.append(" * GHOST_S  : ゴースト中心の位置 = S * 光源像の位置 (λ = 450 / 550 / 650 nm)")
    out.append(" * GHOST_A  : 前玉の高さ h からセンサーへの倍率 (y = A h + S y_L)")
    out.append(" * GHOST_KA, GHOST_KB: 絞りを最初に通る高さ = KA h + KB y_L")
    out.append(" * GHOST_R0 / R1: 2 面の反射率の積 (λ = 420 / 485 / 550 / 615 | 680 nm)")
    out.append(" * GHOST_KA_MAIN: 主光路の前玉 -> 絞りの倍率 (絞り半径 = 入射瞳半径 x |KA_MAIN|)")
    out.append(" * GHOST_FRONT_RADIUS: 前玉の有効半径")
    out.append(" * 表番号 = 設計 x 3 + コーティング (設計 0=ダブルガウス 6 枚, 1=7 枚, 2=Petzval, 3=Sonnar 50/1.5, 4=Summilux 35/1.4,")
    out.append(" *   5=Canon 50/1.2, 6=Hologon 15/8, 7=Flektogon 20/4, 8=Fish-eye Rokkor 16/2.8, 9=Gyogyotto 20/8, 10=Ultra Wide-Heliar 12/5.6,")
    out.append(" *   11=New FD 14/2.8L, 12=STF 135/2.8, 13=FA 28/2.8 Soft, 14=Canon 50/0.95 / コート 0=マルチ, 1=単層, 2=無し)")
    out.append(" */")
    out.append("#ifndef POST_LENS_GHOSTS_GLSL")
    out.append("#define POST_LENS_GHOSTS_GLSL")
    out.append("")
    out.append(f"const int GHOST_TABLE_SIZE = {GHOSTS_PER_TABLE};")
    first = True
    for di, (dname, design) in enumerate(DESIGNS):
        for ci, coat in enumerate(COATINGS):
            ghosts, ka_main, front, bm = build_table(design, coat, seed=17 + di * 7 + ci)
            idx = di * 3 + ci
            out.append(f"{'#if' if first else '#elif'} LENS_GHOST_TABLE == {idx} // {dname} / {coat}")
            first = False
            n = len(ghosts)
            out.append(f"const float GHOST_KA_MAIN = {fmt(abs(ka_main))};")
            out.append(f"const float GHOST_FRONT_RADIUS = {fmt(front)};")
            names = [("GHOST_S", "s", 3), ("GHOST_A", "a", 3), ("GHOST_KA", "ka", 3), ("GHOST_KB", "kb", 3)]
            for gname, attr, dim in names:
                vals = ", ".join(vec(getattr(g, attr)) for g in ghosts)
                out.append(f"const vec{dim} {gname}[{n}] = vec{dim}[{n}]({vals});")
            out.append(f"const vec4 GHOST_R0[{n}] = vec4[{n}](" + ", ".join(vec(g.r[:4]) for g in ghosts) + ");")
            out.append(f"const float GHOST_R1[{n}] = float[{n}](" + ", ".join(fmt(g.r[4]) for g in ghosts) + ");")
            print(f"table {idx} {dname}/{coat}: ghosts={n} KA_MAIN={ka_main:.3f} front={front:.3f} B_main={bm:.3f}")
            for g in ghosts[:6]:
                print(f"   surf {g.i}-{g.j}: s={g.s[1]:+.3f} a={g.a[1]:+.3f} R550={g.r[2]:.2e}")
    out.append("#endif")
    out.append("")
    out.append("#endif")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()

