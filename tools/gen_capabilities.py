"""
能力と機能の表 (tools/capabilities.py) から、GLSL のマクロと shaders.properties の式を生成する

- shaders/lib/settings/capabilities.glsl: CAP_* と FX_* の #define。FX_* を使うファイルが `//@include "/lib/settings/capabilities.glsl"` で宣言する
  (lib/settings.glsl からは取り込まない。全プログラムの include の生成ブロックが変わり、使わないプログラムにも本文が増えるため)
- shaders.properties の `BEGIN GENERATED capabilities` と `END GENERATED capabilities` の間: FX_* の properties の項目
  (shaders.properties からは GLSL のマクロが見えないので、FX_* と CAP_* の式を展開して書く)

使い方:
    uv run tools/gen_capabilities.py            # 生成物を書く
    uv run tools/gen_capabilities.py --check    # 生成物が最新か確認する (ずれていれば終了コード 1)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import gen_settings
from capabilities import CAPS, FXS, LOADER_MACROS
from lib import generated
from lib.paths import SHADERS
from lib.properties import PROPERTIES

CAPABILITIES = "lib/settings/capabilities.glsl"
PROPS_BEGIN = "# BEGIN GENERATED capabilities (tools/gen_capabilities.py)"
PROPS_END = "# END GENERATED capabilities"

IDENT_RE = re.compile(r"[A-Za-z_]\w*")
DEFINED_RE = re.compile(r"\bdefined\s*\(?\s*([A-Za-z_]\w*)\s*\)?")

GLSL_HEADER = """\
/*
  ローダーの能力 (CAP_*) と、本体が見る機能 (FX_*)。tools/gen_capabilities.py が tools/capabilities.py から生成する (手で編集しない)
  本体は FX_* だけを見る。MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS はこのファイルの外で使わない
  値なしの define は Iris がブール設定と見なすので、値 1 で定義する。無い環境では未定義のまま (能力なし) になる
*/"""


def names() -> set[str]:
    return {c.name for c in CAPS} | {f.name for f in FXS}


def table_problems(shaders: Path = SHADERS) -> list[str]:
    """表の書き方の誤り (接頭辞、未定義の名前、後ろの FX_* の参照、ASCII でない properties の項目)"""
    problems: list[str] = []
    settings = gen_settings.parse_settings(shaders)
    seen: set[str] = set()
    for c in CAPS:
        if not c.name.startswith("CAP_"):
            problems.append(f"capabilities.py: {c.name} は CAP_ で始める")
        for ident in IDENT_RE.findall(c.detect):
            if ident != "defined" and ident not in LOADER_MACROS:
                problems.append(f"capabilities.py: {c.name} の検出に {ident} がある (使えるのは {', '.join(LOADER_MACROS)})")
        seen.add(c.name)
    for f in FXS:
        if not f.name.startswith("FX_"):
            problems.append(f"capabilities.py: {f.name} は FX_ で始める")
        for ident in IDENT_RE.findall(f.condition):
            if ident == "defined" or ident in seen or ident in settings:
                continue
            problems.append(f"capabilities.py: {f.name} の条件の {ident} が設定にも、先に書いた CAP_* / FX_* にもない")
        for key in f.properties:
            if not key.isascii():
                problems.append(f"capabilities.py: {f.name} の properties の項目 {key} が ASCII でない")
        seen.add(f.name)
    if len(seen) != len(CAPS) + len(FXS):
        problems.append("capabilities.py: 名前が重複している")
    return problems


def condition_of(name: str) -> str:
    for c in CAPS:
        if c.name == name:
            return c.detect
    for f in FXS:
        if f.name == name:
            return f.condition
    raise KeyError(name)


def properties_expr(name: str) -> str:
    """
    ### properties_expr
    CAP_* / FX_* の条件を、設定とローダーのマクロだけの式に展開する (shaders.properties の #if に書く)

    @param name - CAP_* か FX_* の名前
    @returns 展開した #if の式
    """
    known = names()

    def expand(m: re.Match[str]) -> str:
        ident = m.group(1)
        return f"({properties_expr(ident)})" if ident in known else m.group(0)

    return DEFINED_RE.sub(expand, condition_of(name))


def setting_files(shaders: Path) -> list[str]:
    """FX_* の条件が使う設定の定義元 (lib/settings/ のファイル)"""
    settings = gen_settings.parse_settings(shaders)
    files = {settings[i].file for f in FXS for i in IDENT_RE.findall(f.condition) if i in settings}
    order = [p.relative_to(shaders).as_posix() for p in gen_settings.settings_files(shaders)]
    return sorted(files, key=order.index)


def render_glsl(shaders: Path = SHADERS) -> str:
    out = [GLSL_HEADER, "#ifndef SETTINGS_CAPABILITIES_GLSL", "#define SETTINGS_CAPABILITIES_GLSL", ""]
    out += [f'//@include "/{rel}"' for rel in setting_files(shaders)]
    for c in CAPS:
        out += ["", f"// {c.meaning}。無い環境: {c.missing}", f"#if {c.detect}", f"#define {c.name} 1", "#endif"]
    for f in FXS:
        out += ["", f"// {f.meaning}", f"#if {f.condition}", f"#define {f.name} 1", "#endif"]
    out += ["", "#endif // SETTINGS_CAPABILITIES_GLSL", ""]
    return "\n".join(out)


def render_properties() -> str:
    groups = []
    for f in FXS:
        if not f.properties:
            continue
        lines = [f"# {f.name}", f"#if {properties_expr(f.name)}"]
        lines += [f"{k} = true" for k in f.properties] + ["#else"] + [f"{k} = false" for k in f.properties] + ["#endif"]
        groups.append("\n".join(lines))
    text = "\n".join(groups)
    if not text.isascii():
        raise ValueError("capabilities.py: properties に出す式に ASCII 以外の文字がある")
    return text


def generate(shaders: Path = SHADERS) -> dict[Path, str]:
    problems = table_problems(shaders)
    if problems:
        raise ValueError("\n".join(problems))
    props = shaders / PROPERTIES
    text = generated.replace_block(props.read_bytes().decode("utf-8"), PROPS_BEGIN, PROPS_END, render_properties(), PROPERTIES)
    return {shaders / CAPABILITIES: render_glsl(shaders), props: text.replace("\r\n", "\n")}


def check(shaders: Path = SHADERS) -> list[str]:
    return generated.check(generate, shaders, "gen_capabilities.py")


def main() -> int:
    return generated.cli(generate, "gen_capabilities.py")


if __name__ == "__main__":
    sys.exit(main())
