"""
# ab_scene
設定や版の違いを、同じ場面に立ったまま撮り比べる。場面の準備 (tp・召喚・待ち) を 1 回にし、
版ごとに再読み込みだけをして撮る。揺れの基準 (同じ版の 2 回の差)、前後の差、比較シートを 1 回で出す

### 使い方
- uv run tools/ab_scene.py noon cave_torch --variant base= --variant gi0=GI_MODE=0 --tag gi --out <dir>
- uv run tools/ab_scene.py noon --variant old=dir:<パックのフォルダ> --variant new=dir:<フォルダ> --fps 4
- --variant 名前=指定。指定は空 (始めの Ray.txt のまま)、KEY=V,KEY=V (始めの Ray.txt に上書き)、
  dir:<フォルダ> (shaderpacks/Ray のジャンクションの先を替える。終わったら戻す)、dir:<フォルダ>;KEY=V,KEY=V の組み合わせ
  (区切りの ; と , はどちらでもよい。フォルダに ; と , は使えない。PowerShell では --variant の値を引用符で囲む)
- 版ごとに Ray.txt を全部書き直し、再読み込みの後に Iris が書き直した Ray.txt を読んで、上書きが残っているか確かめる
  (残っていなければ警告。パックに無い設定か不正な値)
- 順番は 1 周目が並べた順、2 周目が逆順 (A B B A)。時間とともに変わるもの (温度・フレームの時間) の偏りを打ち消す
- 撮影は <game>/screenshots/<tag>_<シーン>_<版><周>.png。--out に report.md (差の表・frame_ms・時間) と sheet_<シーン>.jpg

### 揺れの基準
- 版ごとに 2 周の差 (再読み込みをはさんだ同じ設定の差) を出す。前後の差がこれと同じ程度なら見た目は同じ
"""

import argparse
import json
import os
import re
import statistics
import sys
import time
import traceback
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mc import send_job  # noqa: E402
from pixdiff import VISIBLE_STEP, diff_stats  # noqa: E402
from run_scene import DROP_CLEAR, NO_TILE_DROPS, RESTORE_TILE_DROPS, dimension_of  # noqa: E402
from shader_options import load_defaults, option_warning, read_options, write_options  # noqa: E402

ROOT = Path(__file__).resolve().parent
# 差の画像は小さな差も見えるよう増幅する
DIFF_GAIN = 8
PANEL_WIDTH = 640


# 設定の区切りは ; と , のどちらでも受ける。dir:<フォルダ>;A=1;B=2 の ; 以降を 1 つの KEY=V として読むと
# 値が 1;B=2 になって Ray.txt に書かれ、Iris は不正な値を黙って捨てるので上書きが全部効かなかった
SET_SEPARATOR = re.compile(r"[;,]")
SET_ITEM = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s=]+)")


def parse_variant(text: str) -> tuple[str, str | None, dict]:
    if "=" not in text:
        raise SystemExit(f"--variant は 名前=指定: {text}")
    name, spec = text.split("=", 1)
    items = SET_SEPARATOR.split(spec)
    folder = None
    if spec.startswith("dir:"):
        folder, items = items[0][4:], items[1:]
        if not (Path(folder) / "shaders").is_dir():
            raise SystemExit(f"dir: のフォルダに shaders/ が無い ({name}): {folder}")
    sets = {}
    for item in filter(None, (s.strip() for s in items)):
        m = SET_ITEM.fullmatch(item)
        if not m:
            raise SystemExit(f"設定は KEY=V ({name}): {item}")
        sets[m[1]] = m[2]
    return name, folder, sets


def junction_target(link: Path) -> str:
    return os.readlink(link).removeprefix("\\\\?\\")


def same_path(a: str | Path, b: str | Path) -> bool:
    return os.path.normcase(os.path.normpath(a)) == os.path.normcase(os.path.normpath(b))


def same_value(a: str | None, b: str | None) -> bool:
    if a == b:
        return True
    try:
        return a is not None and b is not None and float(a) == float(b)
    except ValueError:
        return False


def set_junction(link: Path, target: str) -> None:
    # 中身は消さず、ジャンクションだけを付け替える。先に別名で作り、できてから古いものと置き換える
    # (消した後に作成が失敗する、mklink を起動できない (WinError 1455 など)、先が無い、でジャンクションを失わない)
    import _winapi  # Windows 専用。cmd/mklink の子プロセスを起動しない

    dest = Path(target).resolve()
    if not dest.is_dir():
        raise FileNotFoundError(f"ジャンクションの先が無い: {dest}")
    tmp = link.with_name(link.name + ".abscene")
    if os.path.lexists(tmp):
        os.rmdir(tmp)
    _winapi.CreateJunction(str(dest), str(tmp))
    try:
        if os.path.lexists(link):
            os.rmdir(link)
        os.rename(tmp, link)
    except OSError:
        # 古いものが残っているなら一時のものだけ消す。消えた後なら一時のものを残し、restore_junction のやり直しに任せる
        if os.path.lexists(link):
            os.rmdir(tmp)
        raise


