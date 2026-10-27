# tools

Ray のテクスチャや ID 表の生成、シェーダーのコンパイル検証、ゲーム内での撮影を自動化するためのスクリプトです  
シェーダーパックを遊ぶだけならこのフォルダは使いません

## 必要なもの

- [uv](https://docs.astral.sh/uv/): Python 本体と依存パッケージ (numpy, glfw, PyOpenGL, Pillow) はリポジトリ直下の `pyproject.toml` と `uv.lock` で管理しています
- glslang (Khronos) の `glslangValidator`: `validate_shaders.py` と `gl_compile_check.py` が前処理に使います。[Releases](https://github.com/KhronosGroup/glslang/releases) から取得して、PATH に置くか、環境変数 `RAY_GLSLANG` で場所を指定するか、`tools/glslang/bin/glslang.exe` に展開してください
- [Minescript](https://minescript.net/): ゲーム内デバッグを使うときだけ必要です

リポジトリ直下で一度 `uv sync` を実行すると、`.venv/` に Python 3.11 と依存パッケージが入ります。以降はどのスクリプトも `uv run tools/<スクリプト>.py` で実行します。グローバルの Python に pip でパッケージを入れる必要はありません

```powershell
uv sync
```

> [!NOTE]
> numpy は 2 未満に固定しています。numpy 2 では float32 の計算結果が変わり、同じシードでも雲のノイズテクスチャが同梱のものと一致しなくなるためです

## スクリプト一覧

### 生成

生成物はリポジトリに含めているので、元の表やパラメーターを変えたときだけ実行します

| スクリプト | 生成するもの |
|---|---|
| `gen_wrappers.py` | `shaders/world0`, `world-1`, `world1` の include だけのラッパー。プログラムを追加・削除したときに実行します。`--check` で過不足の確認だけもできます |
| `gen_block_properties.py` | `shaders/block.properties` と `shaders/item.properties`、ブロックの平均の色の表 `shaders/lib/ids/block_albedo.glsl`。ブロック・アイテム ID の表はこのスクリプトの中にあります。表に無いブロックは `block_colors.json` の色ごとに 2000 番台の ID にまとめます |
| `gen_block_colors.py <client.jar>` | `tools/block_colors.json` (ブロックごとの平均の色)。Minecraft のクライアント jar のブロックモデルとテクスチャを読むだけで、jar は変更しません。バージョンを上げたときに実行し、続けて `gen_block_properties.py` を実行します |
| `gen_blue_noise.py` | `shaders/textures/blue_noise.png` |
| `gen_cloud_noise.py` | `shaders/textures/cloud_*.dat` |
| `gen_water_waves.py` | `shaders/textures/water_waves.dat` |
| `gen_lens_textures.py` | `shaders/textures/lens_starburst.dat`, `lens_dirt.png` |
| `gen_lens_ghosts.py` | `shaders/lib/post/lens_ghosts.glsl` (レンズゴーストの定数表) |
| `gen_look_lut.py` | `shaders/textures/look/` のルックの LUT。`all` で恒等の `user_lut.png` と、`tools/look_luts/*.json` のパラメーターから焼いた同梱の 3D LUT (`split_tone.dat`, `film.dat`) を作り直します。ほかのサブコマンドは下の「ルックの LUT」 |

### 検証

| スクリプト | 内容 |
|---|---|
| `validate_shaders.py` | Iris の前処理 (include の展開、設定値の差し替え、Iris が注入するマクロ) を再現して glslang でコンパイルし、エラーを元ファイルの行番号で表示します。プロファイルの値、「高」プロファイルと既定値の一致、設定画面と lang の過不足、`*.properties` が ASCII だけか、も確認します |
| `gl_compile_check.py` | 同じ前処理の結果を、見えないウィンドウの OpenGL 4.6 compatibility コンテキストで手元の GPU ドライバに compile + link させます。glslang では出ないドライバ固有のエラーと、image / sampler / SSBO / shared メモリの使用数が上限を超えていないかを調べます |
| `equiv_check.py` | 2 つのコミット (または作業ツリー) のシェーダーをドライバにリンクさせ、バイナリが同じかを比べます。リファクタで計算が変わっていないかを、ゲームを使わずに確かめます |
| `pixdiff.py` | 2 枚の撮影の画素の差 (平均・p99・最大・4/255 を超える画素の割合・平均色の差) を出します |

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
| `--shaders DIR` | このリポジトリの `shaders/` の代わりに DIR を検証します |

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
| `--time` | 検証の代わりに、プログラムごとのコンパイル時間を Iris と同じく 1 つずつ測ります。ドライバのキャッシュに当たらないよう、毎回違う `#define` を足します |

## リファクタの前後を比べる

`equiv_check.py` は、基準のコミット (`--base`、既定 HEAD) を `git archive` で `tools/.cache/equiv/` に展開し、作業ツリー (または `--new` のコミット) と同じ前処理・同じ GL コンテキストでリンクして比べます。前処理後の本文が同じプログラムはリンクせずに SAME とします

```powershell
uv run tools/equiv_check.py --gpu 1070                # 既定値・オーバーワールド
uv run tools/equiv_check.py --gpu 1070 --full         # 3 ディメンションと全プロファイル
uv run tools/equiv_check.py --text                    # glslang -E 後の本文 (コメント・空行・#line を除く) を比べる
uv run tools/equiv_check.py --gpu 1070 --layout       # SSBO のメンバーのオフセットと間隔を比べる
uv run tools/equiv_check.py --base HEAD~1 --new HEAD -v
```

- 結果はプログラムごとに `SAME` / `DIFF` / `ERROR` / `ONLY_BASE` / `ONLY_NEW` で、DIFF か ERROR があると終了コードが 1 になります。`-v` で SAME も表示します
- バイナリには本文のハッシュなど、意味が同じでも変わるバイトがあります。基準の本文に違うコメントを足してリンクし直し、変わった位置を比べる対象から外します。コメント・関数名・未使用の関数や定数だけの変更は SAME、式や定数の値の変更は DIFF になります
- 並べ替えなどで意味が同じでもバイナリが変わることがあります。DIFF になったら、撮影して `pixdiff.py` で比べます
- 比べるのは同じ GPU とドライバの中だけです。`--filter`、`--profile`、`--world` で絞れます

## ルックの LUT

LUT は表示の色 (トーンマップと sRGB エンコードの後) から表示の色への写像で、final が CDL の前に掛けます。形式と設定の番号は [README の「ルック」](../README.md#lut)

```powershell
uv run tools/gen_look_lut.py all                                         # 同梱の LUT を作り直す
uv run tools/gen_look_lut.py bake tools/look_luts/split_tone.json --out x.dat   # パラメーターから焼く (.dat = 33^3 RGBA16, .png = 32^3 ストリップ)
uv run tools/gen_look_lut.py from-cube my.cube --out shaders/textures/look/user_lut.png
uv run tools/gen_look_lut.py from-strip graded.png --out x.cube          # 加工したストリップ PNG を .cube / .dat に
uv run tools/gen_look_lut.py to-cube shaders/textures/look/film.dat --out film.cube
uv run tools/gen_look_lut.py preview --lut x.dat --in shot.png --out out.png    # 撮影した画面に CPU で掛けて比べる
uv run tools/gen_look_lut.py check shaders/textures/look/*.dat           # 大きさ・恒等からのずれ・隅の色
uv run tools/gen_look_lut.py test-swap-rb --out shaders/textures/look/user_lut.png  # 赤と青を入れ替える LUT (向きの確認用。終わったら all で戻す)
```

- パラメーター (`tools/look_luts/*.json`) は、色の混ざり (3x3)、色温度の転び、コントラスト (中間グレーを軸にした log2) とチャンネルごとのコントラスト、輝度帯ごとの彩度、Oklab の色相帯ごとの色相の回転・彩度・明るさ、暗部と明部の色付け、出力の黒と白の位置です。意味は `gen_look_lut.py` の `BakeParams`
- 新しい同梱の LUT を足すときは、JSON を足して `BUNDLED` と shaders.properties の `#if LOOK_LUT` に後ろの番号で足し、settings.glsl と lang の LOOK_LUT の値もそろえます
- `.dat` はリトルエンディアンの uint16 で、赤が最速・次に緑・青の順 (.cube と同じ)。PNG のストリップは上の行が緑 0 で、ゲームで恒等と赤青の入れ替えの LUT を使って向きを確かめてあります

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
