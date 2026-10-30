"""
ブロックごとの平均の色 (アルベド) を Minecraft のクライアント jar のテクスチャから計算し、tools/block_colors.json に書く

floodfill の照り返しとボクセル RT の画面外の当たりに使う (表の持ち方は gen_block_properties.py が決める)
上面の色が全体の平均と違うブロック (草ブロック・原木など) は、上面だけの平均を "top" に別に書く。
GI のレイは地面の上面に当たることが多く、草ブロックの全面の平均 (側面の土込み) は茶色で、上面を別に持たないと草地の照り返しが緑にならない

もう 1 つ、光るブロックの面ごとの光り方 (光る範囲の四角と 4x4 のマス) を tools/light_masks.json に書く
対象は tools/id_tables.py の Light.mask_block() が返すブロック。近距離の面の放射 (lib/light/light_select.glsl) が使う
発光の式は gbuffers_solid.fsh の estimateEmission と同じ (そちらを直したらここも直す)

jar は読むだけ。バージョンを上げた時だけ実行し、結果の JSON をリポジトリに入れる (画像は入らない)

使い方: uv run tools/gen_block_colors.py <client.jar>
"""

from __future__ import annotations

import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

from id_tables import LIGHTS
from lib.color import linear_to_srgb, srgb_to_linear
from lib.paths import ROOT

OUT = ROOT / "tools" / "block_colors.json"
MASKS_OUT = ROOT / "tools" / "light_masks.json"

# tintindex の付いた面に掛ける色 (sRGB)。バイオームで変わる草・葉は平原の値を代表にする
GRASS_TINT = (0x91, 0xBD, 0x59)
FOLIAGE_TINT = (0x77, 0xAB, 0x2F)
DRY_FOLIAGE_TINT = (0xA2, 0x80, 0x4C)
WATER_TINT = (0x3F, 0x76, 0xE4)
TINT_BY_BLOCK = {
    "grass_block": GRASS_TINT, "short_grass": GRASS_TINT, "tall_grass": GRASS_TINT, "fern": GRASS_TINT,
    "large_fern": GRASS_TINT, "potted_fern": GRASS_TINT, "sugar_cane": GRASS_TINT, "bush": GRASS_TINT,
    "pink_petals": GRASS_TINT, "wildflowers": GRASS_TINT,
    "spruce_leaves": (0x61, 0x99, 0x61), "birch_leaves": (0x80, 0xA7, 0x55),
    "lily_pad": (0x20, 0x80, 0x30), "leaf_litter": DRY_FOLIAGE_TINT,
    # 信号の強さで変わる。中ほどの強さの赤
    "redstone_wire": (0xB0, 0x10, 0x00),
    "melon_stem": (0xB0, 0xA8, 0x30), "pumpkin_stem": (0xB0, 0xA8, 0x30),
    "attached_melon_stem": (0xE0, 0xC7, 0x1C), "attached_pumpkin_stem": (0xE0, 0xC7, 0x1C),
}
# 要素 (elements) を持たず particle のテクスチャで代用するブロック (液体)
PARTICLE_ONLY = {"water": WATER_TINT, "bubble_column": WATER_TINT, "lava": None}
ALPHA_CUTOFF = 0.1
# 上面の色がこれ (sRGB 8bit のどれかの成分の差) 以上違う時だけ "top" に書く
TOP_COLOR_MIN_DIFF = 8

# 光源ブロックの発光 smoothstep(e0, e1, max(sRGB))。gbuffers_solid.fsh の estimateEmission と、鉱物ブロックは同ファイルの DECOR の式
EMISSION_EDGE = (0.55, 0.90)
DECOR_EMISSION_EDGE = (0.15, 0.85)
# 光る範囲 = 面の最大の発光のこの割合を超える画素の外接矩形
RECT_THRESHOLD = 0.5
MASK_GRID = 4
MASK_GRID_LEVELS = 15
# 面の光の量 (ratio) がこれに満たない面の種類は光らないものとして 0 にする (かまどの上下の 1% 未満など)
MASK_MIN_RATIO = 0.02
FACE_CLASSES = (("up", ("up",)), ("down", ("down",)), ("side", ("north", "south", "east", "west")))


