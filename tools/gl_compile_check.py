"""
実際の GPU ドライバ (OpenGL 4.6 compatibility コンテキスト) で全プログラムを compile + link する検証ツール

glslangValidator は仕様の文法しか見ないので、ドライバ固有の上限 (NVIDIA の「image uniform は 8 個まで」等) や
リンク時のエラーを取りこぼす。ここでは validate_shaders.py と同じ Iris 前処理の再現結果を
不可視ウィンドウの GL コンテキストで実際にコンパイルし、info log を元ファイルの行番号に戻して表示する

あわせて実機の上限値をダンプし、プログラムごとの使用数と比較する
- 宣言数 (glslang -E で前処理した本文から数える。NVIDIA は未使用でも宣言数で弾くことがある)
- アクティブ数 (リンク後のイントロスペクション。Iris はこれを image unit / texture unit に割り当てる)
- compute の local size / workGroups / shared メモリ、カスタムイメージのサイズ、SSBO のサイズ

使い方:
    uv run tools/gl_compile_check.py                    # 高速: 既定値 x world0 + 前回成功から変わったプログラムだけ
    uv run tools/gl_compile_check.py --full             # 既定値 x 3 ディメンション + 全プロファイル (world0)
    uv run tools/gl_compile_check.py --no-cache         # キャッシュ (tools/.cache/gl_compile.json) を使わない
    uv run tools/gl_compile_check.py --profile LOW      # 指定プロファイルのみ (DEFAULT で既定値)
    uv run tools/gl_compile_check.py --filter deferred  # プログラム名に文字列を含むものだけ
    uv run tools/gl_compile_check.py --gpu 1070         # 描画 GPU を選ぶ (ゲームを動かしていない GPU で回す)
    uv run tools/gl_compile_check.py --section shadow,gbuffers --world world-1  # プログラム名の先頭とディメンションで区切る
    uv run tools/gl_compile_check.py --full --section composite -j 4             # 全プロファイルを 1 セクションだけ、並列 4
    uv run tools/gl_compile_check.py --limits           # 上限値の一覧も表示
    uv run tools/gl_compile_check.py --report           # プログラムごとの使用数の表も表示
    uv run tools/gl_compile_check.py --all-programs     # program.*.enabled で無効なプログラムも検査する

必要なもの: glfw, PyOpenGL (uv sync で入る)
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_shaders as vs  # noqa: E402 - 同じディレクトリの前処理を再利用する

try:
    import glfw
    from OpenGL import GL
except ImportError:
    sys.exit("glfw / PyOpenGL が無い: リポジトリ直下で uv sync を実行し、uv run tools/gl_compile_check.py で起動する")

STAGE_ORDER = ["vert", "tesc", "tese", "geom", "frag", "comp"]
# --section の例示用 (実際の判定はプログラム名の前方一致なので dh_ や gbuffers_water なども指定できる)
SECTIONS = ["setup", "begin", "shadow", "prepare", "deferred", "composite", "final", "gbuffers"]
GL_STAGE = {
    "vert": GL.GL_VERTEX_SHADER,
    "tesc": GL.GL_TESS_CONTROL_SHADER,
    "tese": GL.GL_TESS_EVALUATION_SHADER,
    "geom": GL.GL_GEOMETRY_SHADER,
    "frag": GL.GL_FRAGMENT_SHADER,
    "comp": GL.GL_COMPUTE_SHADER,
}
STAGE_PREFIX = {"vert": "VERTEX", "tesc": "TESS_CONTROL", "tese": "TESS_EVALUATION", "geom": "GEOMETRY", "frag": "FRAGMENT", "comp": "COMPUTE"}
# リンク後の info log はステージごとに見出しが付く (NVIDIA)
LOG_HEADER = {"vertex info": "vert", "geometry info": "geom", "fragment info": "frag", "compute info": "comp",
              "tessellation control info": "tesc", "tessellation evaluation info": "tese"}
REFERENCED_BY = {
    "vert": GL.GL_REFERENCED_BY_VERTEX_SHADER,
    "tesc": GL.GL_REFERENCED_BY_TESS_CONTROL_SHADER,
    "tese": GL.GL_REFERENCED_BY_TESS_EVALUATION_SHADER,
    "geom": GL.GL_REFERENCED_BY_GEOMETRY_SHADER,
    "frag": GL.GL_REFERENCED_BY_FRAGMENT_SHADER,
    "comp": GL.GL_REFERENCED_BY_COMPUTE_SHADER,
}

# NVIDIA: "0(123) : error C1008: ..." / "(0) : error C7624: ..."、AMD/Intel: "ERROR: 0:123: ..."
NV_LOG_RE = re.compile(r"^\s*(\d*)\((\d+)\)\s*:\s*(error|warning)\s+(\w+)\s*:\s*(.*)$", re.I)
GENERIC_LOG_RE = re.compile(r"^\s*(ERROR|WARNING):\s*\d+:(\d+):\s*(.*)$", re.I)

# 前処理済み本文から数える宣言 (glslang -E の出力は 1 宣言 1 行に近いが、念のため ; 区切りで見る)
IMAGE_DECL_RE = re.compile(r"\buniform\s+(?:(?:coherent|volatile|restrict|readonly|writeonly|highp|mediump|lowp)\s+)*[iu]?image\w+\s+(\w+)")
SAMPLER_DECL_RE = re.compile(r"\buniform\s+(?:(?:highp|mediump|lowp)\s+)*[iu]?sampler\w+\s+(\w+)")
SSBO_DECL_RE = re.compile(r"\bbuffer\s+(\w+)\s*\{")
SHARED_DECL_RE = re.compile(r"^\s*shared\s+(\w+)\s+(\w+)\s*((?:\[[^\]]*\])*)\s*;", re.M)
LOCAL_SIZE_RE = re.compile(r"layout\s*\(([^)]*local_size_[xyz][^)]*)\)\s*in\s*;")
WORK_GROUPS_RE = re.compile(r"const\s+ivec3\s+workGroups\s*=\s*ivec3\s*\(([^)]*)\)")
PROP_IF_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b\s*(.*)$")

SCALAR_BYTES = {"float": 4, "int": 4, "uint": 4, "bool": 4, "double": 8,
                "vec2": 8, "ivec2": 8, "uvec2": 8, "vec3": 12, "ivec3": 12, "uvec3": 12,
                "vec4": 16, "ivec4": 16, "uvec4": 16, "mat2": 16, "mat3": 36, "mat4": 64}

LIMIT_NAMES = [
    "GL_MAX_IMAGE_UNITS", "GL_MAX_COMBINED_IMAGE_UNIFORMS",
    "GL_MAX_VERTEX_IMAGE_UNIFORMS", "GL_MAX_GEOMETRY_IMAGE_UNIFORMS", "GL_MAX_FRAGMENT_IMAGE_UNIFORMS", "GL_MAX_COMPUTE_IMAGE_UNIFORMS",
    "GL_MAX_TESS_CONTROL_IMAGE_UNIFORMS", "GL_MAX_TESS_EVALUATION_IMAGE_UNIFORMS",
    "GL_MAX_COMBINED_IMAGE_UNITS_AND_FRAGMENT_OUTPUTS",
    "GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS", "GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS",
    "GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS", "GL_MAX_GEOMETRY_SHADER_STORAGE_BLOCKS", "GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS",
    "GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS", "GL_MAX_SHADER_STORAGE_BLOCK_SIZE",
    "GL_MAX_TEXTURE_IMAGE_UNITS", "GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS", "GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS",
    "GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS", "GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS",
    "GL_MAX_COMPUTE_SHARED_MEMORY_SIZE", "GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS", "GL_MAX_COMPUTE_UNIFORM_COMPONENTS",
    "GL_MAX_VERTEX_UNIFORM_COMPONENTS", "GL_MAX_FRAGMENT_UNIFORM_COMPONENTS", "GL_MAX_GEOMETRY_UNIFORM_COMPONENTS",
    "GL_MAX_VERTEX_ATTRIBS", "GL_MAX_VARYING_COMPONENTS", "GL_MAX_VERTEX_OUTPUT_COMPONENTS", "GL_MAX_FRAGMENT_INPUT_COMPONENTS",
    "GL_MAX_GEOMETRY_OUTPUT_VERTICES", "GL_MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS", "GL_MAX_GEOMETRY_OUTPUT_COMPONENTS",
    "GL_MAX_DRAW_BUFFERS", "GL_MAX_COLOR_ATTACHMENTS", "GL_MAX_TEXTURE_SIZE", "GL_MAX_3D_TEXTURE_SIZE",
]
INDEXED_LIMITS = ["GL_MAX_COMPUTE_WORK_GROUP_SIZE", "GL_MAX_COMPUTE_WORK_GROUP_COUNT"]
# RTX 2080 Ti (ドライバ 581.57) の値。GTX 1070 (Pascal) は同じドライバでもこの 2 項目だけ 1536 と緩い
# (--limits で比較済み)。ドライバは緩い方の GPU では通してしまうので、上限との比較で拾う
TARGET_LIMITS: dict[str, int | tuple[int, ...]] = {
    "GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS": 1024,
    "GL_MAX_COMPUTE_WORK_GROUP_SIZE": (1024, 1024, 64),
}

# Iris が gbuffers / shadow で予約するテクスチャユニット数 (IrisSamplers.WORLD_RESERVED_TEXTURE_UNITS)
IRIS_WORLD_RESERVED_UNITS = 3
# Iris のカスタムイメージは 16 枚まで (ShaderProperties の image.*)
IRIS_MAX_CUSTOM_IMAGES = 16


def _gl_types(prefixes: list[str], kinds: list[str]) -> set[int]:
    out: set[int] = set()
    for p in prefixes:
        for k in kinds:
            v = getattr(GL, f"GL_{p}{k}", None)
            if v is not None:
                out.add(int(v))
    return out


IMAGE_TYPES = _gl_types(["IMAGE_", "INT_IMAGE_", "UNSIGNED_INT_IMAGE_"],
                        ["1D", "2D", "3D", "2D_RECT", "CUBE", "BUFFER", "1D_ARRAY", "2D_ARRAY", "CUBE_MAP_ARRAY", "2D_MULTISAMPLE", "2D_MULTISAMPLE_ARRAY"])
SAMPLER_TYPES = _gl_types(["SAMPLER_", "INT_SAMPLER_", "UNSIGNED_INT_SAMPLER_"],
                          ["1D", "2D", "3D", "CUBE", "1D_SHADOW", "2D_SHADOW", "1D_ARRAY", "2D_ARRAY", "1D_ARRAY_SHADOW", "2D_ARRAY_SHADOW",
                           "2D_MULTISAMPLE", "2D_MULTISAMPLE_ARRAY", "CUBE_SHADOW", "BUFFER", "2D_RECT", "2D_RECT_SHADOW", "CUBE_MAP_ARRAY", "CUBE_MAP_ARRAY_SHADOW"])


@dataclass
class StageSource:
    path: Path
    stage: str
    source: str
    linemap: list[tuple[str, int]]
    preprocessed: str = ""


@dataclass
class ProgramResult:
    ok: bool
    messages: list[str] = field(default_factory=list)
    usage: dict[str, int] = field(default_factory=dict)
    usage_problems: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# GL コンテキストと上限値
# ---------------------------------------------------------------------------

def nv_rendering_gpu(selector: str) -> tuple[str, str]:
    """
    NVIDIA の「OpenGL レンダリング GPU」と同じ指定文字列を NVAPI から組み立てる (selector は番号か名前の一部)
    GeForce は WGL_NV_gpu_affinity が無いが、ドライバは環境変数 OGL_DEFAULT_RENDERING_GPU
    (NvApiDriverSettings.h の OGL_IMPLICIT_GPU_AFFINITY_ENV_VAR) をプロファイル設定と同じ書式で読む
    書式: "id,2.0:<デバイスID><ベンダーID>,<バス<<8|スロット>,GF - (<arch>,<impl>,<rev>,<VRAM MB>) @ (0)"。全項目が一致しないと無視される
    """
    try:
        nv = ctypes.WinDLL("nvapi64")
    except OSError:
        sys.exit("--gpu は NVIDIA ドライバ (nvapi64.dll) が必要")
    qi = nv.nvapi_QueryInterface
    qi.restype, qi.argtypes = ctypes.c_void_p, [ctypes.c_uint]

    def fn(fid: int, *argtypes: object):
        return ctypes.CFUNCTYPE(ctypes.c_int, *argtypes)(qi(fid))

    vp, up = ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)
    fn(0x0150E828)()  # NvAPI_Initialize
    handles, count = (vp * 64)(), ctypes.c_uint()
    fn(0xE5AC921F, vp, up)(ctypes.cast(handles, vp), ctypes.byref(count))  # NvAPI_EnumPhysicalGPUs
    gpus = []
    for i in range(count.value):
        h = handles[i]
        name = ctypes.create_string_buffer(64)
        fn(0xCEEE8E9F, vp, ctypes.c_char_p)(h, name)  # NvAPI_GPU_GetFullName
        gpus.append((i, h, name.value.decode(errors="replace")))
    # "1070" のような数字の名前もあるので、GPU 数より小さい数字だけを番号として扱う
    by_index = selector.isdigit() and int(selector) < len(gpus)
    hits = [g for g in gpus if (by_index and g[0] == int(selector)) or (not by_index and selector.lower() in g[2].lower())]
    if len(hits) != 1:
        sys.exit(f"--gpu {selector} に一致する GPU が 1 つに決まらない: " + ", ".join(f"{i}={n}" for i, _, n in gpus))
    _, h, name = hits[0]
    bus, slot, fb = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
    fn(0x1BE0B8E5, vp, up)(h, ctypes.byref(bus))  # NvAPI_GPU_GetBusId
    fn(0x2A0A350F, vp, up)(h, ctypes.byref(slot))  # NvAPI_GPU_GetBusSlotId
    fn(0x46FBEB03, vp, up)(h, ctypes.byref(fb))  # NvAPI_GPU_GetPhysicalFrameBufferSize (KB)
    arch = (ctypes.c_uint * 4)(16 | (2 << 16), 0, 0, 0)  # NV_GPU_ARCH_INFO_V2
    fn(0xD8265D24, vp, vp)(h, ctypes.cast(arch, vp))  # NvAPI_GPU_GetArchInfo
    ids = [ctypes.c_uint() for _ in range(4)]
    fn(0x2DDFB66E, vp, up, up, up, up)(h, *(ctypes.byref(v) for v in ids))  # NvAPI_GPU_GetPCIIdentifiers
    brand = "GL" if any(k in name for k in ("Quadro", "RTX A", "NVIDIA RTX")) else "GF"
    spec = (f"id,2.0:{ids[0].value:08X},{(bus.value << 8) | slot.value:08X},{brand} - "
            f"({arch[1]},{arch[2]},{arch[3]},{round(fb.value / 1024)}) @ (0)")
    return spec, name


def create_context() -> object:
    if not glfw.init():
        sys.exit("glfw の初期化に失敗")
    glfw.window_hint(glfw.VISIBLE, glfw.FALSE)
    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 4)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 6)
    glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_COMPAT_PROFILE)
    win = glfw.create_window(64, 64, "ray gl_compile_check", None, None)
    if not win:
        glfw.terminate()
        sys.exit("OpenGL 4.6 compatibility コンテキストを作れない")
    glfw.make_context_current(win)
    return win


def query_limits() -> dict[str, int | tuple[int, ...]]:
    limits: dict[str, int | tuple[int, ...]] = {}
    for name in LIMIT_NAMES:
        enum = getattr(GL, name, None)
        if enum is None:
            continue
        try:
            limits[name] = int(GL.glGetIntegerv(enum))
        except Exception:  # noqa: BLE001 - 未対応の enum は飛ばす
            GL.glGetError()
    for name in INDEXED_LIMITS:
        enum = getattr(GL, name)
        vals = []
        for i in range(3):
            v = ctypes.c_int()
            GL.glGetIntegeri_v(enum, i, ctypes.byref(v))
            vals.append(v.value)
        limits[name] = tuple(vals)
    # 別 GPU (--gpu) の方が緩い項目は、ゲームを動かす GPU の値で判定する
    for name, target in TARGET_LIMITS.items():
        cur = limits.get(name)
        if isinstance(cur, tuple) and isinstance(target, tuple):
            limits[name] = tuple(min(a, b) for a, b in zip(cur, target))
        elif isinstance(cur, int) and isinstance(target, int):
            limits[name] = min(cur, target)
    return limits


def gl_string(enum: int) -> str:
    v = GL.glGetString(enum)
    return v.decode(errors="replace") if v else "?"


# ---------------------------------------------------------------------------
# shaders.properties の #if を評価して program.*.enabled = false を拾う (Iris と同じく無効なプログラムは読まれない)
# ---------------------------------------------------------------------------

def effective_macros(overrides: dict[str, str | bool], options: dict[str, vs.Option]) -> dict[str, str]:
    """設定の実効値 -> マクロ表 (ブール設定は定義の有無, 値設定は値)"""
    macros: dict[str, str] = {k: v for k, v in vs.IRIS_MACROS.items()}
    for name, opt in options.items():
        val = overrides.get(name, opt.default)
        if opt.kind == "bool":
            if val is True or val == "true":
                macros[name] = "1"
        else:
            macros[name] = str(val).rstrip("f") if re.fullmatch(r"-?[\d.]+f?", str(val)) else str(val)
    return macros


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


def preprocess_properties(macros: dict[str, str]) -> list[str]:
    """#if を解決した shaders.properties の論理行"""
    out: list[str] = []
    stack: list[tuple[bool, bool]] = []  # (この分岐が有効, いずれかの分岐を既に採った)
    active = True
    for line in vs.read_properties_logical_lines(vs.PROPERTIES):
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
    result: set[str] = set()
    for line in prop_lines:
        m = re.match(r"^\s*program\.(\S+)\.enabled\s*=\s*(\S+)", line)
        if m and m.group(2).lower() == "false":
            result.add(m.group(1))
    return result


