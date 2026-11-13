"""
前処理後 (glslang -E) の GLSL から SSBO・uniform ブロックと通常の uniform の宣言を拾い、同じプログラムの段どうしで比べる

AMD のドライバは、同じブロックや同名の uniform が段ごとに違う宣言 (readonly などの修飾子・layout・メンバー・型) だと
リンクで落とす (「Memory readonly qualifier must match」)。NVIDIA は通すので実機の NVIDIA では気づけない
"""

from __future__ import annotations

import re

STAGE_ORDER = ["vert", "tesc", "tese", "geom", "frag", "comp"]
MEMORY_QUALIFIERS = ("readonly", "writeonly", "coherent", "restrict", "volatile")

_QUAL = r"(?:readonly|writeonly|coherent|restrict|volatile|highp|mediump|lowp|std430|std140|shared|packed)"
_HEAD = rf"(?:layout\s*\([^)]*\)\s*|\b{_QUAL}\s+)*"
BLOCK_RE = re.compile(rf"(?P<head>{_HEAD})\b(?P<kind>buffer|uniform)\s+(?P<name>\w+)\s*\{{(?P<body>[^{{}}]*)\}}\s*(?P<inst>\w*)\s*(?P<arr>(?:\[[^\]]*\])*)\s*;")
UNIFORM_RE = re.compile(rf"(?P<head>{_HEAD})\buniform\s+(?P<tail>(?:{_QUAL}\s+)*)(?P<type>\w+)\s+(?P<name>\w+)\s*(?P<arr>(?:\[[^\]]*\])*)\s*(?:=[^;]*)?;")
FIELDS = ("kind", "layout", "quals", "members", "inst")


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def _layout_and_quals(head: str) -> tuple[str, tuple[str, ...]]:
    items = sorted(x.strip().replace(" ", "") for m in re.finditer(r"layout\s*\(([^)]*)\)", head) for x in m.group(1).split(","))
    return ",".join(items), tuple(q for q in MEMORY_QUALIFIERS if re.search(rf"\b{q}\b", head))


def parse_decls(pre: str) -> dict[str, dict[str, object]]:
    """
    ### parse_decls
    前処理後の本文から宣言を拾う

    @param pre - glslang -E の出力
    @returns キー ('block:<名前>' / 'uniform:<名前>') -> 宣言の要素 (kind, layout, quals, members, inst)
    """
    text = re.sub(r"^[ \t]*#.*$", "", pre, flags=re.M)
    out: dict[str, dict[str, object]] = {}
    spans: list[tuple[int, int]] = []
    for m in BLOCK_RE.finditer(text):
        layout, quals = _layout_and_quals(m.group("head"))
        out[f"block:{m.group('name')}"] = {"kind": m.group("kind"), "layout": layout, "quals": quals,
                                          "members": _norm(m.group("body")), "inst": m.group("inst") + m.group("arr")}
        spans.append(m.span())
    for m in UNIFORM_RE.finditer(text):
        if any(a <= m.start() < b for a, b in spans):
            continue
        layout, quals = _layout_and_quals(m.group("head") + " " + m.group("tail"))
        out[f"uniform:{m.group('name')}"] = {"kind": "uniform", "layout": layout, "quals": quals,
                                            "members": _norm(m.group("type") + m.group("arr")), "inst": ""}
    return out


def stage_mismatches(pre_by_stage: dict[str, str]) -> list[str]:
    """
    ### stage_mismatches
    同じプログラムの段の間で、同名のブロック・uniform の宣言が食い違うものを返す

    @param pre_by_stage - 段 (vert / frag / ...) -> 前処理後の本文
    @returns 食い違いの説明のリスト (無ければ空)
    """
    decls = {s: parse_decls(pre) for s, pre in sorted(pre_by_stage.items(), key=lambda kv: STAGE_ORDER.index(kv[0])) if pre}
    problems: list[str] = []
    for key in sorted(set().union(*(d.keys() for d in decls.values()))) if decls else []:
        have = {s: d[key] for s, d in decls.items() if key in d}
        if len(have) < 2:
            continue
        (s1, d1), *rest = have.items()
        for s2, d2 in rest:
            for f in FIELDS:
                if d1[f] != d2[f]:
                    a, b = str(d1[f])[:100], str(d2[f])[:100]
                    problems.append(f"{key.split(':', 1)[1]}: 段 {s1} と {s2} で宣言が食い違う ({f}: {a} / {b})")
    return problems
