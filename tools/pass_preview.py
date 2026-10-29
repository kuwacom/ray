"""
パスを手元の GPU で描いて (compute なら dispatch して) 結果を保存する。シェーダーを変えた直後に、そのパスだけを見るための道具

全画面の fragment パス (composite / deferred / final) と compute パス (.csh) を、プログラム名で渡した順に 1 回ずつ実行する
入力はダミー (灰色の画像・0 の SSBO・既定の uniform) で、見たい入力は --tex と --u で渡す。ゲームの撮影の代わりではなく、
「落ちずに動くか」「この入力ならこの出力か」を数秒で確かめるためのもの。gbuffers / shadow は頂点を与えないので描けない

- パスは world0/ の名前 (composite22)、`world-1/final` のようなフォルダ付きの名前、または .fsh / .csh のファイル
  (shaders/ の外の試験用ファイルでも `#include "/lib/..."` が使える)。vsh が無ければ全画面クアッドの頂点シェーダーを使う
- 複数のパスは出力を共有する。fragment パスの `/* RENDERTARGETS: 4,5 */` の出力は colortex4 / colortex5 に残り、後のパスの
  colortexN で読める。shaders.properties の `image.*` (名前・形式・大きさ・sampler 名) と `customTexture.*` (ノイズなどの実物) を
  既定の設定で読み、image と sampler は同じ画像を指す。それ以外の入力は灰色
- compute の dispatch は `workGroups` (リテラル) か `workGroupsRender` (画面に対する比) と local_size から求める
- 設定は --profile と --set で変える。保存先の既定は tools/.cache/pass_preview/ (--out で接頭辞を変える)

使い方:
    uv run tools/pass_preview.py composite22 --gpu 1070 --tex colortex0=shot.png --tex depthtex0=depth.npy
    uv run tools/pass_preview.py setup1 setup2 prepare prepare1 --save skyViewImg --set CLOUDS=0
    uv run tools/pass_preview.py my_pass.fsh --size 1920x1080 --u rainStrength=1 --frames 8 --out out/x
"""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from OpenGL.error import GLError
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gl_compile_check as gcc  # noqa: E402
import validate_shaders as vs  # noqa: E402
from lib.color import linear_to_srgb  # noqa: E402
from lib.paths import ROOT  # noqa: E402
from lib.properties import preprocess_properties  # noqa: E402

GL = gcc.GL
OUT_DIR = ROOT / "tools" / ".cache" / "pass_preview"
FULLSCREEN_VSH = "#version 460 compatibility\nout vec2 texcoord;\nvoid main() { gl_Position = ftransform(); texcoord = gl_MultiTexCoord0.xy; }\n"
IMAGE_DECL_RE = re.compile(r"layout\s*\(\s*(\w+)[^)]*\)\s*(?:\w+\s+)*?uniform\s+(?:\w+\s+)*?([iu]?image\w+)\s+(\w+)")
TARGETS_RE = re.compile(r"/\*\s*RENDERTARGETS:\s*([\d,]+)\s*\*/")
WORK_GROUPS_RE = re.compile(r"const\s+ivec3\s+workGroups\s*=\s*ivec3\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)")
WORK_GROUPS_RENDER_RE = re.compile(r"const\s+vec2\s+workGroupsRender\s*=\s*vec2\s*\(\s*([\d.]+)\s*,\s*([\d.]+)\s*\)")
GRAY = 0.5
INTEGER_FORMAT_RE = re.compile(r"\d(UI|I)$")


@dataclass
class State:
    """
    パスの間で受け渡すテクスチャ (名前 -> (target, id))。colortexN、image.* の名前、customTexture.* の sampler 名
    images: image 名 -> (sampler 名, 内部形式, 画面に対する比か, 大きさ)、custom: sampler 名 -> customTexture の値の語
    """
    w: int
    h: int
    images: dict[str, tuple[str, str, bool, tuple[float, ...]]]
    custom: dict[str, list[str]]
    tex: dict[str, tuple[int, int]] = field(default_factory=dict)
    written: list[str] = field(default_factory=list)
    unset: set[str] = field(default_factory=set)


