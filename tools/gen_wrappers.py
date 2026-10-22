"""
ディメンション別ラッパー (shaders/world0, world-1, world1) を生成する

ラッパーは `#version` + ディメンション define + `/program/<name>.<ext>` の include だけの薄いファイル。
本体は shaders/program/ に 1 セットだけ置く (BSL / Bliss 方式)。

使い方:
    uv run tools/gen_wrappers.py            # 足りないラッパーだけ作る
    uv run tools/gen_wrappers.py --force    # 全部作り直す
    uv run tools/gen_wrappers.py --check    # 本体の欠落・余分なラッパーを報告するだけ
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"

# ディメンションフォルダ -> 定義するマクロ
WORLDS = {
    "world0": "WORLD_OVERWORLD",
    "world-1": "WORLD_NETHER",
    "world1": "WORLD_END",
}

# プログラム名 -> ステージ (拡張子)。docs/architecture.md のパイプライン表と一致させる
PROGRAMS: dict[str, list[str]] = {
    # setup (起動時 1 回)
    "setup": ["csh"],
    "setup1": ["csh"],
    "setup2": ["csh"],
    # begin (shadow の前)
    "begin": ["csh"],
    # shadow
    "shadow": ["vsh", "fsh"],
    "shadow_entities": ["vsh", "gsh", "fsh"],
    "shadow_block": ["vsh", "gsh", "fsh"],
    # prepare (shadow の後, gbuffers の前)
    "prepare": ["csh"],
    "prepare1": ["csh"],
    "prepare2": ["csh"],
    # gbuffers
    "gbuffers_basic": ["vsh", "fsh"],
    "gbuffers_line": ["vsh", "fsh"],
    "gbuffers_textured": ["vsh", "fsh"],
    "gbuffers_textured_lit": ["vsh", "fsh"],
    "gbuffers_skybasic": ["vsh", "fsh"],
    "gbuffers_skytextured": ["vsh", "fsh"],
    "gbuffers_clouds": ["vsh", "fsh"],
    "gbuffers_terrain": ["vsh", "fsh"],
    "gbuffers_damagedblock": ["vsh", "fsh"],
    "gbuffers_block": ["vsh", "fsh"],
    "gbuffers_beaconbeam": ["vsh", "fsh"],
    "gbuffers_entities": ["vsh", "fsh"],
    "gbuffers_entities_translucent": ["vsh", "fsh"],
    "gbuffers_block_translucent": ["vsh", "fsh"],
    "gbuffers_armor_glint": ["vsh", "fsh"],
    "gbuffers_spidereyes": ["vsh", "fsh"],
    "gbuffers_hand": ["vsh", "fsh"],
    "gbuffers_particles": ["vsh", "fsh"],
    "gbuffers_weather": ["vsh", "fsh"],
    "gbuffers_lightning": ["vsh", "fsh"],
    "gbuffers_water": ["vsh", "fsh"],
    "gbuffers_hand_water": ["vsh", "fsh"],
    "gbuffers_particles_translucent": ["vsh", "fsh"],
    # deferred
    "deferred": ["csh", "csh_a"],
    "deferred1": ["csh"],
    "deferred2": ["vsh", "fsh"],
    "deferred10": ["csh"],
    "deferred11": ["vsh", "fsh"],
    "deferred20": ["vsh", "fsh"],
    "deferred21": ["vsh", "fsh"],
    "deferred30": ["vsh", "fsh"],
    # composite
    "composite": ["csh"],
    "composite1": ["vsh", "fsh"],
    "composite10": ["csh"],
    "composite11": ["vsh", "fsh"],
    "composite20": ["vsh", "fsh"],
    "composite21": ["vsh", "fsh"],
    "composite22": ["vsh", "fsh"],
    "composite23": ["vsh", "fsh"],
    "composite24": ["vsh", "fsh"],
    "composite25": ["csh"],
    "final": ["vsh", "fsh"],
}


def stage_file(name: str, stage: str) -> str:
    """csh_a -> name_a.csh のようにステージ名をファイル名へ変換する"""
    if stage.startswith("csh_"):
        return f"{name}_{stage[4:]}.csh"
    return f"{name}.{stage}"


def version_line(file_name: str) -> str:
    # compute は core プロファイル、それ以外は Iris 推奨の compatibility
    return "#version 460" if file_name.endswith(".csh") else "#version 460 compatibility"


def wrapper_text(file_name: str, world_define: str) -> str:
    return f'{version_line(file_name)}\n#define {world_define}\n#include "/program/{file_name}"\n'


def expected_files() -> list[str]:
    return [stage_file(n, s) for n, stages in PROGRAMS.items() for s in stages]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    files = expected_files()
    problems = 0

    for f in files:
        if not (SHADERS / "program" / f).exists():
            print(f"[missing body] program/{f}")
            problems += 1

    for world, define in WORLDS.items():
        wdir = SHADERS / world
        if not args.check:
            wdir.mkdir(parents=True, exist_ok=True)
        for f in files:
            path = wdir / f
            if args.check:
                if not path.exists():
                    print(f"[missing wrapper] {world}/{f}")
                    problems += 1
                continue
            if path.exists() and not args.force:
                continue
            path.write_text(wrapper_text(f, define), encoding="utf-8", newline="\n")
        if wdir.exists():
            for p in wdir.iterdir():
                if p.name not in files:
                    print(f"[extra wrapper] {world}/{p.name}")

    if args.check:
        print("OK" if problems == 0 else f"{problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
