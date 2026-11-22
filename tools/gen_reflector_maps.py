"""
反射体 (鉄・ラピスラズリ・エメラルド・ダイヤモンド・金のブロック) の面の凹凸を、テクスチャの明るさを高さとみなして
ラプラシアン (面が光を集める・散らす度合い) の 4 段のミップにし、tools/reflector_maps.json に書く

lib/surface/reflector_light.glsl の reflectorPattern が使う (表の持ち方は gen_block_properties.py が決める)
バニラのテクスチャには法線も高さも無いので明るさの勾配で代える。曲面の反射は、面から距離 d の点で光の密度が
1 + 2 d x ラプラシアン (1 次近似) になる。反射の広がりが大きいほどミップを粗くしてぼかす

jar は読むだけ。バージョンを上げた時だけ実行し、結果の JSON をリポジトリに入れる (画像は入らない)
使い方: uv run tools/gen_reflector_maps.py <client.jar>
"""

from __future__ import annotations

import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.paths import ROOT  # noqa: E402

OUT = ROOT / "tools" / "reflector_maps.json"
# ブロック ID (lib/ids/block_ids.glsl の BLOCK_METAL、BLOCK_DECOR_LAPIS..GOLD) とテクスチャの対。ID 10 は銅ブロックと同じ ID
BLOCKS = {10: "iron_block", 13: "lapis_block", 14: "emerald_block", 15: "diamond_block", 16: "gold_block"}
SIZE = 16
LEVELS = 4
# ラプラシアン (明るさ / ブロック^2) をこの値で割って持つ。レベル 0 の二乗平均平方根がおよそ 1 になる値
NORM = 50.0
LUMA = np.array([0.2126, 0.7152, 0.0722])


def laplacian_levels(lum: np.ndarray) -> list[np.ndarray]:
    """明るさを 2x2 の平均で粗くしながら、各段の周期的なラプラシアンを返す (ブロックの面は同じテクスチャで繰り返す)"""
    out = []
    h = lum
    for m in range(LEVELS):
        step = (2**m) / SIZE
        lap = (np.roll(h, 1, 0) + np.roll(h, -1, 0) + np.roll(h, 1, 1) + np.roll(h, -1, 1) - 4.0 * h) / (step * step)
        out.append(lap / NORM)
        h = h.reshape(h.shape[0] // 2, 2, h.shape[1] // 2, 2).mean(axis=(1, 3))
    return out


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("使い方: uv run tools/gen_reflector_maps.py <client.jar>")
    jar = Path(sys.argv[1])
    z = zipfile.ZipFile(jar)
    lines = []
    for block_id, name in BLOCKS.items():
        img = Image.open(io.BytesIO(z.read(f"assets/minecraft/textures/block/{name}.png"))).convert("RGB")
        if img.size != (SIZE, SIZE):
            raise SystemExit(f"{name}: {img.size} (16x16 のテクスチャだけ扱う)")
        lum = np.asarray(img, dtype=np.float64) / 255.0 @ LUMA
        levels = laplacian_levels(lum)
        scales = [max(float(np.abs(v).max()), 1e-3) for v in levels]
        packed = [np.rint(v / s * 127.0).astype(int).ravel().tolist() for v, s in zip(levels, scales)]
        entry = {"block": name, "scales": [round(s, 4) for s in scales], "levels": packed}
        lines.append(f'  "{block_id}": ' + json.dumps(entry))
    OUT.write_text('{\n "source": ' + json.dumps(jar.name) + f',\n "norm": {NORM},\n "maps": {{\n' + ",\n".join(lines) + "\n }\n}\n",
                   encoding="utf-8", newline="\n")
    print(f"{OUT.relative_to(ROOT)}: {len(lines)} ブロック")


if __name__ == "__main__":
    main()
