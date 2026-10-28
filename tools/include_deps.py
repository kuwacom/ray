"""
shaders/ の //@include の宣言の漏れを調べる (読む順番に頼った暗黙の依存の検出)

lib/ と program/ の各ファイルが使う記号 (関数・const・struct・uniform・SSBO・マクロ) を、定義しているファイルへ対応づける
使っている記号の定義元が、そのファイルの //@include の宣言を辿った先 (自分自身を含む) に無ければ「暗黙の依存」
記号の照合は名前の一致なので、局所変数が同名のときなどに誤検出が混ざる。誤検出は余分な宣言になるだけで害はない
あわせて宣言の循環と、lib のガード名 (パスから決める: lib/sky/fog.glsl -> SKY_FOG_GLSL) も調べる

宣言の書き方の検査 (Iris は #include の行を、コメントや #if の中でもガードを見ずに毎回差し込むため)
- lib に #include の行がない (コメントの中も数える)。lib 同士の依存は //@include で宣言する
- 本体の #include が生成ブロックの中にだけある。#include の行末にコメントがない (Iris は名前の一部として読む)
- /* */ の中に //@include がない。宣言のパスが存在する
- lib の宣言がガードの直後にまとまっている (生成は依存を先に並べるので、宣言より前の本文は依存より後ろに来てしまう)
本体の生成ブロックが最新かは gen_includes.py が調べる

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_includes  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
EXTS = {".glsl", ".vsh", ".fsh", ".csh", ".gsh"}

INCLUDE_LINE_RE = re.compile(r'^[ \t]*#[ \t]*include\b')
INCLUDE_TRAILING_RE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+"[^"]*"[ \t]*\S')
FUNC_RE = re.compile(r"^[ \t]*(?:const[ \t]+)?([A-Za-z_]\w*)[ \t]+([A-Za-z_]\w*)[ \t]*\(([^;{)]*)\)[ \t]*\{", re.M)
CONST_RE = re.compile(r"^const[ \t]+\w+[ \t]+([A-Za-z_]\w*)[ \t]*(?:\[[^\]]*\][ \t]*)?=", re.M)
STRUCT_RE = re.compile(r"^struct[ \t]+(\w+)", re.M)
UNIFORM_RE = re.compile(r"^(?:layout\([^)]*\)[ \t]*)?uniform[ \t]+\w+[ \t]+(\w+)[ \t]*(?:\[[^\]]*\])?;", re.M)
BUFFER_RE = re.compile(r"^layout\([^)]*\)[ \t]*(?:\w+[ \t]+)*buffer[ \t]+\w+[ \t]*\{.*?^\}[ \t]*(\w+)[ \t]*;", re.M | re.S)
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
        # 宣言 (//@include) はコメントなので、記号の照合用 (files) とは別に原文を持つ
        self.raw = {
            p.relative_to(shaders).as_posix(): p.read_text(encoding="utf-8")
            for p in shaders.rglob("*")
            if p.suffix in EXTS and p.relative_to(shaders).parts[0] in ("lib", "program")
        }
        self.files = {rel: strip_comments(text) for rel, text in self.raw.items()}
        self.decls = {
            rel: [m.group(2) for ln in gen_includes.mask_block_comments(text).split("\n") if (m := gen_includes.DECL_RE.match(ln))]
            for rel, text in self.raw.items()
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
        return self.decls.get(rel, [])

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
        """使っているのに宣言から辿れない記号。{定義元のファイル: [記号...]}。前方宣言した関数は定義元を読まなくてよい"""
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

    def declaration_problems(self) -> list[str]:
        """#include と //@include の書き方の検査 (Iris が #include をコメントの中でも展開することに由来する)"""
        out = []
        for rel in sorted(self.raw):
            is_lib = rel.startswith("lib/")
            lines = self.raw[rel].split("\n")
            masked = gen_includes.mask_block_comments(self.raw[rel]).split("\n")
            generated = False
            for n, ln in enumerate(lines, 1):
                where = f"{rel}:{n}"
                if ln.strip() == gen_includes.BEGIN:
                    generated = True
                elif ln.strip() == gen_includes.END:
                    generated = False
                elif INCLUDE_LINE_RE.match(ln):
                    if is_lib:
                        out.append(f"{where}: lib に #include がある (コメントの中でも Iris は展開する。//@include で宣言する)")
                    elif not generated:
                        out.append(f"{where}: 生成ブロックの外に #include がある (uv run tools/gen_includes.py で生成する)")
                    if INCLUDE_TRAILING_RE.match(ln):
                        out.append(f"{where}: #include の行末にコメントがある (Iris は名前の一部として読む)")
                if gen_includes.DECL_RE.match(ln) and not gen_includes.DECL_RE.match(masked[n - 1]):
                    out.append(f"{where}: /* */ の中に //@include がある")
            for target in self.decls[rel]:
                if target not in self.raw or not target.startswith("lib/"):
                    out.append(f"{rel}: 宣言のパスが存在しない: /{target}")
            if is_lib:
                out += self._placement_problems(rel, masked)
        return out

    @staticmethod
    def _placement_problems(rel: str, masked: list[str]) -> list[str]:
        """lib の宣言がガードの直後 (空行とコメントを除く) にまとまっているか"""
        out = []
        state = 0  # 0: ガード前、1: #ifndef の後、2: #define の後 (宣言を置ける)、3: 本文に入った
        for n, ln in enumerate(masked, 1):
            if gen_includes.DECL_RE.match(ln):
                if state < 2:
                    break
                if state == 3:
                    out.append(f"{rel}:{n}: 宣言が本文の後にある (宣言はガードの直後にまとめる)")
                continue
            if gen_includes.is_filler(ln):
                continue
            if state == 0 and re.match(r"[ \t]*#[ \t]*ifndef\b", ln):
                state = 1
            elif state == 1 and re.match(r"[ \t]*#[ \t]*define\b", ln):
                state = 2
            elif state < 2:
                break
            else:
                state = 3
        return out

    def problems(self) -> list[str]:
        out = self.guard_problems() + self.declaration_problems()
        for rel in sorted(self.files):
            for owner, syms in self.missing(rel).items():
                out.append(f"{rel}: {owner} を //@include で宣言していない ({', '.join(syms[:4])}{' ...' if len(syms) > 4 else ''})")
        for cyc in self.cycles():
            out.append("宣言の循環: " + " -> ".join(cyc))
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
    print(f"ガード名の不一致 {len(tree.guard_problems())}、宣言の書き方の問題 {len(tree.declaration_problems())}、循環 {len(tree.cycles())}")
    if args.verbose:
        for f, d in miss.items():
            for owner, syms in d.items():
                print(f"  {f} -> {owner}: {', '.join(syms[:5])}")
        for k, n in sorted(cross.items(), key=lambda x: -x[1]):
            print(f"  module {k[0]} -> {k[1]}: {n}")
    return 1 if tree.problems() else 0


if __name__ == "__main__":
    sys.exit(main())