def new_tex(target: int, ifmt: int, dims: tuple[int, ...], data: np.ndarray | bytes | None = None, fmt: int = 0, typ: int = 0,
            linear: bool = True, repeat: bool = False) -> int:
    t = GL.glGenTextures(1)
    GL.glBindTexture(target, t)
    GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 1)
    if len(dims) == 2:
        GL.glTexStorage2D(target, 1, ifmt, *dims)
        if data is not None:
            GL.glTexSubImage2D(target, 0, 0, 0, *dims, fmt, typ, data)
    else:
        GL.glTexStorage3D(target, 1, ifmt, *dims)
        if data is not None:
            GL.glTexSubImage3D(target, 0, 0, 0, 0, *dims, fmt, typ, data)
    for p in (GL.GL_TEXTURE_MIN_FILTER, GL.GL_TEXTURE_MAG_FILTER):
        GL.glTexParameteri(target, p, GL.GL_LINEAR if linear else GL.GL_NEAREST)
    for p in (GL.GL_TEXTURE_WRAP_S, GL.GL_TEXTURE_WRAP_T, GL.GL_TEXTURE_WRAP_R):
        GL.glTexParameteri(target, p, GL.GL_REPEAT if repeat else GL.GL_CLAMP_TO_EDGE)
    return t


def load_tex(path: Path) -> tuple[int, int]:
    """.png (RGBA8) または .npy (高さ x 幅 x チャンネル の float。RGBA32F) を読む。画像の上の行がテクスチャの上 (texcoord.y = 1)"""
    if path.suffix == ".npy":
        a = np.load(path).astype(np.float32)
        a = a[..., None] if a.ndim == 2 else a
        rgba = np.zeros((*a.shape[:2], 4), np.float32)
        rgba[..., :a.shape[2]] = a
        rgba[..., a.shape[2]:] = np.array([0, 0, 0, 1], np.float32)[a.shape[2]:]
        t = new_tex(GL.GL_TEXTURE_2D, GL.GL_RGBA32F, (rgba.shape[1], rgba.shape[0]), np.ascontiguousarray(rgba[::-1]), GL.GL_RGBA, GL.GL_FLOAT)
    else:
        im = np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)
        t = new_tex(GL.GL_TEXTURE_2D, GL.GL_RGBA8, (im.shape[1], im.shape[0]), np.ascontiguousarray(im[::-1]), GL.GL_RGBA, GL.GL_UNSIGNED_BYTE)
    return GL.GL_TEXTURE_2D, t


def load_custom(words: list[str]) -> tuple[int, int]:
    """customTexture.* の値 (`パス` か `パス ターゲット 内部形式 大きさ... 形式 型`) を読む。補間と端の扱いは隣の .mcmeta (無ければ最近傍・繰り返し)"""
    path = vs.SHADERS / words[0]
    meta = {"blur": False, "clamp": False}
    mc = path.with_name(path.name + ".mcmeta")
    if mc.exists():
        meta.update(json.loads(mc.read_text(encoding="utf-8")).get("texture", {}))
    opts = {"linear": bool(meta["blur"]), "repeat": not meta["clamp"]}
    if len(words) == 1:
        im = np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)
        return GL.GL_TEXTURE_2D, new_tex(GL.GL_TEXTURE_2D, GL.GL_RGBA8, (im.shape[1], im.shape[0]), im, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, **opts)
    target = getattr(GL, f"GL_{words[1]}")
    n = 3 if words[1] == "TEXTURE_3D" else 2
    dims = tuple(int(x) for x in words[3:3 + n])
    pfmt, typ = (getattr(GL, f"GL_{x}") for x in words[3 + n:5 + n])
    return target, new_tex(target, getattr(GL, f"GL_{words[2]}"), dims, path.read_bytes(), pfmt, typ, **opts)


