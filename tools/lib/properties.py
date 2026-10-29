"""shaders.properties の読み取り (プロファイルと、Iris と同じ #if の評価)"""

from __future__ import annotations

import re
from pathlib import Path

PROPERTIES = "shaders.properties"
PROP_IF_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b\s*(.*)$")


def read_properties_logical_lines(path: Path) -> list[str]:
    """`\\` の行継続を結合した論理行のリスト"""
    lines: list[str] = []
    buf = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.rstrip()
        if s.endswith("\\"):
            buf += s[:-1] + " "
            continue
        lines.append(buf + s)
        buf = ""
    if buf:
        lines.append(buf)
    return lines


def parse_profiles(shaders: Path) -> dict[str, list[str]]:
    """shaders.properties の profile.* を宣言順に返す"""
    profiles: dict[str, list[str]] = {}
    path = shaders / PROPERTIES
    if not path.exists():
        return profiles
    for line in read_properties_logical_lines(path):
        m = re.match(r"^\s*profile\.(\w+)\s*=\s*(.*)$", line)
        if m:
            profiles[m.group(1)] = m.group(2).split()
    return profiles


def resolve_profile(name: str, profiles: dict[str, list[str]], seen: set[str] | None = None) -> dict[str, str | bool]:
    seen = seen or set()
    if name in seen:
        raise ValueError(f"profile cycle: {name}")
    seen.add(name)
    result: dict[str, str | bool] = {}
    for tok in profiles[name]:
        if tok.startswith("profile."):
            result.update(resolve_profile(tok[len("profile."):], profiles, seen))
        elif tok.startswith("!program."):
            continue
        elif tok.startswith("!"):
            result[tok[1:]] = False
        elif "=" in tok or ":" in tok:
            k, v = re.split(r"[=:]", tok, maxsplit=1)
            result[k] = v
        else:
            result[tok] = True
    return result


def eval_pp_expr(expr: str, macros: dict[str, str]) -> bool:
    expr = expr.split("//")[0]
    expr = re.sub(r"\bdefined\s*\(\s*(\w+)\s*\)", lambda m: "1" if m.group(1) in macros else "0", expr)
    expr = re.sub(r"\bdefined\s+(\w+)", lambda m: "1" if m.group(1) in macros else "0", expr)
    expr = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: macros.get(m.group(0), "0") or "1", expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    try:
        return bool(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307 - 自前の properties の式だけを評価する
    except Exception:  # noqa: BLE001
        print(f"[warn] properties の式を評価できない: {expr}")
        return False


def preprocess_properties(path: Path, macros: dict[str, str]) -> list[str]:
    """#if を解決した shaders.properties の論理行"""
    out: list[str] = []
    stack: list[tuple[bool, bool]] = []  # (この分岐が有効, いずれかの分岐を既に採った)
    active = True
    for line in read_properties_logical_lines(path):
        m = PROP_IF_RE.match(line)
        if m:
            kind, arg = m.group(1), m.group(2).strip()
            if kind in ("if", "ifdef", "ifndef"):
                if kind == "if":
                    cond = eval_pp_expr(arg, macros)
                elif kind == "ifdef":
                    cond = arg.split()[0] in macros
                else:
                    cond = arg.split()[0] not in macros
                stack.append((active, active and cond))
                active = active and cond
            elif kind == "elif":
                parent, taken = stack[-1]
                cond = parent and not taken and eval_pp_expr(arg, macros)
                stack[-1] = (parent, taken or cond)
                active = cond
            elif kind == "else":
                parent, taken = stack[-1]
                active = parent and not taken
                stack[-1] = (parent, True)
            else:
                active = stack.pop()[0]
            continue
        if active:
            out.append(line)
    return out


def disabled_programs(prop_lines: list[str]) -> set[str]:
    """`program.<フォルダ付きの名前>.enabled = false` のプログラム名 (Iris と同じく、無効なプログラムは読まれない)"""
    result: set[str] = set()
    for line in prop_lines:
        m = re.match(r"^\s*program\.(\S+)\.enabled\s*=\s*(\S+)", line)
        if m and m.group(2).lower() == "false":
            result.add(m.group(1))
    return result
