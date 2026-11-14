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

# ray_agent が cmd.json を受け取るまでの上限 (agent の見回りは 0.5 秒ごと)
PICKUP_SEC = 10.0


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


def send_job(game_dir: Path, job: dict, timeout: float, log_lines: int = 15) -> tuple[dict, list[str]]:
    """
    ### send_job
    ray_agent にジョブを渡して終わるまで待つ

    @param game_dir - ゲームディレクトリ
    @param job - {"steps": [...]} か {"stop": true}。id はここで付ける
    @param timeout - 待つ秒。超えたら {"timeout": true, "last_status": ...} を返す
    @param log_lines - ジョブ中に latest.log へ出たシェーダー関連の行を何行まで返すか
    @returns (status.json の内容, シェーダー関連の行)
    """
    ray_dir = game_dir / "minescript" / "ray"
    ray_dir.mkdir(parents=True, exist_ok=True)
    cmd_path = ray_dir / "cmd.json"
    status_path = ray_dir / "status.json"

    job_id = f"{time.time():.3f}"
    job = {"id": job_id, **job}

    log_path = game_dir / "logs" / "latest.log"
    log_size = log_path.stat().st_size if log_path.exists() else 0

    tmp = cmd_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, cmd_path)

    t0 = time.time()
    deadline = t0 + timeout
    status: dict = {}
    picked = False
    while time.time() < deadline:
        time.sleep(0.3)
        try:
            status = json.loads(status_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        picked = picked or status.get("id") == job_id
        if status.get("id") == job_id and status.get("state") not in ("running",):
            break
        # ray_agent は 0.5 秒ごとに cmd.json を見て、受け取るとすぐ running を書く。受け取らないまま timeout まで待たない
        if not picked and time.time() - t0 > PICKUP_SEC:
            return {"timeout": True, "not_picked_up": True, "last_status": status,
                    "hint": "ray_agent が受け取らない (落ちているか、前のジョブが実行中)"}, []
    else:
        return {"timeout": True, "last_status": status}, []

    logs = shader_log_tail(game_dir, log_size, log_lines) if log_path.exists() and log_lines > 0 else []
    return status, logs


def main() -> None:
    args = parse_args()
    if not args.game_dir:
        raise SystemExit("--game-dir か RAY_MC_DIR を指定する")
    if args.stop:
        job: dict = {"stop": True}
    else:
        if not args.steps:
            raise SystemExit("steps を指定する")
        job = {"steps": load_steps(args.steps), "continue_on_error": args.continue_on_error}

    status, logs = send_job(Path(args.game_dir), job, args.timeout, args.log_lines)
    print(json.dumps(status, ensure_ascii=False, indent=1))
    if status.get("timeout"):
        sys.exit(2)
    for ln in logs:
        print("LOG:", ln[:300])
    sys.exit(0 if status.get("ok") else 1)


if __name__ == "__main__":
    main()
