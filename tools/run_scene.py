"""
# run_scene
tools/scenes.json の定点シーンを ray_agent 経由で再現して撮影する

### 使い方
- uv run tools/run_scene.py noon cave_torch            指定シーンを撮影
- uv run tools/run_scene.py --all --reload --tag v2    シェーダー再読み込み後に全シーンを撮影
- 撮影結果は <game>/screenshots/<tag>_<scene>.png
- 流れは setup -> (シーン -> capture -> after) x N -> teardown。詳細は tools/README.md
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def dimension_of(scene) -> str | None:
    """シーンの最初の `execute in minecraft:<dim>` からディメンションを返す (無ければ None)"""
    steps = scene if isinstance(scene, list) else scene["steps"]
    for s in steps:
        cmd = s.get("cmd", "")
        if cmd.startswith("execute in minecraft:"):
            return cmd.split()[2].split(":")[1]
    return None


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("scenes", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--reload", action="store_true", help="撮影前に Iris のシェーダーを再読み込みする")
    p.add_argument("--tag", default="scene")
    # ネザー・エンドで設定を変えて再読み込みを繰り返す時に、最後のシーンの後もそのディメンションに留まる
    p.add_argument("--stay", action="store_true", help="最後のシーンの後もネザー・エンドに留まる")
    # シーン数が多いと再読み込み込みで数分かかるので余裕を持たせる
    p.add_argument("--timeout", type=float, default=600.0)
    args = p.parse_args()

    scenes_path = ROOT / "scenes.json"
    if not scenes_path.exists():
        raise SystemExit(
            "tools/scenes.json がない。tools/scenes.example.json を tools/scenes.json にコピーして、"
            "座標を自分のワールドのものに書き換える")
    conf = json.loads(scenes_path.read_text(encoding="utf-8"))
    names = list(conf["scenes"]) if args.all else args.scenes
    unknown = [n for n in names if n not in conf["scenes"]]
    if not names or unknown:
        raise SystemExit(f"シーン名を指定する。候補: {', '.join(conf['scenes'])}")

    steps = list(conf["setup"])
    if args.reload:
        # 再読み込み直後はコンパイルと履歴バッファの蓄積待ちが必要
        steps += [{"reload_shaders": True}, {"wait": 6}]
    for i, name in enumerate(names):
        # シーンは steps の配列か、撮影後の後始末 (設置ブロックの撤去など) を持つ {"steps", "after"}
        scene = conf["scenes"][name]
        if isinstance(scene, list):
            scene = {"steps": scene}
        shot = f"{args.tag}_{name}"
        # シーン内の途中撮影 (turn の shot など) もタグ付きの名前にできるよう {name} を置き換える
        steps += [json.loads(json.dumps(s).replace("{name}", shot)) for s in scene["steps"]]
        steps += [json.loads(json.dumps(s).replace("{name}", shot)) for s in conf["capture"]]
        after = scene.get("after", [])
        # 同じディメンションのシーンが続く時はオーバーワールドへ戻らない (ディメンション移動はパイプラインを作り直しメモリを食う)
        same_next = i + 1 < len(names) and dimension_of(conf["scenes"][names[i + 1]]) == dimension_of(scene)
        if dimension_of(scene) not in (None, "overworld") and (same_next or (args.stay and i + 1 == len(names))):
            after = [s for s in after if "in minecraft:overworld" not in s.get("cmd", "") and "wait" not in s]
        steps += after
    # HUD や FOV などプレイ用の設定を撮影前の状態に戻す
    steps += conf.get("teardown", [])

    cmd = [sys.executable, str(ROOT / "mc.py"), json.dumps(steps, ensure_ascii=False),
           "--timeout", str(args.timeout), "--log-lines", "20"]
    sys.exit(subprocess.call(cmd, env=os.environ.copy()))


main()
