"""
ブロックごとの平均の色 (アルベド) を Minecraft のクライアント jar のテクスチャから計算し、tools/block_colors.json に書く

floodfill の照り返しとボクセル RT の画面外の当たりに使う (表の持ち方は gen_block_properties.py が決める)
上面の色が全体の平均と違うブロック (草ブロック・原木など) は、上面だけの平均を "top" に別に書く。
GI のレイは地面の上面に当たることが多く、草ブロックの全面の平均 (側面の土込み) は茶色で、草地の照り返しが緑にならなかった (FB #55)
jar は読むだけ。バージョンを上げた時だけ実行し、結果の JSON をリポジトリに入れる

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

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tools" / "block_colors.json"

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


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1.0 / 2.4) - 0.055)


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
        colors[name] = [int(round(x)) for x in linear_to_srgb(rgb) * 255.0]
        if name not in PARTICLE_ONLY:
            top = average_model(assets, model, tint, {"up"})
            if top is not None:
                top8 = [int(round(x)) for x in linear_to_srgb(top) * 255.0]
                if max(abs(a - b) for a, b in zip(top8, colors[name])) >= TOP_COLOR_MIN_DIFF:
                    tops[name] = top8
    # 差分が読めるように 1 ブロック 1 行で書く
    lines = [f'  "{k}": [{v[0]}, {v[1]}, {v[2]}]' for k, v in colors.items()]
    top_lines = [f'  "{k}": [{v[0]}, {v[1]}, {v[2]}]' for k, v in tops.items()]
    body = ('{\n "source": ' + json.dumps(Path(sys.argv[1]).name) + ',\n "colors": {\n' + ",\n".join(lines) + "\n },\n"
            + ' "top": {\n' + ",\n".join(top_lines) + "\n }\n}\n")
    OUT.write_text(body, encoding="utf-8", newline="\n")
    print(f"{OUT.relative_to(ROOT)}: {len(colors)} ブロック (上面が違う {len(tops)})")


if __name__ == "__main__":
    main()
