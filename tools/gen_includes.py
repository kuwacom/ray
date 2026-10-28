"""
本体 (program/) の #include を、本体と lib の //@include の宣言から生成する

Iris は #include の行を、#if の中でも include ガードを見ずに毎回差し込む。lib 同士が #include すると同じ lib が何度も
展開されて本文が数十倍に膨らみ、再読み込みが遅くなる。そこで lib は依存を `//@include "/lib/..."` の宣言で書き (Iris は
コメントとして読み飛ばす)、本体の #include はこのスクリプトが宣言の閉包を依存が先の順に 1 回ずつ並べて生成する

- lib/**/*.glsl: `//@include` の宣言を書いた順に読む。#include は書かない
- program/**: 最初の宣言から最後の宣言まで (その間で開いた #if を閉じる #endif まで) が宣言の範囲。範囲の直後の
  `// BEGIN GENERATED includes` .. `// END GENERATED includes` の間を生成する。範囲に置けるのは宣言・空行・コメント・#if 系だけ
- 並べ方: 宣言の順に、各ファイルの依存を先に (深さ優先の帰りがけ順)。#if の中で並べたものは、その #if の中でだけ並べ済みとする
  (#else / #elif で空に戻る)。宣言を囲む #if 系の行と字下げは生成にも写す

使い方:
    uv run tools/gen_includes.py                    # 生成ブロックを書く
    uv run tools/gen_includes.py --check            # 生成ブロックが最新か確認する (ずれていれば終了コード 1)
    uv run tools/gen_includes.py --shaders <dir>    # 別のフォルダのシェーダーを対象にする
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
EXTS = {".glsl", ".vsh", ".fsh", ".csh", ".gsh"}

BEGIN = "// BEGIN GENERATED includes (tools/gen_includes.py)"
END = "// END GENERATED includes"

DECL_RE = re.compile(r'^([ \t]*)//@include[ \t]+"/([^"]+)"[ \t]*$')
OPEN_RE = re.compile(r"^[ \t]*#[ \t]*(if|ifdef|ifndef)\b")
ELSE_RE = re.compile(r"^[ \t]*#[ \t]*(else|elif)\b")
CLOSE_RE = re.compile(r"^[ \t]*#[ \t]*endif\b")
COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)


def mask_block_comments(text: str) -> str:
    """/* */ の中を空白にする (行数は保つ)。// の行コメントはそのまま残すので、行コメントの中の /* では始まらない"""
    return COMMENT_RE.sub(lambda m: m.group(0) if m.group(0).startswith("//") else re.sub(r"[^\n]", " ", m.group(0)), text)


def read_lines(path: Path) -> list[str]:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n").split("\n")


def is_filler(masked: str) -> bool:
    """宣言の間に置いてよい行 (空行・コメント)"""
    s = masked.strip()
    return not s or s.startswith("//")


