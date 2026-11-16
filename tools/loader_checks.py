"""
ローダー (tools/capabilities.py の ENVS) ごとの静的検査。validate_shaders.py から呼ぶ

- colortex の上限: 前処理の後に有効なプログラムが、上限以上の colortex を書く (RENDERTARGETS)・読む・指定する
  (`colortexNFormat` などの const。Iris はコメントの中も読む)。shaders.properties の `colortexN` の項目も数える
- shaders.properties: iris.features.required が既知の flag か、bufferObject の添字、image の数、
  image と customTexture の pixel format / pixel type / internal format が列挙にあるか
- GLSL の colortexN / shadowcolorN の Format の値が internal format の列挙にあるか
- ローダーに依らない検査: RENDERTARGETS のカンマの後の空白、MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS の直接書き
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import gen_capabilities
import include_deps
from capabilities import CAPS, LOADER_MACROS, Env
from gen_settings import Option
from lib import cpp
from lib.properties import PROPERTIES, PROP_IF_RE, preprocess_properties

RT_RE = re.compile(r"/\*\s*RENDERTARGETS\s*:([^*]*)\*/")
COLORTEX_RE = re.compile(r"\bcolortex(\d+)(?!\d)")
SAMPLER_DECL_RE = re.compile(r"^\s*uniform\s+\w*sampler\w*\s+colortex\d+\s*;")
DIRECTIVE_RE = re.compile(r"\bconst\s+\w+\s+(colortex|shadowcolor)(\d+)(Format|Clear|ClearColor|MipmapEnabled)\s*=\s*([^;]*);")
DIRECT_RE = re.compile(r"\b(" + "|".join(LOADER_MACROS) + r")\b")
GLSL_SUFFIXES = {".glsl", ".vsh", ".fsh", ".gsh", ".csh", ".tcs", ".tes"}
GENERATED_BEGIN_RE = re.compile(r"^\s*#\s*BEGIN GENERATED\b")
GENERATED_END_RE = re.compile(r"^\s*#\s*END GENERATED\b")

# 能力が無いローダーでは読まれないプログラム (ファイルがあっても無視される)
CAP_PROGRAMS = {
    "CAP_SHADOW_ENTITIES": ("shadow_entities", "shadow_block"),
    "CAP_LIGHTNING_PROGRAM": ("gbuffers_lightning",),
}


@dataclass(frozen=True)
class ColortexUse:
    """上限を超える colortex の使用 1 件"""

    env: str
    config: str
    index: int
    kind: str  # 書く / 読む / 指定 / properties
    program: str
    where: str


ScanResult = tuple[list[ColortexUse], list[str]]


def caps_of(env: Env) -> dict[str, bool]:
    return {c.name: cpp.eval_expr(c.detect, env.macros) for c in CAPS}


def missing_programs(env: Env) -> set[str]:
    caps = caps_of(env)
    return {p for name, progs in CAP_PROGRAMS.items() if not caps.get(name) for p in progs}


def settings_macros(options: dict[str, Option], overrides: dict[str, str | bool]) -> dict[str, str]:
    """設定の既定値に上書きを当てた、前処理のマクロ (ブールは定義の有無)"""
    macros: dict[str, str] = {}
    for name, opt in options.items():
        val = overrides.get(name, opt.default)
        if opt.kind == "bool":
            if val is True or val == "true":
                macros[name] = "1"
        elif opt.kind == "value":
            macros[name] = str(val)
    return macros


def properties_problems(env: Env, prop_lines: list[str]) -> list[str]:
    """前処理した shaders.properties の、このローダーで読み込みが失敗する・資源が捨てられる記述"""
    problems: list[str] = []
    images: set[str] = set()
    for line in prop_lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        key, _, value = (p.strip() for p in s.partition("="))
        if key == "iris.features.required":
            for flag in value.split():
                if flag.upper() not in env.features:
                    problems.append(f"iris.features.required の {flag} が {env.name} の flag にない (読み込みが失敗する)")
        elif m := re.fullmatch(r"bufferObject\.(\d+)", key):
            if int(m.group(1)) > env.buffer_object_max_index:
                problems.append(f"{key}: 添字が {env.name} の上限 {env.buffer_object_max_index} を超える (その SSBO が捨てられる)")
        elif key.startswith("image."):
            images.add(key)
            # image.<名前> = <sampler> <format> <internal format> <pixel type> <clear> <relative> <サイズ...>
            toks = value.split()
            if len(toks) >= 4:
                problems += _format_problems(env, key, toks[1], toks[2], toks[3])
        elif key.startswith("customTexture."):
            # 生のデータ: <path> <TEXTURE_nD> <internal format> <サイズ...> <format> <pixel type>
            toks = value.split()
            if len(toks) >= 5 and toks[1].startswith("TEXTURE_"):
                problems += _format_problems(env, key, toks[-2], toks[2], toks[-1])
    if len(images) > env.image_count:
        problems.append(f"image が {len(images)} 個ある ({env.name} の上限は {env.image_count}。超えた分は捨てられる)")
    return problems


def _format_problems(env: Env, key: str, fmt: str, internal: str, pixel_type: str) -> list[str]:
    problems = []
    if fmt.upper() not in env.pixel_formats:
        problems.append(f"{key}: pixel format {fmt} が {env.name} の列挙にない")
    if internal.upper() not in env.internal_formats:
        problems.append(f"{key}: internal format {internal} が {env.name} の列挙にない")
    if pixel_type.upper() not in env.pixel_types:
        problems.append(f"{key}: pixel type {pixel_type} が {env.name} の列挙にない (読み込みが失敗する)")
    return problems


def properties_colortex(env: Env, config: str, prop_lines: list[str]) -> list[ColortexUse]:
    uses = []
    for line in prop_lines:
        s = line.strip()
        if s.startswith("#"):
            continue
        key = s.partition("=")[0]
        for m in COLORTEX_RE.finditer(key):
            if int(m.group(1)) >= env.colortex_count:
                uses.append(ColortexUse(env.name, config, int(m.group(1)), "properties", "-", f"{PROPERTIES}: {key.strip()}"))
    return uses


def program_scan(env: Env, config: str, program: str, src: str, linemap: list[tuple[str, int]]) -> ScanResult:
    """
    ### program_scan
    1 プログラムの前処理後の本文から、上限を超える colortex の使用と、列挙にない Format の値を拾う

    @param program - `world0/composite1` の形の名前
    @param src - validate_shaders.build_source の本文 (設定とローダーのマクロを入れたもの)
    @param linemap - 本文の行 -> (元のファイル, 行)
    @returns (colortex の使用, 問題)
    """
    raw = src.splitlines()
    stripped = include_deps.strip_comments(src).splitlines()
    stripped += [""] * (len(raw) - len(stripped))
    uses: list[ColortexUse] = []
    problems: list[str] = []
    try:
        ranges = cpp.active_ranges(stripped)
    except cpp.ExprError as e:
        return [], [f"{program}: {e}"]

    def where(i: int) -> str:
        return f"{linemap[i][0]}:{linemap[i][1]}" if i < len(linemap) else f"?:{i + 1}"

    for i, line in enumerate(raw):
        if "colortex" not in line and "shadowcolor" not in line and "RENDERTARGETS" not in line:
            continue
        if not cpp.in_ranges(ranges, i):
            continue
        for rt in RT_RE.finditer(line):
            for t in rt.group(1).split(","):
                if t.strip().isdigit() and int(t) >= env.colortex_count:
                    uses.append(ColortexUse(env.name, config, int(t), "書く", program, where(i)))
        for d in DIRECTIVE_RE.finditer(line):
            n = int(d.group(2))
            if d.group(1) == "colortex" and n >= env.colortex_count:
                uses.append(ColortexUse(env.name, config, n, "指定", program, where(i)))
            if d.group(3) == "Format" and d.group(4).strip().upper() not in env.internal_formats:
                problems.append(f"{where(i)}: {d.group(1)}{n}Format の {d.group(4).strip()} が {env.name} の列挙にない")
        code = stripped[i]
        if SAMPLER_DECL_RE.match(code) or DIRECTIVE_RE.search(code):
            continue
        for m in COLORTEX_RE.finditer(code):
            if int(m.group(1)) >= env.colortex_count:
                uses.append(ColortexUse(env.name, config, int(m.group(1)), "読む", program, where(i)))
    return uses, problems


def rendertargets_spacing(shaders: Path) -> list[str]:
    """`/* RENDERTARGETS: 0, 1 */` のカンマの後の空白 (Iris は数として読めず、読み込みが失敗する)"""
    problems = []
    for path in sorted(shaders.rglob("*")):
        if path.suffix not in GLSL_SUFFIXES:
            continue
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for rt in RT_RE.finditer(line):
                if not re.fullmatch(r"\s*\d+(,\d+)*\s*", rt.group(1)):
                    problems.append(f"{path.relative_to(shaders).as_posix()}:{i}: RENDERTARGETS は数をカンマだけで区切る (空白不可): {rt.group(0)}")
    return problems


def direct_loader_macros(shaders: Path) -> list[str]:
    """
    ### direct_loader_macros
    MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS を、生成物の外で使っている箇所 (本体は能力 FX_* を見る)
    GLSL はコメントを除き、lib/settings/capabilities.glsl だけを許す。shaders.properties は生成区間の中だけを許す
    """
    problems = []
    allowed = (shaders / gen_capabilities.CAPABILITIES).resolve()
    for path in sorted(shaders.rglob("*")):
        if path.suffix not in GLSL_SUFFIXES or path.resolve() == allowed:
            continue
        code = include_deps.strip_comments(path.read_text(encoding="utf-8"))
        for i, line in enumerate(code.splitlines(), 1):
            for m in DIRECT_RE.finditer(line):
                problems.append(f"{path.relative_to(shaders).as_posix()}:{i}: {m.group(1)} を直接使っている (tools/capabilities.py の能力にする)")
    for path in sorted(shaders.glob("*.properties")):
        in_generated = False
        for i, line in enumerate(path.read_text(encoding="latin-1").splitlines(), 1):
            if GENERATED_BEGIN_RE.match(line):
                in_generated = True
            elif GENERATED_END_RE.match(line):
                in_generated = False
            elif not in_generated and (PROP_IF_RE.match(line) or not line.lstrip().startswith("#")):
                for m in DIRECT_RE.finditer(line):
                    problems.append(f"{path.name}:{i}: {m.group(1)} を直接使っている (tools/capabilities.py の能力にする)")
    return problems


def preprocessed_properties(shaders: Path, macros: dict[str, str]) -> list[str]:
    path = shaders / PROPERTIES
    return preprocess_properties(path, macros) if path.exists() else []
