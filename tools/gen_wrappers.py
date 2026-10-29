"""
ディメンション別ラッパー (shaders/world0, world-1, world1) を生成する

ラッパーは `#version` + ディメンション define + 本体ごとのマクロ + `/program/<本体>` の include だけのファイル。
プログラムと本体、本体に渡すマクロの対応は PROGRAMS と BODIES の表で持つ。
本体は shaders/program/<モジュール>/ に 1 セットだけ置く (BSL / Bliss 方式)。

使い方:
    uv run tools/gen_wrappers.py            # 足りないラッパーだけ作る
    uv run tools/gen_wrappers.py --force    # 全部作り直す
    uv run tools/gen_wrappers.py --check    # 本体の欠落・ラッパーの過不足・本文の不一致を報告するだけ
"""

from __future__ import annotations

import argparse
import sys

from lib.paths import SHADERS

# ディメンションフォルダ -> 定義するマクロ
WORLDS = {
    "world0": "WORLD_OVERWORLD",
    "world-1": "WORLD_NETHER",
    "world1": "WORLD_END",
}

# ステージ -> (本体の program/ からのパス, 本体の前に定義するマクロ)。None は BODIES の本体でマクロなし
Body = tuple[str, tuple[str, ...]]

FULLSCREEN_VSH: Body = ("common/fullscreen.vsh", ())

# 同名の本体 (マクロなし) の置き場: ラッパーのファイル名 -> program/ からのパス (モジュールごとの役割名)
BODIES: dict[str, str] = {
    # light
    "setup.csh": "light/setup_tables.csh",
    "begin.csh": "light/frame_begin.csh",
    "shadow.vsh": "light/shadow_terrain.vsh",
    "shadow.fsh": "light/shadow_terrain.fsh",
    "shadow_entities.vsh": "light/shadow_entities.vsh",
    "shadow_entities.gsh": "light/shadow_entities.gsh",
    "shadow_entities.fsh": "light/shadow_entities.fsh",
    "deferred.csh": "light/floodfill.csh",
    "deferred_a.csh": "light/light_bins.csh",
    "deferred1.csh": "light/block_light_trace.csh",
    "deferred2.fsh": "light/block_light_denoise.fsh",
    # sky
    "setup1.csh": "sky/transmittance_lut.csh",
    "setup2.csh": "sky/multiscatter_lut.csh",
    "prepare.csh": "sky/sun_sky_light.csh",
    "prepare1.csh": "sky/skyview_lut.csh",
    "prepare2.csh": "sky/cloud_weather.csh",
    "deferred20.fsh": "sky/cloud_march.fsh",
    "deferred21.fsh": "sky/cloud_upscale.fsh",
    "composite1_a.csh": "sky/fog_march.csh",
    "composite11.fsh": "sky/fog_apply.fsh",
    "gbuffers_skybasic.vsh": "sky/vanilla_sky.vsh",
    "gbuffers_skybasic.fsh": "sky/vanilla_sky.fsh",
    "gbuffers_skytextured.vsh": "sky/sun_moon.vsh",
    "gbuffers_skytextured.fsh": "sky/sun_moon.fsh",
    "gbuffers_clouds.vsh": "sky/vanilla_clouds.vsh",
    "gbuffers_clouds.fsh": "sky/vanilla_clouds.fsh",
    "gbuffers_weather.vsh": "sky/weather.vsh",
    "gbuffers_weather.fsh": "sky/weather.fsh",
    # surface
    "gbuffers_lightning.vsh": "surface/lightning.vsh",
    "gbuffers_lightning.fsh": "surface/lightning.fsh",
    "deferred10.csh": "surface/gi_raw.csh",
    "deferred11.fsh": "surface/gi_denoise.fsh",
    "deferred30.fsh": "surface/opaque_shading.fsh",
    "composite.csh": "surface/reflection_trace.csh",
    "composite1.fsh": "surface/translucent_composite.fsh",
    # post
    "composite20.fsh": "post/taa.fsh",
    "composite21.fsh": "post/motion_blur.fsh",
    "composite22.fsh": "post/dof.fsh",
    "composite23.fsh": "post/bloom_down.fsh",
    "composite24.fsh": "post/bloom_blur.fsh",
    "composite25.csh": "post/exposure_autofocus.csh",
    "final.fsh": "post/final.fsh",
}