class Includes:
    def __init__(self, shaders: Path = SHADERS):
        self.shaders = shaders
        self.deps: dict[str, list[str]] = {}
        for p in sorted((shaders / "lib").rglob("*.glsl")):
            rel = p.relative_to(shaders).as_posix()
            self.deps[rel] = self._lib_deps(rel, read_lines(p))

    def _lib_deps(self, rel: str, lines: list[str]) -> list[str]:
        out: list[str] = []
        depth = 0
        for i, ln in enumerate(mask_block_comments("\n".join(lines)).split("\n"), 1):
            if OPEN_RE.match(ln):
                depth += 1
            elif CLOSE_RE.match(ln):
                depth -= 1
            m = DECL_RE.match(ln)
            if m:
                # 深さ 1 は include ガード
                if depth > 1:
                    raise ValueError(f"{rel}:{i}: lib の宣言が #if の中にある (条件付きの依存は本体に書く)")
                out.append(self._target(rel, i, m.group(2)))
        return out

    def _target(self, rel: str, line: int, target: str) -> str:
        if not target.startswith("lib/") or not (self.shaders / target).is_file():
            raise ValueError(f"{rel}:{line}: 宣言のパスが lib にない: /{target}")
        return target

    def order(self, root: str, scopes: list[set[str]], out: list[str], stack: tuple[str, ...] = ()) -> None:
        """root とその依存を帰りがけ順に out へ。scopes は外側から順の、並べ済みの集合 (先頭が条件なし)"""
        if any(root in s for s in scopes):
            return
        if root in stack:
            raise ValueError("宣言の循環: " + " -> ".join(stack + (root,)))
        for d in self.deps.get(root, []):
            self.order(d, scopes, out, stack + (root,))
        scopes[-1].add(root)
        out.append(root)

    def render(self, rel: str, lines: list[str]) -> list[str]:
        """本体の行に生成ブロックを入れた行を返す (宣言が無ければそのまま)"""
        if BEGIN in lines or END in lines:
            if lines.count(BEGIN) != 1 or lines.count(END) != 1 or lines.index(BEGIN) > lines.index(END):
                raise ValueError(f"{rel}: {BEGIN} と {END} が 1 組だけ必要")
            b, e = lines.index(BEGIN), lines.index(END)
            lines = lines[:b] + lines[e + 1:]
        masked = mask_block_comments("\n".join(lines)).split("\n")
        idx = [i for i, ln in enumerate(masked) if DECL_RE.match(ln)]
        if not idx:
            if any(ln.startswith("#include") for ln in lines):
                raise ValueError(f"{rel}: #include があるが //@include の宣言が無い")
            return lines
        first, last = idx[0], idx[-1]
        depth = 0
        for i in range(first, last + 1):
            if OPEN_RE.match(masked[i]):
                depth += 1
            elif CLOSE_RE.match(masked[i]):
                depth -= 1
        while depth > 0:
            last += 1
            if OPEN_RE.match(masked[last]):
                depth += 1
            elif CLOSE_RE.match(masked[last]):
                depth -= 1
        depth = 0
        for ln in masked[:first]:
            if OPEN_RE.match(ln):
                depth += 1
            elif CLOSE_RE.match(ln):
                depth -= 1
        if depth:
            raise ValueError(f"{rel}:{first + 1}: 宣言が本体の先頭から開いた #if の中にある")
        block = [BEGIN]
        scopes: list[set[str]] = [set()]
        for i in range(first, last + 1):
            m = DECL_RE.match(masked[i])
            if m:
                items: list[str] = []
                self.order(self._target(rel, i + 1, m.group(2)), scopes, items)
                block += [f'{m.group(1)}#include "/{x}"' for x in items]
            elif OPEN_RE.match(masked[i]):
                scopes.append(set())
                block.append(lines[i])
            elif ELSE_RE.match(masked[i]):
                scopes[-1] = set()
                block.append(lines[i])
            elif CLOSE_RE.match(masked[i]):
                scopes.pop()
                block.append(lines[i])
            elif not is_filler(masked[i]):
                raise ValueError(f"{rel}:{i + 1}: 宣言の範囲に本文がある: {lines[i].strip()}")
        block.append(END)
        return lines[:last + 1] + block + lines[last + 1:]


def generated(shaders: Path = SHADERS) -> dict[Path, str]:
    """生成ブロックを入れた本体のパスと、あるべき内容 (改行は LF に正規化したもの)"""
    inc = Includes(shaders)
    out: dict[Path, str] = {}
    for p in sorted((shaders / "program").rglob("*")):
        if p.suffix in EXTS:
            out[p] = "\n".join(inc.render(p.relative_to(shaders).as_posix(), read_lines(p)))
    return out


def check(shaders: Path = SHADERS) -> list[str]:
    try:
        expected = generated(shaders)
    except ValueError as e:
        return [str(e)]
    return [f"生成ブロックが古い: {p.relative_to(shaders.parent).as_posix()} (uv run tools/gen_includes.py で再生成する)"
            for p, text in expected.items() if "\n".join(read_lines(p)) != text]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="書かずに、生成ブロックが最新か確認する")
    ap.add_argument("--shaders", type=Path, default=SHADERS, help="対象のシェーダーのフォルダ")
    args = ap.parse_args()
    shaders = args.shaders.resolve()
    if args.check:
        problems = check(shaders)
        for p in problems:
            print(p)
        return 1 if problems else 0
    try:
        expected = generated(shaders)
    except ValueError as e:
        print(e)
        return 1
    for path, text in expected.items():
        if "\n".join(read_lines(path)) != text:
            nl = "\r\n" if b"\r\n" in path.read_bytes() else "\n"
            path.write_bytes(text.replace("\n", nl).encode("utf-8"))
            print(f"書き込み: {path.relative_to(shaders.parent).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
