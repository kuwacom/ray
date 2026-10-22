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
処方は公開されている代表的な設計 (Zemax サンプルのダブルガウス等) を基にした近似で、実在レンズの実測値ではない

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


def refractive_index(glass: str | None, wavelength_nm: float) -> float:
    if glass is None:
        return 1.0
    nd, vd = GLASSES[glass]
    lf, lc, ld = 0.4861, 0.6563, 0.5876
    b = (nd - 1.0) / vd / (1.0 / lf**2 - 1.0 / lc**2)
    a = nd - b / ld**2
    lum = wavelength_nm / 1000.0
    return a + b / lum**2


@dataclass
class Surface:
    radius: float
    thickness: float
    glass: str | None  # この面の後ろの媒質
    semi_diameter: float
    stop: bool = False


def S(r: float, t: float, g: str | None, sd: float) -> Surface:
    return Surface(r, t, g, sd)


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

DESIGNS = [("dg6", DESIGN_DG6), ("dg7", DESIGN_DG7), ("petzval", DESIGN_PETZVAL)]
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
        self.surfaces = [Surface(s.radius, s.thickness, s.glass, s.semi_diameter, s.stop) for s in surfaces]
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
            for wl in R_WAVELENGTHS:
                n1i, n2i = media(i, wl)
                n1j, n2j = media(j, wl)
                ri = surface_reflectance(n1i, n2i, coating, dwl[i], wl)
                rj = surface_reflectance(n1j, n2j, coating, dwl[j], wl)
                refl.append(ri * rj)
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
    out.append(" * 表番号 = 設計 x 3 + コーティング (設計 0=ダブルガウス 6 枚, 1=7 枚, 2=Petzval / コート 0=マルチ, 1=単層, 2=無し)")
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