# ---------------------------------------------------------------------------
# 前処理 (glslang -E) と宣言数
# ---------------------------------------------------------------------------

def glslang_preprocess(glslang: str | None, tmpdir: Path, src: StageSource, tag: str) -> str:
    if glslang is None:
        return ""
    safe = re.sub(r"[^\w.-]", "_", tag)
    tmp = tmpdir / f"{safe}.{src.stage}"
    tmp.write_text(src.source, encoding="utf-8")
    proc = subprocess.run([glslang, "-E", "-S", src.stage, str(tmp)], capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.stdout if proc.returncode == 0 else ""


def shared_bytes(pre: str, consts: dict[str, int]) -> int | None:
    total = 0
    for m in SHARED_DECL_RE.finditer(pre):
        size = SCALAR_BYTES.get(m.group(1))
        if size is None:
            return None
        for dim in re.findall(r"\[([^\]]*)\]", m.group(3)):
            dim = dim.strip()
            if dim.isdigit():
                size *= int(dim)
            elif dim in consts:
                size *= consts[dim]
            else:
                return None
        total += size
    return total


def int_consts(pre: str) -> dict[str, int]:
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"const\s+u?int\s+(\w+)\s*=\s*(\d+)u?\s*;", pre)}


# ---------------------------------------------------------------------------
# GL でのコンパイルとリンク
# ---------------------------------------------------------------------------