def restore_junction(link: Path, target: str, tries: int = 3) -> None:
    # 付け替えが途中で失敗しても本体へ戻す。一時的な失敗 (掴まれている) に備えてやり直し、戻せなければ OSError
    last: Exception | None = None
    for _ in range(tries):
        try:
            if not (os.path.lexists(link) and same_path(junction_target(link), target)):
                set_junction(link, target)
            if same_path(junction_target(link), target):
                return
            last = OSError(f"付け替えた後も先が違う: {junction_target(link)}")
        except OSError as e:
            last = e
        time.sleep(1.0)
    raise OSError(f"{link} を {target} へ戻せない: {last}")


def wait_files(paths: list[Path], timeout: float = 30.0) -> None:
    # 撮影はゲームの側で非同期に書かれるので、大きさが止まるまで待つ
    deadline = time.time() + timeout
    for p in paths:
        last = -1
        while time.time() < deadline:
            size = p.stat().st_size if p.exists() else -1
            if size > 0 and size == last:
                break
            last = size
            time.sleep(0.3)
        else:
            raise SystemExit(f"撮影が見つからない: {p}")


def panel(path: Path, crop: tuple | None, scale: int) -> Image.Image:
    im = Image.open(path).convert("RGB")
    if crop:
        im = im.crop(crop)
        return im.resize((im.width * scale, im.height * scale), Image.NEAREST) if scale != 1 else im
    return im.resize((PANEL_WIDTH, round(im.height * PANEL_WIDTH / im.width)), Image.LANCZOS)


def diff_panel(a: Image.Image, b: Image.Image) -> Image.Image:
    d = np.abs(np.asarray(a, dtype=np.int16) - np.asarray(b, dtype=np.int16)).max(axis=-1)
    return Image.fromarray(np.clip(d * DIFF_GAIN, 0, 255).astype(np.uint8)).convert("RGB")


def make_sheet(out: Path, scene: str, names: list[str], shots: dict, crop, scale) -> None:
    base = panel(shots[names[0]], crop, scale)
    cells = [(f"{names[0]}", base)]
    for n in names[1:]:
        im = panel(shots[n], crop, scale)
        cells.append((n, im))
    for n, im in cells[1:]:
        cells.append((f"|{n} - {names[0]}| x{DIFF_GAIN}", diff_panel(im, base)))
    w, h = base.size
    sheet = Image.new("RGB", (len(cells) * (w + 6) - 6, h + 14), (30, 30, 30))
    draw = ImageDraw.Draw(sheet)
    for k, (label, im) in enumerate(cells):
        sheet.paste(im, (k * (w + 6), 14))
        draw.text((k * (w + 6) + 4, 1), f"{label} {scene}", fill=(255, 255, 255))
    sheet.save(out, quality=92)