class Assets:
    def __init__(self, jar: Path) -> None:
        self.zip = zipfile.ZipFile(jar)
        self.names = set(self.zip.namelist())
        self.models: dict[str, dict] = {}
        self.textures: dict[str, np.ndarray | None] = {}

    def json(self, path: str) -> dict | None:
        return json.loads(self.zip.read(path)) if path in self.names else None

    @staticmethod
    def norm(ref: str) -> str:
        return ref.removeprefix("minecraft:")

    def model(self, ref: str) -> dict:
        """parent を辿って textures を合成し、最も近い elements を持つモデル"""
        ref = self.norm(ref)
        if ref in self.models:
            return self.models[ref]
        raw = self.json(f"assets/minecraft/models/{ref}.json") or {}
        parent = self.model(raw["parent"]) if "parent" in raw else {"textures": {}, "elements": None}
        merged = {
            "textures": {**parent["textures"], **raw.get("textures", {})},
            "elements": raw.get("elements", parent["elements"]),
        }
        self.models[ref] = merged
        return merged

    def texture(self, ref: str) -> np.ndarray | None:
        """線形 RGBA (H, W, 4)。アニメーションは最初のコマだけ"""
        ref = self.norm(ref)
        if ref not in self.textures:
            path = f"assets/minecraft/textures/{ref}.png"
            if path not in self.names:
                self.textures[ref] = None
            else:
                img = np.asarray(Image.open(io.BytesIO(self.zip.read(path))).convert("RGBA"), dtype=np.float64) / 255.0
                w = img.shape[1]
                img = img[:w]
                img[..., :3] = srgb_to_linear(img[..., :3])
                self.textures[ref] = img
        return self.textures[ref]

    def emission(self, ref: str, edge: tuple[float, float]) -> np.ndarray | None:
        """(H, W) の発光 [0, 1]。アニメーションは全コマの平均 (texture() は最初のコマだけ)"""
        path = f"assets/minecraft/textures/{self.norm(ref)}.png"
        if path not in self.names:
            return None
        img = np.asarray(Image.open(io.BytesIO(self.zip.read(path))).convert("RGBA"), dtype=np.float64) / 255.0
        w = img.shape[1]
        frames = img.reshape(-1, w, w, 4)
        t = np.clip((frames[..., :3].max(axis=-1) - edge[0]) / (edge[1] - edge[0]), 0.0, 1.0)
        return (t * t * (3.0 - 2.0 * t) * (frames[..., 3] > ALPHA_CUTOFF)).mean(axis=0)


def resolve_texture(textures: dict[str, str | dict], ref: str | dict) -> str | None:
    for _ in range(16):
        # 新しい書式ではテクスチャが {"sprite": ...} のオブジェクトになっている
        if isinstance(ref, dict):
            ref = ref.get("sprite", "")
        if not ref.startswith("#"):
            return ref
        ref = textures.get(ref[1:], "")
    return None


def face_area(frm: list[float], to: list[float], face: str) -> float:
    d = [abs(t - f) for f, t in zip(frm, to)]
    if face in ("up", "down"):
        return d[0] * d[2]
    if face in ("north", "south"):
        return d[0] * d[1]
    return d[1] * d[2]


def average_model(assets: Assets, model: dict, tint: tuple[int, int, int], faces: set[str] | None = None) -> np.ndarray | None:
    """面積と不透明度で重み付けした線形 RGB の平均。faces を渡すとその向きの面だけ"""
    tint_lin = srgb_to_linear(np.array(tint, dtype=np.float64) / 255.0)
    total = np.zeros(3)
    weight = 0.0
    for el in model["elements"] or []:
        for face, spec in el.get("faces", {}).items():
            if faces is not None and face not in faces:
                continue
            ref = resolve_texture(model["textures"], spec.get("texture", ""))
            tex = assets.texture(ref) if ref else None
            if tex is None:
                continue
            uv = spec.get("uv")
            if uv:
                s = tex.shape[0] / 16.0
                u0, u1 = sorted((uv[0], uv[2]))
                v0, v1 = sorted((uv[1], uv[3]))
                region = tex[int(v0 * s):max(int(v1 * s), int(v0 * s) + 1), int(u0 * s):max(int(u1 * s), int(u0 * s) + 1)]
            else:
                region = tex
            a = region[..., 3]
            mask = a > ALPHA_CUTOFF
            if not mask.any():
                continue
            rgb = (region[..., :3] * a[..., None])[mask].sum(axis=0) / a[mask].sum()
            if "tintindex" in spec:
                rgb = rgb * tint_lin
            w = face_area(el["from"], el["to"], face) * mask.mean()
            total += rgb * w
            weight += w
    return total / weight if weight > 0 else None