def shared(body: str, macro: str, stages: tuple[str, ...] = ("vsh", "fsh")) -> dict[str, Body]:
    """複数のプログラムが 1 つの本体を共有し、マクロで分岐する"""
    return {s: (f"{body}.{s}", (macro,)) for s in stages}


def fullscreen(*own_stages: str) -> dict[str, Body | None]:
    """全画面クアッドの頂点シェーダーは共有し、残りのステージは同名の本体を使う"""
    return {"vsh": FULLSCREEN_VSH, **{s: None for s in own_stages}}


# プログラム名 -> ステージ。docs/architecture.md のパイプライン表と一致させる
# ステージを list で書いたものは、すべて BODIES の本体でマクロなし
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
    "shadow_block": shared("light/shadow_entities", "PROGRAM_SHADOW_BLOCK", ("vsh", "gsh", "fsh")),
    # prepare (shadow の後, gbuffers の前)
    "prepare": ["csh"],
    "prepare1": ["csh"],
    "prepare2": ["csh"],
    # gbuffers
    "gbuffers_basic": shared("surface/gbuffers_solid", "GBUF_BASIC"),
    "gbuffers_line": shared("surface/gbuffers_solid", "GBUF_LINE"),
    "gbuffers_textured": shared("surface/gbuffers_solid", "GBUF_TEXTURED"),
    "gbuffers_textured_lit": shared("surface/gbuffers_solid", "GBUF_TEXTURED_LIT"),
    "gbuffers_skybasic": ["vsh", "fsh"],
    "gbuffers_skytextured": ["vsh", "fsh"],
    "gbuffers_clouds": ["vsh", "fsh"],
    "gbuffers_terrain": shared("surface/gbuffers_solid", "GBUF_TERRAIN"),
    "gbuffers_damagedblock": shared("surface/gbuffers_overlay", "GBUF_DAMAGEDBLOCK"),
    "gbuffers_block": shared("surface/gbuffers_solid", "GBUF_BLOCK"),
    "gbuffers_beaconbeam": shared("surface/gbuffers_solid", "GBUF_BEACON"),
    "gbuffers_entities": shared("surface/gbuffers_solid", "GBUF_ENTITIES"),
    "gbuffers_entities_translucent": shared("surface/gbuffers_translucent", "GBUF_ENTITIES_TRANSLUCENT"),
    "gbuffers_block_translucent": shared("surface/gbuffers_translucent", "GBUF_BLOCK_TRANSLUCENT"),
    "gbuffers_armor_glint": shared("surface/gbuffers_overlay", "GBUF_ARMOR_GLINT"),
    "gbuffers_spidereyes": shared("surface/gbuffers_overlay", "GBUF_SPIDEREYES"),
    "gbuffers_hand": shared("surface/gbuffers_solid", "GBUF_HAND"),
    "gbuffers_particles": shared("surface/gbuffers_solid", "GBUF_PARTICLES"),
    "gbuffers_weather": ["vsh", "fsh"],
    "gbuffers_lightning": ["vsh", "fsh"],
    "gbuffers_water": shared("surface/gbuffers_translucent", "GBUF_WATER"),
    "gbuffers_hand_water": shared("surface/gbuffers_translucent", "GBUF_HAND_WATER"),
    "gbuffers_particles_translucent": shared("surface/gbuffers_translucent", "GBUF_PARTICLES_TRANSLUCENT"),
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
    "composite1": fullscreen("fsh", "csh_a"),
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
        result[file_name] = body if body is not None else (BODIES[file_name], ())
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