def main() -> None:
    p = argparse.ArgumentParser(description="同じ場面に立ったまま、版・設定を替えて撮り比べる")
    p.add_argument("scenes", nargs="+")
    p.add_argument("--variant", action="append", required=True, help="名前=指定 (2 つ以上)")
    p.add_argument("--tag", default="ab")
    p.add_argument("--rounds", type=int, default=2, help="周の数。2 以上で揺れの基準が出る")
    # 再読み込みの後、自動露出と TAA の履歴がそろうまでの待ち。run_scene の再読み込みの後の待ち (6 秒) と同じ
    # 壁時計で待つと、パイプラインの作成が速い版 (ドライバのキャッシュあり) は作成の後の最初のフレームの詰まりと待ちが重なり、
    # 履歴・露出が溜まる前の 1〜数フレーム目を撮る。また霧・葉・波は frameTimeCounter で動くので、版ごとに位相がずれる (mv-s2dbg)
    # 新しいフレームを数えた後、Iris の frameTimeCounter (再読み込みで 0) が settle 秒になった所で撮る
    p.add_argument("--settle", type=float, default=6.0, help="再読み込みから撮影までの frameTimeCounter の秒")
    p.add_argument("--settle-frames", type=int, default=10, help="再読み込みの後、settle の前に待つ新しいフレームの数")
    p.add_argument("--fps", type=int, default=0, help="撮影の後に fps ステップを N 回 (frame_ms を版ごとに比べる)")
    p.add_argument("--crop", help="シートの切り出し x0,y0,x1,y1[:倍率] (既定は縮小した全体)")
    p.add_argument("--out", type=Path, help="report.md とシートの置き場 (既定 ./ab_<tag>)")
    p.add_argument("--timeout", type=float, default=900.0, help="1 ジョブの上限秒 (cold の再読み込みを含む)")
    args = p.parse_args()

    if not os.environ.get("RAY_MC_DIR"):
        raise SystemExit("RAY_MC_DIR を指定する")
    game = Path(os.environ["RAY_MC_DIR"])
    variants = [parse_variant(v) for v in args.variant]
    names = [v[0] for v in variants]
    if len(variants) < 2 or len(set(names)) != len(names):
        raise SystemExit("--variant は名前の違うものを 2 つ以上")
    conf = json.loads((ROOT / "scenes.json").read_text(encoding="utf-8"))
    unknown = [s for s in args.scenes if s not in conf["scenes"]]
    if unknown:
        raise SystemExit(f"scenes.json に無い: {unknown}")
    out = args.out or Path(f"ab_{args.tag}")
    out.mkdir(parents=True, exist_ok=True)
    crop, scale = None, 1
    if args.crop:
        box, _, s = args.crop.partition(":")
        crop, scale = tuple(int(v) for v in box.split(",")), int(s or 1)

    ray_txt = game / "shaderpacks" / "Ray.txt"
    link = game / "shaderpacks" / "Ray"
    header, values0 = read_options(ray_txt)
    original_text = ray_txt.read_text(encoding="utf-8") if ray_txt.exists() else None
    defaults = load_defaults()
    for name, _, sets in variants:
        for k, v in sets.items():
            warning = option_warning(defaults, k, v)
            if warning:
                print(f"{warning} ({name})", file=sys.stderr)
    original_target = None
    if any(v[1] for v in variants):
        try:
            original_target = junction_target(link)
        except OSError as e:
            raise SystemExit(f"{link} がジャンクションでない (前の中断で消えた?): {e}。本体へ手で戻す: mklink /J <link> <本体>")
    # 撮影の後始末は capture の撮影と待ち以外 (一人称に戻す・HUD・tag=ray の除去)
    cleanup = [s for s in conf["capture"] if "screenshot" not in s and "wait" not in s]

    # fps は reload+settle+shot のジョブの中の秒 (内数)
    timing: dict[str, float] = {"prep": 0.0, "reload+settle+shot": 0.0, "fps": 0.0, "cleanup": 0.0}
    frame_ms: dict[tuple[str, str], list[float]] = {}
    logs: list[str] = []
    override_warnings: list[str] = []
    shots: dict[str, dict[str, list[Path]]] = {}
    t_start = time.time()

    def run(steps: list, key: str) -> dict:
        t0 = time.time()
        status, hits = send_job(game, {"steps": steps}, args.timeout, 20)
        timing[key] += time.time() - t0
        logs.extend(h for h in hits if any(w in h.lower() for w in ("error", "exception", "fail")))
        if status.get("timeout") or not status.get("ok"):
            raise SystemExit(f"ジョブが失敗した ({key}): {json.dumps(status, ensure_ascii=False)[:1500]}")
        return status

    def apply(variant) -> None:
        _, folder, sets = variant
        write_options(ray_txt, header, {**values0, **sets})
        wanted = folder or original_target
        if wanted and not same_path(junction_target(link), Path(wanted).resolve()):
            set_junction(link, wanted)

    def check_applied(variant, scene_name: str) -> None:
        # Iris は再読み込みの後、パックが受け取った設定だけを Ray.txt に書き直す (既定と同じ値は書かない)
        name, _, sets = variant
        _, actual = read_options(ray_txt)
        for k, v in sets.items():
            if not same_value(actual.get(k), v) and not same_value(defaults.get(k, (None,))[0], v):
                msg = f"警告: {scene_name} {name}: {k}={v} を Iris が受け取っていない (パックに無い設定か不正な値)"
                override_warnings.append(msg)
                print(msg, file=sys.stderr)

    try:
        order = []
        for r in range(args.rounds):
            seq = variants if r % 2 == 0 else variants[::-1]
            order += [(r + 1, v) for v in seq]
        for i, scene_name in enumerate(args.scenes):
            scene = conf["scenes"][scene_name]
            scene = scene if isinstance(scene, dict) else {"steps": scene}
            shot_base = f"{args.tag}_{scene_name}"
            steps = (list(conf["setup"]) + NO_TILE_DROPS) if i == 0 else []
            steps += [json.loads(json.dumps(s).replace("{name}", shot_base)) for s in scene["steps"]]
            steps += DROP_CLEAR
            run(steps, "prep")
            shots[scene_name] = {n: [] for n in names}
            for rnd, v in order:
                apply(v)
                name = f"{shot_base}_{v[0]}{rnd}"
                steps = [{"reload_shaders": True}, {"wait_frames": args.settle_frames, "timeout": args.timeout},
                         {"wait_frame_time": args.settle, "timeout": args.timeout}, {"screenshot": name}]
                if args.fps:
                    steps.append({"fps": args.fps, "unlimited": True})
                st = run(steps, "reload+settle+shot")
                check_applied(v, scene_name)
                shots[scene_name][v[0]].append(game / "screenshots" / f"{name}.png")
                if args.fps:
                    timing["fps"] += st["results"][4].get("sec", 0.0)
                    ms = st["results"][4]["value"].get("frame_ms")
                    if ms:
                        frame_ms.setdefault((scene_name, v[0]), []).append(ms)
            after = scene.get("after", [])
            same_next = i + 1 < len(args.scenes) and dimension_of(conf["scenes"][args.scenes[i + 1]]) == dimension_of(scene)
            if dimension_of(scene) not in (None, "overworld") and same_next:
                after = [s for s in after if "in minecraft:overworld" not in s.get("cmd", "") and "wait" not in s]
            run(cleanup + after, "cleanup")
    finally:
        # 始めの Ray.txt とパックに戻して読み直す (撮影の前の状態)。どこかが失敗しても残りは続け、最後にまとめて大きくエラーにする
        problems: list[str] = []
        if original_text is not None:
            try:
                tmp = ray_txt.with_suffix(".tmp")
                tmp.write_text(original_text, encoding="utf-8")
                os.replace(tmp, ray_txt)
            except OSError as e:
                problems.append(f"Ray.txt を戻せない: {e}")
        junction_ok = True
        if original_target:
            try:
                restore_junction(link, original_target)
            except OSError as e:
                junction_ok = False
                problems.append(f"{e}。手で戻す: rmdir \"{link}\" してから mklink /J \"{link}\" \"{original_target}\" "
                                f"(\"{link}.abscene\" が残っていれば rmdir)")
        if junction_ok:
            try:
                status, _ = send_job(game, {"steps": conf.get("teardown", []) + RESTORE_TILE_DROPS + DROP_CLEAR + [{"reload_shaders": True}]},
                                     args.timeout, 0)
                if status.get("timeout") or not status.get("ok"):
                    problems.append(f"最後の再読み込みのジョブが失敗した: {json.dumps(status, ensure_ascii=False)[:500]}")
            except Exception as e:
                problems.append(f"最後の再読み込みのジョブを送れない: {e}")
        else:
            problems.append("最後の再読み込みはしていない (戻せていない)")
        if problems:
            # SystemExit が途中の例外を隠さないよう、先に出す
            if sys.exc_info()[1] is not None:
                traceback.print_exception(sys.exc_info()[1])
            banner = "!" * 70
            print("\n".join(["", banner, "ab_scene: 後始末に失敗した。ゲームの状態を確かめる", *problems, banner]), file=sys.stderr)
            raise SystemExit(1)
    total = time.time() - t_start

    lines = [f"# ab_scene {args.tag}", "", f"版: {', '.join(args.variant)}。周 {args.rounds}、settle {args.settle} 秒", "",
             f"| シーン | 組 | mean | p99 | max | >{VISIBLE_STEP}/255 % | 平均色 |", "|---|---|---|---|---|---|---|"]
    for scene_name, per in shots.items():
        wait_files([p for ps in per.values() for p in ps])
        rows = []
        for n in names:
            if len(per[n]) >= 2:
                rows.append((f"揺れ {n}1/{n}2", per[n][0], per[n][1]))
        for n in names[1:]:
            for r in range(min(len(per[n]), len(per[names[0]]))):
                rows.append((f"{names[0]}{r + 1}/{n}{r + 1}", per[names[0]][r], per[n][r]))
        for label, a, b in rows:
            s = diff_stats(a, b)
            lines.append(f"| {scene_name} | {label} | {s['mean']:.2f} | {s['p99']:.1f} | {s['max']:.0f} | {s['over']:.2f} | {s['mean_color']:.2f} |")
        make_sheet(out / f"sheet_{scene_name}.jpg", scene_name, names, {n: per[n][0] for n in names}, crop, scale)
    if args.fps:
        lines += ["", "| シーン | 版 | frame_ms (撮った順) | 中央値 |", "|---|---|---|---|"]
        for (scene_name, n), xs in frame_ms.items():
            lines.append(f"| {scene_name} | {n} | {' '.join(f'{x:.2f}' for x in xs)} | {statistics.median(xs):.2f} |")
    lines += ["", f"時間 {total:.0f} 秒: " + "、".join(f"{k} {v:.0f}" for k, v in timing.items()),
              "", "latest.log のエラー: " + (f"{len(logs)} 行" if logs else "なし")]
    lines += [f"- {h[:300]}" for h in logs[:10]]
    if override_warnings:
        lines += ["", "上書きが効いていない版 (Iris が受け取っていない):", *[f"- {w}" for w in override_warnings]]
    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