def gray_tex(target: int, w: int, h: int) -> tuple[int, int]:
    if target == GL.GL_TEXTURE_3D:
        return target, new_tex(target, GL.GL_RGBA16F, (8, 8, 8), np.full((8, 8, 8, 4), GRAY, np.float32), GL.GL_RGBA, GL.GL_FLOAT)
    return target, new_tex(target, GL.GL_RGBA32F, (w, h), np.full((h, w, 4), GRAY, np.float32), GL.GL_RGBA, GL.GL_FLOAT)


def sun_vectors(world_time: int, rot: float) -> tuple[np.ndarray, float]:
    """worldTime 0 = 日の出 (東 +x)、6000 = 南中。MC の天体角は worldTime に対して非線形。sunPathRotation で z 軸まわりに傾ける"""
    t0 = (world_time / 24000.0 - 0.25) % 1.0
    celestial = t0 + ((1.0 - (math.cos(t0 * math.pi) + 1.0) / 2.0) - t0) / 3.0
    ang = celestial * 2 * math.pi
    sx, sy = -math.sin(ang), math.cos(ang)
    r = math.radians(rot)
    sun = np.array([sx, sy * math.cos(r), sy * math.sin(r)])
    return sun / np.linalg.norm(sun), (celestial + 0.25) % 1.0


def default_uniforms(a: argparse.Namespace, frame: int) -> dict[str, tuple[float, ...]]:
    sun, sun_angle = sun_vectors(a.time, a.rot)
    shadow = sun if sun[1] > 0 else -sun
    aspect = a.w / a.h
    f = 1.0 / math.tan(math.radians(a.fov) / 2)
    near, far = 0.05, 256.0
    proj = np.zeros((4, 4))
    proj[0, 0], proj[1, 1] = f / aspect, f
    proj[2, 2], proj[2, 3], proj[3, 2] = (far + near) / (near - far), 2 * far * near / (near - far), -1.0
    ident = np.identity(4)
    cam = (1234.5, 100.0, -567.25)
    mats = {
        "gbufferModelView": ident, "gbufferModelViewInverse": ident, "gbufferPreviousModelView": ident,
        "gbufferProjection": proj, "gbufferProjectionInverse": np.linalg.inv(proj), "gbufferPreviousProjection": proj,
    }
    # GL の行列は列優先
    out: dict[str, tuple[float, ...]] = {k: tuple(m.flatten("F")) for k, m in mats.items()}
    out.update({
        "cameraPosition": cam, "previousCameraPosition": cam, "sunPosition": tuple(sun * 100), "moonPosition": tuple(-sun * 100),
        "shadowLightPosition": tuple(shadow * 100), "upPosition": (0, 100, 0), "fogColor": (0.6, 0.7, 0.9), "skyColor": (0.5, 0.6, 1.0),
        "eyeAltitude": (cam[1],), "frameTimeCounter": (a.ftc + frame / 60.0,), "frameTime": (1 / 60,), "rainStrength": (0.0,),
        "wetness": (0.0,), "thunderStrength": (0.0,), "viewWidth": (float(a.w),), "viewHeight": (float(a.h),), "aspectRatio": (aspect,),
        "near": (near,), "far": (far,), "sunAngle": (sun_angle,), "worldTime": (a.time,), "worldDay": (0,), "frameCounter": (frame,),
        "moonPhase": (0,), "isEyeInWater": (0,), "heightLimit": (384,), "bedrockLevel": (-64,), "eyeBrightnessSmooth": (0, 240),
        "eyeBrightness": (0, 240),
    })
    for item in a.u:
        k, v = item.split("=", 1)
        out[k] = tuple(float(x) for x in v.split(","))
    return out