def map_log(log: str, default_stage: str, sources: dict[str, StageSource], level: str) -> list[str]:
    msgs: list[str] = []
    stage = default_stage
    for raw in log.splitlines():
        line = raw.strip()
        if not line:
            continue
        low = line.lower().rstrip(":")
        if low in LOG_HEADER:
            stage = LOG_HEADER[low]
            continue
        if set(line) <= {"-"}:
            continue
        m = NV_LOG_RE.match(line)
        if m:
            sev, code, text = m.group(3).lower(), m.group(4), m.group(5)
            if sev == "warning" and level != "warning":
                continue
            where = f"<{stage}>"
            src = sources.get(stage)
            if m.group(1) != "" and src is not None:
                idx = int(m.group(2)) - 1
                if 0 <= idx < len(src.linemap):
                    where = f"{src.linemap[idx][0]}:{src.linemap[idx][1]}"
            msgs.append(f"{sev} {where}: {code}: {text}")
            continue
        m = GENERIC_LOG_RE.match(line)
        if m:
            sev = m.group(1).lower()
            if sev == "warning" and level != "warning":
                continue
            src = sources.get(stage)
            idx = int(m.group(2)) - 1
            where = f"{src.linemap[idx][0]}:{src.linemap[idx][1]}" if src and 0 <= idx < len(src.linemap) else f"<{stage}>"
            msgs.append(f"{sev} {where}: {m.group(3)}")
            continue
        if "error" in low:
            msgs.append(f"error <{stage}>: {line}")
        elif level == "warning":
            msgs.append(f"info <{stage}>: {line}")
    return msgs


