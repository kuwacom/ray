"""
Iris の前処理を簡易再現して glslangValidator で全プログラムをコンパイル検証する

再現している内容
- `#include "/..."` の絶対パス解決 (shaders/ 起点, 再帰)。ガード付きのファイルの 2 回目以降の include は差し込まない
  (Iris は毎回差し込むが、前処理の後の本文は同じ。膨らんだ本文を glslang やドライバに渡すと遅い)
- 設定 (#define / const) の値の差し替え。プロファイル (shaders.properties の profile.*) を適用可能
- Iris が自動定義するマクロ (MC_VERSION, IS_IRIS, MC_RENDER_STAGE_*, IRIS_FEATURE_* 等) の注入
- エラー行を元のファイル名・行番号へ戻して表示

あわせて静的チェックも行う
- //@include の宣言の漏れ (使う記号の定義元を宣言しているか)、宣言の循環・書き方、lib のガード名 (tools/include_deps.py)
- 本体の #include の生成ブロックが最新か (tools/gen_includes.py)
- プロファイルが参照する設定が lib/settings/ に存在するか
- ラッパー (shaders/world*) と shaders.properties の program.*.enabled の生成が最新か、止める条件の設定が存在するか (tools/gen_wrappers.py)
- lang (en_US / ja_JP) に全設定・全画面のラベルがあるか
- shaders.properties の screen に全設定が載っているか
- 能力の生成物 (tools/gen_capabilities.py) が最新か、MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS を生成物の外で使っていないか、
  RENDERTARGETS のカンマの後に空白が無いか

ローダー (tools/capabilities.py の ENVS: latest / mid / 1.7.6) ごとに、マクロを変えてコンパイルし、次も調べる (tools/loader_checks.py)
- iris.features.required の flag、bufferObject の添字、image の数、image と customTexture の形式の列挙
- 前処理の後に有効なプログラムが colortex の上限以上を使っていないか (今は警告。COLORTEX_LIMIT_STRICT か --strict-colortex で失敗)

使い方:
    uv run tools/validate_shaders.py                    # 高速: 既定値・world0 のみ + 前回成功から変わったものだけ
    uv run tools/validate_shaders.py --full             # 既定値 + 全プロファイル (world0) + 既定値 (world-1, world1)
    uv run tools/validate_shaders.py --profile HIGH     # 指定プロファイルのみ
    uv run tools/validate_shaders.py --filter deferred  # ファイル名に文字列を含むものだけ
    uv run tools/validate_shaders.py --no-cache         # キャッシュを使わず全部コンパイルし直す
    uv run tools/validate_shaders.py --shaders <dir>    # 別のフォルダのシェーダーを検証する
    uv run tools/validate_shaders.py --env 1.7.6        # このローダーだけ (既定は ENVS の全部)
    uv run tools/validate_shaders.py --colortex-report <path>   # colortex の上限を超える使用の一覧を書く

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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_slots  # noqa: E402
import gen_block_properties  # noqa: E402
import gen_capabilities  # noqa: E402
import gen_includes  # noqa: E402
import gen_settings  # noqa: E402
import gen_wrappers  # noqa: E402
import include_deps  # noqa: E402
import loader_checks  # noqa: E402
from capabilities import ENVS, Env  # noqa: E402
from gen_settings import CONST_RE, DEFINE_RE, Option  # noqa: E402
from lib.paths import ROOT, SHADERS  # noqa: E402
from lib.properties import disabled_programs, read_properties_logical_lines, resolve_profile  # noqa: E402


PROPERTIES = SHADERS / "shaders.properties"
LANG_FILES = [SHADERS / "lang" / "en_US.lang", SHADERS / "lang" / "ja_JP.lang"]
WORLDS = ["world0", "world-1", "world1"]

STAGE_OF_EXT = {".vsh": "vert", ".fsh": "frag", ".gsh": "geom", ".csh": "comp", ".tcs": "tesc", ".tes": "tese"}


def set_shaders_dir(path: Path) -> None:
    """
    ### set_shaders_dir
    検証するシェーダーのフォルダを差し替える (別のコミットを展開したツリーなどを、このリポジトリのツールで検証するため)
    include の展開のキャッシュは絶対パスがキーなので、ツリーを行き来しても混ざらない。キャッシュ (tools/.cache) の場所は変えない

    @param path - shaders.properties を含むフォルダ
    """
    global SHADERS, PROPERTIES, LANG_FILES
    SHADERS = Path(path).resolve()
    PROPERTIES = SHADERS / "shaders.properties"
    LANG_FILES = [SHADERS / "lang" / "en_US.lang", SHADERS / "lang" / "ja_JP.lang"]

# Iris が定義するレンダーステージのマクロ (値は検証用の仮の連番)
RENDER_STAGES = [
    "NONE", "SKY", "SUNSET", "CUSTOM_SKY", "SUN", "MOON", "STARS", "VOID", "TERRAIN_SOLID",
    "TERRAIN_CUTOUT_MIPPED", "TERRAIN_CUTOUT", "ENTITIES", "BLOCK_ENTITIES", "DESTROY", "OUTLINE",
    "DEBUG", "HAND_SOLID", "TERRAIN_TRANSLUCENT", "TRIPWIRE", "PARTICLES", "CLOUDS", "RAIN_SNOW",
    "WORLD_BORDER", "HAND_TRANSLUCENT",
]

# バージョンで変わるマクロ (MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS) は capabilities.ENVS のローダーごとに入れる
IRIS_MACROS = {
    "MC_GL_VERSION": "460",
    "MC_GLSL_VERSION": "460",
    "IS_IRIS": "",
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
ERROR_RE = re.compile(r"^(ERROR|WARNING): 0:(\d+): (.*)$")


def parse_settings() -> dict[str, Option]:
    """lib/settings/ から設定項目を拾う (解析は gen_settings.py)"""
    return gen_settings.parse_settings(SHADERS)


def parse_profiles() -> dict[str, list[str]]:
    return gen_settings.parse_profiles(SHADERS)


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

GUARD_IFNDEF_RE = re.compile(r"^\s*#\s*ifndef\s+(\w+)\s*(?://.*)?$")
COND_OPEN_RE = re.compile(r"^\s*#\s*if(?:n?def)?\b")
COND_CLOSE_RE = re.compile(r"^\s*#\s*endif\b")


@functools.lru_cache(maxsize=None)
def include_target(parent: Path, target: str) -> Path:
    inc = SHADERS / target.lstrip("/") if target.startswith("/") else parent / target
    return inc.resolve()


def _outside_guard_ok(lines: tuple[str, ...]) -> bool:
    """ガードの外の行が空行かコメントだけか (外に本文があると、2 回目以降を省くと消えてしまう)"""
    in_block = False
    for ln in lines:
        s = ln.strip()
        if in_block:
            in_block = "*/" not in s
            continue
        if not s or s.startswith("//"):
            continue
        if s.startswith("/*"):
            in_block = "*/" not in s[2:]
            continue
        return False
    return True


@functools.lru_cache(maxsize=None)
def include_guard(path: Path) -> str | None:
    """
    ### include_guard
    ファイル全体を囲むインクルードガード (`#ifndef X` / `#define X` ... 最後の `#endif`) のマクロ名

    @param path - 調べるファイル
    @returns ガードのマクロ名。ガードが無い・外に本文がある・途中でガードの #if が閉じる場合は None
    """
    lines = read_lines(path)
    idx = [i for i, ln in enumerate(lines) if ln.lstrip().startswith("#")]
    if len(idx) < 3:
        return None
    m = GUARD_IFNDEF_RE.match(lines[idx[0]])
    if not m or not re.match(rf"^\s*#\s*define\s+{m.group(1)}\b", lines[idx[1]]) or not COND_CLOSE_RE.match(lines[idx[-1]]):
        return None
    depth = 0
    for i in idx[:-1]:
        if COND_OPEN_RE.match(lines[i]):
            depth += 1
        elif COND_CLOSE_RE.match(lines[i]):
            depth -= 1
            if depth == 0:
                return None
    if not _outside_guard_ok(lines[:idx[0]]) or not _outside_guard_ok(lines[idx[-1] + 1:]):
        return None
    return m.group(1)


def _expand_unit(path: Path, done: set[Path], unconditional: bool, out: list[str], linemap: list[tuple[str, int]]) -> None:
    """
    ### _expand_unit
    1 つのプログラム (翻訳単位) の中で、ファイルを include 込みで展開する

    Iris の include 展開はガードを見ずに毎回全部を差し込むので、lib が自分の依存を include すると本文が数十倍に膨らむ
    (前処理の後はガードで同じ本文になる)。glslang やドライバに膨らんだ本文を渡すと遅いので、ガード付きのファイルの
    2 回目以降の include は差し込まない。条件付き (#if の中) で初めて読んだファイルは、その条件が偽ならガードが立たないので、
    条件なしで展開したファイルだけを「展開済み」にする

    @param path - 展開するファイル
    @param done - この翻訳単位で、条件なしで展開済みのガード付きファイル
    @param unconditional - この include に至る経路がすべて条件なしか
    @param out - 展開した行の出力先
    @param linemap - 各行の (元ファイル, 行番号) の出力先
    """
    if path in _EXPANDING:
        raise RuntimeError(f"include cycle: {path}")
    if not path.exists():
        raise FileNotFoundError(path)
    guard = include_guard(path)
    if guard and path in done:
        return
    if guard and unconditional:
        done.add(path)
    _EXPANDING.add(path)
    try:
        try:
            rel = path.relative_to(SHADERS).as_posix()
        except ValueError:
            rel = path.name  # shaders/ の外の試験用ファイル (tools/pass_preview.py に渡したもの)
        # ガードの #ifndef の中は条件なしと同じ (初めての展開ではガードは必ず真)
        base = 1 if guard else 0
        depth = 0
        for i, line in enumerate(read_lines(path), 1):
            if "#" in line:
                if COND_OPEN_RE.match(line):
                    depth += 1
                elif COND_CLOSE_RE.match(line):
                    depth -= 1
            m = INCLUDE_RE.match(line) if "include" in line else None
            if m:
                _expand_unit(include_target(path.parent, m.group(1)), done, unconditional and depth <= base, out, linemap)
                continue
            out.append(line)
            linemap.append((rel, i))
    finally:
        _EXPANDING.discard(path)


def expand_file(path: Path) -> tuple[tuple[str, ...], tuple[tuple[str, int], ...]]:
    """1 ファイルを翻訳単位の起点として include 込みで展開する (ガード付きのファイルは 1 回だけ差し込む)"""
    out: list[str] = []
    linemap: list[tuple[str, int]] = []
    _expand_unit(path, set(), True, out, linemap)
    return tuple(out), tuple(linemap)


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

def build_source(wrapper: Path, overrides: dict[str, str | bool], options: dict[str, Option], features: list[str],
                 env: Env = ENVS[0]) -> tuple[str, list[tuple[str, int]]]:
    raw, raw_map, candidates = expanded(wrapper)
    linemap = list(raw_map)
    lines = apply_overrides(list(raw), overrides, options, candidates)
    assert lines[0].startswith("#version"), f"{wrapper}: 1 行目が #version ではない"
    inject = [f"#define {k} {v}".rstrip() for k, v in {**IRIS_MACROS, **env.macros}.items()]
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
                cache: SuccessCache | None = None, glslang_id: str = "", env: Env = ENVS[0]) -> tuple[str, list[str], str | None]:
    """戻り値: (表示名, メッセージ, 成功時に記録するキャッシュキー。キャッシュから返した時と失敗時は None)"""
    label = f"[{env.name}/{cfg_name}] {wrapper.relative_to(SHADERS).as_posix()}"
    try:
        src, linemap = build_source(wrapper, overrides, options, features, env)
    except Exception as e:  # noqa: BLE001 - 前処理の失敗はそのまま報告する
        return label, [f"preprocess: {e}"], None
    stage = STAGE_OF_EXT[wrapper.suffix]
    key = SuccessCache.key(glslang_id, stage, src)
    if cache is not None and cache.get(key) is not None:
        return label, [], None
    safe = re.sub(r"[^\w.-]", "_", f"{env.name}_{cfg_name}_{wrapper.parent.name}_{wrapper.stem}")
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


_SCAN_STATE: dict[str, tuple[dict[str, Option], list[str]]] = {}


def scan_one(shaders: str, wrapper: str, cfg_name: str, overrides: dict, env_name: str) -> tuple[str, loader_checks.ScanResult]:
    """
    ### scan_one
    1 プログラムのローダーの検査 (loader_checks.program_scan)。前処理の評価は Python で重いので、別のプロセスで回す

    @returns (表示名, 結果)
    """
    if Path(shaders) != SHADERS:
        set_shaders_dir(Path(shaders))
    if shaders not in _SCAN_STATE:
        req, opt = parse_features()
        _SCAN_STATE[shaders] = (parse_settings(), req + opt)
    options, features = _SCAN_STATE[shaders]
    env = next(e for e in ENVS if e.name == env_name)
    path = Path(wrapper)
    src, linemap = build_source(path, overrides, options, features, env)
    return f"[{env.name}/{cfg_name}]", loader_checks.program_scan(env, cfg_name, f"{path.parent.name}/{path.name}", src, linemap)


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
    problems += include_deps.Tree(SHADERS).problems()
    problems += gen_includes.check(SHADERS)
    problems += gen_wrappers.check(SHADERS)
    problems += check_slots.check(SHADERS)
    problems += gen_settings.check(SHADERS)
    problems += gen_settings.definition_problems(SHADERS)
    problems += gen_block_properties.check(SHADERS)
    problems += gen_capabilities.check(SHADERS)
    problems += loader_checks.rendertargets_spacing(SHADERS)
    problems += loader_checks.direct_loader_macros(SHADERS)
    for pname in profiles:
        for k, v in resolve_profile(pname, profiles).items():
            opt = options.get(k)
            if opt is None:
                problems.append(f"profile.{pname}: 未定義の設定 {k}")
            # Iris は値を文字列で値リストと比べる
            elif opt.kind != "bool" and opt.values and v not in opt.values:
                problems.append(f"profile.{pname}: {k}={v} が値リストにない")
    # 素の既定値は HIGH と一致させる方針 (docs/architecture.md)
    if "HIGH" in profiles:
        for k, v in resolve_profile("HIGH", profiles).items():
            opt = options.get(k)
            if opt is None:
                continue
            default = opt.default
            same = (v is True) == default if opt.kind == "bool" else v == default
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


# colortex の上限 (Iris 1.10.4 以前と Oculus は 16 枚) を超える使用を失敗にするか。今は再配置の前なので警告で一覧を出す
# 再配置が終わったら True にする (--strict-colortex でも切り替えられる)
COLORTEX_LIMIT_STRICT = False


def properties_by_loader(env: Env, cfg_name: str, ov: dict, options: dict[str, Option]) -> tuple[set[str], list[str], list[loader_checks.ColortexUse]]:
    """
    ### properties_by_loader
    1 つのローダーと設定の組で shaders.properties を前処理して調べる (tools/loader_checks.py)

    @returns (読まれないプログラム `world0/shadow_entities` の形。properties で止めたものと、能力が無くて読まれないもの,
              問題, 上限を超える colortex の項目)
    """
    macros = {**IRIS_MACROS, **env.macros, **loader_checks.settings_macros(options, ov)}
    props = loader_checks.preprocessed_properties(SHADERS, macros)
    skipped = disabled_programs(props) | {f"{w}/{p}" for w in WORLDS for p in loader_checks.missing_programs(env)}
    problems = [f"[{env.name}/{cfg_name}] {p}" for p in loader_checks.properties_problems(env, props)]
    return skipped, problems, loader_checks.properties_colortex(env, cfg_name, props)


def colortex_rows(uses: list[loader_checks.ColortexUse]) -> list[tuple[str, int, str, str, list[str], list[str]]]:
    """(ローダー, 番号, 種類, 場所) ごとにまとめた行 (使うプログラムと設定の組の一覧付き)"""
    grouped: dict[tuple[str, int, str, str], tuple[set[str], set[str]]] = {}
    for u in uses:
        progs, cfgs = grouped.setdefault((u.env, u.index, u.kind, u.where), (set(), set()))
        progs.add(u.program)
        cfgs.add(u.config)
    def order(k: tuple[str, int, str, str]):
        file, _, line = k[3].rpartition(":")
        return (k[0], k[1], k[2], file, int(line) if line.isdigit() else 0)

    return [(*k, sorted(grouped[k][0]), sorted(grouped[k][1])) for k in sorted(grouped, key=order)]


def write_colortex_report(path: Path, rows, envs: list[Env], configs: list[tuple[str, dict, list[str]]]) -> None:
    out = ["# colortex の上限を超える使用", "",
           "`uv run tools/validate_shaders.py --colortex-report <path>` が書く一覧。前処理の後に有効なプログラムだけを数える"
           " (sampler の宣言だけの行は数えない。種類の「指定」は colortexN の Format / Clear / ClearColor / MipmapEnabled)", "",
           "設定の組: " + ", ".join(f"{name} ({' '.join(worlds)})" for name, _, worlds in configs), ""]
    for env in envs:
        sel = [r for r in rows if r[0] == env.name]
        out += [f"## {env.name} (colortex {env.colortex_count} 枚。{env.note})", ""]
        if not sel:
            out += ["なし", ""]
            continue
        out += [f"{len(sel)} 件。番号ごとの件数: " + ", ".join(f"colortex{n} {sum(1 for r in sel if r[1] == n)}" for n in sorted({r[1] for r in sel})), ""]
        out += ["| colortex | 種類 | 場所 | プログラム | 設定 |", "|---|---|---|---|---|"]
        for _, n, kind, where, progs, cfgs in sel:
            shown = ", ".join(progs[:6]) + (f" ほか {len(progs) - 6}" if len(progs) > 6 else "")
            out.append(f"| {n} | {kind} | `{where}` | {shown} | {', '.join(cfgs)} |")
        out.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", help="このプロファイルだけ検証する (DEFAULT で既定値)")
    ap.add_argument("--filter", default="", help="ファイル名にこの文字列を含むものだけ")
    ap.add_argument("--full", action="store_true", help="既定値 x 3 ディメンション + 全プロファイル")
    ap.add_argument("--quick", action="store_true", help="既定値 x world0 のみ (既定の動作。互換のため残す)")
    ap.add_argument("--no-cache", action="store_true", help="前回成功したものも含めて全部コンパイルする")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--shaders", type=Path, help="検証するシェーダーのフォルダ (既定: このリポジトリの shaders/)")
    ap.add_argument("--env", help="このローダーだけ検証する (カンマ区切り。tools/capabilities.py の ENVS の名前)")
    ap.add_argument("--strict-colortex", action="store_true", help="colortex の上限を超える使用を失敗にする")
    ap.add_argument("--colortex-report", type=Path, help="colortex の上限を超える使用の一覧を Markdown で書く")
    args = ap.parse_args()
    if args.shaders:
        set_shaders_dir(args.shaders)
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

    envs = ENVS
    if args.env:
        names = args.env.split(",")
        envs = [e for e in ENVS if e.name in names]
        if len(envs) != len(names):
            sys.exit(f"--env: 未知のローダー (候補: {', '.join(e.name for e in ENVS)})")

    jobs = []
    tmpdir = Path(tempfile.mkdtemp(prefix="ray_glsl_"))
    glslang_id = tool_version(glslang)
    cached = 0
    loader: dict[str, str] = {}  # 同じ文面は最初の組だけ出す (文面 -> 表示)
    uses: list[loader_checks.ColortexUse] = []
    scans = []
    # glslang はプロセスとして起動するのでスレッドから呼べば CPU コア数だけ並列に走る。ローダーの検査は Python の処理なので別のプロセスで回す
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex, cf.ProcessPoolExecutor(max_workers=args.jobs) as px:
        for env in envs:
            for cfg_name, ov, worlds in configs:
                skipped, props_problems, props_uses = properties_by_loader(env, cfg_name, ov, options)
                for p in props_problems:
                    loader.setdefault(p.split("] ", 1)[1], p)
                uses += props_uses
                for w in worlds:
                    for f in sorted((SHADERS / w).glob("*")):
                        if f.suffix not in STAGE_OF_EXT or args.filter not in f.name:
                            continue
                        jobs.append(ex.submit(compile_one, glslang, tmpdir, f, cfg_name, ov, options, features, cache, glslang_id, env))
                        if f"{w}/{f.stem}" not in skipped:
                            scans.append(px.submit(scan_one, str(SHADERS), str(f), cfg_name, ov, env.name))
        for fut in cf.as_completed(scans):
            tag, (found, msgs) = fut.result()
            uses += found
            for p in msgs:
                loader.setdefault(p, f"{tag} {p}")
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
        for p in loader.values():
            print(f"[loader] {p}")
        problems += list(loader.values())
        rows = colortex_rows(uses)
        strict = COLORTEX_LIMIT_STRICT or args.strict_colortex
        # 上限が同じローダーでは同じ箇所が並ぶので、ローダーの名前をまとめて 1 行にする
        merged: dict[tuple[int, str, str], list[str]] = {}
        for env_name, n, kind, where, _, _ in rows:
            merged.setdefault((n, kind, where), []).append(env_name)
        for (n, kind, where), env_names in merged.items():
            msg = f"colortex{n} を{kind} {where} ({', '.join(env_names)})"
            print(f"[colortex] {msg}" if strict else f"[warn colortex] {msg}")
            if strict:
                problems.append(msg)
        if merged and not strict:
            print(f"[warn colortex] {len(merged)} 箇所 (再配置の前なので警告。--strict-colortex で失敗にする)")
        if args.colortex_report:
            write_colortex_report(args.colortex_report, rows, envs, configs)
    shutil.rmtree(tmpdir, ignore_errors=True)
    cache.save()
    print(f"\n{len(jobs)} compiled ({cached} unchanged, cached), {failed} failed, {warned} with warnings, {len(problems)} static problem(s)")
    return 1 if failed or problems else 0


if __name__ == "__main__":
    sys.exit(main())