def set_uniform(loc: int, typ: int, v: tuple[float, ...]) -> None:
    ints = {GL.GL_INT: 1, GL.GL_BOOL: 1, GL.GL_UNSIGNED_INT: 1, GL.GL_INT_VEC2: 2, GL.GL_INT_VEC3: 3, GL.GL_INT_VEC4: 4}
    floats = {GL.GL_FLOAT: 1, GL.GL_FLOAT_VEC2: 2, GL.GL_FLOAT_VEC3: 3, GL.GL_FLOAT_VEC4: 4}
    if typ in ints and len(v) >= ints[typ]:
        (GL.glUniform1ui if typ == GL.GL_UNSIGNED_INT else getattr(GL, f"glUniform{ints[typ]}i"))(loc, *[int(x) for x in v[:ints[typ]]])
    elif typ in floats and len(v) >= floats[typ]:
        getattr(GL, f"glUniform{floats[typ]}f")(loc, *v[:floats[typ]])
    elif typ == GL.GL_FLOAT_MAT4 and len(v) == 16:
        GL.glUniformMatrix4fv(loc, 1, GL.GL_FALSE, np.array(v, np.float32))


def stage_sources(files: list[Path], overrides: dict, options: dict, features: list[str]) -> list[gcc.StageSource]:
    stages = []
    for f in files:
        src, lm = vs.build_source(f, overrides, options, features)
        stages.append(gcc.StageSource(f, vs.STAGE_OF_EXT[f.suffix], src, lm))
    if all(s.stage == "frag" for s in stages):
        stages.insert(0, gcc.StageSource(Path("<fullscreen>"), "vert", FULLSCREEN_VSH, [("<fullscreen>", 0)] * (FULLSCREEN_VSH.count("\n") + 1)))
    return stages


def find_files(arg: str, world: str) -> list[Path]:
    p = Path(arg)
    if p.suffix in (".fsh", ".csh") and p.exists():
        return [p.resolve()]
    base = arg if "/" in arg else f"{world}/{arg}"
    for ext in (".fsh", ".csh"):
        f = vs.SHADERS / f"{base}{ext}"
        if f.exists():
            return [f.with_suffix(".vsh"), f] if ext == ".fsh" and f.with_suffix(".vsh").exists() else [f]
    sys.exit(f"パスが見つからない: {arg} ({vs.SHADERS / base}.fsh / .csh)")


def link(stages: list[gcc.StageSource]) -> int:
    p = gcc.start_link(stages, "error")
    if p.prog and GL.glGetProgramiv(p.prog, GL.GL_LINK_STATUS):
        return p.prog
    msgs = p.msgs
    if p.prog:
        msgs += gcc.map_log(gcc._info_log(p.prog, True), stages[-1].stage, {s.stage: s for s in stages}, "error")
    sys.exit("\n".join(msgs) or "リンクに失敗 (log なし)")


def read_pack(overrides: dict, options: dict) -> tuple[dict, dict]:
    """shaders.properties の image.* と customTexture.* (#if は現在の設定で解く)。(images, custom) を State の形で返す"""
    images: dict[str, tuple[str, str, bool, tuple[float, ...]]] = {}
    custom: dict[str, list[str]] = {}
    for line in preprocess_properties(vs.PROPERTIES, gcc.effective_macros(overrides, options)):
        m = re.match(r"^\s*(image|customTexture)\.(\w+)\s*=\s*(.*)$", line)
        if not m:
            continue
        words = m.group(3).split()
        if m.group(1) == "image":
            images[m.group(2)] = (words[0], words[2], words[5] == "true", tuple(float(x) for x in words[6:]))
        else:
            custom[m.group(2)] = words
    return images, custom