def _info_log(obj: int, is_program: bool) -> str:
    log = GL.glGetProgramInfoLog(obj) if is_program else GL.glGetShaderInfoLog(obj)
    if isinstance(log, bytes):
        return log.decode(errors="replace")
    return log or ""


def _resource_props(prog: int, interface: int, index: int, props: list[int]) -> list[int]:
    p = (ctypes.c_uint * len(props))(*props)
    out = (ctypes.c_int * len(props))()
    length = ctypes.c_int()
    GL.glGetProgramResourceiv(prog, interface, index, len(props), p, len(props), ctypes.byref(length), out)
    return list(out)


def _active_count(prog: int, interface: int) -> int:
    v = ctypes.c_int()
    GL.glGetProgramInterfaceiv(prog, interface, GL.GL_ACTIVE_RESOURCES, ctypes.byref(v))
    return v.value


def introspect(prog: int, stages: list[str]) -> dict[str, int]:
    usage: dict[str, int] = {}
    images = samplers = 0
    stage_props = [REFERENCED_BY[s] for s in stages]
    for i in range(_active_count(prog, GL.GL_UNIFORM)):
        vals = _resource_props(prog, GL.GL_UNIFORM, i, [GL.GL_TYPE, GL.GL_ARRAY_SIZE, GL.GL_BLOCK_INDEX] + stage_props)
        typ, arr, block = vals[0], max(vals[1], 1), vals[2]
        if block != -1:
            continue
        if typ in IMAGE_TYPES:
            images += arr
            for s, ref in zip(stages, vals[3:]):
                if ref:
                    usage[f"activeImages.{s}"] = usage.get(f"activeImages.{s}", 0) + arr
        elif typ in SAMPLER_TYPES:
            samplers += arr
            for s, ref in zip(stages, vals[3:]):
                if ref:
                    usage[f"activeSamplers.{s}"] = usage.get(f"activeSamplers.{s}", 0) + arr
    usage["activeImages"] = images
    usage["activeSamplers"] = samplers
    ssbo = _active_count(prog, GL.GL_SHADER_STORAGE_BLOCK)
    usage["activeSSBO"] = ssbo
    max_binding = -1
    for i in range(ssbo):
        binding, size = _resource_props(prog, GL.GL_SHADER_STORAGE_BLOCK, i, [GL.GL_BUFFER_BINDING, GL.GL_BUFFER_DATA_SIZE])
        max_binding = max(max_binding, binding)
        usage[f"ssboSize.{binding}"] = size
    usage["maxSSBOBinding"] = max_binding
    if "comp" in stages:
        ls = (ctypes.c_int * 3)()
        GL.glGetProgramiv(prog, GL.GL_COMPUTE_WORK_GROUP_SIZE, ls)
        usage["localSizeX"], usage["localSizeY"], usage["localSizeZ"] = ls[0], ls[1], ls[2]
    return usage


