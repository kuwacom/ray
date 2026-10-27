"""
リファクタの前後で、ドライバが作るプログラムが同じかを比べる (ゲームを使わずに「計算が変わっていない」ことを確かめる)

基準のコミットを git archive で tools/.cache/equiv/<sha>/ に展開し、作業ツリー (または --new のコミット) と
validate_shaders.py と同じ前処理を通して、同じ GL コンテキストで compile + link したバイナリを比べる
NVIDIA のバイナリには本文のハッシュ (コメントを変えても変わる 8 バイト) と、同じ本文でも変わる先頭近くの 2 バイトが入る
ハッシュは、基準の本文の末尾に毎回違うコメントを足してリンクし直し、元と違った位置を比べる対象から外す
先頭近くの 2 バイトは足し直しで見つからないことがあるので、位置を決めて外す (NV_NOISE_OFFSETS)

結果: プログラムごとに SAME / DIFF / ERROR / ONLY_BASE / ONLY_NEW。DIFF か ERROR があれば終了コード 1
前処理後の本文が両方で同じプログラムは、リンクせずに SAME とする (--always-link でリンクして比べる)

使い方:
    uv run tools/equiv_check.py                         # HEAD と作業ツリー、既定値 x world0
    uv run tools/equiv_check.py --full                  # 既定値 x 3 ディメンション + 全プロファイル (world0)
    uv run tools/equiv_check.py --base HEAD~3 --new HEAD
    uv run tools/equiv_check.py --text                  # バイナリの代わりに glslang -E の本文 (コメント・空行・#line を除く) を比べる
    uv run tools/equiv_check.py --layout                # SSBO のメンバーのオフセットと間隔を比べる
    uv run tools/equiv_check.py --gpu 1070 --filter deferred -v
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import difflib
import io
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gl_compile_check as gcc  # noqa: E402 - 前処理・GL の処理を使い回す
import validate_shaders as vs  # noqa: E402

GL = gcc.GL
EQUIV_DIR = vs.CACHE_DIR / "equiv"
# 基準に違うコメントを足して何回リンクし直すか。1 回だとハッシュのバイトが偶然同じ値になった位置を取りこぼす (1/256 ずつ)
SALT_COUNT = 3
# NVIDIA のバイナリの先頭近くで、同じ本文でも変わる 2 バイト。プロセスごとに違い、同じプロセスの中でも途中で 1 増えることがあるので、
# 足し直しでは見つけられないことがある (ディスクキャッシュから返ったバイナリは、作った時のプロセスの値を持つ)
NV_NOISE_OFFSETS = (68, 69)
COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)


@dataclass
class Tree:
    label: str
    shaders: Path
    options: dict[str, vs.Option]
    profiles: dict[str, list[str]]
    features: list[str]

    def activate(self) -> None:
        vs.set_shaders_dir(self.shaders)


def git(*args: str) -> str:
    proc = subprocess.run(["git", "-C", str(vs.ROOT), *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout.strip()


def extract(ref: str) -> tuple[Path, str]:
    """コミットの shaders/ を展開したフォルダ (展開済みなら使い回す) と短い sha"""
    sha = git("rev-parse", "--verify", f"{ref}^{{commit}}")
    dest = EQUIV_DIR / sha
    if not (dest / ".complete").exists():
        shutil.rmtree(dest, ignore_errors=True)
        data = subprocess.run(["git", "-C", str(vs.ROOT), "archive", "--format=tar", sha, "shaders"],
                              capture_output=True, check=True).stdout
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            tf.extractall(dest)  # noqa: S202 - 自分のリポジトリのコミットだけを展開する
        (dest / ".complete").write_text(ref, encoding="utf-8")
    return dest / "shaders", sha[:10]


def load_tree(label: str, shaders: Path) -> Tree:
    vs.set_shaders_dir(shaders)
    required, optional = vs.parse_features()
    return Tree(label, vs.SHADERS, vs.parse_settings(), vs.parse_profiles(), required + optional)


def programs(tree: Tree, cfg: str, world: str, flt: str) -> dict[str, list[gcc.StageSource]] | None:
    """設定 cfg で有効なプログラム -> 前処理したステージ。そのツリーに無いプロファイルなら None"""
    tree.activate()
    if cfg == "DEFAULT":
        ov: dict = {}
    elif cfg in tree.profiles:
        ov = vs.resolve_profile(cfg, tree.profiles)
    else:
        return None
    disabled = gcc.disabled_programs(gcc.preprocess_properties(gcc.effective_macros(ov, tree.options)))
    out: dict[str, list[gcc.StageSource]] = {}
    for pname, files in gcc.collect_programs(world, flt).items():
        if f"{world}/{pname.removesuffix('.csh')}" in disabled:
            continue
        stages = []
        for f in files:
            src, lm = vs.build_source(f, ov, tree.options, tree.features)
            stages.append(gcc.StageSource(f, vs.STAGE_OF_EXT[f.suffix], src, lm))
        out[f"{world}/{pname}"] = stages
    return out


def salted(stages: list[gcc.StageSource], salt: str) -> list[gcc.StageSource]:
    return [gcc.StageSource(s.path, s.stage, f"{s.source}// equiv-salt {salt}\n", s.linemap + [("<salt>", 0)]) for s in stages]


def same_source(a: list[gcc.StageSource], b: list[gcc.StageSource]) -> bool:
    return [(s.stage, s.source) for s in a] == [(s.stage, s.source) for s in b]


def normalize(pre: str) -> list[str]:
    """glslang -E の本文からコメント・空行・#line を除き、行内の空白をそろえる"""
    out = []
    for line in COMMENT_RE.sub("", pre).splitlines():
        line = " ".join(line.split())
        if line and not line.startswith("#line"):
            out.append(line)
    return out