def ensure_image(st: State, name: str, is3d: bool, decl_fmt: str, sizes: dict[str, tuple[int, ...]]) -> tuple[int, int, int]:
    """image の (target, id, 内部形式)。properties に無い image は shader の layout の形式、2D は画面、3D は 64^3"""
    spec = st.images.get(name)
    fmt = spec[1] if spec else decl_fmt.upper()
    ifmt = getattr(GL, f"GL_{fmt}", GL.GL_RGBA16F)
    if spec:
        dims = tuple(int(d * s) if spec[2] else int(d) for d, s in zip(spec[3], (st.w, st.h)))
    else:
        dims = (64, 64, 64) if is3d else (st.w, st.h)
    if name not in st.tex:
        target = GL.GL_TEXTURE_3D if len(dims) == 3 or is3d else GL.GL_TEXTURE_2D
        st.tex[name] = (target, new_tex(target, ifmt, sizes.get(name, dims), linear=not INTEGER_FORMAT_RE.search(fmt)))
    return (*st.tex[name], ifmt)


def bind_resources(prog: int, src: str, st: State, a: argparse.Namespace, frame: int) -> None:
    """uniform の値、sampler、image を割り当てる (まだ無い画像はここで作る)"""
    decls = {m.group(3): m.group(1) for m in IMAGE_DECL_RE.finditer(src)}
    sizes = {k: tuple(int(x) for x in v.split(",")) for k, v in (s.split("=", 1) for s in a.image_size)}
    values = default_uniforms(a, frame)
    unit = img_unit = 0
    for i in range(GL.glGetProgramiv(prog, GL.GL_ACTIVE_UNIFORMS)):
        raw, _, typ = GL.glGetActiveUniform(prog, i)
        name = (raw.decode() if isinstance(raw, bytes) else raw).removesuffix("[0]")
        loc = GL.glGetUniformLocation(prog, name)
        if loc < 0:
            continue
        is3d = typ in (GL.GL_IMAGE_3D, GL.GL_INT_IMAGE_3D, GL.GL_UNSIGNED_INT_IMAGE_3D,
                       GL.GL_SAMPLER_3D, GL.GL_INT_SAMPLER_3D, GL.GL_UNSIGNED_INT_SAMPLER_3D)
        if typ in gcc.IMAGE_TYPES:
            _, t, ifmt = ensure_image(st, name, is3d, decls.get(name, "rgba16f"), sizes)
            GL.glBindImageTexture(img_unit, t, 0, GL.GL_TRUE, 0, GL.GL_READ_WRITE, ifmt)
            GL.glUniform1i(loc, img_unit)
            img_unit += 1
        elif typ in gcc.SAMPLER_TYPES:
            key = next((img for img, spec in st.images.items() if spec[0] == name), name)
            if key in st.images:
                ensure_image(st, key, is3d, "rgba16f", sizes)
            elif name in st.custom and key not in st.tex:
                st.tex[key] = load_custom(st.custom[name])
            elif key not in st.tex:
                st.tex[key] = gray_tex(GL.GL_TEXTURE_3D if is3d else GL.GL_TEXTURE_2D, st.w, st.h)
                st.unset.add(name)
            GL.glActiveTexture(GL.GL_TEXTURE0 + unit)
            GL.glBindTexture(*st.tex[key])
            GL.glUniform1i(loc, unit)
            unit += 1
        elif name in values:
            set_uniform(loc, typ, values[name])
        elif not name.startswith("gl_"):
            st.unset.add(name)

def compute_groups(prog: int, src: str, w: int, h: int) -> tuple[int, int, int]:
    m = WORK_GROUPS_RE.search(src)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    local = (ctypes.c_int * 3)()
    GL.glGetProgramiv(prog, GL.GL_COMPUTE_WORK_GROUP_SIZE, local)
    m = WORK_GROUPS_RENDER_RE.search(src)
    rx, ry = (float(m.group(1)), float(m.group(2))) if m else (1.0, 1.0)
    return math.ceil(w * rx / local[0]), math.ceil(h * ry / local[1]), 1


