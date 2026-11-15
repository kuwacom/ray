"""C プリプロセッサの #if の簡易評価 (検証で、前処理後に残る行を知るため)

対応: #if / #ifdef / #ifndef / #elif / #else / #endif、オブジェクト形式の #define / #undef、defined、整数と小数、比較と論理演算
関数形式のマクロは定義として数えない (Ray の #if の式には出てこない)
"""

from __future__ import annotations

import bisect
import re

PP_RE = re.compile(r"^\s*#\s*(\w+)\b\s*(.*)$")
DEFINE_RE = re.compile(r"^\s*#\s*define\s+([A-Za-z_]\w*)(?:\s+(.*?))?\s*$")
DEFINED_RE = re.compile(r"\bdefined\s*(?:\(\s*([A-Za-z_]\w*)\s*\)|([A-Za-z_]\w*))")
IDENT_RE = re.compile(r"\b[A-Za-z_]\w*\b")
NUMBER_SUFFIX_RE = re.compile(r"\b(\d+(?:\.\d*)?)[uUlLfF]+\b")
HEX_RE = re.compile(r"\b0[xX][0-9a-fA-F]+\b")


class ExprError(ValueError):
    pass


def eval_expr(expr: str, macros: dict[str, str], depth: int = 0) -> bool:
    """
    ### eval_expr
    #if の式を評価する。未定義の名前は 0、値の無い定義は 1。値はマクロを展開してから評価する

    @param expr - #if の後ろの式 (行末のコメントは除いてよい)
    @param macros - 定義済みのマクロ (名前 -> 値の文字列)
    @returns 真偽
    """
    return bool(_value(expr.split("//")[0], macros, depth))


def _value(expr: str, macros: dict[str, str], depth: int) -> float:
    if depth > 16:
        raise ExprError(f"マクロの展開が深すぎる: {expr}")
    expr = DEFINED_RE.sub(lambda m: "1" if (m.group(1) or m.group(2)) in macros else "0", expr)
    expr = HEX_RE.sub(lambda m: str(int(m.group(0), 16)), expr)
    expr = NUMBER_SUFFIX_RE.sub(r"\1", expr)

    def ident(m: re.Match[str]) -> str:
        name = m.group(0)
        if name not in macros:
            return "0"
        val = macros[name].split("//")[0].strip()
        return f"({_value(val, macros, depth + 1)})" if val else "1"

    expr = IDENT_RE.sub(ident, expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    try:
        return eval(expr, {"__builtins__": {}}, {})  # noqa: S307 - 自前のシェーダーの #if の式だけを評価する
    except Exception as e:  # noqa: BLE001
        raise ExprError(f"#if を評価できない: {expr}") from e


def active_ranges(lines: list[str], macros: dict[str, str] | None = None) -> list[tuple[int, int]]:
    """
    ### active_ranges
    #if を解決して、前処理の後に残る行 (指令の行を除く) の区間を返す。#define は読んだ順に効かせる
    指令の行だけを調べる (本文は数千行あり、検証では全プログラム x 全プロファイルで呼ぶため)

    @param lines - コメントを除いた本文の行 (行の数は元と同じにしておく)
    @param macros - 最初から定義されているマクロ
    @returns 残る行の区間 [start, end) の昇順のリスト
    """
    defs = dict(macros or {})
    out: list[tuple[int, int]] = []
    stack: list[tuple[bool, bool]] = []  # (親が有効, いずれかの枝を採った)
    active = True
    start = 0
    for i in [i for i, ln in enumerate(lines) if "#" in ln]:
        line = lines[i]
        m = PP_RE.match(line)
        if not m:
            continue
        if active and start < i:
            out.append((start, i))
        start = i + 1
        kind, arg = m.group(1), m.group(2).strip()
        if kind in ("if", "ifdef", "ifndef"):
            if not active:
                cond = False
            elif kind == "if":
                cond = eval_expr(arg, defs)
            elif kind == "ifdef":
                cond = arg.split()[0] in defs
            else:
                cond = arg.split()[0] not in defs
            stack.append((active, cond))
            active = active and cond
        elif kind == "elif":
            parent, taken = stack[-1]
            cond = parent and not taken and eval_expr(arg, defs)
            stack[-1] = (parent, taken or cond)
            active = cond
        elif kind == "else":
            parent, taken = stack[-1]
            active = parent and not taken
            stack[-1] = (parent, True)
        elif kind == "endif":
            active = stack.pop()[0] if stack else True
        elif kind == "define" and active:
            d = DEFINE_RE.match(line)
            if d:
                defs[d.group(1)] = d.group(2) or ""
        elif kind == "undef" and active:
            defs.pop(arg.split()[0], None)
    if active and start < len(lines):
        out.append((start, len(lines)))
    return out


def in_ranges(ranges: list[tuple[int, int]], i: int) -> bool:
    """i 行目が active_ranges の区間に入っているか"""
    k = bisect.bisect_right(ranges, (i, float("inf"))) - 1
    return k >= 0 and ranges[k][0] <= i < ranges[k][1]
