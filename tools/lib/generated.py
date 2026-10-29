"""生成物 (gen_*.py が書くファイル) の書き込みと、最新かどうかの確認

生成スクリプトは「パス -> あるべき内容 (改行は LF)」の表を返す関数だけを書き、--check と書き込みはここに任せる
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Callable

from lib.paths import SHADERS

Generate = Callable[[Path], dict[Path, str]]


def read_normalized(path: Path) -> str | None:
    """改行を LF にそろえて読む。無ければ None"""
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n") if path.exists() else None


def replace_block(text: str, begin: str, end: str, block: str, where: str) -> str:
    """マーカーの間だけを差し替える。改行は元のファイルに合わせる。マーカーが 1 組でなければ例外"""
    if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
        raise ValueError(f"{where}: {begin} と {end} が 1 組だけ必要")
    nl = "\r\n" if "\r\n" in text else "\n"
    head, rest = text.split(begin)
    tail = rest.split(end)[1]
    return head + begin + nl + block.replace("\n", nl) + nl + end + tail


def check(generate: Generate, shaders: Path, script: str, what: str = "生成物が古い") -> list[str]:
    """あるべき内容と違うファイルを、再生成のコマンド付きで返す"""
    try:
        expected = generate(shaders)
    except ValueError as e:
        return [str(e)]
    return [f"{what}: {path.relative_to(shaders.parent).as_posix()} (uv run tools/{script} で再生成する)"
            for path, text in expected.items() if read_normalized(path) != text]


def write(expected: dict[Path, str], shaders: Path) -> None:
    """内容が違うファイルだけ書く。改行は既存のファイルに合わせる"""
    for path, text in expected.items():
        if read_normalized(path) != text:
            nl = "\r\n" if path.exists() and b"\r\n" in path.read_bytes() else "\n"
            path.write_bytes(text.replace("\n", nl).encode("utf-8"))
            print(f"書き込み: {path.relative_to(shaders.parent).as_posix()}")


def cli(generate: Generate, script: str, what: str = "生成物が古い") -> int:
    """--check (書かずに確認、ずれていれば終了コード 1) と --shaders を持つ gen_*.py の main"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="書かずに、生成物が最新か確認する")
    ap.add_argument("--shaders", type=Path, default=SHADERS, help="対象のシェーダーのフォルダ")
    args = ap.parse_args()
    shaders = args.shaders.resolve()
    if args.check:
        problems = check(generate, shaders, script, what)
        for p in problems:
            print(p)
        return 1 if problems else 0
    try:
        expected = generate(shaders)
    except ValueError as e:
        print(e)
        return 1
    write(expected, shaders)
    return 0
