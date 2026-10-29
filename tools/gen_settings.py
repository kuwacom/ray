"""
設定の解析と生成物の管理

設定の正本は shaders/lib/settings.glsl が宣言する lib/settings/*.glsl の #define / const の行そのもの
Iris はこの行を直接読むので、手で書く部分と生成する部分を分けている
- lib/settings/bool_refs.glsl: 全ブールの空の #ifdef (Iris は #ifdef / #ifndef で参照されないブールを設定として認識しない)
- shaders.properties の sliders: BEGIN / END GENERATED sliders の間 (スライダーにする設定の一覧)

使い方:
    uv run tools/gen_settings.py                    # 生成物を書く
    uv run tools/gen_settings.py --check            # 生成物が最新か確認する (ずれていれば終了コード 1)
    uv run tools/gen_settings.py --shaders <dir>    # 別のフォルダのシェーダーを対象にする
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from lib.generated import check as generated_check
from lib.generated import cli, replace_block
from lib.paths import SHADERS
from lib.properties import PROPERTIES, parse_profiles, resolve_profile

DEFINE_RE = re.compile(r"^(\s*)(//\s*)?#define\s+([A-Za-z_]\w*)(?:\s+([^\s/]+))?\s*(//.*)?$")
CONST_RE = re.compile(r"^(\s*)const\s+(int|float|bool)\s+(\w+)\s*=\s*([^;]+);\s*(//.*)?$")
SETTINGS_INCLUDE_RE = re.compile(r'^\s*//@include\s+"(/lib/settings/[^"]+)"')

BOOL_REFS = "lib/settings/bool_refs.glsl"
SLIDERS_BEGIN = "# BEGIN GENERATED sliders (tools/gen_settings.py)"
SLIDERS_END = "# END GENERATED sliders"
ARCHITECTURE = "architecture.md"
SETTINGS_DOC = "settings.md"
TABLES_BEGIN = "<!-- BEGIN GENERATED settings (tools/gen_settings.py) -->"
TABLES_END = "<!-- END GENERATED settings -->"

NUMBER_RE = re.compile(r"-?\d+(\.\d+)?")
# 値がすべて数値で 4 個以上ならスライダーにする。名前の付いたモード・プリセットはドロップダウンのままにする
NOT_SLIDER = {
    "CLOUDS", "CLOUD_HEIGHT_PRESET", "CLOUD_REGION_PRESET", "CLOUD_STYLE", "DOF_APERTURE_BLADES", "DOF_SENSOR",
    "FOG_HEIGHT_PRESET", "FOG_STYLE", "GI_MODE", "LENS_C_DESIGN", "LENS_PRESET", "LENS_QUALITY",
    "LIGHT_ENTITY_TRIANGLES", "LOOK_LUT", "LOOK_PRESET", "REFLECTIONS", "TONEMAP",
}
# 値は 3 個でも段階の大きさで選ぶ設定
FORCE_SLIDER = {"LIGHT_TRACE_RES"}

BOOL_REFS_HEADER = """\
/*
  Iris にブール設定として認識させるための参照
  (Iris は #ifdef / #ifndef で一度も参照されない define をブール設定として扱わないため)
*/
"""


@dataclass
class Option:
    name: str
    kind: str  # "bool" | "value" | "const"
    default: str | bool
    values: list[str] = field(default_factory=list)
    file: str = ""  # shaders からの相対パス
    line: int = 0
    raw: str = ""  # 値リストの [] の中身そのまま


def settings_files(shaders: Path = SHADERS) -> list[Path]:
    """入口の settings.glsl と、そこで宣言する lib/settings/ の定義ファイルを読む順に返す (生成物の bool_refs は含めない)"""
    entry = shaders / "lib" / "settings.glsl"
    files = [entry]
    for line in entry.read_text(encoding="utf-8").splitlines():
        m = SETTINGS_INCLUDE_RE.match(line)
        if m and m.group(1).lstrip("/") != BOOL_REFS:
            files.append(shaders / m.group(1).lstrip("/"))
    return files


def definitions(shaders: Path = SHADERS) -> list[Option]:
    """設定の定義を、重複も含めて読む順にすべて返す (値リスト付きの数値 define, ブール define, 値リスト付き const)"""
    found: list[Option] = []
    for path in settings_files(shaders):
        rel = path.relative_to(shaders).as_posix()
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = DEFINE_RE.match(line)
            if m:
                commented, name, value, comment = m.group(2), m.group(3), m.group(4), m.group(5) or ""
                if value is None:
                    # 値なし define がブール設定 (インクルードガードは除く)
                    if not name.endswith("_GLSL"):
                        found.append(Option(name, "bool", commented is None, [], rel, i))
                elif commented is None and comment.startswith("//") and "[" in comment:
                    vals = re.search(r"\[([^\]]*)\]", comment)
                    raw = vals.group(1) if vals else ""
                    found.append(Option(name, "value", value, raw.split(), rel, i, raw))
                continue
            m = CONST_RE.match(line)
            if m and m.group(5) and "[" in m.group(5):
                vals = re.search(r"\[([^\]]*)\]", m.group(5))
                raw = vals.group(1) if vals else ""
                found.append(Option(m.group(3), "const", m.group(4).strip(), raw.split(), rel, i, raw))
    return found


def parse_settings(shaders: Path = SHADERS) -> dict[str, Option]:
    """設定項目を名前で引く。ブールは最初の定義、値付きは最後の定義を採る"""
    opts: dict[str, Option] = {}
    for o in definitions(shaders):
        if o.kind != "bool" or o.name not in opts:
            opts[o.name] = o
    return opts


def definition_problems(shaders: Path = SHADERS) -> list[str]:
    """Iris が設定ごと捨てる、または画面の並びが崩れる定義を返す"""
    problems = []
    seen: dict[str, Option] = {}
    for o in definitions(shaders):
        where = f"{o.file}:{o.line}"
        if o.name in seen:
            problems.append(f"{where}: 設定 {o.name} が重複している ({seen[o.name].file}:{seen[o.name].line}。Iris は既定値が違うと設定ごと捨てる)")
        seen.setdefault(o.name, o)
        if o.kind == "bool":
            continue
        # Iris は値リストを split(" ") で分けるので、空白が 2 つ続くと空の値になる
        if "" in o.raw.rstrip(" ").split(" ") and o.raw.strip():
            problems.append(f"{where}: {o.name} の値リストに空の要素がある (空白が連続している)")
        if o.values and o.default not in o.values:
            problems.append(f"{where}: {o.name} の既定値 {o.default} が値リストにない (Iris が末尾に足して画面の並びが崩れる)")
    return problems


def is_slider(o: Option) -> bool:
    if o.kind == "bool":
        return False
    if o.name in FORCE_SLIDER:
        return True
    return o.name not in NOT_SLIDER and len(o.values) >= 4 and all(NUMBER_RE.fullmatch(v) for v in o.values)


def render_bool_refs(opts: dict[str, Option], shaders: Path = SHADERS) -> str:
    order = [p.relative_to(shaders).as_posix() for p in settings_files(shaders)]
    bools = sorted((o for o in opts.values() if o.kind == "bool"), key=lambda o: (order.index(o.file), o.line))
    out = [BOOL_REFS_HEADER.rstrip("\n"), "#ifndef SETTINGS_BOOL_REFS_GLSL", "#define SETTINGS_BOOL_REFS_GLSL", ""]
    for rel in order[1:]:
        if any(o.file == rel for o in bools):
            out.append(f'//@include "/{rel}"')
    out.append("")
    for o in bools:
        out += [f"#ifdef {o.name}", "#endif"]
    out += ["", "#endif // SETTINGS_BOOL_REFS_GLSL", ""]
    return "\n".join(out)


def render_sliders(opts: dict[str, Option], shaders: Path = SHADERS) -> str:
    """設定ファイル 1 つにつき 1 行の sliders 定義 (行末は継続の ` \\`)"""
    rows = []
    for path in settings_files(shaders):
        rel = path.relative_to(shaders).as_posix()
        names = [o.name for o in opts.values() if o.file == rel and is_slider(o)]
        if names:
            rows.append(" ".join(names))
    lines = [("sliders = " if i == 0 else "    ") + row + (" \\" if i < len(rows) - 1 else "") for i, row in enumerate(rows)]
    return "\n".join(lines)


def resolved_profiles(shaders: Path) -> dict[str, dict[str, str | bool]]:
    profiles = parse_profiles(shaders)
    return {name: resolve_profile(name, profiles) for name in profiles}


def shown(o: Option, v: str | bool) -> str:
    return ("ON" if v else "OFF") if o.kind == "bool" else str(v)


def file_title(rel: str) -> str:
    stem = Path(rel).stem
    return f"{'version' if stem == 'settings' else stem} (`{rel}`)"


def render_profile_tables(opts: dict[str, Option], shaders: Path = SHADERS) -> str:
    """プロファイルのどれかが値を決めている設定を、設定ファイルごとの表にする (太字は既定値と違う値)"""
    resolved = resolved_profiles(shaders)
    decided = {k for r in resolved.values() for k in r}
    out = []
    for path in settings_files(shaders):
        rel = path.relative_to(shaders).as_posix()
        rows = sorted((o for o in opts.values() if o.file == rel and o.name in decided), key=lambda o: o.line)
        if not rows:
            continue
        out += [f"#### {file_title(rel)}", "", "| 設定 | 既定 | " + " | ".join(resolved) + " |", "|---|---|" + "---|" * len(resolved)]
        for o in rows:
            default = shown(o, o.default)
            cells = []
            for r in resolved.values():
                s = shown(o, r.get(o.name, o.default))
                cells.append(s if s == default else f"**{s}**")
            out.append(f"| {o.name} | {default} | " + " | ".join(cells) + " |")
        out.append("")
    return "\n".join(out[:-1])


SETTINGS_DOC_HEAD = """\
# 設定の一覧

