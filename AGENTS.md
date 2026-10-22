Iris 向け Minecraft シェーダーパック Ray のリポジトリ。人間向けの説明は [README.md](README.md)、設計は [docs/architecture.md](docs/architecture.md)

## 構成

- `shaders/`: パック本体
  - `lib/`: 共有コード。`light` (ブロックライト) / `sky` (大気・雲・フォグ) / `surface` (マテリアル・影・GI・反射・水) / `post` (カメラ・ポストプロセス) と、共通部の `common` / `buffers` / `ids`
  - `program/`: 各パスの本体
  - `world0/`, `world-1/`, `world1/`: include だけのラッパー。手で編集せず `uv run tools/gen_wrappers.py` で生成する
  - `lib/settings.glsl`: 全設定の定義。素の既定値は「高」(HIGH) プロファイルと一致させる
- `tools/`: 生成・検証・ゲーム内デバッグのスクリプト ([tools/README.md](tools/README.md))
- `docs/`: 設計と調査資料

## 変更したら必ず検証する

Python は uv で管理している (`pyproject.toml`, `uv.lock`)。最初に `uv sync` を実行し、スクリプトは必ず `uv run` で起動する。グローバルの Python に pip で入れない

```powershell
uv run tools/validate_shaders.py          # glslang でコンパイル + 静的チェック (既定値・world0)
uv run tools/validate_shaders.py --full   # 設定やプロファイルを変えたとき
uv run tools/gl_compile_check.py          # 実機のドライバで compile + link
```

glslang は `RAY_GLSLANG`、PATH、`tools/glslang/bin/glslang.exe` の順に探す

## はまりやすい制約

- `*.properties` は ASCII のみ。Iris は ISO-8859-1 で読むので、日本語はコメントでも前処理を壊す
- image uniform は 1 ステージ 8 個まで (NVIDIA)。`lib/buffers/images.glsl` は opt-in なので、使う `IMG_*` だけを `common.glsl` の include 前に `#define` する
- compute の `workGroups` / `workGroupsRender` はリテラルで書く (式・マクロ不可)
- `block.properties` / `item.properties` は `tools/gen_block_properties.py` から生成する。ID の番号帯は `lib/ids/*.glsl` と合わせる
- 設定を足したら `lib/settings.glsl`、`shaders.properties` (画面と `profile.*`)、`lang/en_US.lang`、`lang/ja_JP.lang` をそろえる。漏れは validate_shaders.py が検出する
- バッファ・ID・設定の割り当てを変えたら docs/architecture.md の表も直す

## コードの書き方

- コメントは日本語で、文末に「。」を付けない。何をしているかより、なぜそうしているかを書く
- マジックナンバーは定数にする。重い機能は `#ifdef` で丸ごと外し、パス単位では `program.*.enabled` で止める
- 他のシェーダーパックのコードは持ち込まない。手法を参考にしたら CREDITS.md に出典を書く

## ゲーム内での確認

Minescript 経由で、設定変更・シェーダー再読み込み・撮影・ログ確認を CLI から回せる。手順は [tools/README.md](tools/README.md#ゲーム内で撮影する)

```powershell
$env:RAY_MC_DIR = "<ゲームディレクトリ>"
uv run tools/shader_options.py set KEY=VALUE
uv run tools/run_scene.py <シーン名> --reload --tag <tag>   # <game>/screenshots/<tag>_<シーン名>.png
```

撮影結果を見るときは `latest.log` のシェーダーエラーも確認する (`mc.py` が該当行を表示する)