def enable_parallel_compile(jobs: int | None = None) -> bool:
    """
    GL_KHR_parallel_shader_compile でドライバのコンパイルスレッドを使う
    glCompileShader がすぐ返るので、先に全部発行してから結果を順に読むと CPU コア数ぶん並列に進む
    jobs を指定するとスレッド数を絞る (ゲーム起動中に CPU を食い合わないように)。1 なら逐次
    """
    if jobs == 1:
        return False
    try:
        from OpenGL.GL.KHR import parallel_shader_compile as khr
        if not khr.glInitParallelShaderCompileKHR():
            return False
        khr.glMaxShaderCompilerThreadsKHR(jobs or 0xFFFFFFFF)
        return True
    except Exception:  # noqa: BLE001 - 拡張が無ければ逐次で動かす
        GL.glGetError()
        return False


def start_compiles(stages: list[StageSource]) -> list[int]:
    """コンパイルを発行だけする (結果は compile_and_link が読む)"""
    shaders = []
    for s in stages:
        sh = GL.glCreateShader(GL_STAGE[s.stage])
        GL.glShaderSource(sh, s.source)
        GL.glCompileShader(sh)
        shaders.append(sh)
    return shaders


@dataclass
class PendingLink:
    stages: list[StageSource]
    shaders: list[int]
    prog: int  # 0 ならコンパイルに失敗してリンクしていない
    msgs: list[str]


def start_link(stages: list[StageSource], level: str, started: list[int] | None = None) -> PendingLink:
    """
    コンパイル結果を読んでリンクを発行だけする (結果は finish_link が読む)
    NVIDIA は最適化とコード生成をリンク時に行うので、ここが重い。並列コンパイル拡張があれば
    glLinkProgram はすぐ返るので、全部発行してから結果を読むとリンクも並列に進む
    """
    by_stage = {s.stage: s for s in stages}
    shaders: list[int] = []
    msgs: list[str] = []
    ok = True
    started = started or start_compiles(stages)
    for s, sh in zip(stages, started):
        status = GL.glGetShaderiv(sh, GL.GL_COMPILE_STATUS)
        msgs += map_log(_info_log(sh, False), s.stage, by_stage, level)
        if not status:
            ok = False
            if not any(m.startswith("error") for m in msgs):
                msgs.append(f"error <{s.stage}>: コンパイル失敗 (log なし)")
        shaders.append(sh)
    prog = 0
    if ok:
        prog = GL.glCreateProgram()
        for sh in shaders:
            GL.glAttachShader(prog, sh)
        GL.glLinkProgram(prog)
    return PendingLink(stages, shaders, prog, msgs)


def finish_link(p: PendingLink, level: str) -> ProgramResult:
    by_stage = {s.stage: s for s in p.stages}
    ok = p.prog != 0
    usage: dict[str, int] = {}
    if p.prog:
        if not GL.glGetProgramiv(p.prog, GL.GL_LINK_STATUS):
            ok = False
            link_msgs = map_log(_info_log(p.prog, True), p.stages[-1].stage, by_stage, level)
            p.msgs += [f"link: {m}" for m in link_msgs] or ["link: error (log なし)"]
        else:
            usage = introspect(p.prog, [s.stage for s in p.stages])
        GL.glDeleteProgram(p.prog)
    for sh in p.shaders:
        GL.glDeleteShader(sh)
    return ProgramResult(ok, p.msgs, usage)


def compile_and_link(stages: list[StageSource], level: str, started: list[int] | None = None) -> ProgramResult:
    return finish_link(start_link(stages, level, started), level)


# ---------------------------------------------------------------------------
# 上限との比較 (静的チェック)
# ---------------------------------------------------------------------------