def run_fragment(prog: int, src: str, st: State, runs: int) -> float:
    m = TARGETS_RE.search(src)
    targets = [int(x) for x in m.group(1).split(",")] if m else [0]
    # 出力は毎回新しいテクスチャへ描く (同じパスが読む colortex に書いても、読む側が壊れない。Iris の入れ替えと同じ)
    fresh = [new_tex(GL.GL_TEXTURE_2D, GL.GL_RGBA32F, (st.w, st.h)) for _ in targets]
    fbo = GL.glGenFramebuffers(1)
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo)
    for i, t in enumerate(fresh):
        GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0 + i, GL.GL_TEXTURE_2D, t, 0)
    GL.glDrawBuffers(len(targets), (GL.GLenum * len(targets))(*[GL.GL_COLOR_ATTACHMENT0 + i for i in range(len(targets))]))
    GL.glViewport(0, 0, st.w, st.h)
    st.written = [f"colortex{n}" for n in targets]

    def draw() -> None:
        GL.glBegin(GL.GL_TRIANGLES)
        for u, v in ((0, 0), (2, 0), (0, 2)):
            GL.glTexCoord2f(u, v)
            GL.glVertex2f(u * 2 - 1, v * 2 - 1)
        GL.glEnd()

    draw()
    GL.glFinish()
    t0 = time.perf_counter()
    for _ in range(runs):
        draw()
    GL.glFinish()
    elapsed = (time.perf_counter() - t0) / runs * 1000.0
    for n, t in zip(targets, fresh):
        if f"colortex{n}" in st.tex:
            GL.glDeleteTextures([st.tex[f"colortex{n}"][1]])
        st.tex[f"colortex{n}"] = (GL.GL_TEXTURE_2D, t)
    GL.glDeleteFramebuffers(1, [fbo])
    return elapsed


def read_tex(target: int, t: int) -> np.ndarray:
    GL.glBindTexture(target, t)
    a = np.frombuffer(GL.glGetTexImage(target, 0, GL.GL_RGBA, GL.GL_FLOAT), np.float32)
    w, h = GL.glGetTexLevelParameteriv(target, 0, GL.GL_TEXTURE_WIDTH), GL.glGetTexLevelParameteriv(target, 0, GL.GL_TEXTURE_HEIGHT)
    if target == GL.GL_TEXTURE_3D:
        return a.reshape(GL.glGetTexLevelParameteriv(target, 0, GL.GL_TEXTURE_DEPTH), h, w, 4)
    return a.reshape(h, w, 4)[::-1]


def save(name: str, arr: np.ndarray, prefix: Path, ev: float) -> None:
    prefix.parent.mkdir(parents=True, exist_ok=True)
    np.save(f"{prefix}_{name}.npy", arr.astype(np.float32))
    print(f"  {name}: {arr.shape} min {arr.min():.4g} mean {arr.mean():.4g} max {arr.max():.4g}")
    if arr.ndim == 3:
        x = linear_to_srgb(np.clip(arr[..., :3] * 2.0 ** ev, 0.0, 1.0), 1.0)
        Image.fromarray(np.round(x * 255).astype(np.uint8)).save(f"{prefix}_{name}.png")