全設定の既定値と値の候補です。既定値は「高」(HIGH) プロファイルと同じです。プロファイルごとの値は [architecture.md](architecture.md) の「設定とプリセット」、設定の説明は設定画面にあります

このファイルは `tools/gen_settings.py` が `shaders/lib/settings/` から生成します
"""


def render_settings_doc(opts: dict[str, Option], shaders: Path = SHADERS) -> str:
    out = [SETTINGS_DOC_HEAD]
    for path in settings_files(shaders):
        rel = path.relative_to(shaders).as_posix()
        rows = sorted((o for o in opts.values() if o.file == rel), key=lambda o: o.line)
        if not rows:
            continue
        out += [f"## {file_title(rel)}", "", "| 設定 | 既定 | 値の候補 |", "|---|---|---|"]
        for o in rows:
            choices = "ON / OFF" if o.kind == "bool" else ", ".join(o.values) or "-"
            out.append(f"| {o.name} | {shown(o, o.default)} | {choices} |")
        out.append("")
    return "\n".join(out)


def generated(shaders: Path = SHADERS) -> dict[Path, str]:
    """生成物のパスと、あるべき内容 (改行は LF に正規化したもの)。docs が無いフォルダ (shaders だけの展開) では文書を含めない"""
    opts = parse_settings(shaders)
    props = shaders / PROPERTIES
    out = {
        shaders / BOOL_REFS: render_bool_refs(opts, shaders),
        props: replace_block(props.read_bytes().decode("utf-8"), SLIDERS_BEGIN, SLIDERS_END, render_sliders(opts, shaders), PROPERTIES).replace("\r\n", "\n"),
    }
    docs = shaders.parent / "docs"
    if docs.is_dir():
        arch = docs / ARCHITECTURE
        out[arch] = replace_block(arch.read_bytes().decode("utf-8"), TABLES_BEGIN, TABLES_END, render_profile_tables(opts, shaders), f"docs/{ARCHITECTURE}").replace("\r\n", "\n")
        out[docs / SETTINGS_DOC] = render_settings_doc(opts, shaders)
    return out


def check(shaders: Path = SHADERS) -> list[str]:
    return generated_check(generated, shaders, "gen_settings.py")


def main() -> int:
    return cli(generated, "gen_settings.py")


if __name__ == "__main__":
    sys.exit(main())