class Linker:
    """
    # Linker
    本文ごとに 1 回だけリンクし、バイナリか SSBO の配置を取っておく

    ### 特徴
    - 1 つの設定の分をまとめて発行してから読む (並列コンパイル拡張があればドライバが並列に進める)
    - 同じ本文は実行の間ずっと使い回す (--full で設定が違っても本文が同じプログラムが多い)
    """

    def __init__(self, mode: str):
        self.mode = mode
        self.results: dict[str, tuple[bool, bytes | dict, list[str]]] = {}
        self.pending: dict[str, gcc.PendingLink] = {}

    def submit(self, stages: list[gcc.StageSource], side: str) -> str:
        # 側ごとに分けるのは、--always-link で同じ本文を別のリンクとして比べるため
        key = f"{side}:{gcc.run_key(stages)}"
        if key not in self.results and key not in self.pending:
            self.pending[key] = gcc.start_link(stages, "error", gcc.start_compiles(stages), retrievable=self.mode == "binary")
        return key

    def get(self, key: str) -> tuple[bool, bytes | dict, list[str]]:
        if key not in self.results:
            p = self.pending.pop(key)
            data: bytes | dict = b""
            if p.prog and GL.glGetProgramiv(p.prog, GL.GL_LINK_STATUS):
                data = gcc.program_binary(p.prog) if self.mode == "binary" else gcc.ssbo_layout(p.prog)
            res = gcc.finish_link(p, "error")
            self.results[key] = (res.ok, data, res.messages)
        return self.results[key]


def compare_binary(base: bytes, salts: list[bytes], new: bytes, noise: tuple[int, ...]) -> tuple[int, int, list[int]]:
    """(揺れるバイトを外した後の違うバイト数, 外したバイト数, 違う位置の先頭)"""
    b = np.frombuffer(base, np.uint8)
    mask = np.zeros(len(b), bool)
    mask[[i for i in noise if i < len(b)]] = True
    for s in salts:
        n = min(len(b), len(s))
        mask[:n] |= b[:n] != np.frombuffer(s, np.uint8)[:n]
        # 長さまで変わるなら位置で比べられないので、はみ出した分は全部外す
        mask[n:] |= len(s) != len(b)
    x = np.frombuffer(new, np.uint8)
    n = min(len(b), len(x))
    hits = (b[:n] != x[:n]) & ~mask[:n]
    return int(hits.sum()) + abs(len(b) - len(x)), int(mask.sum()), np.flatnonzero(hits)[:16].tolist()


