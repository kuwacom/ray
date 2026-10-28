Iris 向け Minecraft シェーダーパック Ray のリポジトリ。人間向けの説明は [README.md](README.md)、設計は [docs/architecture.md](docs/architecture.md)

## 構成

- `shaders/`: パック本体
  - `lib/`: 共有コード。`light` (ブロックライト) / `sky` (大気・雲・フォグ) / `surface` (マテリアル・影・GI・反射・水) / `post` (カメラ・ポストプロセス) と、共通部の `common` / `buffers` / `ids`
  - `program/`: 各パスの本体。`light` / `sky` / `surface` / `post` のモジュールごとのフォルダに置く (`common/` は全画面の頂点シェーダー)。Iris のプログラム名との対応は `tools/gen_wrappers.py` の表
  - `world0/`, `world-1/`, `world1/`: ディメンションと本体のマクロを定義して本体を include するだけのラッパー。手で編集せず `uv run tools/gen_wrappers.py` で生成する
  - `lib/settings.glsl`: 設定の入口。設定の定義は `lib/settings/` に lib のモジュールごとのファイルで書く。素の既定値は「高」(HIGH) プロファイルと一致させる。`lib/settings/bool_refs.glsl` は `uv run tools/gen_settings.py` で生成する
- `tools/`: 生成・検証・ゲーム内デバッグのスクリプト ([tools/README.md](tools/README.md))
- `docs/`: 設計資料

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
- image uniform は 1 ステージ 8 個まで (NVIDIA)。`lib/buffers/images.glsl` は opt-in なので、使う `IMG_*` だけを `common.glsl` の宣言の前に `#define` する
- `lib/` と `program/` のファイルは、使う記号の定義元を `//@include "/lib/..."` の行で宣言する (読む順番に頼らない)。lib のファイルには `#include` を書かない。コメントの中にも `#include` で始まる行を書かない (Iris は `#include` の行をコメントや `#if` の中でもガードを見ずに毎回差し込むので、lib 同士が include すると本文が数十倍に膨らみ、読み込みが遅くなる)。本体の `#include` は `uv run tools/gen_includes.py` が宣言から生成する (`BEGIN GENERATED includes` の間。手で編集しない)。lib の宣言はガードの直後にまとめ、本体の宣言は opt-in の `#define` の後にまとめる。ガード名はパスから決める (`lib/sky/fog.glsl` は `SKY_FOG_GLSL`)。宣言の漏れと生成の古さは `tools/include_deps.py` と validate_shaders.py が検出する
- compute の `workGroups` / `workGroupsRender` はリテラルで書く (式・マクロ不可)
- `block.properties` / `item.properties` / `entity.properties` と `lib/ids/{block,light,entity}_ids.glsl`、`lib/light/light_table_data.glsl` は `tools/gen_block_properties.py` (表は `tools/id_tables.py`) から生成する。手で編集しない。光源の追加は `id_tables.py` の `LIGHTS` に 1 行
- 設定を足したら `lib/settings/` の該当モジュールのファイル (`gen_settings.py` も実行)、`shaders.properties` (画面と `profile.*`)、`lang/en_US.lang`、`lang/ja_JP.lang` をそろえる。漏れは validate_shaders.py が検出する
- 設定・関数・定数の名前は docs/architecture.md の「命名」に従う。保存済みの設定の名前と番号は変えない
- バッファ・ID の割り当てを変えたら docs/architecture.md の表も直す。設定の表 (architecture.md の設定とプリセット、docs/settings.md) は `gen_settings.py` が生成する

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