def first_model(state: dict) -> str | None:
    if "variants" in state:
        v = next(iter(state["variants"].values()))
        return (v[0] if isinstance(v, list) else v)["model"]
    if "multipart" in state:
        a = state["multipart"][0]["apply"]
        return (a[0] if isinstance(a, list) else a)["model"]
    return None


def state_model(state: dict, props: dict[str, str]) -> str | None:
    """variants のキー (facing=north,lit=true など) が props をすべて含む最初のモデル。無ければ first_model"""
    for key, v in state.get("variants", {}).items():
        have = dict(p.split("=", 1) for p in key.split(",") if p)
        if all(have.get(k) == val for k, val in props.items()):
            return (v[0] if isinstance(v, list) else v)["model"]
    return first_model(state)


def face_emission(assets: Assets, model: dict, element: dict, face: str, edge: tuple[float, float]) -> np.ndarray | None:
    spec = element.get("faces", {}).get(face)
    ref = resolve_texture(model["textures"], spec.get("texture", "")) if spec else None
    e = assets.emission(ref, edge) if ref else None
    if e is None:
        return None
    uv = spec.get("uv")
    if uv:
        s = e.shape[0] / 16.0
        u0, u1 = sorted((uv[0], uv[2]))
        v0, v1 = sorted((uv[1], uv[3]))
        e = e[int(v0 * s):max(int(v1 * s), int(v0 * s) + 1), int(u0 * s):max(int(u1 * s), int(u0 * s) + 1)]
    return e


def emission_rect(e: np.ndarray) -> tuple[int, int, int, int] | None:
    """最大の発光の RECT_THRESHOLD 倍を超える画素の外接矩形 (x0, y0, x1, y1。画素の境界で x1, y1 は含まない)"""
    if e.max() <= 1e-6:
        return None
    ys, xs = np.nonzero(e > RECT_THRESHOLD * e.max())
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def overlap_weights(lo: float, hi: float, count: int, size: int) -> np.ndarray:
    """[lo, hi) を count 等分した各区間と、各画素 [p, p + 1) の重なる長さ (count, size)"""
    edges = lo + (hi - lo) * np.arange(count + 1) / count
    px = np.arange(size)
    return np.clip(np.minimum(edges[1:, None], px + 1) - np.maximum(edges[:-1, None], px), 0.0, None)


def class_mask(e: np.ndarray, norm: float) -> dict | None:
    """面の種類の発光 e から、光る範囲の四角と 4x4 のマスを作る。norm は光源の正規化 N。光らない面は None"""
    r = emission_rect(e)
    if r is None:
        return None
    h, w = e.shape
    x0, y0, x1, y1 = r
    area = (x1 - x0) * (y1 - y0) / (w * h)
    ratio = e.mean() / (area * norm)
    if ratio < MASK_MIN_RATIO:
        return None
    # 四角の中を 4x4 に分け、画素との重なりの面積で重み付けした平均。画素に丸めると境目の 1 画素が隣のマスへ漏れる
    cells = overlap_weights(y0, y1, MASK_GRID, h) @ e @ overlap_weights(x0, x1, MASK_GRID, w).T
    cells = cells / ((x1 - x0) * (y1 - y0) / MASK_GRID**2)
    # マスは四角の中の配分だけを決め、面全体の光の量 (ratio x 四角の面積) は四角と同じに保つ
    weights = ratio * cells / cells.mean()
    scale = float(weights.max())
    levels = np.rint(weights / scale * MASK_GRID_LEVELS).astype(int)
    return {"rect": [round(v, 4) for v in (x0 / w, y0 / h, x1 / w, y1 / h)], "ratio": round(float(ratio), 4),
            "scale": round(scale, 4), "grid": " ".join("".join(f"{v:x}" for v in row) for row in levels)}


