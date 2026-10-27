"""
ディメンション別ラッパー (shaders/world0, world-1, world1) を生成する

ラッパーは `#version` + ディメンション define + 本体ごとのマクロ + `/program/<本体>` の include だけのファイル。
プログラムと本体、本体に渡すマクロの対応は PROGRAMS の表 1 か所で持つ。
本体は shaders/program/ に 1 セットだけ置く (BSL / Bliss 方式)。

使い方:
    uv run tools/gen_wrappers.py            # 足りないラッパーだけ作る
    uv run tools/gen_wrappers.py --force    # 全部作り直す
    uv run tools/gen_wrappers.py --check    # 本体の欠落・ラッパーの過不足・本文の不一致を報告するだけ
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

# ステージ -> (本体の program/ からのパス, 本体の前に定義するマクロ)。None は同名の本体でマクロなし
Body = tuple[str, tuple[str, ...]]

FULLSCREEN_VSH: Body = ("common/fullscreen.vsh", ())


def shared(body: str, macro: str, stages: tuple[str, ...] = ("vsh", "fsh")) -> dict[str, Body]:
    """複数のプログラムが 1 つの本体を共有し、マクロで分岐する"""
    return {s: (f"{body}.{s}", (macro,)) for s in stages}


def fullscreen(*own_stages: str) -> dict[str, Body | None]:
    """全画面クアッドの頂点シェーダーは共有し、残りのステージは同名の本体を使う"""
    return {"vsh": FULLSCREEN_VSH, **{s: None for s in own_stages}}


# プログラム名 -> ステージ。docs/architecture.md のパイプライン表と一致させる
# ステージを list で書いたものは、すべて同名の本体でマクロなし
PROGRAMS: dict[str, list[str] | dict[str, Body | None]] = {
    # setup (起動時 1 回)
    "setup": ["csh"],
    "setup1": ["csh"],
    "setup2": ["csh"],
    # begin (shadow の前)
    "begin": ["csh"],
    # shadow
    "shadow": ["vsh", "fsh"],
    "shadow_entities": ["vsh", "gsh", "fsh"],
    # ブロックエンティティ用。本体は shadow_entities と共通 (light モジュール)
    "shadow_block": shared("shadow_entities", "PROGRAM_SHADOW_BLOCK", ("vsh", "gsh", "fsh")),
    # prepare (shadow の後, gbuffers の前)
    "prepare": ["csh"],
    "prepare1": ["csh"],
    "prepare2": ["csh"],
    # gbuffers
    "gbuffers_basic": shared("gbuffers/solid", "GBUF_BASIC"),
    "gbuffers_line": shared("gbuffers/solid", "GBUF_LINE"),
    "gbuffers_textured": shared("gbuffers/solid", "GBUF_TEXTURED"),
    "gbuffers_textured_lit": shared("gbuffers/solid", "GBUF_TEXTURED_LIT"),
    "gbuffers_skybasic": ["vsh", "fsh"],
    "gbuffers_skytextured": ["vsh", "fsh"],
    "gbuffers_clouds": ["vsh", "fsh"],
    "gbuffers_terrain": shared("gbuffers/solid", "GBUF_TERRAIN"),
    "gbuffers_damagedblock": shared("gbuffers/overlay", "GBUF_DAMAGEDBLOCK"),
    "gbuffers_block": shared("gbuffers/solid", "GBUF_BLOCK"),
    "gbuffers_beaconbeam": shared("gbuffers/solid", "GBUF_BEACON"),
    "gbuffers_entities": shared("gbuffers/solid", "GBUF_ENTITIES"),
    "gbuffers_entities_translucent": shared("gbuffers/translucent", "GBUF_ENTITIES_TRANSLUCENT"),
    "gbuffers_block_translucent": shared("gbuffers/translucent", "GBUF_BLOCK_TRANSLUCENT"),
    "gbuffers_armor_glint": shared("gbuffers/overlay", "GBUF_ARMOR_GLINT"),
    "gbuffers_spidereyes": shared("gbuffers/overlay", "GBUF_SPIDEREYES"),
    "gbuffers_hand": shared("gbuffers/solid", "GBUF_HAND"),
    "gbuffers_particles": shared("gbuffers/solid", "GBUF_PARTICLES"),
    "gbuffers_weather": ["vsh", "fsh"],
    "gbuffers_lightning": ["vsh", "fsh"],
    "gbuffers_water": shared("gbuffers/translucent", "GBUF_WATER"),
    "gbuffers_hand_water": shared("gbuffers/translucent", "GBUF_HAND_WATER"),
    "gbuffers_particles_translucent": shared("gbuffers/translucent", "GBUF_PARTICLES_TRANSLUCENT"),
    # deferred
    "deferred": ["csh", "csh_a"],
    "deferred1": ["csh"],
    "deferred2": fullscreen("fsh"),
    "deferred10": ["csh"],
    "deferred11": fullscreen("fsh"),
    "deferred20": fullscreen("fsh"),
    "deferred21": fullscreen("fsh"),
    "deferred30": fullscreen("fsh"),
    # composite
    "composite": ["csh"],
    "composite1": fullscreen("fsh"),
    "composite10": ["csh"],
    "composite11": fullscreen("fsh"),
    "composite20": fullscreen("fsh"),
    "composite21": fullscreen("fsh"),
    "composite22": fullscreen("fsh"),
    "composite23": fullscreen("fsh"),
    "composite24": fullscreen("fsh"),
    "composite25": ["csh"],
    "final": fullscreen("fsh"),
}


def stage_file(name: str, stage: str) -> str:
    """csh_a -> name_a.csh のようにステージ名をファイル名へ変換する"""
    if stage.startswith("csh_"):
        return f"{name}_{stage[4:]}.csh"
    return f"{name}.{stage}"


def stage_bodies(name: str) -> dict[str, Body]:
    """ラッパーのファイル名 -> (本体, マクロ)"""
    spec = PROGRAMS[name]
    stages = {s: None for s in spec} if isinstance(spec, list) else spec
    result: dict[str, Body] = {}
    for stage, body in stages.items():
        file_name = stage_file(name, stage)
        result[file_name] = body if body is not None else (file_name, ())
    return result


def version_line(file_name: str) -> str:
    # compute は core プロファイル、それ以外は Iris 推奨の compatibility
    return "#version 460" if file_name.endswith(".csh") else "#version 460 compatibility"


def wrapper_text(file_name: str, world_define: str, body: Body) -> str:
    path, macros = body
    lines = [version_line(file_name), f"#define {world_define}"]
    lines += [f"#define {m}" for m in macros]
    lines.append(f'#include "/program/{path}"')
    return "\n".join(lines) + "\n"


def expected_wrappers() -> dict[str, Body]:
    return {f: b for n in PROGRAMS for f, b in stage_bodies(n).items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    wrappers = expected_wrappers()
    problems = 0

    for path in sorted({b[0] for b in wrappers.values()}):
        if not (SHADERS / "program" / path).exists():
            print(f"[missing body] program/{path}")
            problems += 1

    for world, define in WORLDS.items():
        wdir = SHADERS / world
        if not args.check:
            wdir.mkdir(parents=True, exist_ok=True)
        for f, body in wrappers.items():
            path = wdir / f
            text = wrapper_text(f, define, body)
            if args.check:
                if not path.exists():
                    print(f"[missing wrapper] {world}/{f}")
                    problems += 1
                elif path.read_bytes().decode("utf-8") != text:
                    print(f"[mismatch wrapper] {world}/{f}")
                    problems += 1
                continue
            if path.exists() and not args.force and path.read_bytes().decode("utf-8") == text:
                continue
            path.write_text(text, encoding="utf-8", newline="\n")
        if wdir.exists():
            for p in wdir.iterdir():
                if p.name not in wrappers:
                    print(f"[extra wrapper] {world}/{p.name}")

    if args.check:
        print("OK" if problems == 0 else f"{problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
