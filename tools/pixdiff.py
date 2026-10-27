"""
2 枚の撮影の画素の差を数字で出す (変更の前後の見た目が、同じ設定で 2 回撮った時の揺らぎに収まるかを見る)

差は画素ごとに RGB の差の絶対値の最大 (0-255) をとり、平均・p99・最大・4/255 を超える画素の割合と、画面全体の平均色の差を出す
TAA・雲・時刻で同じシーンでも少し揺れるので、基準を 2 回撮った差を先に出し、それと比べる

使い方:
    uv run tools/pixdiff.py before_a.png before_b.png before_a.png after.png   # 2 枚ずつ組にして比べる
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

# 8 bit の 1-2 段の揺れ (ディザ・TAA) を除いた、目に見えうる差の目安
VISIBLE_STEP = 4


def diff_stats(a: Path, b: Path) -> dict[str, float]:
    x = np.asarray(Image.open(a).convert("RGB"), dtype=np.float64)
    y = np.asarray(Image.open(b).convert("RGB"), dtype=np.float64)
    if x.shape != y.shape:
        raise SystemExit(f"大きさが違う: {a.name} {x.shape[1]}x{x.shape[0]} / {b.name} {y.shape[1]}x{y.shape[0]}")
    d = np.abs(x - y).max(axis=-1)
    return {
        "mean": float(d.mean()),
        "p99": float(np.percentile(d, 99)),
        "max": float(d.max()),
        "over": float((d > VISIBLE_STEP).mean() * 100),
        "mean_color": float(np.abs(x.mean((0, 1)) - y.mean((0, 1))).max()),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="2 枚ずつの組で撮影の画素の差を出す")
    ap.add_argument("images", nargs="+", type=Path, help="a1 b1 [a2 b2 ...]")
    args = ap.parse_args()
    if len(args.images) % 2:
        ap.error("画像は 2 枚ずつの組で渡す")
    print(f"{'pair':48s} {'mean':>6s} {'p99':>6s} {'max':>5s} {f'>{VISIBLE_STEP}/255':>9s} {'mean color':>10s}")
    for a, b in zip(args.images[0::2], args.images[1::2]):
        s = diff_stats(a, b)
        print(f"{a.name + ' / ' + b.name:48s} {s['mean']:6.2f} {s['p99']:6.1f} {s['max']:5.0f} {s['over']:8.2f}% {s['mean_color']:10.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