def light_mask(assets: Assets, block_spec: str, decor: bool) -> dict | None:
    """光源ブロック 1 つの 3 種類の面 (上・下・側面) の光り方。元は最も大きい要素 (ランタンは本体)"""
    name, *states = block_spec.split(":")
    state = assets.json(f"assets/minecraft/blockstates/{name}.json")
    ref = state_model(state, dict(s.split("=", 1) for s in states)) if state else None
    if ref is None:
        return None
    model = assets.model(ref)
    elements = model["elements"] or []
    if not elements:
        return None
    el = max(elements, key=lambda x: np.prod([t - f for f, t in zip(x["from"], x["to"])]))
    edge = DECOR_EMISSION_EDGE if decor else EMISSION_EDGE
    faces = {f: e for f in ("up", "down", "north", "south", "east", "west") if (e := face_emission(assets, model, el, f, edge)) is not None}
    # 正規化 N: 6 面それぞれの光る範囲の中の発光の平均の最大。明るい面の光る部分が今と同じ明るさになる
    inner = []
    for e in faces.values():
        r = emission_rect(e)
        if r is not None:
            inner.append(e[r[1]:r[3], r[0]:r[2]].mean())
    if not inner:
        return None
    norm = max(inner)
    out: dict = {"block": block_spec}
    any_light = False
    for cls, names in FACE_CLASSES:
        es = [faces[f] for f in names if f in faces]
        # 側面は 4 面を同じテクスチャの座標のまま平均する (向きはボクセルに無い)。大きさが違えば最初の面
        e = np.mean(es, axis=0) if es and all(x.shape == es[0].shape for x in es) else (es[0] if es else None)
        mask = class_mask(e, norm) if e is not None else None
        any_light = any_light or mask is not None
        out[cls] = mask
    return out if any_light else None


def write_light_masks(assets: Assets, jar_name: str) -> None:
    lines = []
    for light in LIGHTS:
        spec = light.mask_block()
        if not spec:
            continue
        mask = light_mask(assets, spec, light.is_decor())
        if mask is None:
            raise SystemExit(f"光源 {light.index} ({light.title}): {spec} の面の光り方を測れない")
        lines.append(f'  "{light.index}": ' + json.dumps({"light": light.title, **mask}, ensure_ascii=False))
    MASKS_OUT.write_text('{\n "source": ' + json.dumps(jar_name) + ',\n "lights": {\n' + ",\n".join(lines) + "\n }\n}\n",
                         encoding="utf-8", newline="\n")
    print(f"{MASKS_OUT.relative_to(ROOT)}: {len(lines)} 光源")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("使い方: uv run tools/gen_block_colors.py <client.jar>")
    assets = Assets(Path(sys.argv[1]))
    prefix = "assets/minecraft/blockstates/"
    colors: dict[str, list[int]] = {}
    tops: dict[str, list[int]] = {}
    for path in sorted(n for n in assets.names if n.startswith(prefix) and n.endswith(".json")):
        name = path[len(prefix):-5]
        ref = first_model(assets.json(path) or {})
        if ref is None:
            continue
        model = assets.model(ref)
        tint = TINT_BY_BLOCK.get(name, FOLIAGE_TINT)
        if name in PARTICLE_ONLY:
            ref = resolve_texture(model["textures"], model["textures"].get("particle", ""))
            tex = assets.texture(ref) if ref else None
            if tex is None:
                continue
            rgb = tex[..., :3].reshape(-1, 3).mean(axis=0)
            t = PARTICLE_ONLY[name]
            if t is not None:
                rgb = rgb * srgb_to_linear(np.array(t, dtype=np.float64) / 255.0)
        else:
            rgb = average_model(assets, model, tint)
            if rgb is None:
                continue
        colors[name] = [int(round(x)) for x in linear_to_srgb(rgb, 1.0) * 255.0]
        if name not in PARTICLE_ONLY:
            top = average_model(assets, model, tint, {"up"})
            if top is not None:
                top8 = [int(round(x)) for x in linear_to_srgb(top, 1.0) * 255.0]
                if max(abs(a - b) for a, b in zip(top8, colors[name])) >= TOP_COLOR_MIN_DIFF:
                    tops[name] = top8
    # 差分が読めるように 1 ブロック 1 行で書く
    lines = [f'  "{k}": [{v[0]}, {v[1]}, {v[2]}]' for k, v in colors.items()]
    top_lines = [f'  "{k}": [{v[0]}, {v[1]}, {v[2]}]' for k, v in tops.items()]
    body = ('{\n "source": ' + json.dumps(Path(sys.argv[1]).name) + ',\n "colors": {\n' + ",\n".join(lines) + "\n },\n"
            + ' "top": {\n' + ",\n".join(top_lines) + "\n }\n}\n")
    OUT.write_text(body, encoding="utf-8", newline="\n")
    print(f"{OUT.relative_to(ROOT)}: {len(colors)} ブロック (上面が違う {len(tops)})")
    write_light_masks(assets, Path(sys.argv[1]).name)


if __name__ == "__main__":
    main()