def check_usage(name: str, stages: list[StageSource], res: ProgramResult, limits: dict, buffer_sizes: dict[int, int]) -> list[str]:
    problems: list[str] = []
    u = res.usage
    # GLSL のブロックが shaders.properties の bufferObject.N より大きいと範囲外アクセスになる
    for key, size in list(u.items()):
        if not key.startswith("ssboSize."):
            continue
        binding = int(key.split(".")[1])
        alloc = buffer_sizes.get(binding)
        if alloc is None:
            problems.append(f"SSBO binding {binding} に対応する bufferObject.{binding} が shaders.properties に無い")
        elif size > alloc:
            problems.append(f"SSBO binding {binding} のブロック {size} bytes > bufferObject.{binding} = {alloc}")
    declared_images_total = 0
    for s in stages:
        pre = s.preprocessed
        if not pre:
            continue
        prefix = STAGE_PREFIX[s.stage]
        n_img = len(set(IMAGE_DECL_RE.findall(pre)))
        n_smp = len(set(SAMPLER_DECL_RE.findall(pre)))
        n_ssbo = len(set(SSBO_DECL_RE.findall(pre)))
        declared_images_total += n_img
        u[f"declImages.{s.stage}"] = n_img
        u[f"declSamplers.{s.stage}"] = n_smp
        u[f"declSSBO.{s.stage}"] = n_ssbo
        lim = limits.get(f"GL_MAX_{prefix}_IMAGE_UNIFORMS")
        if isinstance(lim, int) and n_img > lim:
            problems.append(f"{s.stage}: image uniform の宣言 {n_img} > GL_MAX_{prefix}_IMAGE_UNIFORMS {lim}")
        lim = limits.get(f"GL_MAX_{prefix}_SHADER_STORAGE_BLOCKS")
        if isinstance(lim, int) and n_ssbo > lim:
            problems.append(f"{s.stage}: SSBO の宣言 {n_ssbo} > GL_MAX_{prefix}_SHADER_STORAGE_BLOCKS {lim}")
        if s.stage == "comp":
            consts = int_consts(pre)
            sh = shared_bytes(pre, consts)
            if sh is not None:
                u["sharedBytes"] = sh
                lim = limits.get("GL_MAX_COMPUTE_SHARED_MEMORY_SIZE")
                if isinstance(lim, int) and sh > lim:
                    problems.append(f"comp: shared {sh} bytes > GL_MAX_COMPUTE_SHARED_MEMORY_SIZE {lim}")
            wg = WORK_GROUPS_RE.search(pre)
            if wg:
                counts = [int(x) for x in re.findall(r"\d+", wg.group(1))]
                maxc = limits.get("GL_MAX_COMPUTE_WORK_GROUP_COUNT")
                if isinstance(maxc, tuple):
                    for axis, (c, m) in enumerate(zip(counts, maxc)):
                        if c > m:
                            problems.append(f"comp: workGroups[{axis}] {c} > GL_MAX_COMPUTE_WORK_GROUP_COUNT {m}")
    u["declImages"] = declared_images_total
    if res.ok:
        lim = limits.get("GL_MAX_IMAGE_UNITS")
        if isinstance(lim, int) and u.get("activeImages", 0) > lim:
            problems.append(f"アクティブな image {u['activeImages']} > GL_MAX_IMAGE_UNITS {lim} (Iris が image unit を割り当てられない)")
        lim = limits.get("GL_MAX_COMBINED_IMAGE_UNIFORMS")
        if isinstance(lim, int) and u.get("activeImages", 0) > lim:
            problems.append(f"アクティブな image {u['activeImages']} > GL_MAX_COMBINED_IMAGE_UNIFORMS {lim}")
        lim = limits.get("GL_MAX_TEXTURE_IMAGE_UNITS")
        is_world = name.split("/")[-1].startswith(("gbuffers_", "shadow"))
        if isinstance(lim, int):
            avail = lim - (IRIS_WORLD_RESERVED_UNITS if is_world else 0)
            if u.get("activeSamplers", 0) > avail:
                problems.append(f"アクティブな sampler {u['activeSamplers']} > Iris で使えるテクスチャユニット {avail}")
        lim = limits.get("GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS")
        if isinstance(lim, int) and u.get("maxSSBOBinding", -1) >= lim:
            problems.append(f"SSBO binding {u['maxSSBOBinding']} >= GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS {lim}")
        if "localSizeX" in u:
            inv = u["localSizeX"] * u["localSizeY"] * u["localSizeZ"]
            u["localInvocations"] = inv
            lim = limits.get("GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS")
            if isinstance(lim, int) and inv > lim:
                problems.append(f"local size の積 {inv} > GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS {lim}")
            lim = limits.get("GL_MAX_COMPUTE_WORK_GROUP_SIZE")
            ls = (u["localSizeX"], u["localSizeY"], u["localSizeZ"])
            if isinstance(lim, tuple) and any(a > b for a, b in zip(ls, lim)):
                problems.append(f"local size {ls} > GL_MAX_COMPUTE_WORK_GROUP_SIZE {lim}")
    return problems


def buffer_object_sizes(prop_lines: list[str]) -> dict[int, int]:
    sizes: dict[int, int] = {}
    for ln in prop_lines:
        m = re.match(r"^\s*bufferObject\.(\d+)\s*=\s*(\d+)", ln)
        if m:
            sizes[int(m.group(1))] = int(m.group(2))
    return sizes


def check_properties(prop_lines: list[str], limits: dict) -> list[str]:
    """カスタムイメージ・SSBO・影マップの解像度を上限と比べる"""
    problems: list[str] = []
    images = [ln for ln in prop_lines if re.match(r"^\s*image\.\w+\s*=", ln)]
    if len(images) > IRIS_MAX_CUSTOM_IMAGES:
        problems.append(f"カスタムイメージ {len(images)} 枚 > Iris の上限 {IRIS_MAX_CUSTOM_IMAGES}")
    for ln in images:
        key, val = ln.split("=", 1)
        parts = val.split()
        if len(parts) < 7 or parts[5] == "true":
            continue
        dims = [int(x) for x in parts[6:]]
        lim = limits.get("GL_MAX_3D_TEXTURE_SIZE" if len(dims) == 3 else "GL_MAX_TEXTURE_SIZE")
        if isinstance(lim, int) and max(dims) > lim:
            problems.append(f"{key.strip()}: サイズ {dims} > 上限 {lim}")
    lim = limits.get("GL_MAX_SHADER_STORAGE_BLOCK_SIZE")
    for ln in prop_lines:
        m = re.match(r"^\s*bufferObject\.(\d+)\s*=\s*(\d+)", ln)
        if m and isinstance(lim, int) and int(m.group(2)) > lim:
            problems.append(f"bufferObject.{m.group(1)} = {m.group(2)} > GL_MAX_SHADER_STORAGE_BLOCK_SIZE {lim}")
    return problems


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def run_key(stages: list[StageSource]) -> str:
    # 前処理後の本文が同じなら結果も同じなので 1 回の実行の中で使い回す (設定差分が効かないプログラムが多い)
    key_src = "\0".join(s.stage + (s.preprocessed or s.source) for s in stages)
    return hashlib.sha1(key_src.encode()).hexdigest()