def compare_layout(base: dict, new: dict) -> list[str]:
    lines = []
    for block in sorted(set(base) | set(new)):
        a, b = set(base.get(block, [])), set(new.get(block, []))
        lines += [f"{block}: base {r}" for r in sorted(a - b)] + [f"{block}: new  {r}" for r in sorted(b - a)]
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description="リファクタの前後でドライバのバイナリ・前処理後の本文・SSBO の配置を比べる")
    ap.add_argument("--base", default="HEAD", help="基準のコミット (既定 HEAD)")
    ap.add_argument("--new", default="", help="比べるコミット (既定: 作業ツリー)")
    ap.add_argument("--full", action="store_true", help="既定値 x 3 ディメンション + 全プロファイル (world0)")
    ap.add_argument("--profile", help="この設定だけ (カンマ区切り。DEFAULT で既定値)")
    ap.add_argument("--world", default="", help="ディメンション (カンマ区切り。既定 world0、--full の既定値は 3 つ)")
    ap.add_argument("--filter", default="", help="プログラム名にこの文字列を含むものだけ")
    ap.add_argument("--text", action="store_true", help="バイナリの代わりに前処理後の本文を比べる (GL を使わない)")
    ap.add_argument("--layout", action="store_true", help="バイナリの代わりに SSBO のメンバーのオフセットと間隔を比べる")
    ap.add_argument("--always-link", action="store_true", help="本文が同じプログラムもリンクして比べる (道具自体の確認用)")
    ap.add_argument("--gpu", default="", help="NVIDIA の描画 GPU を番号か名前の一部で選ぶ (例 1070)")
    ap.add_argument("-j", "--jobs", type=int, help="ドライバのコンパイルと glslang -E の並列数 (既定: CPU 数)")
    ap.add_argument("-v", "--verbose", action="store_true", help="SAME のプログラムも表示し、DIFF の中身を詳しく出す")
    args = ap.parse_args()
    if args.text and args.layout:
        sys.exit("--text と --layout は同時に使えない")
    mode = "text" if args.text else "layout" if args.layout else "binary"
    t_start = time.perf_counter()

    base_dir, base_sha = extract(args.base)
    if args.new:
        new_dir, new_sha = extract(args.new)
    else:
        new_dir, new_sha = vs.ROOT / "shaders", "worktree"
    work_shaders = vs.SHADERS
    base = load_tree(f"base {args.base} ({base_sha})", base_dir)
    new = load_tree(f"new {args.new or 'worktree'} ({new_sha})", new_dir)
    print(f"{base.label} -> {new.label}, mode {mode}")

    worlds = [w for w in args.world.split(",") if w]
    for w in worlds:
        if w not in vs.WORLDS:
            sys.exit(f"--world {w}: {', '.join(vs.WORLDS)} のどれか")
    configs: list[tuple[str, list[str]]] = []
    if args.profile:
        configs = [(p, worlds or ["world0"]) for p in args.profile.split(",")]
    elif args.full:
        configs.append(("DEFAULT", worlds or vs.WORLDS))
        names = list(base.profiles) + [p for p in new.profiles if p not in base.profiles]
        configs += [(p, ["world0"]) for p in names]
    else:
        configs.append(("DEFAULT", worlds or ["world0"]))

    win = None
    glslang = ""
    tmpdir = Path(tempfile.mkdtemp(prefix="ray_equiv_"))
    if mode == "text":
        glslang = vs.find_glslang()
    else:
        win = gcc.open_context(args.gpu)
        gcc.enable_parallel_compile(args.jobs)
        print(f"GL: {gcc.gl_string(GL.GL_RENDERER)} / {gcc.gl_string(GL.GL_VERSION)}")
    noise = NV_NOISE_OFFSETS if win is not None and "NVIDIA" in gcc.gl_string(GL.GL_VENDOR) else ()
    linker = Linker(mode)
    nonce = uuid.uuid4().hex[:12]
    counts = {k: 0 for k in ("SAME", "DIFF", "ERROR", "ONLY_BASE", "ONLY_NEW")}
    pair_cache: dict[tuple[str, str], tuple[str, list[str]]] = {}
    pre_cache: dict[str, list[str]] = {}

    def report(status: str, label: str, detail: list[str]) -> None:
        counts[status] += 1
        if status != "SAME" or args.verbose:
            print(f"{status:9s} {label}" + (f"  {detail[0]}" if detail else ""))
            for d in detail[1:] if args.verbose or status == "ERROR" else []:
                print(f"    {d}")

    def text_lines(stages: list[gcc.StageSource], ex: cf.ThreadPoolExecutor) -> list[str]:
        key = gcc.run_key(stages)
        if key not in pre_cache:
            futs = [ex.submit(gcc.glslang_preprocess, glslang, tmpdir, s, f"{key[:12]}_{i}") for i, s in enumerate(stages)]
            lines: list[str] = []
            for s, fu in zip(stages, futs):
                pre = fu.result()
                lines += [f"<{s.stage}>"] + (normalize(pre) if pre else ["<glslang -E failed>"])
            pre_cache[key] = lines
        return pre_cache[key]

    try:
        with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for cfg, cfg_worlds in configs:
                for world in cfg_worlds:
                    bp = programs(base, cfg, world, args.filter)
                    np_ = programs(new, cfg, world, args.filter)
                    if bp is None or np_ is None:
                        if bp is None and np_ is None:
                            print(f"[{cfg}] どちらのツリーにも無い設定")
                            continue
                        status = "ONLY_NEW" if bp is None else "ONLY_BASE"
                        n = len(np_ if bp is None else bp)
                        counts[status] += n
                        print(f"{status:9s} [{cfg}] {world}: 片方のツリーにだけある設定 ({n} programs)")
                        continue
                    names = sorted(set(bp) | set(np_))
                    todo: list[str] = []
                    for name in names:
                        label = f"[{cfg}] {name}"
                        if name not in np_:
                            report("ONLY_BASE", label, [])
                        elif name not in bp:
                            report("ONLY_NEW", label, [])
                        elif same_source(bp[name], np_[name]) and not args.always_link:
                            report("SAME", label, [])
                        else:
                            todo.append(name)
                    if mode == "text":
                        for name in todo:
                            a, b = text_lines(bp[name], ex), text_lines(np_[name], ex)
                            if a == b:
                                report("SAME", f"[{cfg}] {name}", [])
                                continue
                            diff = [d for d in difflib.unified_diff(a, b, "base", "new", n=0, lineterm="")
                                    if d[:1] in "+-" and not d.startswith(("+++", "---"))]
                            report("DIFF", f"[{cfg}] {name}", [f"{len(diff)} lines"] + diff[:20])
                        continue
                    # 1 つの設定の分をまとめて発行してから読む
                    keys: dict[str, tuple[str, list[str], str]] = {}
                    for name in todo:
                        salted_keys = []
                        if mode == "binary":
                            salted_keys = [linker.submit(salted(bp[name], f"{nonce}-{k}"), "salt") for k in range(SALT_COUNT)]
                        keys[name] = (linker.submit(bp[name], "base"), salted_keys, linker.submit(np_[name], "new"))
                    for name in todo:
                        label = f"[{cfg}] {name}"
                        bkey, skeys, nkey = keys[name]
                        if (bkey, nkey) not in pair_cache:
                            b_ok, b_data, b_msgs = linker.get(bkey)
                            n_ok, n_data, n_msgs = linker.get(nkey)
                            s_res = [linker.get(k) for k in skeys]
                            if not b_ok or not n_ok or not all(r[0] for r in s_res):
                                side = "base" if not b_ok else "new" if not n_ok else "salt"
                                msgs = b_msgs if not b_ok else n_msgs if not n_ok else next(r[2] for r in s_res if not r[0])
                                pair_cache[(bkey, nkey)] = ("ERROR", [f"{side} のリンクに失敗"] + msgs[:10])
                            elif mode == "binary":
                                diff, masked, where = compare_binary(b_data, [r[1] for r in s_res], n_data, noise)
                                info = f"{diff} bytes differ ({masked} masked, {len(b_data)} -> {len(n_data)} bytes)"
                                pair_cache[(bkey, nkey)] = ("DIFF", [info, f"offsets {where}"]) if diff else ("SAME", [info])
                            else:
                                rows = compare_layout(b_data, n_data)
                                pair_cache[(bkey, nkey)] = ("DIFF", [f"{len(rows)} rows"] + rows[:40]) if rows else ("SAME", [])
                        status, detail = pair_cache[(bkey, nkey)]
                        report(status, label, detail)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        vs.set_shaders_dir(work_shaders)
        if win is not None:
            for p in linker.pending.values():
                gcc.finish_link(p, "error")
            gcc.glfw.destroy_window(win)
            gcc.glfw.terminate()

    print("\n" + ", ".join(f"{v} {k}" for k, v in counts.items()) + f"  ({time.perf_counter() - t_start:.1f}s)")
    return 1 if counts["DIFF"] or counts["ERROR"] else 0


if __name__ == "__main__":
    sys.exit(main())
