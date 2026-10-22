"""
Iris の前処理を簡易再現して glslangValidator で全プログラムをコンパイル検証する

再現している内容
- `#include "/..."` の絶対パス解決 (shaders/ 起点, 再帰)
- 設定 (#define / const) の値の差し替え。プロファイル (shaders.properties の profile.*) を適用可能
- Iris が自動定義するマクロ (MC_VERSION, IS_IRIS, MC_RENDER_STAGE_*, IRIS_FEATURE_* 等) の注入
- エラー行を元のファイル名・行番号へ戻して表示

あわせて静的チェックも行う
- プロファイル・program.enabled が参照する設定が settings.glsl に存在するか
- lang (en_US / ja_JP) に全設定・全画面のラベルがあるか
- shaders.properties の screen に全設定が載っているか

使い方:
    uv run tools/validate_shaders.py                    # 高速: 既定値・world0 のみ + 前回成功から変わったものだけ
    uv run tools/validate_shaders.py --full             # 既定値 + 全プロファイル (world0) + 既定値 (world-1, world1)
    uv run tools/validate_shaders.py --profile HIGH     # 指定プロファイルのみ
    uv run tools/validate_shaders.py --filter deferred  # ファイル名に文字列を含むものだけ
    uv run tools/validate_shaders.py --no-cache         # キャッシュを使わず全部コンパイルし直す

キャッシュ (tools/.cache/validate.json): include を展開し設定を差し替えた後の本文のハッシュを、成功したものだけ記録する
本文には依存ファイルと設定値がすべて入っているので、どのファイルを変えても影響するプログラムだけが再コンパイルされる

glslangValidator の場所: 環境変数 RAY_GLSLANG > PATH 上の glslangValidator / glslang
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import functools
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
SETTINGS = SHADERS / "lib" / "settings.glsl"
PROPERTIES = SHADERS / "shaders.properties"
LANG_FILES = [SHADERS / "lang" / "en_US.lang", SHADERS / "lang" / "ja_JP.lang"]
WORLDS = ["world0", "world-1", "world1"]

STAGE_OF_EXT = {".vsh": "vert", ".fsh": "frag", ".gsh": "geom", ".csh": "comp", ".tcs": "tesc", ".tes": "tese"}

# Iris が定義するレンダーステージのマクロ (値は検証用の仮の連番)
RENDER_STAGES = [
    "NONE", "SKY", "SUNSET", "CUSTOM_SKY", "SUN", "MOON", "STARS", "VOID", "TERRAIN_SOLID",
    "TERRAIN_CUTOUT_MIPPED", "TERRAIN_CUTOUT", "ENTITIES", "BLOCK_ENTITIES", "DESTROY", "OUTLINE",
    "DEBUG", "HAND_SOLID", "TERRAIN_TRANSLUCENT", "TRIPWIRE", "PARTICLES", "CLOUDS", "RAIN_SNOW",
    "WORLD_BORDER", "HAND_TRANSLUCENT",
]

IRIS_MACROS = {
    "MC_VERSION": "12104",
    "MC_GL_VERSION": "460",
    "MC_GLSL_VERSION": "460",
    "IS_IRIS": "",
    "IRIS_VERSION": "10800",
    "IRIS_TAG_SUPPORT": "2",
    "MC_OS_WINDOWS": "",
    "MC_GL_VENDOR_NVIDIA": "",
    "MC_GL_RENDERER_GEFORCE": "",
    "MC_HAND_DEPTH": "0.125",
    "MC_MIPMAP_LEVEL": "4",
    "MC_NORMAL_MAP": "",
    "MC_SPECULAR_MAP": "",
}

INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"')
DEFINE_RE = re.compile(r"^(\s*)(//\s*)?#define\s+([A-Za-z_]\w*)(?:\s+([^\s/]+))?\s*(//.*)?$")
CONST_RE = re.compile(r"^(\s*)const\s+(int|float|bool)\s+(\w+)\s*=\s*([^;]+);\s*(//.*)?$")
ERROR_RE = re.compile(r"^(ERROR|WARNING): 0:(\d+): (.*)$")


@dataclass
class Option:
    name: str
    kind: str  # "bool" | "value" | "const"
    default: str | bool
    values: list[str] = field(default_factory=list)


def parse_settings() -> dict[str, Option]:
    """settings.glsl から設定項目を拾う (値リスト付きの数値 define, ブール define, 値リスト付き const)"""
    opts: dict[str, Option] = {}
    for line in SETTINGS.read_text(encoding="utf-8").splitlines():
        m = DEFINE_RE.match(line)
        if m:
            commented, name, value, comment = m.group(2), m.group(3), m.group(4), m.group(5) or ""
            if value is None:
                # 値なし define がブール設定 (インクルードガードは除く)
                if name not in opts and not name.endswith("_GLSL"):
                    opts[name] = Option(name, "bool", commented is None)
            elif commented is None and comment.startswith("//") and "[" in comment:
                vals = re.search(r"\[([^\]]*)\]", comment)
                opts[name] = Option(name, "value", value, vals.group(1).split() if vals else [])
            continue
        m = CONST_RE.match(line)
        if m and m.group(5) and "[" in m.group(5):
            vals = re.search(r"\[([^\]]*)\]", m.group(5))
            opts[m.group(3)] = Option(m.group(3), "const", m.group(4).strip(), vals.group(1).split() if vals else [])
    return opts


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


def parse_profiles() -> dict[str, list[str]]:
    profiles: dict[str, list[str]] = {}
    if not PROPERTIES.exists():
        return profiles
    for line in read_properties_logical_lines(PROPERTIES):
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


def parse_features() -> tuple[list[str], list[str]]:
    req: list[str] = []
    opt: list[str] = []
    if not PROPERTIES.exists():
        return req, opt
    for line in read_properties_logical_lines(PROPERTIES):
        m = re.match(r"^\s*iris\.features\.(required|optional)\s*=\s*(.*)$", line)
        if m:
            (req if m.group(1) == "required" else opt).extend(m.group(2).split())
    return req, opt


@functools.lru_cache(maxsize=None)
def read_lines(path: Path) -> tuple[str, ...]:
    # 1 回の実行中は同じ lib を何百回も展開するので読み込みを使い回す
    return tuple(path.read_text(encoding="utf-8").splitlines())


# 展開中のファイル (循環 include の検出用)。スレッドから呼ばれるので展開全体を _EXPAND_LOCK で直列化する
_EXPANDING: set[Path] = set()
_EXPAND_LOCK = threading.RLock()


@functools.lru_cache(maxsize=None)
def include_target(parent: Path, target: str) -> Path:
    inc = SHADERS / target.lstrip("/") if target.startswith("/") else parent / target
    return inc.resolve()


@functools.lru_cache(maxsize=None)
def expand_file(path: Path) -> tuple[tuple[str, ...], tuple[tuple[str, int], ...]]:
    """1 ファイルを include 込みで展開する。インクルードガードは GLSL 側で効くので、展開結果は呼び出し元に依らずファイルごとに使い回せる"""
    if path in _EXPANDING:
        raise RuntimeError(f"include cycle: {path}")
    if not path.exists():
        raise FileNotFoundError(path)
    _EXPANDING.add(path)
    try:
        rel = path.relative_to(SHADERS).as_posix()
        out: list[str] = []
        linemap: list[tuple[str, int]] = []
        for i, line in enumerate(read_lines(path), 1):
            m = INCLUDE_RE.match(line) if "include" in line else None
            if m:
                sub, sub_map = expand_file(include_target(path.parent, m.group(1)))
                out.extend(sub)
                linemap.extend(sub_map)
                continue
            out.append(line)
            linemap.append((rel, i))
        return tuple(out), tuple(linemap)
    finally:
        _EXPANDING.discard(path)


def is_setting_line(line: str) -> bool:
    # 正規表現は重いので、define / const で始まる行だけに掛ける (全プログラム x 数千行を毎回処理するため)
    head = line.lstrip()[:9]
    return head.startswith("#") or head.startswith("//") or head.startswith("const")


def apply_overrides(lines: list[str], overrides: dict[str, str | bool], options: dict[str, Option],
                    candidates: tuple[int, ...] | None = None) -> list[str]:
    result = list(lines)
    if not overrides:
        return result
    for idx in candidates if candidates is not None else range(len(lines)):
        line = lines[idx]
        if candidates is None and not is_setting_line(line):
            continue
        m = DEFINE_RE.match(line)
        if m and m.group(3) in overrides and options.get(m.group(3)):
            name = m.group(3)
            opt = options[name]
            val = overrides[name]
            if opt.kind == "bool":
                line = f"#define {name}" if val is True or val == "true" else f"//#define {name}"
            elif opt.kind == "value" and m.group(2) is None:
                line = f"#define {name} {val}"
        else:
            c = CONST_RE.match(line)
            if c and c.group(3) in overrides:
                line = f"const {c.group(2)} {c.group(3)} = {overrides[c.group(3)]};"
        result[idx] = line
    return result


@functools.lru_cache(maxsize=None)
def expanded(wrapper: Path) -> tuple[tuple[str, ...], tuple[tuple[str, int], ...], tuple[int, ...]]:
    # include 展開は設定に依らないので、プロファイルを変えて何度も検証する時に使い回す
    with _EXPAND_LOCK:
        lines, linemap = expand_file(wrapper.resolve())
    candidates = tuple(i for i, ln in enumerate(lines) if is_setting_line(ln))
    return lines, linemap, candidates

def build_source(wrapper: Path, overrides: dict[str, str | bool], options: dict[str, Option], features: list[str]) -> tuple[str, list[tuple[str, int]]]:
    raw, raw_map, candidates = expanded(wrapper)
    linemap = list(raw_map)
    lines = apply_overrides(list(raw), overrides, options, candidates)
    assert lines[0].startswith("#version"), f"{wrapper}: 1 行目が #version ではない"
    inject = [f"#define {k} {v}".rstrip() for k, v in IRIS_MACROS.items()]
    inject += [f"#define MC_RENDER_STAGE_{s} {i}" for i, s in enumerate(RENDER_STAGES)]
    inject += [f"#define IRIS_FEATURE_{f}" for f in features]
    out = [lines[0]] + inject + lines[1:]
    lm = [linemap[0]] + [("<iris>", 0)] * len(inject) + linemap[1:]
    return "\n".join(out) + "\n", lm


CACHE_DIR = ROOT / "tools" / ".cache"


class SuccessCache:
    """
    # SuccessCache
    成功した検証結果のハッシュを JSON に残し、同じ入力の再検証を省く

    ### 特徴
    - キーは呼び出し側が作る (前処理後の本文 + ツールの版などのハッシュ)
    - 値は任意の JSON (gl_compile_check はプログラムの使用数を入れる)
    - 失敗した結果は記録しないので、直すまで毎回検証される
    """

    def __init__(self, name: str, enabled: bool = True):
        self.path = CACHE_DIR / f"{name}.json"
        self.enabled = enabled
        self.data: dict = {}
        self.used: set[str] = set()
        if enabled and self.path.exists():
            try:
                self.data = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                self.data = {}

    @staticmethod
    def key(*parts: str) -> str:
        h = hashlib.sha1()
        for p in parts:
            h.update(p.encode("utf-8", "surrogatepass"))
            h.update(b"\0")
        return h.hexdigest()

    def get(self, key: str):
        if not self.enabled or key not in self.data:
            return None
        self.used.add(key)
        return self.data[key]

    def put(self, key: str, value=True) -> None:
        self.data[key] = value
        self.used.add(key)

    def save(self) -> None:
        if not self.enabled:
            return
        # 古いエントリが溜まり続けないよう、今回参照したものだけを残す (フルと高速で別ファイルにはしない)
        keep = {k: v for k, v in self.data.items() if k in self.used} if len(self.data) > 20000 else self.data
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(keep), encoding="utf-8")


def tool_version(exe: str) -> str:
    """キャッシュのキーに入れる実行ファイルの識別子 (更新されたら無効化する)"""
    try:
        st = Path(exe).stat()
        return f"{exe}:{st.st_size}:{int(st.st_mtime)}"
    except OSError:
        return exe


def find_glslang() -> str:
    env = os.environ.get("RAY_GLSLANG")
    if env and Path(env).exists():
        return env
    for name in ("glslangValidator", "glslang"):
        p = shutil.which(name)
        if p:
            return p
    # PATH に無くても tools/glslang/ (gitignore 済み) に展開しておけば使える
    fallback = Path(__file__).resolve().parent / "glslang" / "bin" / "glslang.exe"
    if fallback.exists():
        return str(fallback)
    sys.exit("glslangValidator が見つからない。RAY_GLSLANG を設定するか PATH に置くこと")


def compile_one(glslang: str, tmpdir: Path, wrapper: Path, cfg_name: str, overrides, options, features,
                cache: SuccessCache | None = None, glslang_id: str = "") -> tuple[str, list[str], str | None]:
    """戻り値: (表示名, メッセージ, 成功時に記録するキャッシュキー。キャッシュから返した時と失敗時は None)"""
    label = f"[{cfg_name}] {wrapper.relative_to(SHADERS).as_posix()}"
    try:
        src, linemap = build_source(wrapper, overrides, options, features)
    except Exception as e:  # noqa: BLE001 - 前処理の失敗はそのまま報告する
        return label, [f"preprocess: {e}"], None
    stage = STAGE_OF_EXT[wrapper.suffix]
    key = SuccessCache.key(glslang_id, stage, src)
    if cache is not None and cache.get(key) is not None:
        return label, [], None
    safe = re.sub(r"[^\w.-]", "_", f"{cfg_name}_{wrapper.parent.name}_{wrapper.stem}")
    tmp = tmpdir / f"{safe}.{stage}"
    tmp.write_text(src, encoding="utf-8")
    proc = subprocess.run([glslang, "-S", stage, str(tmp)], capture_output=True, text=True, encoding="utf-8", errors="replace")
    msgs: list[str] = []
    for line in (proc.stdout + proc.stderr).splitlines():
        m = ERROR_RE.match(line.strip())
        if not m:
            continue
        idx = int(m.group(2)) - 1
        where = f"{linemap[idx][0]}:{linemap[idx][1]}" if 0 <= idx < len(linemap) else f"?:{idx + 1}"
        msgs.append(f"{m.group(1)} {where}: {m.group(3)}")
    if proc.returncode != 0 and not any(s.startswith("ERROR") for s in msgs):
        msgs.append("ERROR (glslang): " + (proc.stdout + proc.stderr).strip().splitlines()[-1] if (proc.stdout + proc.stderr).strip() else "ERROR (glslang): unknown")
    # 警告付きも記録しない (毎回表示されるように)
    return label, msgs, (key if proc.returncode == 0 and not msgs else None)


def properties_checks() -> list[str]:
    """Iris が .properties を読む時の制約"""
    problems: list[str] = []
    for path in sorted(SHADERS.glob("*.properties")):
        raw = path.read_bytes()
        # Iris は ISO-8859-1 で読み、Java の \R (U+0085 を含む) で行分割してから C プリプロセッサに通す。
        # UTF-8 の日本語はコメント行でも途中で分割されて不正トークンになり、ファイル全体の前処理が止まる
        for i, line in enumerate(raw.split(b"\n"), 1):
            if not line.isascii():
                problems.append(f"{path.name}:{i}: ASCII 以外の文字がある (Iris の前処理が失敗する)")
                break
        if path.name in ("block.properties", "item.properties"):
            # Iris の状態フィルタは 1 値の完全一致のみ。"prop=a,b" は何にも一致しない
            for i, line in enumerate(raw.decode("latin-1").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                for tok in line.split("=", 1)[-1].split():
                    if "=" in tok and "," in tok.split("=", 1)[1]:
                        problems.append(f"{path.name}:{i}: 状態値のカンマ区切りは Iris で一致しない: {tok}")
    return problems


def static_checks(options: dict[str, Option], profiles: dict[str, list[str]]) -> list[str]:
    problems: list[str] = properties_checks()
    for pname in profiles:
        for k, v in resolve_profile(pname, profiles).items():
            opt = options.get(k)
            if opt is None:
                problems.append(f"profile.{pname}: 未定義の設定 {k}")
            elif opt.kind != "bool" and opt.values and not any(float(v) == float(x) for x in opt.values):
                problems.append(f"profile.{pname}: {k}={v} が値リストにない")
    # 素の既定値は HIGH と一致させる方針 (docs/architecture.md)
    if "HIGH" in profiles:
        for k, v in resolve_profile("HIGH", profiles).items():
            opt = options.get(k)
            if opt is None:
                continue
            default = opt.default
            same = (v is True) == default if opt.kind == "bool" else (v is not False and float(v) == float(str(default).rstrip("f")))
            if not same:
                problems.append(f"HIGH と既定値が不一致: {k} (HIGH={v}, 既定={default})")
    # Iris は workGroups / workGroupsRender をリテラルとしてしか読めない (式やマクロは #if で分岐して書く)
    for csh in (SHADERS / "program").rglob("*.csh"):
        for i, line in enumerate(csh.read_text(encoding="utf-8").splitlines(), 1):
            m = re.search(r"const\s+(ivec3|vec2)\s+(workGroups|workGroupsRender)\s*=\s*\w+\(([^)]*)\)", line)
            if m and not re.fullmatch(r"[\d.,\s]+", m.group(3)):
                problems.append(f"{csh.relative_to(SHADERS).as_posix()}:{i}: {m.group(2)} がリテラルでない")
    if PROPERTIES.exists():
        text = "\n".join(read_properties_logical_lines(PROPERTIES))
        screen_items: set[str] = set()
        screens: set[str] = set()
        for m in re.finditer(r"^\s*screen(?:\.(\w+))?\s*=\s*(.*)$", text, re.M):
            if m.group(1) and m.group(1).endswith("columns"):
                continue
            for tok in m.group(2).split():
                if tok.startswith("[") and tok.endswith("]"):
                    screens.add(tok[1:-1])
                elif tok not in ("<empty>", "<profile>", "*"):
                    screen_items.add(tok)
        for name in options:
            if name not in screen_items:
                problems.append(f"screen に載っていない設定: {name}")
        for tok in screen_items:
            if tok not in options:
                problems.append(f"screen の未定義の設定: {tok}")
        for m in re.finditer(r"^\s*sliders\s*=\s*(.*)$", text, re.M):
            for tok in m.group(1).split():
                if tok not in options:
                    problems.append(f"sliders の未定義の設定: {tok}")
        for lang in LANG_FILES:
            if not lang.exists():
                problems.append(f"lang がない: {lang.name}")
                continue
            keys = {ln.split("=", 1)[0].strip() for ln in lang.read_text(encoding="utf-8").splitlines() if "=" in ln and not ln.lstrip().startswith("#")}
            for name in options:
                if f"option.{name}" not in keys:
                    problems.append(f"{lang.name}: option.{name} がない")
            for s in screens:
                if f"screen.{s}" not in keys:
                    problems.append(f"{lang.name}: screen.{s} がない")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", help="このプロファイルだけ検証する (DEFAULT で既定値)")
    ap.add_argument("--filter", default="", help="ファイル名にこの文字列を含むものだけ")
    ap.add_argument("--full", action="store_true", help="既定値 x 3 ディメンション + 全プロファイル")
    ap.add_argument("--quick", action="store_true", help="既定値 x world0 のみ (既定の動作。互換のため残す)")
    ap.add_argument("--no-cache", action="store_true", help="前回成功したものも含めて全部コンパイルする")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()
    cache = SuccessCache("validate", enabled=not args.no_cache)

    options = parse_settings()
    profiles = parse_profiles()
    required, optional = parse_features()
    features = required + optional
    glslang = find_glslang()

    problems = static_checks(options, profiles)
    for p in problems:
        print(f"[static] {p}")

    configs: list[tuple[str, dict, list[str]]] = []
    if args.profile:
        ov = {} if args.profile == "DEFAULT" else resolve_profile(args.profile, profiles)
        configs.append((args.profile, ov, ["world0"]))
    elif args.full:
        configs.append(("DEFAULT", {}, WORLDS))
        for p in profiles:
            configs.append((p, resolve_profile(p, profiles), ["world0"]))
    else:
        configs.append(("DEFAULT", {}, ["world0"]))

    jobs = []
    tmpdir = Path(tempfile.mkdtemp(prefix="ray_glsl_"))
    glslang_id = tool_version(glslang)
    cached = 0
    # glslang はプロセスとして起動するのでスレッドから呼べば CPU コア数だけ並列に走る
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for cfg_name, ov, worlds in configs:
            for w in worlds:
                for f in sorted((SHADERS / w).glob("*")):
                    if f.suffix not in STAGE_OF_EXT or args.filter not in f.name:
                        continue
                    jobs.append(ex.submit(compile_one, glslang, tmpdir, f, cfg_name, ov, options, features, cache, glslang_id))
        failed = 0
        warned = 0
        for fut in cf.as_completed(jobs):
            label, msgs, new_key = fut.result()
            if new_key:
                cache.put(new_key)
            elif not msgs:
                cached += 1
            errors = [m for m in msgs if m.startswith("ERROR") or m.startswith("preprocess")]
            if errors:
                failed += 1
                print(f"FAIL {label}")
                for m in msgs[:20]:
                    print(f"    {m}")
            elif msgs:
                warned += 1
    shutil.rmtree(tmpdir, ignore_errors=True)
    cache.save()
    print(f"\n{len(jobs)} compiled ({cached} unchanged, cached), {failed} failed, {warned} with warnings, {len(problems)} static problem(s)")
    return 1 if failed or problems else 0


if __name__ == "__main__":
    sys.exit(main())
