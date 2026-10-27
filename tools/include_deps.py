"""
shaders/ の #include の漏れを調べる (読む順番に頼った暗黙の依存の検出)

lib/ と program/ の各ファイルが使う記号 (関数・const・struct・uniform・SSBO・マクロ) を、定義しているファイルへ対応づける
使っている記号の定義元が、そのファイルの #include を辿った先 (自分自身を含む) に無ければ「暗黙の依存」
記号の照合は名前の一致なので、局所変数が同名のときなどに誤検出が混ざる。誤検出は余分な include になるだけで害はない
あわせて include の循環と、lib のガード名 (パスから決める: lib/sky/fog.glsl -> SKY_FOG_GLSL) も調べる

使い方:
    uv run tools/include_deps.py            # 件数の一覧
    uv run tools/include_deps.py -v         # ファイルごとの不足
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
EXTS = {".glsl", ".vsh", ".fsh", ".csh", ".gsh"}

INCLUDE_RE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+"/([^"]+)"', re.M)
FUNC_RE = re.compile(r"^[ \t]*(?:const[ \t]+)?([A-Za-z_]\w*)[ \t]+([A-Za-z_]\w*)[ \t]*\(([^;{)]*)\)[ \t]*\{", re.M)
CONST_RE = re.compile(r"^const[ \t]+\w+[ \t]+([A-Za-z_]\w*)[ \t]*(?:\[[^\]]*\][ \t]*)?=", re.M)
STRUCT_RE = re.compile(r"^struct[ \t]+(\w+)", re.M)
UNIFORM_RE = re.compile(r"^(?:layout\([^)]*\)[ \t]*)?uniform[ \t]+\w+[ \t]+(\w+)[ \t]*(?:\[[^\]]*\])?;", re.M)
BUFFER_RE = re.compile(r"^layout\([^)]*\)[ \t]*buffer[ \t]+\w+[ \t]*\{.*?^\}[ \t]*(\w+)[ \t]*;", re.M | re.S)
PROTO_RE = re.compile(r"^(?:const[ \t]+)?[A-Za-z_]\w*[ \t]+([A-Za-z_]\w*)[ \t]*\([^;{)]*\)[ \t]*;", re.M)
DEFINE_RE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(\w+)", re.M)
IDENT_RE = re.compile(r"\b[A-Za-z_]\w*\b")
KEYWORDS = {"if", "for", "while", "switch", "return", "else", "do", "main"}


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def guard_name(rel: str) -> str:
    """lib/sky/fog.glsl -> SKY_FOG_GLSL。lib/settings.glsl -> SETTINGS_GLSL"""
    stem = rel[len("lib/"):].rsplit(".", 1)[0]
    return re.sub(r"[^A-Za-z0-9]", "_", stem).upper() + "_GLSL"


class Tree:
    def __init__(self, shaders: Path = SHADERS):
        self.shaders = shaders
        self.files = {
            p.relative_to(shaders).as_posix(): strip_comments(p.read_text(encoding="utf-8"))
            for p in shaders.rglob("*")
            if p.suffix in EXTS and p.relative_to(shaders).parts[0] in ("lib", "program")
        }
        self.owners = self._collect_owners()

    @staticmethod
    def definitions(text: str) -> set[str]:
        names: set[str] = set()
        for m in FUNC_RE.finditer(text):
            if m.group(1) not in KEYWORDS and m.group(2) not in KEYWORDS:
                names.add(m.group(2))
        for rx in (CONST_RE, STRUCT_RE, UNIFORM_RE, BUFFER_RE):
            names.update(m.group(1) for m in rx.finditer(text))
        names.update(m.group(1) for m in DEFINE_RE.finditer(text) if not m.group(1).endswith("_GLSL"))
        return names

    def _collect_owners(self) -> dict[str, set[str]]:
        owners: dict[str, set[str]] = defaultdict(set)
        for rel, text in self.files.items():
            if rel.startswith("lib/"):
                for name in self.definitions(text):
                    owners[name].add(rel)
        return owners

    def includes(self, rel: str) -> list[str]:
        return INCLUDE_RE.findall(self.files.get(rel, ""))

    def closure(self, rel: str) -> set[str]:
        seen: set[str] = set()
        stack = [rel]
        while stack:
            for inc in self.includes(stack.pop()):
                if inc not in seen:
                    seen.add(inc)
                    stack.append(inc)
        return seen

    def missing(self, rel: str) -> dict[str, list[str]]:
        """使っているのに include から辿れない記号。{定義元のファイル: [記号...]}。前方宣言した関数は定義元を読まなくてよい"""
        avail = self.closure(rel) | {rel}
        forward = {m.group(1) for m in PROTO_RE.finditer(self.files[rel])} | self.definitions(self.files[rel])
        out: dict[str, list[str]] = defaultdict(list)
        for tok in sorted(set(IDENT_RE.findall(self.files[rel]))):
            own = self.owners.get(tok)
            if not own or own & avail or tok in forward:
                continue
            out[sorted(own)[0]].append(tok)
        return out

    def cycles(self) -> list[list[str]]:
        found: list[list[str]] = []
        state: dict[str, int] = {}
        path: list[str] = []

        def visit(f: str) -> None:
            state[f] = 1
            path.append(f)
            for inc in self.includes(f):
                if state.get(inc) == 1:
                    found.append(path[path.index(inc):] + [inc])
                elif inc not in state and inc in self.files:
                    visit(inc)
            path.pop()
            state[f] = 2

        for f in sorted(self.files):
            if f not in state:
                visit(f)
        return found

    def guard_problems(self) -> list[str]:
        problems = []
        for rel, text in self.files.items():
            if not rel.startswith("lib/") or not text.strip():
                continue
            m = re.search(r"^[ \t]*#[ \t]*ifndef[ \t]+(\w+)[ \t]*\n[ \t]*#[ \t]*define[ \t]+(\w+)", text, re.M)
            want = guard_name(rel)
            if not m:
                problems.append(f"{rel}: include ガードがない (期待: {want})")
            elif m.group(1) != want or m.group(2) != want:
                problems.append(f"{rel}: ガード名が {m.group(1)} (期待: {want})")
        return problems

    def problems(self) -> list[str]:
        out = self.guard_problems()
        for rel in sorted(self.files):
            for owner, syms in self.missing(rel).items():
                out.append(f"{rel}: {owner} を include していない ({', '.join(syms[:4])}{' ...' if len(syms) > 4 else ''})")
        for cyc in self.cycles():
            out.append("include の循環: " + " -> ".join(cyc))
        return out


def module_of(rel: str) -> str:
    parts = rel.split("/")
    return parts[1] if parts[0] == "lib" and len(parts) > 2 else parts[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--shaders", type=Path, default=SHADERS)
    args = ap.parse_args()
    tree = Tree(args.shaders)
    lib = [f for f in tree.files if f.startswith("lib/")]
    miss = {f: tree.missing(f) for f in sorted(tree.files)}
    lib_edges = sum(len(miss[f]) for f in lib)
    prog_edges = sum(len(miss[f]) for f in miss if f not in lib)
    cross = defaultdict(int)
    for f in lib:
        for owner in miss[f]:
            if module_of(f) != module_of(owner):
                cross[(module_of(f), module_of(owner))] += 1
    print(f"lib {len(lib)} files: 暗黙の依存 {lib_edges} 件 ({sum(1 for f in lib if miss[f])} ファイル)")
    print(f"program {len(tree.files) - len(lib)} files: 暗黙の依存 {prog_edges} 件")
    print(f"ガード名の不一致 {len(tree.guard_problems())}、循環 {len(tree.cycles())}")
    if args.verbose:
        for f, d in miss.items():
            for owner, syms in d.items():
                print(f"  {f} -> {owner}: {', '.join(syms[:5])}")
        for k, n in sorted(cross.items(), key=lambda x: -x[1]):
            print(f"  module {k[0]} -> {k[1]}: {n}")
    return 1 if tree.problems() else 0


if __name__ == "__main__":
    sys.exit(main())
