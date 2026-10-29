"""リポジトリの場所 (tools/ 配下のスクリプトが共通で使う)"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SHADERS = ROOT / "shaders"
