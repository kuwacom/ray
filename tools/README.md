# tools

Ray のテクスチャや ID 表の生成、シェーダーのコンパイル検証、ゲーム内での撮影を自動化するためのスクリプトです  
シェーダーパックを遊ぶだけならこのフォルダは使いません

## 必要なもの

- [uv](https://docs.astral.sh/uv/): Python 本体と依存パッケージ (numpy, glfw, PyOpenGL) はリポジトリ直下の `pyproject.toml` と `uv.lock` で管理しています
- glslang (Khronos) の `glslangValidator`: `validate_shaders.py` と `gl_compile_check.py` が前処理に使います。[Releases](https://github.com/KhronosGroup/glslang/releases) から取得して、PATH に置くか、環境変数 `RAY_GLSLANG` で場所を指定するか、`tools/glslang/bin/glslang.exe` に展開してください
- [Minescript](https://minescript.net/): ゲーム内デバッグを使うときだけ必要です

リポジトリ直下で一度 `uv sync` を実行すると、`.venv/` に Python 3.11 と依存パッケージが入ります。以降はどのスクリプトも `uv run tools/<スクリプト>.py` で実行します。グローバルの Python に pip でパッケージを入れる必要はありません

```powershell
uv sync
```

> [!NOTE]
> numpy は 2 未満に固定しています。numpy 2 では float32 の計算結果が変わり、同じシードでも雲のノイズテクスチャが今の内容と一致しなくなるためです

## スクリプト一覧

### 生成

生成物はリポジトリに含めているので、元の表やパラメーターを変えたときだけ実行します

| スクリプト | 生成するもの |
|---|---|
| `gen_wrappers.py` | `shaders/world0`, `world-1`, `world1` の include だけのラッパー。プログラムを追加・削除したときに実行します。`--check` で過不足の確認だけもできます |
| `gen_block_properties.py` | `shaders/block.properties` と `shaders/item.properties`。ブロック・アイテム ID の表はこのスクリプトの中にあります |
| `gen_blue_noise.py` | `shaders/textures/blue_noise.png` |
| `gen_cloud_noise.py` | `shaders/textures/cloud_*.dat` |
| `gen_water_waves.py` | `shaders/textures/water_waves.dat` |
| `gen_lens_textures.py` | `shaders/textures/lens_starburst.dat`, `lens_dirt.png` |
| `gen_lens_ghosts.py` | `shaders/lib/post/lens_ghosts.glsl` (レンズゴーストの定数表) |

### 検証

| スクリプト | 内容 |
|---|---|
| `validate_shaders.py` | Iris の前処理 (include の展開、設定値の差し替え、Iris が注入するマクロ) を再現して glslang でコンパイルし、エラーを元ファイルの行番号で表示します。プロファイルの値、「高」プロファイルと既定値の一致、設定画面と lang の過不足、`*.properties` が ASCII だけか、も確認します |
| `gl_compile_check.py` | 同じ前処理の結果を、見えないウィンドウの OpenGL 4.6 compatibility コンテキストで手元の GPU ドライバに compile + link させます。glslang では出ないドライバ固有のエラーと、image / sampler / SSBO / shared メモリの使用数が上限を超えていないかを調べます |

### ゲーム内デバッグ

| スクリプト | 内容 |
|---|---|
| `minescript/ray_agent.py` | ゲーム内に常駐し、`<game>/minescript/ray/cmd.json` に書かれた手順を実行します |
| `minescript/ray_steps.py` | 手順の中身 (コマンド実行、視点、撮影、シェーダー再読み込みなど)。ジョブごとに読み直すので、編集しても常駐側を再起動する必要はありません |
| `mc.py` | ゲームの外から手順 (JSON 配列) を送り、結果と、その間に `latest.log` に出たシェーダー関連の行を表示します |
| `run_scene.py` | `scenes.json` に書いた定点シーンを再現して撮影します |
| `shader_options.py` | Iris の設定ファイル `<game>/shaderpacks/Ray.txt` を読み書きします |

## コンパイルを検証する

```powershell
# PATH や tools/glslang/ に置いた場合は不要
$env:RAY_GLSLANG = "<glslang のパス>\bin\glslang.exe"

uv run tools/validate_shaders.py                    # 既定値・オーバーワールドだけ
uv run tools/validate_shaders.py --full             # 3 ディメンションと全プロファイル
uv run tools/gl_compile_check.py                    # 手元のドライバで compile + link
uv run tools/gl_compile_check.py --full --limits --report
```

どちらも前回成功したプログラムは前処理後の内容が変わっていなければ飛ばします。結果は `tools/.cache/` に保存され、`--no-cache` で全部やり直します

| オプション | 内容 |
|---|---|
| `--full` | 既定値を 3 ディメンションで、全プロファイルをオーバーワールドで検証します |
| `--profile NAME` | 1 つのプロファイルだけ検証します (`DEFAULT` で既定値) |
| `--filter TEXT` | 名前に TEXT を含むものだけ検証します |
| `--no-cache` | キャッシュを使わずに全部検証します |
| `--jobs N` | 並列数 (既定は CPU 数) |

`gl_compile_check.py` だけにあるオプション

| オプション | 内容 |
|---|---|
| `--section LIST` | プログラム名の先頭一致で絞ります (例 `shadow,gbuffers`) |
| `--world LIST` | ディメンションを指定します (例 `world-1,world1`) |
| `--gpu NAME` | NVIDIA の GPU が複数あるとき、番号か名前の一部で選びます |
| `--limits` | ドライバの上限値を表示します |
| `--report` | プログラムごとの使用数を表示します |
| `--warnings` | ドライバの警告も表示します |
| `--all-programs` | `program.*.enabled` で無効になるプログラムも検証します (既定では Iris と同じく飛ばします) |

## ゲーム内で撮影する

Minescript を使うと、ゲームの外から「設定を変える -> シェーダーを再読み込み -> 決まった場所で撮影 -> ログを確認」を繰り返せます

1. Minescript を導入し、`tools/minescript/ray_agent.py` と `ray_steps.py` をゲームディレクトリの `minescript/` にコピーします
2. ワールドに入り、チャットで `\ray_agent` と打って常駐させます
3. 環境変数 `RAY_MC_DIR` にゲームディレクトリを設定します (`mc.py` は `--game-dir` でも指定できます)
4. `tools/scenes.example.json` を `tools/scenes.json` にコピーし、テレポート先などの座標を自分のワールドに合わせて書き換えます

```powershell
$env:RAY_MC_DIR = "<ゲームディレクトリ>"

# 手順を直接送る
uv run tools/mc.py '[{"cmd": "time set noon"}, {"reload_shaders": true}, {"wait": 3}, {"screenshot": "t1"}]'

# scenes.json のシーンを撮る (<game>/screenshots/<tag>_<シーン名>.png に保存されます)
uv run tools/run_scene.py noon night
uv run tools/run_scene.py --all --reload --tag before

# 設定を書き換える (次の再読み込みで反映されます)
uv run tools/shader_options.py set GI_MODE=0 LIGHT_SHADOWS=false

# 常駐を終わらせる
uv run tools/mc.py --stop
```

## リポジトリに含めないもの

| パス | 理由 |
|---|---|
| `tools/glslang/` | 各自がダウンロードして置く外部ツールのため |
| `tools/.cache/` | 検証結果のキャッシュで、環境ごとに内容が変わるため |
| `tools/scenes.json` | 座標が自分のワールドに依存するため。雛形は `scenes.example.json` です |