def collect_programs(world: str, flt: str, sections: list[str] | None = None) -> dict[str, list[Path]]:
    progs: dict[str, list[Path]] = {}
    for f in sorted((vs.SHADERS / world).glob("*")):
        if f.suffix not in vs.STAGE_OF_EXT or flt not in f.stem:
            continue
        if sections and not any(f.stem.startswith(s) for s in sections):
            continue
        progs.setdefault(f.stem if f.suffix != ".csh" else f"{f.stem}.csh", []).append(f)
    for files in progs.values():
        files.sort(key=lambda p: STAGE_ORDER.index(vs.STAGE_OF_EXT[p.suffix]))
    return progs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", help="このプロファイルだけ (DEFAULT で既定値。カンマ区切りで複数)")
    ap.add_argument("--filter", default="", help="プログラム名にこの文字列を含むものだけ")
    ap.add_argument("--section", default="", help=f"プログラム名の先頭で区切る (カンマ区切り。例 {','.join(SECTIONS)})")
    ap.add_argument("--world", default="", help="ディメンションを指定 (カンマ区切り。例 world-1,world1。--full の DEFAULT 以外は既定 world0)")
    ap.add_argument("--gpu", default="", help="NVIDIA の描画 GPU を番号か名前の一部で選ぶ (例 1070。ゲームと別の GPU で回す)")
    ap.add_argument("-j", "--jobs", type=int, help="glslang -E とドライバのコンパイルの並列数 (既定: CPU 数。1 で逐次)")
    ap.add_argument("--full", action="store_true", help="既定値 x 3 ディメンション + 全プロファイル")
    ap.add_argument("--quick", action="store_true", help="既定値 x world0 のみ (既定の動作。互換のため残す)")
    ap.add_argument("--no-cache", action="store_true", help="前回成功したものも含めて全部リンクし直す")
    ap.add_argument("--limits", action="store_true", help="上限値の一覧を表示")
    ap.add_argument("--report", action="store_true", help="プログラムごとの使用数を表示")
    ap.add_argument("--warnings", action="store_true", help="ドライバの警告も表示")
    ap.add_argument("--all-programs", action="store_true", help="program.*.enabled で無効なプログラムも検査")
    args = ap.parse_args()
    level = "warning" if args.warnings else "error"

    options = vs.parse_settings()
    profiles = vs.parse_profiles()
    required, optional = vs.parse_features()
    features = required + optional
    try:
        glslang: str | None = vs.find_glslang()
    except SystemExit:
        glslang = None
        print("[warn] glslangValidator が無いので宣言数のチェックを省略する")

    gpu_name = ""
    if args.gpu:
        # ICD はコンテキスト作成時に読み込まれるので、それより前に環境変数を置けば効く
        os.environ["OGL_DEFAULT_RENDERING_GPU"], gpu_name = nv_rendering_gpu(args.gpu)
    win = create_context()
    limits = query_limits()
    parallel = enable_parallel_compile(args.jobs)
    print(f"GL: {gl_string(GL.GL_VENDOR)} / {gl_string(GL.GL_RENDERER)} / {gl_string(GL.GL_VERSION)}")
    if gpu_name and not gl_string(GL.GL_RENDERER).startswith(gpu_name):
        glfw.terminate()
        sys.exit(f"--gpu {args.gpu}: {gpu_name} を指定したがドライバが別の GPU でコンテキストを作った")
    if args.limits:
        for k, v in limits.items():
            print(f"  {k:52s} {v}")

    sections = [s for s in args.section.split(",") if s]
    worlds_opt = [w for w in args.world.split(",") if w]
    for w in worlds_opt:
        if w not in vs.WORLDS:
            sys.exit(f"--world {w}: {', '.join(vs.WORLDS)} のどれか")
    configs: list[tuple[str, dict, list[str]]] = []
    if args.profile:
        for p in args.profile.split(","):
            configs.append((p, {} if p == "DEFAULT" else vs.resolve_profile(p, profiles), worlds_opt or ["world0"]))
    elif args.full:
        configs.append(("DEFAULT", {}, worlds_opt or vs.WORLDS))
        for p in profiles:
            configs.append((p, vs.resolve_profile(p, profiles), ["world0"]))
    else:
        configs.append(("DEFAULT", {}, worlds_opt or ["world0"]))

    tmpdir = Path(tempfile.mkdtemp(prefix="ray_glcheck_"))
    cache: dict[str, ProgramResult] = {}
    persist = vs.SuccessCache("gl_compile", enabled=not args.no_cache)
    driver_id = f"{gl_string(GL.GL_RENDERER)} {gl_string(GL.GL_VERSION)}"
    glslang_id = vs.tool_version(glslang) if glslang else "-"
    failed = checked = skipped = persisted = 0
    static_problems: list[str] = []
    seen_static: set[str] = set()
    report_rows: list[tuple[str, dict[str, int]]] = []

    try:
        for cfg_name, ov, worlds in configs:
            macros = effective_macros(ov, options)
            prop_lines = preprocess_properties(macros)
            disabled = disabled_programs(prop_lines)
            buffer_sizes = buffer_object_sizes(prop_lines)
            for p in check_properties(prop_lines, limits):
                if p not in seen_static:
                    seen_static.add(p)
                    static_problems.append(f"[{cfg_name}] {p}")

            for world in worlds:
                progs = collect_programs(world, args.filter, sections)
                # glslang -E はプロセス起動が重いので並列に回す。前回成功した入力のプログラムは -E も省く
                stage_jobs: dict[tuple[str, int], StageSource] = {}
                persist_keys: dict[str, str] = {}
                with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
                    futures = {}
                    for pname, files in progs.items():
                        prog_key = f"{world}/{pname.removesuffix('.csh')}"
                        if prog_key in disabled and not args.all_programs:
                            continue
                        srcs = []
                        for i, f in enumerate(files):
                            src, lm = vs.build_source(f, ov, options, features)
                            ss = StageSource(f, vs.STAGE_OF_EXT[f.suffix], src, lm)
                            stage_jobs[(pname, i)] = ss
                            srcs.append(ss.stage + ss.source)
                        # 結果は本文・プログラム名 (予約ユニットの判定)・SSBO サイズ・ドライバ・警告レベルで決まる
                        pk = vs.SuccessCache.key(driver_id, glslang_id, level, prog_key, json.dumps(buffer_sizes, sort_keys=True), *srcs)
                        persist_keys[pname] = pk
                        if persist.get(pk) is not None:
                            continue
                        for i in range(len(files)):
                            ss = stage_jobs[(pname, i)]
                            futures[ex.submit(glslang_preprocess, glslang, tmpdir, ss, f"{cfg_name}_{world}_{ss.path.name}")] = ss
                    for fut, ss in futures.items():
                        ss.preprocessed = fut.result()

                # 検証が必要なプログラムのコンパイルを先に全部発行する (並列コンパイル拡張があればドライバが並列に進める)
                started: dict[str, tuple[list[StageSource], list[int]]] = {}
                if parallel:
                    for pname, files in progs.items():
                        prog_key = f"{world}/{pname.removesuffix('.csh')}"
                        if (prog_key in disabled and not args.all_programs) or persist.get(persist_keys[pname]) is not None:
                            continue
                        stages = [stage_jobs[(pname, i)] for i in range(len(files))]
                        k = run_key(stages)
                        if k not in cache and k not in started:
                            started[k] = (stages, start_compiles(stages))
                # リンクも先に全部発行する (コンパイル待ちの間も先のリンクが裏で進む)
                linking = {k: start_link(stages, level, shs) for k, (stages, shs) in started.items()}

                for pname, files in progs.items():
                    prog_key = f"{world}/{pname.removesuffix('.csh')}"
                    if prog_key in disabled and not args.all_programs:
                        skipped += 1
                        continue
                    hit = persist.get(persist_keys[pname])
                    if hit is not None:
                        checked += 1
                        persisted += 1
                        cache[persist_keys[pname]] = ProgramResult(True, usage=hit)
                        continue
                    stages = [stage_jobs[(pname, i)] for i in range(len(files))]
                    key = run_key(stages)
                    res = cache.get(key)
                    if res is None:
                        pend = linking.pop(key, None)
                        res = finish_link(pend, level) if pend else compile_and_link(stages, level)
                        res.usage_problems = check_usage(prog_key, stages, res, limits, buffer_sizes)
                        cache[key] = res
                    checked += 1
                    label = f"[{cfg_name}] {prog_key} ({'+'.join(s.stage for s in stages)})"
                    if args.report:
                        report_rows.append((label, res.usage))
                    errors = [m for m in res.messages if "error" in m.split(":")[0] or m.startswith("link")]
                    if not res.ok or errors:
                        failed += 1
                        print(f"FAIL {label}")
                        for m in res.messages[:20]:
                            print(f"    {m}")
                    elif res.messages:
                        print(f"WARN {label}")
                        for m in res.messages[:10]:
                            print(f"    {m}")
                    elif not res.usage_problems:
                        persist.put(persist_keys[pname], res.usage)
                    for p in res.usage_problems:
                        sp = f"{label}: {p}"
                        if sp not in seen_static:
                            seen_static.add(sp)
                            static_problems.append(sp)
                for pend in linking.values():
                    finish_link(pend, level)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        glfw.destroy_window(win)
        glfw.terminate()
    persist.save()

    if args.report:
        cols = ["declImages", "activeImages", "activeSamplers", "activeSSBO", "localInvocations", "sharedBytes"]
        print("\n" + f"{'program':64s} " + " ".join(f"{c:>16s}" for c in cols))
        for label, u in report_rows:
            print(f"{label:64s} " + " ".join(f"{str(u.get(c, '-')):>16s}" for c in cols))

    for p in static_problems:
        print(f"[static] {p}")
    max_decl = max((r.usage.get("declImages", 0) for r in cache.values()), default=0)
    max_act = max((r.usage.get("activeImages", 0) for r in cache.values()), default=0)
    max_smp = max((r.usage.get("activeSamplers", 0) for r in cache.values()), default=0)
    print(f"\n最大使用数: image 宣言 {max_decl} / アクティブ image {max_act} (GL_MAX_IMAGE_UNITS {limits.get('GL_MAX_IMAGE_UNITS')}) / "
          f"アクティブ sampler {max_smp} (GL_MAX_TEXTURE_IMAGE_UNITS {limits.get('GL_MAX_TEXTURE_IMAGE_UNITS')})")
    print(f"{checked} programs linked ({len(cache)} unique, {persisted} unchanged, cached), {failed} failed, {skipped} disabled skipped, {len(static_problems)} static problem(s)")
    return 1 if failed or static_problems else 0


if __name__ == "__main__":
    sys.exit(main())
