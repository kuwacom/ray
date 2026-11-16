"""
colortex の論理名 (shaders/lib/buffers/slots.glsl) の検査

slots.glsl は、時間で分け合う枠と番号を移す枠に TEX_* の名前と区間 (最初のパス -> 最後のパス) を付けた表
1 つの枠を 2 つ以上の用途で使うときに、番号の直し漏れと、区間の外での読み書き (前の用途の値を壊す・読む) を見つける

静的な検査 (validate_shaders.py が毎回呼ぶ。glslang を使わない)
- 表の書式: 区間のパスが実在のプログラムか、最初より最後が前でないか
- 同じ枠の名前どうしの区間が重ならないか ((永続) の名前は 1 フレームの全体を占める。別名は問わない。
  colortex の deferred / composite のパスは、前の用途の最後と次の用途の最初を兼ねてよい (handoff_ok)
- 名前の付いた枠を、slots.glsl と宣言のファイル (formats・samplers・images) 以外で colortexN / colorimgN と直接書いていないか (コメントは除く)

区間の検査 (--intervals。glslang を全プログラムに掛けるので重い)
- 書き: 前処理後の本文の RENDERTARGETS / DRAWBUFFERS と imageStore、読み: glslang -l -i のリンク後の木に残る名前 (呼ばれない関数は消える)
- 名前の付いた枠を読み書きするプログラムが、その枠のどれかの名前の区間に入っているか。止まるプログラム (program.*.enabled) は除く
- リンク後の木は定数を畳まないので、実行時に通らない枝の読みも残る。調べて通らないと分かったものは KNOWN_UNREACHABLE に書く

使い方:
    uv run tools/check_slots.py                        # 静的な検査
    uv run tools/check_slots.py --intervals            # + 区間の検査 (既定値 x 3 ディメンション)
    uv run tools/check_slots.py --intervals --all      # + 代表の設定の組と全プロファイル (world0)
    uv run tools/check_slots.py --intervals --configs DEFAULT,DEBUG6 -v   # 枠ごとの読み書きの並びも出す
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.paths import SHADERS  # noqa: E402

SLOTS = "lib/buffers/slots.glsl"
# 枠そのものを宣言するファイル。ここでは番号で書くのが正しい
DECLARING = {SLOTS, "lib/buffers/formats.glsl", "lib/common/samplers.glsl", "lib/buffers/images.glsl"}
EXTS = {".glsl", ".vsh", ".fsh", ".csh", ".gsh"}

SLOT_RE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(TEX_\w+)[ \t]+(\w+)[ \t]*(?://(.*))?$")
COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
PASS_RE = re.compile(r"^(setup|begin|prepare|deferred|composite|final)(\d*)(?:_([a-z]))?$")
# Iris の実行順の群。gbuffers は deferred の前 (不透明) と後 (半透明) に分かれる
GROUPS = ["setup", "begin", "shadow", "prepare", "G_opaque", "deferred", "G_translucent", "composite", "final"]
# deferred の後に描かれる gbuffers (docs/architecture.md のパイプライン表)
G_TRANSLUCENT = {
    "gbuffers_water", "gbuffers_hand_water", "gbuffers_particles_translucent", "gbuffers_weather", "gbuffers_clouds",
    "gbuffers_entities_translucent", "gbuffers_block_translucent", "gbuffers_lightning",
}
# リンク後の木には残るが、実行時に通らない読み (名前, プログラム): 理由
KNOWN_UNREACHABLE = {
}

Pos = tuple[int, int, int, str]


@dataclass
class Slot:
    name: str
    value: str
    line: int
    first: str = ""
    lasts: list[str] = field(default_factory=list)
    persistent: bool = False


def program_kinds(shaders: Path) -> dict[str, set[str]]:
    """world0 のプログラム名 -> 拡張子の集合 (位置を決めるのに compute だけのパスかを見る)"""
    kinds: dict[str, set[str]] = {}
    for f in (shaders / "world0").iterdir():
        if f.suffix in EXTS:
            kinds.setdefault(f.stem, set()).add(f.suffix)
    return kinds


def position(prog: str, kinds: dict[str, set[str]]) -> Pos | None:
    """Iris の実行順での位置。同じ番号では compute (無印 -> _a -> _b ...) が fragment より先"""
    if prog == "gbuffers":
        return (GROUPS.index("G_opaque"), 0, 0, "")
    if prog.startswith("gbuffers_"):
        return (GROUPS.index("G_translucent" if prog in G_TRANSLUCENT else "G_opaque"), 0, 0, "")
    if prog.startswith("shadow"):
        return (GROUPS.index("shadow"), 0, 0, "")
    m = PASS_RE.match(prog)
    if not m:
        return None
    stage, num, suffix = m.group(1), int(m.group(2) or 0), m.group(3) or ""
    sub = 1 if suffix else (2 if ".fsh" in kinds.get(prog, set()) else 0)
    return (GROUPS.index(stage), num, sub, suffix)


def parse_slots(shaders: Path) -> tuple[list[Slot], list[str]]:
    path = shaders / SLOTS
    if not path.exists():
        return [], []
    slots: list[Slot] = []
    problems: list[str] = []
    for i, ln in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        m = SLOT_RE.match(ln)
        if not m:
            if re.match(r"^[ \t]*#[ \t]*define[ \t]+TEX_", ln):
                problems.append(f"{SLOTS}:{i}: 論理名の行の形が違う (#define TEX_<名前> <sampler> // <パス> -> <パス>)")
            continue
        s = Slot(m.group(1), m.group(2), i)
        note = m.group(3) or ""
        s.persistent = "(永続)" in note
        spec = re.sub(r"\([^)]*\)", " ", note)
        left, _, right = spec.partition("->")
        s.first = left.strip()
        s.lasts = [t.strip() for t in right.split("/") if t.strip()] if right.strip() else [s.first]
        slots.append(s)
    return slots, problems


def resolve(slots: list[Slot]) -> dict[str, str]:
    """名前 -> 枠 (別名は辿る)"""
    by = {s.name: s.value for s in slots}
    out = {}
    for s in slots:
        v, seen = s.value, {s.name}
        while v in by and v not in seen:
            seen.add(v)
            v = by[v]
        out[s.name] = v
    return out


def direct_names(slot: str) -> list[str]:
    """枠を直接指す名前。colortexN は colorimgN、xxxSampler は xxxImg も同じ枠"""
    m = re.fullmatch(r"colortex(\d+)", slot)
    if m:
        return [slot, f"colorimg{m.group(1)}"]
    if slot.endswith("Sampler"):
        return [slot, slot[: -len("Sampler")] + "Img"]
    return [slot]


def intervals(slots: list[Slot], kinds) -> tuple[dict[str, tuple[Pos, Pos] | None], list[str]]:
    """名前 -> (最初, 最後) の位置。(永続) は None (全体)"""
    out: dict[str, tuple[Pos, Pos] | None] = {}
    problems = []
    for s in slots:
        if s.value.startswith("TEX_"):
            continue
        where = f"{SLOTS}:{s.line}: {s.name}"
        if not s.first:
            problems.append(f"{where}: 区間が書かれていない")
            continue
        pf = position(s.first, kinds)
        pl = [position(t, kinds) for t in s.lasts]
        bad = [t for t, p in zip([s.first] + s.lasts, [pf] + pl) if p is None or (t not in kinds and t != "gbuffers")]
        if bad:
            problems.append(f"{where}: 区間のパス {', '.join(bad)} が world0 のプログラムに無い")
            continue
        if s.persistent:
            out[s.name] = None
            continue
        last = max(pl)
        if last < pf:
            problems.append(f"{where}: 最後のパス {s.lasts} が最初の {s.first} より前 (前フレームを読むなら (永続) を書く)")
            continue
        out[s.name] = (pf, last)
    return out, problems


def handoff_ok(slot: str, sa: tuple[Pos, Pos], sb: tuple[Pos, Pos]) -> bool:
    """
    ### handoff_ok
    片方の最後のパスが他方の最初のパスと同じでも、そのパスで前の用途を読んで次の用途を書くだけなら重ならない。
    Iris は composite / deferred のパスで書く colortex の読む側と書く側を分け、パスの後に入れ替える (composite20 の読み書きと同じ) ので、
    そのパスの読みは前の用途の値のまま。gbuffers (入れ替えない) と image (同じ面を読み書きする) は除く

    @param slot - 枠 (colortexN / xxxSampler)
    @param sa - 一方の区間
    @param sb - 他方の区間
    @returns 端の 1 パスだけを共有する colortex の区間なら True
    """
    if not re.fullmatch(r"colortex\d+", slot):
        return False
    shared = sa[1] if sa[1] == sb[0] else sb[1] if sb[1] == sa[0] else None
    if shared is None or sa[0] == sa[1] or sb[0] == sb[1]:
        return False
    return shared[0] in (GROUPS.index("deferred"), GROUPS.index("composite"))


def overlap_problems(slots: list[Slot], spans) -> list[str]:
    target = resolve(slots)
    problems = []
    own = [s for s in slots if not s.value.startswith("TEX_") and s.name in spans]
    for i, a in enumerate(own):
        for b in own[i + 1:]:
            if target[a.name] != target[b.name]:
                continue
            sa, sb = spans[a.name], spans[b.name]
            if sa is not None and sb is not None and handoff_ok(target[a.name], sa, sb):
                continue
            if sa is None or sb is None or not (sa[1] < sb[0] or sb[1] < sa[0]):
                problems.append(f"{SLOTS}:{b.line}: {b.name} と {a.name} ({target[a.name]}) の区間が重なる")
    return problems


def strip_comments(text: str) -> str:
    return COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def direct_use_problems(shaders: Path, slots: list[Slot]) -> list[str]:
    target = resolve(slots)
    owner: dict[str, str] = {}
    for name, slot in target.items():
        for d in direct_names(slot):
            owner.setdefault(d, name)
    if not owner:
        return []
    pat = re.compile(r"\b(" + "|".join(map(re.escape, sorted(owner))) + r")\b")
    problems = []
    for f in sorted(shaders.rglob("*")):
        if f.suffix not in EXTS:
            continue
        rel = f.relative_to(shaders).as_posix()
        if rel in DECLARING:
            continue
        for i, ln in enumerate(strip_comments(f.read_text(encoding="utf-8")).splitlines(), 1):
            for m in pat.finditer(ln):
                problems.append(f"{rel}:{i}: {m.group(1)} を直接書いている (論理名 {owner[m.group(1)]} を使う。lib/buffers/slots.glsl)")
    return problems


def check(shaders: Path = SHADERS) -> list[str]:
    """
    ### check
    静的な検査 (表の書式、区間の重なり、直接書き)。validate_shaders.py の静的チェックから呼ぶ

    @param shaders - shaders/ のパス
    @returns 問題の一覧 (空なら合格)
    """
    slots, problems = parse_slots(shaders)
    if not slots:
        return problems
    spans, p = intervals(slots, program_kinds(shaders))
    return problems + p + overlap_problems(slots, spans) + direct_use_problems(shaders, slots)


# 区間の検査 (glslang)

RT_RE = re.compile(r"/\*\s*(RENDERTARGETS|DRAWBUFFERS):\s*([^*]*)\*/")
RT_MARK = "RAY_SLOT_RT"
MARK_RE = re.compile(RT_MARK + r"[ \t]+(\d[\d, \t]*)")
STORE_RE = re.compile(r"\bimage(?:Store|Atomic\w+)\s*\(\s*(\w+)")
NAME_RE = re.compile(r"'(\w+)' \(")
EXT_OF_STAGE = {"vert": "vsh", "frag": "fsh", "geom": "gsh", "comp": "csh"}

# 設定の組: 名前 -> (上書き, ディメンション)。区間が設定で変わる所 (GI・雲・水・ブルーム・光芒・きらめき・debug) を選んだ
CONFIGS: dict[str, tuple[dict[str, str | bool], tuple[str, ...]]] = {
    "DEFAULT": ({}, ("world0", "world-1", "world1")),
    "NO_GI_AO": ({"GI_MODE": "0", "AO_MODE": "0"}, ("world0",)),
    "GI0_AO2": ({"GI_MODE": "0"}, ("world0",)),
    "GI_DENOISE0": ({"GI_DENOISE": "0"}, ("world0",)),
    "GI3": ({"GI_MODE": "3"}, ("world0",)),
    "CLOUDS1": ({"CLOUDS": "1"}, ("world0",)),
    "CLOUD_RES1": ({"CLOUD_RES": "1"}, ("world0",)),
    "HDR": ({"LOCAL_TONEMAP": "4"}, ("world0",)),
    "NO_BLOOM_HDR": ({"BLOOM": False, "LOCAL_TONEMAP": "4"}, ("world0",)),
    "REFL0": ({"REFLECTIONS": "0"}, ("world0",)),
    "REFL3": ({"REFLECTIONS": "3"}, ("world0",)),
    "NO_SPARKLE": ({"SPECULAR_SPARKLE": False}, ("world0",)),
    "GODRAYS_RES4": ({"GODRAYS_RES": "4"}, ("world0",)),
    "NO_TAA": ({"TAA": False}, ("world0",)),
    "NO_LIGHT_SHADOWS": ({"LIGHT_SHADOWS": False}, ("world0",)),
    "REFR0": ({"WATER_REFRACTION": "0"}, ("world0",)),
}
for _d in range(1, 13):
    CONFIGS[f"DEBUG{_d}"] = ({"DEBUG_VIEW": str(_d)}, ("world0",))


def glslang_run(glslang: str, stage: str, src: str, args: list[str]) -> str:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / f"x.{EXT_OF_STAGE[stage]}"
        tmp.write_text(src, encoding="utf-8")
        p = subprocess.run([glslang, "-S", stage, *args, str(tmp)], capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
    return p.stdout + p.stderr


def scan_program(glslang: str, V, wrapper: Path, ov, options, features) -> tuple[set[int], set[str], set[str]]:
    """(RENDERTARGETS の番号, imageStore の先, リンク後の木の名前)"""
    src, _ = V.build_source(wrapper, ov, options, features)
    stage = V.STAGE_OF_EXT[wrapper.suffix]

    def mark(m: re.Match) -> str:
        nums = m.group(2).strip()
        if m.group(1) == "DRAWBUFFERS":
            nums = ",".join(nums)
        return f"{RT_MARK} {nums}"

    # コメントは前処理で消えるので、RENDERTARGETS を印の行に変えて #if の評価を glslang に任せる
    pre = glslang_run(glslang, stage, RT_RE.sub(mark, src), ["-E"])
    rts = {int(t) for m in MARK_RE.finditer(pre) for t in m.group(1).split(",") if t.strip()}
    stores = set(STORE_RE.findall(pre))
    out = glslang_run(glslang, stage, src, ["-l", "-i"])
    at = out.find("Linked ")
    if at < 0:
        raise RuntimeError(f"{wrapper}: glslang の出力にリンク後の木が無い: {out[-400:]}")
    linked = out[at:]
    end = linked.find("Linker Objects")
    return rts, stores, set(NAME_RE.findall(linked[:end] if end >= 0 else linked))


def config_macros(options, ov) -> dict[str, str]:
    macros: dict[str, str] = {}
    for n, opt in options.items():
        if opt.kind != "bool":
            macros[n] = str(opt.default)
        elif opt.default:
            macros[n] = "1"
    for n, v in ov.items():
        if v is False:
            macros.pop(n, None)
        else:
            macros[n] = "1" if v is True else str(v)
    return macros


def interval_check(shaders: Path, config_names: list[str], jobs: int, verbose: bool, V=None) -> list[str]:
    """
    ### interval_check
    区間の検査 (glslang)。validate_shaders.py --full からも呼ぶ

    @param V - validate_shaders のモジュール (validate_shaders から呼ぶ時は自分を渡す。省略で読み込む)
    @returns 問題の一覧
    """
    if V is None:
        import validate_shaders as V  # validate_shaders から呼ばれる静的な検査では読み込まない (循環を避ける)
    from lib import properties as P

    slots, _ = parse_slots(shaders)
    kinds = program_kinds(shaders)
    spans, _ = intervals(slots, kinds)
    target = resolve(slots)
    names_of: dict[str, list[str]] = {}
    for s in slots:
        names_of.setdefault(target[s.name], []).append(s.name)
    glslang = V.find_glslang()
    options = V.parse_settings()
    req, opt = V.parse_features()
    profiles = P.parse_profiles(shaders)
    problems: list[str] = []
    for cfg in config_names:
        if cfg.startswith("PROFILE_"):
            ov, worlds = P.resolve_profile(cfg[len("PROFILE_"):], profiles), ("world0",)
        else:
            ov, worlds = CONFIGS[cfg]
        disabled = P.disabled_programs(P.preprocess_properties(shaders / "shaders.properties", config_macros(options, ov)))
        files = [f for w in worlds for f in sorted((shaders / w).iterdir())
                 if f.suffix in V.STAGE_OF_EXT and f"{w}/{f.stem}" not in disabled]
        with cf.ThreadPoolExecutor(jobs) as ex:
            res = dict(zip(files, ex.map(lambda f: scan_program(glslang, V, f, ov, options, req + opt), files)))
        for w in worlds:
            uses: dict[str, dict[str, set[str]]] = {}  # 枠 -> プログラム -> {"R", "W"}
            for f, (rts, stores, names) in res.items():
                if f.parent.name != w:
                    continue
                for slot in names_of:
                    direct = direct_names(slot)
                    tags = set()
                    m = re.fullmatch(r"colortex(\d+)", slot)
                    if m and int(m.group(1)) in rts and not f.stem.startswith("shadow"):
                        tags.add("W")
                    if direct[-1] in stores:
                        tags.add("W")
                    if any(d in names for d in direct):
                        tags.add("R")
                    if tags:
                        uses.setdefault(slot, {}).setdefault(f.stem, set()).update(tags)
            for slot, progs in uses.items():
                order = sorted(progs, key=lambda p: position(p, kinds) or (99, 0, 0, ""))
                if verbose:
                    seq = " -> ".join(f"{p}:{''.join(sorted(progs[p]))}" for p in order)
                    print(f"[{cfg}/{w}] {slot} ({', '.join(names_of[slot])}): {seq}")
                for p in order:
                    pos = position(p, kinds)
                    ok = any(n in spans and (spans[n] is None or spans[n][0] <= pos <= spans[n][1]) for n in names_of[slot])
                    if ok or any((n, p) in KNOWN_UNREACHABLE for n in names_of[slot]):
                        continue
                    kind = "読み書きする" if len(progs[p]) > 1 else ("書く" if "W" in progs[p] else "読む")
                    problems.append(f"[{cfg}/{w}] {p} が {slot} ({', '.join(names_of[slot])}) を{kind}が、どの区間にも入らない")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description="colortex の論理名の検査 (lib/buffers/slots.glsl)")
    ap.add_argument("--intervals", action="store_true", help="glslang で読み書きを調べ、区間の外の使用を探す")
    ap.add_argument("--all", action="store_true", help="--intervals で代表の設定の組と全プロファイルも見る")
    ap.add_argument("--configs", default="", help="--intervals の設定の組 (カンマ区切り。PROFILE_<名前> も可)")
    ap.add_argument("-j", "--jobs", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("-v", "--verbose", action="store_true", help="枠ごとの読み書きの並びを出す")
    args = ap.parse_args()
    problems = check(SHADERS)
    if args.intervals:
        from lib import properties as P

        names = [c for c in args.configs.split(",") if c]
        if not names:
            names = ["DEFAULT"]
            if args.all:
                names = list(CONFIGS) + [f"PROFILE_{p}" for p in P.parse_profiles(SHADERS)]
        problems += interval_check(SHADERS, names, args.jobs, args.verbose)
    for p in problems:
        print(p)
    slots, _ = parse_slots(SHADERS)
    print(f"論理名 {len(slots)} 個、問題 {len(problems)} 件")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
