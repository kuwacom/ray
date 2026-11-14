"""
# ab_scene
設定や版の違いを、同じ場面に立ったまま撮り比べる。場面の準備 (tp・召喚・待ち) を 1 回にし、
版ごとに再読み込みだけをして撮る。揺れの基準 (同じ版の 2 回の差)、前後の差、比較シートを 1 回で出す

### 使い方
- uv run tools/ab_scene.py noon cave_torch --variant base= --variant gi0=GI_MODE=0 --tag gi --out <dir>
- uv run tools/ab_scene.py noon --variant old=dir:<パックのフォルダ> --variant new=dir:<フォルダ> --fps 4
- --variant 名前=指定。指定は空 (始めの Ray.txt のまま)、KEY=V,KEY=V (始めの Ray.txt に上書き)、
  dir:<フォルダ> (shaderpacks/Ray のジャンクションの先を替える。終わったら戻す)、dir:<フォルダ>;KEY=V の組み合わせ
- 順番は 1 周目が並べた順、2 周目が逆順 (A B B A)。時間とともに変わるもの (温度・フレームの時間) の偏りを打ち消す
- 撮影は <game>/screenshots/<tag>_<シーン>_<版><周>.png。--out に report.md (差の表・frame_ms・時間) と sheet_<シーン>.jpg

### 揺れの基準
- 版ごとに 2 周の差 (再読み込みをはさんだ同じ設定の差) を出す。前後の差がこれと同じ程度なら見た目は同じ
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mc import send_job  # noqa: E402
from pixdiff import VISIBLE_STEP, diff_stats  # noqa: E402
from run_scene import DROP_CLEAR, NO_TILE_DROPS, RESTORE_TILE_DROPS, dimension_of  # noqa: E402
from shader_options import read_options, write_options  # noqa: E402

ROOT = Path(__file__).resolve().parent
# 差の画像は小さな差も見えるよう増幅する
DIFF_GAIN = 8
PANEL_WIDTH = 640


def parse_variant(text: str) -> tuple[str, str | None, dict]:
    if "=" not in text:
        raise SystemExit(f"--variant は 名前=指定: {text}")
    name, spec = text.split("=", 1)
    folder = None
    if spec.startswith("dir:"):
        folder, _, spec = spec[4:].partition(";")
    sets = {}
    for item in filter(None, spec.split(",")):
        if "=" not in item:
            raise SystemExit(f"設定は KEY=V: {item}")
        k, v = item.split("=", 1)
        sets[k.strip()] = v.strip()
    return name, folder, sets


def junction_target(link: Path) -> str:
    return os.readlink(link).removeprefix("\\\\?\\")


def set_junction(link: Path, target: str) -> None:
    # 中身は消さず、ジャンクションだけを付け替える
    subprocess.run(["cmd", "/c", "rmdir", str(link)], check=True, capture_output=True)
    subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(Path(target).resolve())], check=True, capture_output=True)


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
    p.add_argument("--settle", type=float, default=6.0, help="再読み込みから撮影までの秒")
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
    original_target = junction_target(link) if any(v[1] for v in variants) else None
    # 撮影の後始末は capture の撮影と待ち以外 (一人称に戻す・HUD・tag=ray の除去)
    cleanup = [s for s in conf["capture"] if "screenshot" not in s and "wait" not in s]

    # fps は reload+settle+shot のジョブの中の秒 (内数)
    timing: dict[str, float] = {"prep": 0.0, "reload+settle+shot": 0.0, "fps": 0.0, "cleanup": 0.0}
    frame_ms: dict[tuple[str, str], list[float]] = {}
    logs: list[str] = []
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
        if folder:
            set_junction(link, folder)
        elif original_target:
            set_junction(link, original_target)

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
                steps = [{"reload_shaders": True}, {"wait": args.settle}, {"screenshot": name}]
                if args.fps:
                    steps.append({"fps": args.fps, "unlimited": True})
                st = run(steps, "reload+settle+shot")
                shots[scene_name][v[0]].append(game / "screenshots" / f"{name}.png")
                if args.fps:
                    timing["fps"] += st["results"][3].get("sec", 0.0)
                    ms = st["results"][3]["value"].get("frame_ms")
                    if ms:
                        frame_ms.setdefault((scene_name, v[0]), []).append(ms)
            after = scene.get("after", [])
            same_next = i + 1 < len(args.scenes) and dimension_of(conf["scenes"][args.scenes[i + 1]]) == dimension_of(scene)
            if dimension_of(scene) not in (None, "overworld") and same_next:
                after = [s for s in after if "in minecraft:overworld" not in s.get("cmd", "") and "wait" not in s]
            run(cleanup + after, "cleanup")
    finally:
        # 始めの Ray.txt とパックに戻して読み直す (撮影の前の状態)
        if original_text is not None:
            tmp = ray_txt.with_suffix(".tmp")
            tmp.write_text(original_text, encoding="utf-8")
            os.replace(tmp, ray_txt)
        if original_target:
            set_junction(link, original_target)
        send_job(game, {"steps": conf.get("teardown", []) + RESTORE_TILE_DROPS + DROP_CLEAR + [{"reload_shaders": True}]},
                 args.timeout, 0)
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
    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