def main() -> int:
    ap = argparse.ArgumentParser(description="パスを手元の GPU で描いて保存する (詳しくはファイルの先頭)")
    ap.add_argument("passes", nargs="+", help="パス名 (composite22 / world-1/final) か .fsh / .csh のファイル。複数なら順に実行する")
    ap.add_argument("--world", default="world0", help="フォルダ無しの名前を引くディメンション")
    ap.add_argument("--gpu", default="", help="描画 GPU (番号か名前の一部。ゲームを動かしていない GPU を選ぶ)")
    ap.add_argument("--size", default="960x540", help="画面の大きさ WxH")
    ap.add_argument("--profile", help="適用するプロファイル")
    ap.add_argument("--set", action="append", default=[], metavar="NAME=VALUE", help="設定の値 (ブールは on / off)")
    ap.add_argument("--tex", action="append", default=[], metavar="NAME=FILE", help="sampler に渡す画像 (.png / .npy)。NAME は colortex0 など")
    ap.add_argument("--u", action="append", default=[], metavar="NAME=V[,V...]", help="uniform の値 (行列は 16 個、列優先)")
    ap.add_argument("--image-size", action="append", default=[], metavar="NAME=W,H[,D]", help="image uniform の大きさ (既定 2D は画面、3D は 64^3)")
    ap.add_argument("--time", type=int, default=6000, help="worldTime")
    ap.add_argument("--rot", type=float, default=0.0, help="sunPathRotation")
    ap.add_argument("--fov", type=float, default=70.0, help="垂直の視野角")
    ap.add_argument("--ftc", type=float, default=100.0, help="frameTimeCounter の開始")
    ap.add_argument("--frames", type=int, default=1, help="全パスを繰り返す回数 (frameCounter が増える。時間方向の蓄積を進める)")
    ap.add_argument("--save", action="append", default=[], metavar="NAME", help="保存するテクスチャ (colortexN か image.* の名前)。既定は最後の fragment パスの出力")
    ap.add_argument("--ev", type=float, default=0.0, help="PNG の露出 (EV)")
    ap.add_argument("--out", type=Path, help="保存先の接頭辞 (既定 tools/.cache/pass_preview/<最後のパス>)")
    a = ap.parse_args()
    a.w, a.h = (int(x) for x in a.size.lower().split("x"))

    options = vs.parse_settings()
    req, opt = vs.parse_features()
    overrides: dict = vs.resolve_profile(a.profile, vs.parse_profiles()) if a.profile else {}
    for s in a.set:
        k, v = s.split("=", 1)
        overrides[k] = True if v == "on" else (False if v == "off" else v)

    win = gcc.open_context(a.gpu)
    st = State(a.w, a.h, *read_pack(overrides, options))
    runs = []
    for arg in a.passes:
        files = find_files(arg, a.world)
        stages = stage_sources(files, overrides, options, req + opt)
        runs.append((arg, stages[-1].source, link(stages), stages[-1].stage))
    for item in a.tex:
        k, v = item.split("=", 1)
        st.tex[k] = load_tex(Path(v))

    for i in range(9):
        buf = GL.glGenBuffers(1)
        GL.glBindBuffer(GL.GL_SHADER_STORAGE_BUFFER, buf)
        GL.glBufferData(GL.GL_SHADER_STORAGE_BUFFER, 4 << 20, None, GL.GL_DYNAMIC_DRAW)
        GL.glBindBufferBase(GL.GL_SHADER_STORAGE_BUFFER, i, buf)

    ms: dict[str, float] = {}
    for frame in range(a.frames):
        for arg, src, prog, stage in runs:
            GL.glUseProgram(prog)
            bind_resources(prog, src, st, a, frame)
            if stage == "comp":
                GL.glDispatchCompute(*compute_groups(prog, src, a.w, a.h))
                GL.glMemoryBarrier(GL.GL_ALL_BARRIER_BITS)
            else:
                ms[arg] = run_fragment(prog, src, st, 10 if frame == a.frames - 1 else 1)
            err = GL.glGetError()
            if err:
                print(f"[GL error] {arg}: 0x{err:x}")
    GL.glFinish()

    prefix = a.out or OUT_DIR / Path(a.passes[-1]).stem
    names = a.save or st.written
    for arg, t in ms.items():
        print(f"{arg}: {t:.3f} ms / draw at {a.w}x{a.h}")
    if st.unset:
        print("入力なし (灰色 / 0): " + " ".join(sorted(st.unset)))
    if not names:
        print("保存するものがない (compute だけのときは --save <image の名前> を渡す)")
    for name in names:
        if name not in st.tex:
            print(f"  {name}: 無い")
            continue
        try:
            save(name, read_tex(*st.tex[name]), prefix, a.ev)
        except GLError as e:
            print(f"  {name}: 読めない (整数形式の image は保存しない): {e}")
    gcc.glfw.destroy_window(win)
    gcc.glfw.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
