"""
# shader_options
Iris のシェーダー設定ファイル (<game>/shaderpacks/Ray.txt) を外部から読み書きする

### 使い方
- uv run tools/shader_options.py get                    上書き中の設定を全て表示
- uv run tools/shader_options.py get GI_MODE SHADOWS     指定キーの現在値と既定値を表示
- uv run tools/shader_options.py set GI_MODE=0 LIGHT_SHADOWS=false
- uv run tools/shader_options.py unset GI_MODE           既定値に戻す (行を消す)
- 反映はシェーダー再読み込み時 (run_scene.py --reload か mc.py の reload_shaders)
- 既定値と選択肢は shaders/lib/settings.glsl から読む。未知のキーや選択肢外の値は警告だけ出して書き込む
"""

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "shaders" / "lib" / "settings.glsl"


def load_defaults() -> dict:
    # キー -> (既定値, 選択肢) 。bool は #define の有無、値付きは // [a b c] の選択肢を拾う
    defaults = {}
    for line in SETTINGS.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        mt = re.match(r"^(//\s*)?#define\s+(\w+)(?:\s+([^\s/]+))?\s*(?://\s*(?:\[([^\]]*)\])?.*)?$", s)
        if mt:
            commented, key, value, choices = mt.groups()
            if value is None:
                defaults[key] = ("false" if commented else "true", ["true", "false"])
            elif not commented:
                defaults[key] = (value, choices.split() if choices else [])
            continue
        mt = re.match(r"^const\s+\w+\s+(\w+)\s*=\s*([^;]+);\s*(?://\s*\[([^\]]*)\])?", s)
        if mt:
            key, value, choices = mt.groups()
            defaults[key] = (value.strip(), choices.split() if choices else [])
    return defaults


def read_options(path: Path) -> tuple[list[str], dict]:
    header, values = [], {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("#") or not line.strip():
                header.append(line)
            elif "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    return header, values


def write_options(path: Path, header: list[str], values: dict) -> None:
    # Iris と同じくキー順で書く。書きかけを読まれないよう一時ファイルから置き換える
    lines = header + [f"{k}={values[k]}" for k in sorted(values)]
    tmp = path.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["get", "set", "unset"])
    p.add_argument("items", nargs="*", help="get/unset はキー、set は KEY=VALUE")
    p.add_argument("--file", help="既定は $RAY_MC_DIR/shaderpacks/Ray.txt")
    args = p.parse_args()

    if args.file:
        path = Path(args.file)
    elif os.environ.get("RAY_MC_DIR"):
        path = Path(os.environ["RAY_MC_DIR"]) / "shaderpacks" / "Ray.txt"
    else:
        raise SystemExit("--file か RAY_MC_DIR を指定する")

    defaults = load_defaults()
    header, values = read_options(path)

    if args.action == "get":
        keys = args.items or sorted(values)
        for k in keys:
            default = defaults.get(k, ("?", []))[0]
            print(f"{k}={values.get(k, default)}  (既定 {default}{', 上書き中' if k in values else ''})")
        return

    if args.action == "unset":
        for k in args.items:
            values.pop(k, None)
    else:
        for item in args.items:
            if "=" not in item:
                raise SystemExit(f"KEY=VALUE で指定する: {item}")
            k, v = (s.strip() for s in item.split("=", 1))
            if k not in defaults:
                print(f"警告: {k} は settings.glsl に見つからない", file=sys.stderr)
            elif defaults[k][1] and v not in defaults[k][1]:
                print(f"警告: {k}={v} は選択肢 {defaults[k][1]} に無い", file=sys.stderr)
            values[k] = v
    write_options(path, header, values)
    for k in args.items:
        k = k.split("=", 1)[0].strip()
        print(f"{k}={values.get(k, defaults.get(k, ('?',))[0])}")


main()
