"""
# mc
開発エージェント側から Minecraft 内の ray_agent に指示を送り、結果を待つクライアント

### 使い方
- uv run tools/mc.py '[{"cmd": "time set noon"}, {"reload_shaders": true}, {"wait": 3}, {"screenshot": "t1"}]'
- uv run tools/mc.py --stop
- ゲームディレクトリは --game-dir か環境変数 RAY_MC_DIR で指定する
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("steps", nargs="?", help="steps の JSON 配列、またはそれを書いたファイルパス")
    p.add_argument("--game-dir", default=os.environ.get("RAY_MC_DIR"))
    p.add_argument("--timeout", type=float, default=60.0)
    p.add_argument("--continue-on-error", action="store_true")
    p.add_argument("--stop", action="store_true", help="ray_agent を終了させる")
    p.add_argument("--log-lines", type=int, default=15, help="完了後に表示する latest.log のシェーダー関連行数")
    return p.parse_args()


def load_steps(arg: str) -> list:
    path = Path(arg)
    text = path.read_text(encoding="utf-8") if path.is_file() else arg
    steps = json.loads(text)
    if not isinstance(steps, list):
        raise SystemExit("steps は JSON 配列で指定する")
    return steps


def shader_log_tail(game_dir: Path, since_size: int, limit: int) -> list[str]:
    # 今回のジョブ中に追記された分だけを見ることで過去のエラーと混同しない
    log = game_dir / "logs" / "latest.log"
    with open(log, "rb") as f:
        f.seek(since_size)
        lines = f.read().decode("utf-8", errors="replace").splitlines()
    keys = ("iris", "shader", "error", "Ray", "C7", "C1", "C0")
    hits = [ln for ln in lines if any(k.lower() in ln.lower() for k in keys)]
    return hits[-limit:]


def main() -> None:
    args = parse_args()
    if not args.game_dir:
        raise SystemExit("--game-dir か RAY_MC_DIR を指定する")
    game_dir = Path(args.game_dir)
    ray_dir = game_dir / "minescript" / "ray"
    ray_dir.mkdir(parents=True, exist_ok=True)
    cmd_path = ray_dir / "cmd.json"
    status_path = ray_dir / "status.json"

    job_id = f"{time.time():.3f}"
    job: dict = {"id": job_id}
    if args.stop:
        job["stop"] = True
    else:
        if not args.steps:
            raise SystemExit("steps を指定する")
        job["steps"] = load_steps(args.steps)
        job["continue_on_error"] = args.continue_on_error

    log_path = game_dir / "logs" / "latest.log"
    log_size = log_path.stat().st_size if log_path.exists() else 0

    tmp = cmd_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, cmd_path)

    deadline = time.time() + args.timeout
    status: dict = {}
    while time.time() < deadline:
        time.sleep(0.3)
        try:
            status = json.loads(status_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if status.get("id") == job_id and status.get("state") not in ("running",):
            break
    else:
        print(json.dumps({"timeout": True, "last_status": status}, ensure_ascii=False, indent=1))
        sys.exit(2)

    print(json.dumps(status, ensure_ascii=False, indent=1))
    if log_path.exists() and args.log_lines > 0:
        for ln in shader_log_tail(game_dir, log_size, args.log_lines):
            print("LOG:", ln[:300])
    sys.exit(0 if status.get("ok") else 1)


main()
