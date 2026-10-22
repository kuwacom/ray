"""
# ray_agent
Minescript 上で常駐し、外部 (開発エージェント) からの指示ファイルを実行する

### 特徴
- minescript/ray/cmd.json を監視し、id が更新されたら steps を順に実行する
- 結果は minescript/ray/status.json に書く
- ステップの中身は ray_steps.py にあり、ジョブごとに再読み込みするので常駐側の再起動は不要
- ゲーム内チャットで `\\ray_agent` と打って起動する
"""

import importlib
import json
import os
import sys
import time
import traceback

import minescript as m

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.join(SCRIPT_DIR, "ray")
CMD_PATH = os.path.join(BASE_DIR, "cmd.json")
STATUS_PATH = os.path.join(BASE_DIR, "status.json")
POLL_SEC = 0.5

if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)


def write_status(data: dict) -> None:
    # 書きかけを読まれないよう一時ファイルから置き換える
    tmp = STATUS_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATUS_PATH)


def load_steps_module():
    if "ray_steps" in sys.modules:
        return importlib.reload(sys.modules["ray_steps"])
    return importlib.import_module("ray_steps")


def main() -> None:
    os.makedirs(BASE_DIR, exist_ok=True)
    last_id = None
    if os.path.exists(STATUS_PATH):
        try:
            with open(STATUS_PATH, encoding="utf-8") as f:
                last_id = json.load(f).get("id")
        except (OSError, ValueError):
            last_id = None
    write_status({"id": last_id, "ok": True, "state": "ready", "started_at": time.time()})
    m.echo("[ray_agent] ready")

    while True:
        time.sleep(POLL_SEC)
        try:
            with open(CMD_PATH, encoding="utf-8") as f:
                job = json.load(f)
        except (OSError, ValueError):
            continue
        if job.get("id") == last_id:
            continue
        last_id = job.get("id")
        if job.get("stop"):
            write_status({"id": last_id, "ok": True, "state": "stopped"})
            m.echo("[ray_agent] stopped")
            return
        write_status({"id": last_id, "ok": True, "state": "running"})
        try:
            write_status(load_steps_module().run_job(job))
        except Exception:
            write_status({"id": last_id, "ok": False, "error": traceback.format_exc(limit=5)})


main()
