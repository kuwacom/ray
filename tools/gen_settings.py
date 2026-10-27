"""
設定の解析と生成物の管理

設定の正本は shaders/lib/settings.glsl が include する lib/settings/*.glsl の #define / const の行そのもの
Iris はこの行を直接読むので、手で書く部分と生成する部分を分けている
- lib/settings/bool_refs.glsl: 全ブールの空の #ifdef (Iris は #ifdef / #ifndef で参照されないブールを設定として認識しない)

使い方:
    uv run tools/gen_settings.py                    # 生成物を書く
    uv run tools/gen_settings.py --check            # 生成物が最新か確認する (ずれていれば終了コード 1)
    uv run tools/gen_settings.py --shaders <dir>    # 別のフォルダのシェーダーを対象にする
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"

DEFINE_RE = re.compile(r"^(\s*)(//\s*)?#define\s+([A-Za-z_]\w*)(?:\s+([^\s/]+))?\s*(//.*)?$")
CONST_RE = re.compile(r"^(\s*)const\s+(int|float|bool)\s+(\w+)\s*=\s*([^;]+);\s*(//.*)?$")
SETTINGS_INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"(/lib/settings/[^"]+)"')

BOOL_REFS = "lib/settings/bool_refs.glsl"

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


def settings_files(shaders: Path = SHADERS) -> list[Path]:
    """入口の settings.glsl と、そこから include する lib/settings/ の定義ファイルを読む順に返す (生成物の bool_refs は含めない)"""
    entry = shaders / "lib" / "settings.glsl"
    files = [entry]
    for line in entry.read_text(encoding="utf-8").splitlines():
        m = SETTINGS_INCLUDE_RE.match(line)
        if m and m.group(1).lstrip("/") != BOOL_REFS:
            files.append(shaders / m.group(1).lstrip("/"))
    return files


def parse_settings(shaders: Path = SHADERS) -> dict[str, Option]:
    """設定項目を拾う (値リスト付きの数値 define, ブール define, 値リスト付き const)"""
    opts: dict[str, Option] = {}
    for path in settings_files(shaders):
        rel = path.relative_to(shaders).as_posix()
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = DEFINE_RE.match(line)
            if m:
                commented, name, value, comment = m.group(2), m.group(3), m.group(4), m.group(5) or ""
                if value is None:
                    # 値なし define がブール設定 (インクルードガードは除く)
                    if name not in opts and not name.endswith("_GLSL"):
                        opts[name] = Option(name, "bool", commented is None, [], rel, i)
                elif commented is None and comment.startswith("//") and "[" in comment:
                    vals = re.search(r"\[([^\]]*)\]", comment)
                    opts[name] = Option(name, "value", value, vals.group(1).split() if vals else [], rel, i)
                continue
            m = CONST_RE.match(line)
            if m and m.group(5) and "[" in m.group(5):
                vals = re.search(r"\[([^\]]*)\]", m.group(5))
                opts[m.group(3)] = Option(m.group(3), "const", m.group(4).strip(), vals.group(1).split() if vals else [], rel, i)
    return opts


def render_bool_refs(opts: dict[str, Option], shaders: Path = SHADERS) -> str:
    order = [p.relative_to(shaders).as_posix() for p in settings_files(shaders)]
    bools = sorted((o for o in opts.values() if o.kind == "bool"), key=lambda o: (order.index(o.file), o.line))
    out = [BOOL_REFS_HEADER.rstrip("\n"), "#ifndef SETTINGS_BOOL_REFS_GLSL", "#define SETTINGS_BOOL_REFS_GLSL", ""]
    for rel in order[1:]:
        if any(o.file == rel for o in bools):
            out.append(f'#include "/{rel}"')
    out.append("")
    for o in bools:
        out += [f"#ifdef {o.name}", "#endif"]
    out += ["", "#endif // SETTINGS_BOOL_REFS_GLSL", ""]
    return "\n".join(out)


def generated(shaders: Path = SHADERS) -> dict[Path, str]:
    """生成物のパスと、あるべき内容"""
    opts = parse_settings(shaders)
    return {shaders / BOOL_REFS: render_bool_refs(opts, shaders)}


def check(shaders: Path = SHADERS) -> list[str]:
    problems = []
    for path, text in generated(shaders).items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != text:
            problems.append(f"生成物が古い: {path.relative_to(shaders).as_posix()} (uv run tools/gen_settings.py で再生成する)")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="書かずに、生成物が最新か確認する")
    ap.add_argument("--shaders", type=Path, default=SHADERS, help="対象のシェーダーのフォルダ")
    args = ap.parse_args()
    shaders = args.shaders.resolve()
    if args.check:
        problems = check(shaders)
        for p in problems:
            print(p)
        return 1 if problems else 0
    for path, text in generated(shaders).items():
        if not path.exists() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8", newline="\n")
            print(f"書き込み: {path.relative_to(shaders).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
