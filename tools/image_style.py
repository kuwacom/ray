"""
写真・参考画像の画づくり (トーン・色・質感・構図) を数値で測る汎用スクリプト

1 枚ずつ縮小 (既定は長辺 640 px) して測り、1 枚 1 行の CSV / JSON と、中央値・四分位の集計 (全体・フォルダ・場面・焦点距離帯) を出す
測るのは見た目 (sRGB の輝度と色) で、RAW の露出ではない。場面の種類 (scene_auto) は数値からの粗い推定なので、目視で直すなら --labels を使う
縮小した画像の一覧 (コンタクトシート) も作れる (画像入力で目視するため)

使い方:
    uv run tools/image_style.py measure <画像かフォルダ>... --out <出力フォルダ> [--jobs 8] [--labels labels.csv]
    uv run tools/image_style.py aggregate <出力フォルダ>/metrics.csv [--labels labels.csv]   # 測り直さずに集計だけやり直す
    uv run tools/image_style.py sheet <画像かフォルダ>... --out <出力フォルダ> [--cols 6 --rows 4 --thumb 256]
    uv run tools/image_style.py sheet --from-csv <出力フォルダ>/metrics.csv --sort y_p50 --where scene_auto=night --out <出力フォルダ>

フォルダ名の集計 (folder 列) は、画像の親フォルダ名 (親が export のときはその上) を使う
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

from lib.color import srgb_to_linear

DEFAULT_SIZE = 640
EXTS = (".jpg", ".jpeg")
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float64)
RGB_TO_XYZ = np.array(
    [[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]]
)
D65_WHITE = RGB_TO_XYZ.sum(axis=1)
HUE_BINS = 12
# 色相の集計に入れる画素 (彩度と明るさが低い画素は色相が不安定)
HUE_MIN_SAT = 0.15
HUE_MIN_VAL = 0.10
# 緑の色相の範囲 (HSV の度)
GREEN_HUE = (70.0, 170.0)
# 白に近い無彩色とみなす画素 (Lab の彩度 C* の上限と、輝度 (sRGB) の下限)
NEUTRAL_MAX_C = 12.0
NEUTRAL_MIN_Y = 0.35
SKY_TOP_BLOCK = 8
SKY_MAX_STD = 0.05
SKY_MIN_Y = 0.25
SKY_GREEN_MARGIN = 1.03
THIRDS = (1 / 3, 2 / 3)
NATIVE_CROP = 512

# 集計の表に出す主な指標 (全部の指標は aggregate.csv に出る)
KEY_METRICS = [
    "y_p1", "y_p50", "y_p99", "y_std", "local_contrast", "dark_ch", "vig_stops",
    "chroma_p50", "chroma_p90", "sat_p90", "neu_b", "neu_cct", "sh_b", "hi_b", "split_db",
    "sky_frac", "sky_hue", "green_hue", "horizon_y", "sal_third_dist", "flat_frac", "focal_eq", "hour",
]
FOCAL_BUCKETS = [("w<24", 0, 24), ("n24-50", 24, 50), ("m50-100", 50, 100), ("t100+", 100, 1e9)]


def box_axis(a: np.ndarray, r: int, axis: int) -> np.ndarray:
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * r + 1)


def blur(a: np.ndarray, r: int, passes: int = 3) -> np.ndarray:
    """箱ぼかしを重ねたガウス近似 (a は H x W か H x W x C)"""
    for _ in range(passes):
        a = box_axis(box_axis(a, r, 0), r, 1)
    return a


def blocks(a: np.ndarray, b: int) -> np.ndarray:
    h, w = a.shape[0] // b * b, a.shape[1] // b * b
    return a[:h, :w].reshape(h // b, b, w // b, b, *a.shape[2:])


def rgb_to_lab(lin: np.ndarray) -> np.ndarray:
    xyz = (lin @ RGB_TO_XYZ.T) / D65_WHITE
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def rgb_to_hsv(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(axis=-1), rgb.min(axis=-1)
    d = np.maximum(mx - mn, 1e-9)
    h = np.select([mx == r, mx == g], [((g - b) / d) % 6, (b - r) / d + 2], (r - g) / d + 4) * 60.0
    h = np.where(mx - mn < 1e-6, 0.0, h)
    s = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-9), 0.0)
    return h, s, mx


def circ_mean_deg(deg: np.ndarray, w: np.ndarray) -> float:
    if w.sum() <= 0:
        return math.nan
    rad = np.deg2rad(deg)
    return float(np.rad2deg(np.arctan2((w * np.sin(rad)).sum(), (w * np.cos(rad)).sum())) % 360)


def mccamy_cct(lin_rgb: np.ndarray) -> float:
    xyz = RGB_TO_XYZ @ lin_rgb
    s = xyz.sum()
    if s <= 0:
        return math.nan
    x, y = xyz[0] / s, xyz[1] / s
    if abs(0.1858 - y) < 1e-6:
        return math.nan
    n = (x - 0.3320) / (0.1858 - y)
    return float(449 * n**3 + 3525 * n**2 + 6823.3 * n + 5520.33)


def read_exif(im: Image.Image) -> dict:
    out: dict = {}
    try:
        ex = im.getexif()
        sub = ex.get_ifd(0x8769)
    except Exception:
        return out

    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None

    iso = sub.get(0x8827)
    if isinstance(iso, (tuple, list)) and iso:
        iso = iso[0]
    out["focal_mm"] = num(sub.get(0x920A))
    out["focal_35mm"] = num(sub.get(0xA405))
    # 35mm 換算が EXIF に無いカメラはフルサイズ機が多いので実焦点距離で代える (クロップ機では換算にならない)
    out["focal_eq"] = out["focal_35mm"] or out["focal_mm"]
    out["f_number"] = num(sub.get(0x829D))
    out["shutter_s"] = num(sub.get(0x829A))
    out["iso"] = num(iso)
    stamp = str(sub.get(0x9003) or ex.get(0x0132) or "").strip("\x00 ")
    out["date"] = stamp[:10].replace(":", "-")
    try:
        hh, mm = int(stamp[11:13]), int(stamp[14:16])
        out["hour"] = hh + mm / 60
    except ValueError:
        out["hour"] = None
    out["model"] = str(ex.get(0x0110) or "").strip("\x00 ")
    out["lens"] = str(sub.get(0xA434) or "").strip("\x00 ")
    return out


def native_stats(im: Image.Image) -> dict:
    """縮小で消える粒子とエッジの鋭さを、原寸の中央の切り出しで測る"""
    w, h = im.size
    if min(w, h) < NATIVE_CROP:
        return {"noise_native": math.nan, "edge_native": math.nan}
    x0, y0 = (w - NATIVE_CROP) // 2, (h - NATIVE_CROP) // 2
    crop = np.asarray(im.crop((x0, y0, x0 + NATIVE_CROP, y0 + NATIVE_CROP)), dtype=np.float32) / 255 @ LUMA
    hp = (crop - blur(crop, 1, 1))[4:-4, 4:-4]
    hb = blocks(hp, 8).std(axis=(1, 3))
    yb = blocks(blur(crop, 2, 1)[4:-4, 4:-4], 8).std(axis=(1, 3))
    flat = yb <= np.percentile(yb, 20)
    return {
        "noise_native": float(np.median(hb[flat]) * 255),
        "edge_native": float(np.percentile(np.abs(hp), 99.5) * 255),
    }


def sky_analysis(rgb: np.ndarray, y: np.ndarray) -> tuple[dict, np.ndarray]:
    """上から連続する滑らかで緑でないブロックを空とみなす (夜空や白い壁は拾えない前提の粗い推定)"""
    b = SKY_TOP_BLOCK
    rb = blocks(rgb, b).mean(axis=(1, 3))
    yb = blocks(y, b)
    ystd, ymean = yb.std(axis=(1, 3)), yb.mean(axis=(1, 3))
    r, g, bl = rb[..., 0], rb[..., 1], rb[..., 2]
    cand = (ystd < SKY_MAX_STD) & (ymean > SKY_MIN_Y) & ~(g > np.maximum(r, bl) * SKY_GREEN_MARGIN)
    sky = np.cumprod(cand, axis=0).astype(bool)
    out = {"sky_frac": float(sky.mean())}
    keys = ("sky_L", "sky_a", "sky_b", "sky_hue", "sky_sat", "sky_y", "sky_grad_L")
    if sky.sum() < 6:
        return {**out, **{k: math.nan for k in keys}}, sky
    px = rb[sky]
    lab = rgb_to_lab(srgb_to_linear(px.mean(axis=0)))
    h, s, _ = rgb_to_hsv(px.mean(axis=0))
    rows = np.where(sky.any(axis=1))[0]
    third = max(1, len(rows) // 3)
    labs = rgb_to_lab(srgb_to_linear(rb))[..., 0]
    top = labs[rows[:third]][sky[rows[:third]]]
    low = labs[rows[-third:]][sky[rows[-third:]]]
    out.update(
        sky_L=float(lab[0]), sky_a=float(lab[1]), sky_b=float(lab[2]), sky_hue=float(h), sky_sat=float(s),
        sky_y=float(px.mean(axis=0) @ LUMA),
        sky_grad_L=float(low.mean() - top.mean()) if len(top) and len(low) else math.nan,
    )
    return out, sky


def horizon_analysis(y: np.ndarray) -> dict:
    """行ごとの縦方向の勾配の平均が最大の行 (水平に伸びる明暗の境) を地平線とみなす"""
    g = blur(y, 2, 2)
    step = 4
    gy = g[step:] - g[:-step]
    mean_row = gy.mean(axis=1)
    score = np.abs(box_axis(mean_row, 1, 0))
    n = len(score)
    lo, hi = int(n * 0.08), int(n * 0.92)
    i = lo + int(np.argmax(score[lo:hi]))
    sign = np.sign(mean_row[i])
    cons = float(((np.sign(gy[i]) == sign) & (np.abs(gy[i]) > 0.02)).mean())
    return {"horizon_y": (i + step / 2) / y.shape[0], "horizon_str": float(score[i]), "horizon_cons": cons}


def thirds_dist(x: float, yy: float) -> float:
    return min(math.hypot(x - tx, yy - ty) for tx in THIRDS for ty in THIRDS)


def saliency_analysis(small: Image.Image) -> dict:
    """細かい尺度と粗い尺度の Lab の差 (中心周辺差) を目立ちとし、その重心を主題の位置の目安にする"""
    s = 96 / max(small.size)
    sm = small.resize((max(8, round(small.width * s)), max(8, round(small.height * s))), Image.BOX)
    lab = rgb_to_lab(srgb_to_linear(np.asarray(sm, dtype=np.float64) / 255))
    sal = np.linalg.norm(blur(lab, 1, 2) - blur(lab, 10, 3), axis=-1)
    h, w = sal.shape
    wt = sal**2
    ys, xs = (np.arange(h) + 0.5) / h, (np.arange(w) + 0.5) / w
    cx, cy = float((wt.sum(0) * xs).sum() / wt.sum()), float((wt.sum(1) * ys).sum() / wt.sum())
    spread = math.sqrt(float((wt.sum(0) * (xs - cx) ** 2).sum() / wt.sum() + (wt.sum(1) * (ys - cy) ** 2).sum() / wt.sum()))
    g = np.asarray(sm.convert("L"), dtype=np.float64) / 255

    def corr(a, b):
        return float(np.corrcoef(a.ravel(), b.ravel())[0, 1]) if a.std() > 1e-6 and b.std() > 1e-6 else math.nan

    return {
        "sal_cx": cx, "sal_cy": cy, "sal_spread": spread,
        "sal_third_dist": thirds_dist(cx, cy), "sal_center_dist": math.hypot(cx - 0.5, cy - 0.5),
        "subject_area": float((sal > 0.5 * sal.max()).mean()),
        "sym_lr": corr(g, g[:, ::-1]), "sym_tb": corr(g, g[::-1]),
    }


def measure_image(path: str, size: int = DEFAULT_SIZE) -> dict:
    p = Path(path)
    try:
        im = Image.open(p)
        row: dict = {"path": str(p), "file": p.stem, "folder": folder_name(p)}
        row.update(read_exif(im))
        im = ImageOps.exif_transpose(im).convert("RGB")
        w0, h0 = im.size
        native = native_stats(im)
        scale = min(1.0, size / max(w0, h0))
        small = im.resize((max(1, round(w0 * scale)), max(1, round(h0 * scale))), Image.BOX) if scale < 1 else im
        del im
        row.update(width=w0, height=h0, aspect=w0 / h0, orient="landscape" if w0 > h0 else ("portrait" if h0 > w0 else "square"))
        row.update(measure_array(small), **native)
        row["scene_auto"] = classify(row)
        return row
    except Exception as e:  # 壊れた画像 1 枚で全体を止めない
        return {"path": str(p), "file": p.stem, "error": f"{type(e).__name__}: {e}"}


def measure_array(small: Image.Image) -> dict:
    rgb = np.asarray(small, dtype=np.float64) / 255
    lin = srgb_to_linear(rgb)
    y = rgb @ LUMA
    ylin = lin @ LUMA
    hh, ww = y.shape
    out: dict = {}

    # トーン
    qs = [1, 5, 10, 20, 25, 40, 50, 60, 75, 80, 90, 95, 99]
    q = dict(zip(qs, np.percentile(y, qs)))
    for k, v in q.items():
        out[f"y_p{k}"] = float(v)
    out["y_mean"] = float(y.mean())
    out["y_std"] = float(y.std())
    out["y_skew"] = float(((y - y.mean()) ** 3).mean() / max(y.std(), 1e-9) ** 3)
    out["dyn_range"] = float(q[99] - q[1])
    out["mid_spread"] = float((q[75] - q[25]) / max(q[95] - q[5], 1e-9))
    out["gamma_mid"] = float(math.log(q[50]) / math.log(0.5)) if q[50] > 0 else math.nan
    out["black_clip"] = float((y <= 2 / 255).mean())
    out["white_clip"] = float((y >= 253 / 255).mean())
    out["hist32"] = (np.histogram(y, bins=32, range=(0, 1))[0] / y.size).round(5).tolist()
    ys = blocks(y, 16).std(axis=(1, 3))
    out["local_contrast"] = float(np.median(ys))
    out["detail_frac"] = float((ys > 0.06).mean())
    out["flat_frac"] = float((ys < 0.015).mean())
    lap = y[1:-1, 1:-1] * 4 - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:]
    out["lap_var"] = float(lap.var() * 1000)

    # 色
    lab = rgb_to_lab(lin)
    c = np.hypot(lab[..., 1], lab[..., 2])
    hue, sat, val = rgb_to_hsv(rgb)
    out["mean_a"], out["mean_b"] = float(lab[..., 1].mean()), float(lab[..., 2].mean())
    for k, v in zip((50, 90, 99), np.percentile(c, (50, 90, 99))):
        out[f"chroma_p{k}"] = float(v)
    out["chroma_mean"] = float(c.mean())
    out["colorful_frac"] = float((c > 20).mean())
    cond = (sat > HUE_MIN_SAT) & (val > HUE_MIN_VAL)
    out["chromatic_frac"] = float(cond.mean())
    sv = sat[val > HUE_MIN_VAL]
    for k, v in zip((50, 90, 99), np.percentile(sv, (50, 90, 99)) if sv.size else (math.nan,) * 3):
        out[f"sat_p{k}"] = float(v)
    wgt = (sat * val)[cond]
    bins = np.bincount((hue[cond] // (360 / HUE_BINS)).astype(int) % HUE_BINS, weights=wgt, minlength=HUE_BINS)
    frac = bins / bins.sum() if bins.sum() > 0 else np.full(HUE_BINS, math.nan)
    for i, v in enumerate(frac):
        out[f"hue{i * 30:03d}"] = float(v)
    out["hue_dom"] = circ_mean_deg(hue[cond], wgt)
    pos = frac[frac > 0]
    out["hue_entropy"] = float(-(pos * np.log2(pos)).sum() / math.log2(HUE_BINS)) if pos.size else math.nan
    gm = cond & (hue >= GREEN_HUE[0]) & (hue <= GREEN_HUE[1])
    out["green_frac"] = float(gm.mean())
    if gm.sum() > 20:
        gw = (sat * val)[gm]
        out["green_hue"] = circ_mean_deg(hue[gm], gw)
        out["green_sat"], out["green_val"] = float(sat[gm].mean()), float(val[gm].mean())
        out["green_C"] = float(c[gm].mean())
    else:
        out.update(green_hue=math.nan, green_sat=math.nan, green_val=math.nan, green_C=math.nan)
    nm = (c < NEUTRAL_MAX_C) & (y > NEUTRAL_MIN_Y)
    out["neu_frac"] = float(nm.mean())
    if nm.mean() >= 0.005:
        m = lin[nm].mean(axis=0)
        out["neu_a"], out["neu_b"] = float(lab[nm][:, 1].mean()), float(lab[nm][:, 2].mean())
        out["neu_cct"] = mccamy_cct(m)
        out["neu_rb"] = float(math.log2(max(m[0], 1e-6) / max(m[2], 1e-6)))
    else:
        out.update(neu_a=math.nan, neu_b=math.nan, neu_cct=math.nan, neu_rb=math.nan)
    for name, lo, hi in (("sh", None, q[20]), ("mid", q[40], q[60]), ("hi", q[80], None)):
        band = np.ones_like(y, dtype=bool)
        if lo is not None:
            band &= y >= lo
        if hi is not None:
            band &= y <= hi
        out[f"{name}_a"], out[f"{name}_b"] = float(lab[band][:, 1].mean()), float(lab[band][:, 2].mean())
        out[f"{name}_C"] = float(c[band].mean())
    out["split_da"], out["split_db"] = out["hi_a"] - out["sh_a"], out["hi_b"] - out["sh_b"]
    out["split_mag"] = math.hypot(out["split_da"], out["split_db"])

    sky_out, sky = sky_analysis(rgb, y)
    out.update(sky_out)
    out["ground_frac"] = 1 - out["sky_frac"]

    # 質感
    yy, xx = np.mgrid[0:hh, 0:ww]
    rad = np.hypot((xx + 0.5 - ww / 2) / (ww / 2), (yy + 0.5 - hh / 2) / (hh / 2)) / math.sqrt(2)
    centre, corner = ylin[rad < 0.25].mean(), ylin[rad > 0.85].mean()
    out["vig_stops"] = float(math.log2(max(corner, 1e-6) / max(centre, 1e-6)))
    out["dark_ch"] = float(blocks(rgb.min(axis=-1), 16).min(axis=(1, 3)).mean())

    # 構図
    out["bright_top_y"] = float(np.percentile(y, 98))
    bm = y >= out["bright_top_y"]
    bx, by = float((xx[bm] + 0.5).mean() / ww), float((yy[bm] + 0.5).mean() / hh)
    out.update(bright_cx=bx, bright_cy=by, bright_third_dist=thirds_dist(bx, by))
    out.update(horizon_analysis(y))
    out["horizon_third_dist"] = min(abs(out["horizon_y"] - t) for t in THIRDS)
    out.update(saliency_analysis(small))
    out["top_bottom_ratio"] = float(ylin[: hh // 2].mean() / max(ylin[hh // 2 :].mean(), 1e-6))
    out["left_right_ratio"] = float(ylin[:, : ww // 2].mean() / max(ylin[:, ww // 2 :].mean(), 1e-6))
    return out


def classify(m: dict) -> str:
    """数値からの粗い場面分け。目視で直す場合は --labels"""
    if m.get("y_p50", 1) < 0.14:
        return "night"
    if (m.get("sky_frac") or 0) >= 0.2:
        return "sky_landscape"
    if (m.get("green_frac") or 0) >= 0.3:
        return "green_nature"
    if (m.get("detail_frac") or 0) >= 0.5:
        return "urban_detail"
    if (m.get("flat_frac") or 0) >= 0.5:
        return "flat_closeup"
    return "other"


def folder_name(p: Path) -> str:
    parent = p.parent
    return parent.parent.name if parent.name.lower() == "export" else parent.name


def parse_exts(s: str) -> tuple[str, ...]:
    return tuple(e if e.startswith(".") else "." + e for e in s.lower().split(","))


def collect(paths: list[Path], exts: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        if p.is_dir():
            files += [f for f in sorted(p.rglob("*")) if f.suffix.lower() in exts]
        elif p.suffix.lower() in exts:
            files.append(p)
    # macOS が外付けドライブに作る "._" の付随ファイルは画像ではない
    return [f for f in files if not f.name.startswith("._")]


def clean(v):
    if isinstance(v, (np.floating, np.integer)):
        v = float(v)
    if isinstance(v, float):
        return None if math.isnan(v) or math.isinf(v) else round(v, 5)
    return v


def write_metrics(rows: list[dict], out: Path) -> None:
    rows = [{k: clean(v) for k, v in r.items()} for r in rows]
    (out / "metrics.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    keys: list[str] = []
    for r in rows:
        keys += [k for k in r if k not in keys and k != "hist32"]
    with open(out / "metrics.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: ("" if r.get(k) is None else r[k]) for k in keys})


def read_metrics(csv_path: Path) -> list[dict]:
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    cols = list(rows[0].keys()) if rows else []
    numeric = set()
    for k in cols:
        try:
            for r in rows:
                if r[k] != "":
                    float(r[k])
            numeric.add(k)
        except ValueError:
            pass
    numeric -= {"file", "folder", "date", "model", "lens", "path"}
    for r in rows:
        for k in cols:
            r[k] = (float(r[k]) if r[k] != "" else None) if k in numeric else r[k]
    return rows


def read_labels(path: Path) -> dict[str, str]:
    """file,scene の CSV。file は拡張子なしのファイル名か 'フォルダ/ファイル名'"""
    with open(path, newline="", encoding="utf-8-sig") as f:
        return {r["file"].strip(): r["scene"].strip() for r in csv.DictReader(f)}


def apply_labels(rows: list[dict], labels: dict[str, str]) -> None:
    for r in rows:
        auto = r.get("scene_auto") or ""
        r["scene"] = labels.get(f"{r.get('folder')}/{r.get('file')}") or labels.get(str(r.get("file"))) or auto


def focal_bucket(v) -> str:
    if v is None:
        return "unknown"
    return next(name for name, lo, hi in FOCAL_BUCKETS if lo <= v < hi)


def stats(values: list[float]) -> tuple[int, float, float, float, float]:
    a = np.array(values, dtype=np.float64)
    a = a[~np.isnan(a)]
    if a.size == 0:
        return 0, math.nan, math.nan, math.nan, math.nan
    p25, p50, p75 = np.percentile(a, (25, 50, 75))
    return int(a.size), float(p25), float(p50), float(p75), float(a.mean())


def col(rows: list[dict], k: str) -> list[float]:
    return [r[k] if r.get(k) is not None else math.nan for r in rows]


def aggregate(rows: list[dict], out: Path) -> None:
    rows = [r for r in rows if not r.get("error")]
    for r in rows:
        r["focal_bucket"] = focal_bucket(r.get("focal_eq"))
    numeric = [
        k for k in rows[0]
        if k != "hist32" and all(r.get(k) is None or (isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool)) for r in rows)
    ]
    groups: list[tuple[str, str, list[dict]]] = [("all", "all", rows)]
    for gtype in ("scene", "focal_bucket", "orient", "folder"):
        names = sorted({str(r.get(gtype)) for r in rows})
        groups += [(gtype, n, [r for r in rows if str(r.get(gtype)) == n]) for n in names]
    with open(out / "aggregate.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["group_type", "group", "metric", "n", "p25", "median", "p75", "mean"])
        for gtype, gname, grp in groups:
            for k in numeric:
                n, p25, p50, p75, mean = stats(col(grp, k))
                w.writerow([gtype, gname, k, n] + ["" if clean(v) is None else clean(v) for v in (p25, p50, p75, mean)])
    (out / "summary.md").write_text(summary_md(rows, groups, numeric), encoding="utf-8")


def fmt(v: float) -> str:
    if v is None or math.isnan(v):
        return "-"
    return f"{v:.0f}" if abs(v) >= 100 else f"{v:.3f}" if abs(v) < 1 else f"{v:.2f}"


def summary_md(rows: list[dict], groups: list, numeric: list[str]) -> str:
    keys = [k for k in KEY_METRICS if k in numeric]
    lines = [f"# 画づくりの集計 ({len(rows)} 枚)", "", "## 全体 (中央値, 四分位)", "", "| 指標 | n | 中央値 | p25 | p75 |", "|---|---|---|---|---|"]
    for k in numeric:
        n, p25, p50, p75, _ = stats(col(rows, k))
        lines.append(f"| {k} | {n} | {fmt(p50)} | {fmt(p25)} | {fmt(p75)} |")
    for gtype in ("scene", "focal_bucket", "orient", "folder"):
        lines += ["", f"## {gtype} ごとの中央値", "", "| group | n | " + " | ".join(keys) + " |", "|---|---|" + "---|" * len(keys)]
        for gt, gname, grp in groups:
            if gt == gtype:
                lines.append(f"| {gname} | {len(grp)} | " + " | ".join(fmt(stats(col(grp, k))[2]) for k in keys) + " |")
    hist = [r["hist32"] for r in rows if r.get("hist32")]
    if hist:
        lines += ["", "## 輝度ヒストグラム (32 区間の平均, %)", "", " ".join(f"{v * 100:.1f}" for v in np.mean(hist, axis=0))]
    hue_keys = [f"hue{i * 30:03d}" for i in range(HUE_BINS)]
    if all(k in numeric for k in hue_keys):
        lines += ["", "## 色相の使い方 (HSV 30 度刻みの中央値, %。0 = 赤, 60 = 黄, 120 = 緑, 180 = シアン, 240 = 青, 300 = マゼンタ)", ""]
        lines.append(" ".join(f"{k[3:]}:{stats(col(rows, k))[2] * 100:.1f}" for k in hue_keys))
    hours = [r["hour"] for r in rows if r.get("hour") is not None]
    if hours:
        counts = np.bincount([int(h) for h in hours], minlength=24)
        lines += ["", "## 撮影時刻 (時ごとの枚数)", "", " ".join(f"{h}:{c}" for h, c in enumerate(counts) if c)]
    return "\n".join(lines) + "\n"


def cmd_measure(a: argparse.Namespace) -> int:
    files = collect(a.paths, parse_exts(a.ext))
    if not files:
        print("画像が見つからない", file=sys.stderr)
        return 1
    a.out.mkdir(parents=True, exist_ok=True)
    print(f"{len(files)} 枚を測る (長辺 {a.size}, jobs {a.jobs})", flush=True)
    rows: list[dict] = []
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        for i, r in enumerate(ex.map(measure_image, map(str, files), [a.size] * len(files), chunksize=2), 1):
            rows.append(r)
            if i % 25 == 0 or i == len(files):
                print(f"  {i}/{len(files)}", flush=True)
    bad = [r for r in rows if r.get("error")]
    if bad:
        print(f"失敗 {len(bad)} 枚: " + ", ".join(f"{r['file']}({r['error']})" for r in bad[:5]), file=sys.stderr)
    good = [r for r in rows if not r.get("error")]
    apply_labels(good, read_labels(a.labels) if a.labels else {})
    write_metrics(good, a.out)
    aggregate(good, a.out)
    print(f"書き出し: {a.out} (metrics.csv / metrics.json / aggregate.csv / summary.md)")
    return 0


def cmd_aggregate(a: argparse.Namespace) -> int:
    rows = read_metrics(a.metrics)
    jpath = a.metrics.parent / "metrics.json"
    hist = {r["path"]: r.get("hist32") for r in json.loads(jpath.read_text(encoding="utf-8"))} if jpath.exists() else {}
    for r in rows:
        r["hist32"] = hist.get(r["path"])
    apply_labels(rows, read_labels(a.labels) if a.labels else {})
    write_metrics(rows, a.metrics.parent)
    aggregate(rows, a.metrics.parent)
    return 0


def thumb_image(path: str, size: int) -> Image.Image:
    im = Image.open(path)
    im.draft("RGB", (size * 2, size * 2))
    im = ImageOps.exif_transpose(im).convert("RGB")
    im.thumbnail((size, size), Image.LANCZOS)
    return im


def cmd_sheet(a: argparse.Namespace) -> int:
    if a.from_csv:
        rows = read_metrics(a.from_csv)
        for cond in a.where or []:
            k, v = cond.split("=", 1)
            rows = [r for r in rows if str(r.get(k)) == v]
        if a.sort:
            rows = sorted((r for r in rows if r.get(a.sort) is not None), key=lambda r: r[a.sort], reverse=a.desc)
        items = [(r["path"], r.get(a.label_metric) if a.label_metric else None) for r in rows]
    else:
        items = [(str(f), None) for f in collect(a.paths, parse_exts(a.ext))]
    if not items:
        print("画像が見つからない", file=sys.stderr)
        return 1
    a.out.mkdir(parents=True, exist_ok=True)
    font = ImageFont.load_default()
    per, pad, label_h = a.cols * a.rows, 4, 14
    cell_w, cell_h = a.thumb + pad, a.thumb + label_h + pad
    index = []
    for s in range(0, len(items), per):
        chunk = items[s : s + per]
        sheet = Image.new("RGB", (a.cols * cell_w + pad, a.rows * cell_h + pad), (24, 24, 24))
        d = ImageDraw.Draw(sheet)
        for i, (path, extra) in enumerate(chunk):
            try:
                t = thumb_image(path, a.thumb)
            except Exception:
                continue
            x, y = pad + (i % a.cols) * cell_w, pad + (i // a.cols) * cell_h
            sheet.paste(t, (x + (a.thumb - t.width) // 2, y + (a.thumb - t.height) // 2))
            tag = f"#{s + i + 1} {Path(path).stem}" + (f" {extra:.3g}" if isinstance(extra, float) else "")
            d.text((x + 2, y + a.thumb + 1), tag, fill=(235, 235, 235), font=font)
            index.append({"sheet": s // per + 1, "index": s + i + 1, "path": path})
        sheet.save(a.out / f"{a.prefix}_{s // per + 1:02d}.jpg", quality=88)
    with open(a.out / f"{a.prefix}_index.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["sheet", "index", "path"])
        w.writeheader()
        w.writerows(index)
    print(f"{len(items)} 枚 -> {len(range(0, len(items), per))} 枚のシート: {a.out}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("measure", help="1 枚ずつ測って CSV / JSON と集計を出す")
    m.add_argument("paths", nargs="+", type=Path, help="画像かフォルダ (フォルダは再帰)")
    m.add_argument("--out", type=Path, required=True)
    m.add_argument("--size", type=int, default=DEFAULT_SIZE, help="測る前に縮小する長辺 (px)")
    m.add_argument("--jobs", type=int, default=8)
    m.add_argument("--ext", default=",".join(EXTS))
    m.add_argument("--labels", type=Path, help="file,scene の CSV (scene_auto を上書きする)")
    m.set_defaults(func=cmd_measure)

    g = sub.add_parser("aggregate", help="metrics.csv から集計だけやり直す")
    g.add_argument("metrics", type=Path)
    g.add_argument("--labels", type=Path)
    g.set_defaults(func=cmd_aggregate)

    s = sub.add_parser("sheet", help="縮小画像の一覧 (コンタクトシート) を作る")
    s.add_argument("paths", nargs="*", type=Path)
    s.add_argument("--out", type=Path, required=True)
    s.add_argument("--prefix", default="sheet")
    s.add_argument("--cols", type=int, default=6)
    s.add_argument("--rows", type=int, default=4)
    s.add_argument("--thumb", type=int, default=256)
    s.add_argument("--ext", default=",".join(EXTS))
    s.add_argument("--from-csv", type=Path, help="metrics.csv の行を並べる (--sort と --where が使える)")
    s.add_argument("--sort", help="並べ替えに使う指標の列名")
    s.add_argument("--desc", action="store_true")
    s.add_argument("--where", action="append", help="列=値 で絞る (複数可)")
    s.add_argument("--label-metric", help="ラベルに添える指標の列名")
    s.set_defaults(func=cmd_sheet)

    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
