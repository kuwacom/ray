"""
ルックの LUT (LOOK_LUT) を作る・変換する・確かめる

LUT は表示値 (sRGB エンコード後の 0-1) から表示値への写像。final.fsh がトーンマップの後、CDL の前に掛ける
- 同梱の 3D LUT (.dat): 33^3、RGBA16 (リトルエンディアンの uint16)、x = 赤が最速・次に y = 緑・z = 青 (.cube と同じ並び)。
  shaders.properties の `customTexture.lookLutTex = ... TEXTURE_3D RGBA16 33 33 33 RGBA UNSIGNED_SHORT` で読む
- ユーザーの LUT (shaders/textures/look/user_lut.png): 32^3 の PNG ストリップ 1024x32。青を 32 枚横に並べ、
  各枚は x = 赤、y = 緑 (上の行が緑 0)。恒等の画像に画像編集ソフトで色調補正を掛けて置き換えるだけで使える
- どちらも .mcmeta で双線形 + clamp にする (ファイルが無いとパックの読み込みが失敗するので恒等の画像を必ず置く)

使い方 (uv run tools/gen_look_lut.py <サブコマンド>):
  all                                    同梱の LUT をすべて作り直す (恒等の user_lut.png と tools/look_luts/*.json を焼いた .dat)
  identity --out x.dat [--size 33]       恒等の 3D LUT
  strip-identity --out x.png [--size 32] 恒等のストリップ PNG (ユーザーの LUT の雛形)
  bake params.json --out x.dat|x.png     パラメーターから焼く (下の BakeParams)
  from-cube in.cube --out x.dat|x.png    .cube (Resolve / Photoshop など) を読む。大きさが違えば三重線形で直す。入力は sRGB の表示値とみなす
  from-strip graded.png --out x.dat|x.cube  加工したストリップ PNG を 3D LUT や .cube に
  to-cube x.dat|x.png --out x.cube       .cube に書き出す (外のソフトで見る・直す)
  preview --lut x.dat|x.png|x.cube --in shot.png --out out.png [--strength 1]  撮影した画面に CPU で掛ける (ゲームを使わずに比べる)
  check x.dat|x.png ...                  大きさと恒等からのずれ、向き (隅の色) を表示
  test-swap-rb --out x.dat|x.png         赤と青を入れ替える LUT (テクスチャの向きの確認用。同梱しない)
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
LOOK_DIR = ROOT / "shaders" / "textures" / "look"
PARAMS_DIR = Path(__file__).resolve().parent / "look_luts"
DAT_SIZE = 33
STRIP_SIZE = 32
# 同梱の 3D LUT: shaders.properties の LOOK_LUT の番号と同じ並び (2 から)
BUNDLED = ("split_tone", "film", "portra", "ektar", "vision3_500t", "velvia", "provia", "eterna")
MCMETA = {"texture": {"blur": True, "clamp": True}}


# ---- 色の変換 (sRGB の区分曲線, Oklab) ----
def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def linear_to_oklab(c: np.ndarray) -> np.ndarray:
    lms = np.cbrt(c @ M1.T)
    return lms @ M2.T


def oklab_to_linear(lab: np.ndarray) -> np.ndarray:
    lms = lab @ np.linalg.inv(M2).T
    return (lms ** 3) @ np.linalg.inv(M1).T


LUMA = np.array([0.2126, 0.7152, 0.0722])


# ---- LUT の格子 (形 (B, G, R, 3) の表示値) ----
def identity_lut(size: int) -> np.ndarray:
    t = np.linspace(0.0, 1.0, size)
    b, g, r = np.meshgrid(t, t, t, indexing="ij")
    return np.stack([r, g, b], axis=-1)


def sample_lut(lut: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    """lut (B, G, R, 3) を表示値 rgb (..., 3) で三重線形に引く (シェーダーと同じ格子点の扱い)"""
    n = lut.shape[0]
    p = np.clip(rgb, 0.0, 1.0) * (n - 1)
    i0 = np.minimum(np.floor(p).astype(int), n - 2)
    f = p - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    out = np.zeros(rgb.shape, dtype=np.float64)
    for db in (0, 1):
        wb = fb if db else 1.0 - fb
        for dg in (0, 1):
            wg = fg if dg else 1.0 - fg
            for dr in (0, 1):
                wr = fr if dr else 1.0 - fr
                out += lut[b0 + db, g0 + dg, r0 + dr] * (wb * wg * wr)
    return out


def resize_lut(lut: np.ndarray, size: int) -> np.ndarray:
    if lut.shape[0] == size:
        return lut
    return sample_lut(lut, identity_lut(size))


# ---- 読み書き ----
def write_dat(lut: np.ndarray, path: Path) -> None:
    n = lut.shape[0]
    q = np.round(np.clip(lut, 0.0, 1.0) * 65535.0).astype("<u2")
    rgba = np.concatenate([q, np.full((n, n, n, 1), 65535, dtype="<u2")], axis=-1)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(rgba.tobytes())
    write_mcmeta(path)


def read_dat(path: Path) -> np.ndarray:
    data = np.frombuffer(path.read_bytes(), dtype="<u2")
    n = round((data.size / 4) ** (1.0 / 3.0))
    if n ** 3 * 4 != data.size:
        raise ValueError(f"{path}: 大きさが N^3 x 4 チャンネルではない ({data.size} 個)")
    return data.reshape(n, n, n, 4)[..., :3].astype(np.float64) / 65535.0


def write_strip(lut: np.ndarray, path: Path) -> None:
    n = lut.shape[0]
    # (B, G, R) -> 画像 (y = G, x = B * n + R)
    img = lut.transpose(1, 0, 2, 3).reshape(n, n * n, 3)
    a = np.round(np.clip(img, 0.0, 1.0) * 255.0).astype(np.uint8)
    rgba = np.concatenate([a, np.full((n, n * n, 1), 255, dtype=np.uint8)], axis=-1)
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgba, "RGBA").save(path)
    write_mcmeta(path)


def read_strip(path: Path) -> np.ndarray:
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    n = a.shape[0]
    if a.shape[1] != n * n:
        raise ValueError(f"{path}: ストリップは横 N^2 x 縦 N ({a.shape[1]}x{a.shape[0]})")
    return a.reshape(n, n, n, 3).transpose(1, 0, 2, 3)


def read_cube(path: Path) -> np.ndarray:
    size = 0
    dmin, dmax = np.zeros(3), np.ones(3)
    rows: list[list[float]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        key = s.split()[0].upper()
        if key == "LUT_3D_SIZE":
            size = int(s.split()[1])
        elif key == "DOMAIN_MIN":
            dmin = np.array([float(v) for v in s.split()[1:4]])
        elif key == "DOMAIN_MAX":
            dmax = np.array([float(v) for v in s.split()[1:4]])
        elif key in ("TITLE", "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE"):
            if key.startswith("LUT_1D"):
                raise ValueError(f"{path}: 1D の .cube には対応していない")
        else:
            rows.append([float(v) for v in s.split()[:3]])
    if size == 0 or len(rows) != size ** 3:
        raise ValueError(f"{path}: LUT_3D_SIZE {size} と行数 {len(rows)} が合わない")
    if np.any(dmin != 0.0) or np.any(dmax != 1.0):
        print(f"注意: DOMAIN が 0-1 ではない ({dmin} - {dmax})。表示値の 0-1 として読む", file=sys.stderr)
    return np.array(rows).reshape(size, size, size, 3)


def write_cube(lut: np.ndarray, path: Path, title: str) -> None:
    n = lut.shape[0]
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {n}", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
    lines += [f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in lut.reshape(-1, 3)]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_mcmeta(path: Path) -> None:
    path.with_name(path.name + ".mcmeta").write_text(json.dumps(MCMETA, indent=2) + "\n", encoding="ascii")


def read_any(path: Path) -> np.ndarray:
    suffix = path.suffix.lower()
    if suffix == ".dat":
        return read_dat(path)
    if suffix == ".png":
        return read_strip(path)
    if suffix == ".cube":
        return read_cube(path)
    raise ValueError(f"{path}: .dat / .png / .cube のどれか")


def write_any(lut: np.ndarray, path: Path) -> None:
    suffix = path.suffix.lower()
    if suffix == ".dat":
        write_dat(resize_lut(lut, DAT_SIZE), path)
    elif suffix == ".png":
        write_strip(resize_lut(lut, STRIP_SIZE), path)
    elif suffix == ".cube":
        write_cube(lut, path, path.stem)
    else:
        raise ValueError(f"{path}: .dat / .png / .cube のどれか")
    print(f"{path}")


# ---- パラメーターから焼く ----
@dataclass
class HueBand:
    center: float            # Oklab の色相 (度)
    width: float             # 半値幅 (度)。この幅のガウスで効かせる
    shift: float = 0.0       # 色相を回す量 (度)
    saturation: float = 1.0  # 彩度の倍率
    lightness: float = 0.0   # 明るさ (EV。線形の値に 2^x を掛ける)


@dataclass
class BakeParams:
    """
    演算は表示値 -> 線形 -> (色の混ざり -> 色温度 -> コントラスト -> チャンネルごとの階調 -> 輝度帯の彩度 -> 色相帯 -> 影と明部の色付け -> 全体の彩度)
    -> 表示値 -> 黒と白の位置
    - mix: 線形 RGB の 3x3 (行 = 出力)。フィルムの色素の重なり (クロストーク) で色の分かれ方を変える。各行の和を 1 にすると灰色は変わらない
    - wb: 線形 RGB に掛ける倍率 (白の輝度を保つように正規化する)。色温度の転び
    - contrast: 中間グレー (pivot, 線形) を軸に log2 で掛ける。黒と白の端は toe / shoulder で 0 と 1 へ戻す (LUT の外へ出さない)
    - channel_contrast: チャンネルごとのコントラスト (log2, pivot が軸)。フィルムの特性曲線が色ごとに違う傾きを持つのを近似する
    - sat_shadows / sat_mids / sat_highlights: 輝度帯ごとの彩度 (Oklab の彩度に掛ける。帯は線形輝度の 0.03 / 0.18 / 0.6 中心)
    - shadow_tint / highlight_tint: 色 (線形 RGB) と量。暗部・明部に向かって輝度を保ったまま色を寄せる (split toning)
    - hue_bands: 色相帯ごとの色相の回転・彩度・明るさ
    - black / white: 出力の黒と白の表示値 (フィルムのベースの濃度で黒が浮く・プリントで白が落ちる)
    """
    contrast: float = 1.0
    pivot: float = 0.18
    saturation: float = 1.0
    sat_shadows: float = 1.0
    sat_mids: float = 1.0
    sat_highlights: float = 1.0
    shadow_tint: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])
    shadow_tint_amount: float = 0.0
    highlight_tint: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])
    highlight_tint_amount: float = 0.0
    hue_bands: list[HueBand] = field(default_factory=list)
    mix: list[list[float]] | None = None
    wb: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])
    channel_contrast: list[float] = field(default_factory=lambda: [1.0, 1.0, 1.0])
    black: float = 0.0
    white: float = 1.0
    name: str = ""
    comment: str = ""


def load_params(path: Path) -> BakeParams:
    d = json.loads(path.read_text(encoding="utf-8"))
    bands = [HueBand(**b) for b in d.pop("hue_bands", [])]
    return BakeParams(**d, hue_bands=bands)


def smooth_band(x: np.ndarray, center: float, width: float) -> np.ndarray:
    return np.exp(-0.5 * ((x - center) / width) ** 2)


def bake(p: BakeParams, size: int) -> np.ndarray:
    disp = identity_lut(size).reshape(-1, 3)
    lin = srgb_to_linear(disp)
    if p.mix is not None:
        lin = np.maximum(lin @ np.array(p.mix, dtype=np.float64).T, 0.0)
    if p.wb != [1.0, 1.0, 1.0]:
        g = np.array(p.wb, dtype=np.float64)
        lin = lin * (g / (g @ LUMA))
    lum = lin @ LUMA

    # コントラスト: log2 で pivot を軸に。端 (黒 0 / 白 1) は変えない (sRGB の 0-1 を LUT の外に出さない)
    if p.contrast != 1.0:
        safe = np.maximum(lum, 1e-6)
        log_l = np.log2(safe / p.pivot) * p.contrast
        new_l = p.pivot * np.exp2(log_l)
        # 白の近くと黒の近くで元の輝度へ戻す
        w = smooth_band(np.log2(safe / p.pivot), 0.0, 2.2)
        new_l = lum + (np.minimum(new_l, 1.0) - lum) * w
        lin = lin * (new_l / safe)[:, None]
        lum = lin @ LUMA

    # チャンネルごとのコントラスト (端は全体のコントラストと同じく元へ戻す)
    if p.channel_contrast != [1.0, 1.0, 1.0]:
        cc = np.array(p.channel_contrast, dtype=np.float64)
        safe = np.maximum(lin, 1e-6)
        rel = np.log2(safe / p.pivot)
        w = smooth_band(rel, 0.0, 2.2)
        new = p.pivot * np.exp2(rel * cc)
        lin = lin + (np.minimum(new, 1.0) - lin) * w
        lum = lin @ LUMA

    lab = linear_to_oklab(np.maximum(lin, 0.0))
    chroma = np.hypot(lab[:, 1], lab[:, 2])
    hue = np.degrees(np.arctan2(lab[:, 2], lab[:, 1]))

    # 輝度帯の彩度 (log 輝度で 3 帯を滑らかに混ぜる)
    ll = np.log2(np.maximum(lum, 1e-6))
    w_s = smooth_band(ll, np.log2(0.03), 1.6)
    w_m = smooth_band(ll, np.log2(0.18), 1.6)
    w_h = smooth_band(ll, np.log2(0.6), 1.2)
    sat = (w_s * p.sat_shadows + w_m * p.sat_mids + w_h * p.sat_highlights) / np.maximum(w_s + w_m + w_h, 1e-12)
    chroma = chroma * sat * p.saturation

    # 色相帯 (色の薄い所ほど弱める: 灰色の色相は意味が無い)
    light_ev = np.zeros_like(hue)
    for b in p.hue_bands:
        d = (hue - b.center + 180.0) % 360.0 - 180.0
        w = smooth_band(d, 0.0, b.width) * np.clip(chroma / 0.03, 0.0, 1.0)
        hue = hue + b.shift * w
        chroma = chroma * (1.0 + (b.saturation - 1.0) * w)
        light_ev = light_ev + b.lightness * w

    h = np.radians(hue)
    lab[:, 1] = chroma * np.cos(h)
    lab[:, 2] = chroma * np.sin(h)
    lin = np.maximum(oklab_to_linear(lab), 0.0)
    if np.any(light_ev != 0.0):
        lin = lin * np.exp2(light_ev)[:, None]

    # 影と明部の色付け: 輝度を保ったまま色を寄せる
    def tint(c: np.ndarray, color: list[float], amount: np.ndarray) -> np.ndarray:
        t = np.array(color, dtype=np.float64)
        t = t / (t @ LUMA)
        l = c @ LUMA
        return c + (c * t - c) * amount[:, None] * (l > 0)[:, None]

    lum = lin @ LUMA
    disp_l = linear_to_srgb(lum)
    if p.shadow_tint_amount > 0.0:
        lin = tint(lin, p.shadow_tint, p.shadow_tint_amount * np.clip(1.0 - disp_l / 0.5, 0.0, 1.0) ** 1.5)
    if p.highlight_tint_amount > 0.0:
        lin = tint(lin, p.highlight_tint, p.highlight_tint_amount * np.clip((disp_l - 0.4) / 0.6, 0.0, 1.0) ** 1.5)

    out = linear_to_srgb(lin)
    # 白の近くは白へ戻す (明部の色付けで白が色付いて見える・1 を超えるのを防ぐ)
    white = np.clip((disp.min(axis=1) - 0.92) / 0.08, 0.0, 1.0)[:, None]
    out = out + (disp - out) * white
    if p.black != 0.0 or p.white != 1.0:
        out = p.black + (p.white - p.black) * np.clip(out, 0.0, 1.0)
    return np.clip(out, 0.0, 1.0).reshape(size, size, size, 3)


# ---- 確認 ----
def check(path: Path) -> None:
    lut = read_any(path)
    n = lut.shape[0]
    ident = identity_lut(n)
    dev = np.abs(lut - ident)
    corners = {"黒": lut[0, 0, 0], "赤": lut[0, 0, n - 1], "緑": lut[0, n - 1, 0], "青": lut[n - 1, 0, 0], "白": lut[n - 1, n - 1, n - 1]}
    desc = "  ".join(f"{k}=({v[0]:.3f},{v[1]:.3f},{v[2]:.3f})" for k, v in corners.items())
    print(f"{path.name}: {n}^3  恒等からのずれ 最大 {dev.max() * 255:.2f}/255 平均 {dev.mean() * 255:.2f}/255  {desc}")


def apply_to_image(lut: np.ndarray, src: Path, dst: Path, strength: float) -> None:
    im = Image.open(src).convert("RGB")
    a = np.asarray(im, dtype=np.float64) / 255.0
    out = a + (sample_lut(lut, a) - a) * strength
    Image.fromarray(np.round(np.clip(out, 0.0, 1.0) * 255.0).astype(np.uint8), "RGB").save(dst)
    print(dst)


def build_all() -> None:
    write_any(identity_lut(STRIP_SIZE), LOOK_DIR / "user_lut.png")
    for name in BUNDLED:
        params = load_params(PARAMS_DIR / f"{name}.json")
        write_any(bake(params, DAT_SIZE), LOOK_DIR / f"{name}.dat")
    for path in [LOOK_DIR / "user_lut.png", *(LOOK_DIR / f"{n}.dat" for n in BUNDLED)]:
        check(path)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("all")
    s = sub.add_parser("identity"); s.add_argument("--out", type=Path, required=True); s.add_argument("--size", type=int, default=DAT_SIZE)
    s = sub.add_parser("strip-identity"); s.add_argument("--out", type=Path, required=True); s.add_argument("--size", type=int, default=STRIP_SIZE)
    s = sub.add_parser("bake"); s.add_argument("params", type=Path); s.add_argument("--out", type=Path, required=True)
    s = sub.add_parser("from-cube"); s.add_argument("src", type=Path); s.add_argument("--out", type=Path, required=True)
    s = sub.add_parser("from-strip"); s.add_argument("src", type=Path); s.add_argument("--out", type=Path, required=True)
    s = sub.add_parser("to-cube"); s.add_argument("src", type=Path); s.add_argument("--out", type=Path, required=True)
    s = sub.add_parser("preview"); s.add_argument("--lut", type=Path, required=True); s.add_argument("--in", dest="src", type=Path, required=True)
    s.add_argument("--out", type=Path, required=True); s.add_argument("--strength", type=float, default=1.0)
    s = sub.add_parser("check"); s.add_argument("files", type=Path, nargs="+")
    s = sub.add_parser("test-swap-rb"); s.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    if a.cmd == "all":
        build_all()
    elif a.cmd in ("identity", "strip-identity"):
        lut = identity_lut(a.size)
        if a.out.suffix.lower() == ".png":
            write_strip(lut, a.out)
        else:
            write_dat(lut, a.out)
        print(a.out)
    elif a.cmd == "bake":
        size = STRIP_SIZE if a.out.suffix.lower() == ".png" else DAT_SIZE
        write_any(bake(load_params(a.params), size), a.out)
    elif a.cmd in ("from-cube", "from-strip", "to-cube"):
        write_any(read_any(a.src), a.out)
    elif a.cmd == "preview":
        apply_to_image(read_any(a.lut), a.src, a.out, a.strength)
    elif a.cmd == "check":
        for f in a.files:
            check(f)
    elif a.cmd == "test-swap-rb":
        size = STRIP_SIZE if a.out.suffix.lower() == ".png" else DAT_SIZE
        write_any(identity_lut(size)[..., ::-1], a.out)


if __name__ == "__main__":
    main()
