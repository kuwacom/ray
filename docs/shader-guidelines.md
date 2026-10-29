# シェーダーの書き方の指針

Ray のシェーダーを書くときに、読み込み (Iris の前処理とドライバのコンパイル・リンク) が速く、描画も速く、NVIDIA 以外でも動く形を選ぶための判断材料をまとめる。リポジトリの決まりは [AGENTS.md](../AGENTS.md)、設計と命名・検証は [architecture.md](architecture.md) の「規約・単位・検証」にあり、ここでは繰り返さない

- Iris の動きは Iris 1.11.4 (Minecraft 26.1.2) のソースで確かめたもの。Iris を更新したら、include の展開・設定の検出・資源の上限が変わっていないか見直す
- 時間の数値は GTX 1070 (ドライバ 581.57、Windows) での例。描画の時間は 1920x1080 の RGBA16F に全画面で描いて測った。桁と傾向の目安で、GPU が変われば変わる。リンクの時間は同じ条件で 2〜5 倍揺れた
- 確かめていないことは指針にしていない

## 読み込みの時間がどこで決まるか

| 段 | 中身 | 時間を決めるもの |
|---|---|---|
| Iris の前処理 | ファイルの読み込み、設定の検出、`#include` の展開、前処理器 (JCPP) | 展開した後の本文の大きさ (JCPP は無効な `#if` の中も字句解析する) |
| コンパイル | `glCompileShader` | 本文の大きさに比例するが小さい (NVIDIA は構文と意味の解析だけ) |
| リンク | `glLinkProgram` | 関数を inline した後の命令の量。NVIDIA は最適化とコード生成をここで行う |

- Iris はプログラムを 1 本ずつ順にコンパイル・リンクする (composite・deferred・compute は完了を待ってから次へ進む)。いちばん重いリンクがそのまま全体の時間に足される
- 設定を 1 つ変えても、R キーで再読み込みしても、ディメンションが変わっても、パイプラインは全部作り直す
- `program.<フォルダ>/<名前>.enabled = false` にしたプログラムは、include の展開も前処理もされない。使わないパスは `#ifdef` で中を空にするより、こちらで止めるほうが読み込みが速い
- gbuffers と shadow の本体は、Iris が頂点の形式やアルファテストの違い (ShaderKey) と Sodium の地形の 6 パスごとに別々にコンパイル・リンクする。1 つの gbuffers の本体が何十回もリンクされるので、gbuffers に重い関数を入れるとその回数分だけ読み込みが伸びる

## include と本文の大きさ

- Iris の `#include` は、ガード (`#ifndef X` / `#define X`) も `#pragma once` も見ず、`#if` の中でも `/* */` の中でも、行頭が `#include` なら毎回展開する。lib 同士が include し合うと、本文は include の経路の数だけ膨らむ
- そのため lib は `//@include "/lib/..."` の行で依存を宣言するだけにし、`#include` の行は本体の生成ブロックに `tools/gen_includes.py` が 1 回ずつ並べる。決まりは AGENTS.md のとおり
- `#include` の解決はマクロの評価より前に行われるので、`#ifdef` で読むファイルを切り替えても、どちらのファイルも本文には入る (前処理器が落とすのは中身だけ)。読み込みの時間を減らしたいなら、プログラムを分けるか `program.*.enabled` で止める
- `#include` の行の末尾にコメントを書かない。Iris はコメントもファイル名の一部として読む
- 使われない関数は、本文が大きくなるぶんの解析 (1 KB あたり約 0.3 ms、GTX 1070 での例) しか掛からず、リンク後には消える。lib に関数が多いこと自体は問題にならない

## 設定で変わる処理

- 設定で決まる分岐は `#ifdef` / `#if` か `const` で書く。uniform で分岐すると、実行しない側もコンパイルとリンクの対象になる。GTX 1070 での例: 重い関数を 480 回呼ぶ側と 1 回だけの側を選ぶシェーダーで、`#define` / `const` はリンク約 6 ms、uniform は 400〜950 ms。描画の時間はどちらも同じだった
- uniform の分岐でまとめると、レジスタの数も両側のうち多いほうで決まる (下の「パスを分けるかまとめるか」)
- ブールの設定 (`#define NAME` / `//#define NAME`) は、パックのどこかに `#ifdef NAME` か `#ifndef NAME` だけの行があるときだけ設定画面に出る。`#if defined(NAME)` や、行末にコメントのある `#ifdef` は数えない。Ray では `lib/settings/bool_refs.glsl` (`gen_settings.py` が生成) がこの行を持つ
- 値のある設定は `#define NAME 値 // [候補 候補 ...]` の形で、値は 1 トークン (数か英数字)。候補の一覧が無い行、`vec3(...)` や式の値は設定にならない。設定を変えた行は Iris が書き換え、行末のコメントは消える
- `const` が設定になるのは Iris が決めた名前 (`shadowMapResolution`、`sunPathRotation` など) だけ。colortex の形式などを設定で変えたいときは、`#define` の設定から `const` の値を作る
- 同じ名前の設定を既定値の違う 2 か所に書くと、Iris は曖昧として設定ごと無視する。設定は `lib/settings/` の 1 か所にだけ書く
- `shaders.properties` は前処理器にかけてから読む。行の途中に `#` を書かない (行頭以外の `#` は消される)。`screen`・`sliders`・`profile.*`・`iris.features.*` は前処理前の原文から読むので、`#if` の中に置いても両方の分岐の行が読まれ、同じキーは後ろの行が勝つ

## リンクの時間を抑える書き方

- NVIDIA は関数をほぼ全部 inline する。リンクの時間は「重い関数を何回呼ぶか」で決まる。同じ重い関数を多くの地点から呼ぶより、ループにまとめるか結果を共有する
- リンクの時間は命令の量に比例せず、ある大きさを超えると急に伸びる。GTX 1070 での例 (約 15 演算と 1 回の読みの関数を K 回 inline): K = 480 で 0.3 秒、720 で 0.8〜3.6 秒、1320 で 2.4〜14 秒。さらに大きくなる (K = 1440) とドライバは最適化を省き、リンクは 0.5 秒に縮むが描画は 1.6〜3 倍遅くなった。composite1 のような大きなプログラムに機能を足すと、リンクが何倍にもなりうる。足す前後で `uv run tools/gl_compile_check.py --gpu 1070 --time` を見る
- `#pragma optionNV(...)` は使わない。NVIDIA だけに効き、`unroll all` は composite1 のリンクを約 9 秒から 26〜44 秒にし、`inline none` は Ray のコード (関数の引数で成分の番号を渡す所) をリンクできなくする
- ループの展開はドライバの既定に任せる。`[[unroll]]` と `GL_EXT_control_flow_attributes` は glslang を通るが NVIDIA では構文エラーになる。展開を強めても描画は速くならなかった

## 描画の速さ

### パスを分けるかまとめるか

- レジスタはコンパイルの時に割り当てるので、1 本のシェーダーのレジスタの数は、通りうる経路のうち最も多いもので決まる。レジスタが多いと同時に動けるワープが減り (占有率)、テクスチャ読みの待ちを隠せなくなる。GTX 1070 での例: レジスタの少ない処理 A (0.76 ms) と多い処理 B (3.49 ms) を uniform で選ぶ 1 本にまとめると、A だけを実行しても 3.52 ms になった
- 全画面のパスを 1 本足す費用は、ほぼ読み書きの帯域で決まる。GTX 1070 での例 (1920x1080、1 テクセル読みと 1 テクセル書き): RGBA8・R11F_G11F_B10F・RG16F で約 0.08 ms、RGBA16F で約 0.15 ms、RGBA32F で約 0.30 ms
- この 2 つから、パスをまとめるのは、まとめる処理どうしのレジスタの使い方が近いときだけにする。重いレイマーチと軽い合成のように重さの違う処理は、分けたときの帯域の費用 (RGBA16F で 0.15 ms 程度) のほうが安いことが多いので、別のパスのままにする
- テクスチャ読みの待ちが長い処理 (レイマーチ、ボリュームライト) ほど、生かしておく値の数が効く。長いループの外で持つ値を減らす

### 分岐

- NVIDIA は 32 スレッド (ワープ) ごとに同じ命令を実行する。ワープの中で条件が分かれると両側を順に実行する。GTX 1070 での例: 条件が 4x4 画素の市松で変わると全画素が重い側と同じ時間、8x8 以上の塊で揃うと約半分になった
- 空かどうか、範囲外かどうかの早期の return のように、画面上で大きな塊になる条件だけが得をする。細かい模様で変わる条件は両側の費用を払うと考える
- 暗黙の微分を使う `texture()` を、画素ごとに変わる条件の中で呼ばない (結果は未定義)。分岐の中で読むなら `textureLod` か `textureGrad` にする

### 表と配列

- 画素ごとに違う添字でローカル配列を引くと、配列はローカルメモリ (VRAM 上のスレッドごとの領域) に置かれる。GTX 1070 での例 (16 要素の float 配列を 64 回引く): 画素ごとに違う添字 0.98 ms、全画素同じ添字 0.82 ms、添字が定数に畳まれるとき 0.19 ms。`switch` で定数の添字に書き換えると 2.58 ms でさらに遅い
- 画素ごとに違う添字で引く表 (光源のリスト、パレット) は SSBO かテクスチャに置く。GTX 1070 での例 (`vec4[256]` を 1 画素 16 回): 添字が画素ごとに違うと uniform 配列 5.3 ms・UBO 4.7 ms・SSBO 0.33 ms。全画素が同じ添字なら uniform・UBO が 0.06 ms で SSBO (0.36 ms) より速い
- 小さな表は `const` の配列にして、添字が定数になる使い方 (展開されるループのカウンタなど) で引く
- ローカル配列は NVIDIA では約 4000 要素が上限で、4095 要素以上はリンクエラー (`C5041`) になる。glslang はこれを検出しない
- sampler と image の配列は、全スレッドで同じ値 (dynamically uniform) の添字でしか引けない

### テクスチャの読み

- `texelFetch`・`texture`・`textureLod`・`textureGather` は、キャッシュに載るデータなら 1 回の読みの費用が同じだった。`texelFetch` を `texture` に替えても速くならない
- 1 成分の 4 近傍が欲しいときは `textureGather` で 1 回にする。ぼかしは双一次補間で隣り合う 2 タップを 1 回の読みにまとめる (GTX 1070 での例: 9 タップのガウスが 0.115 ms -> 5 回の双一次で 0.069 ms)
- `const bool colortexNMipmapEnabled = true` を書いたパスの前に、Iris は毎フレームそのバッファのミップを作る。ミップが要るパスだけに書く

### compute

- 水平 1 次元のぼかしでは、fragment・compute・shared memory を使う compute の間に差は無かった (GTX 1070 で 0.41〜0.48 ms)。compute にするのは、image に書く・集計するなど compute でしかできないことがあるときにする
- ヒストグラムのような集計は、shared memory に集めてからグローバルに書く。GTX 1070 での例 (256 ビン、207 万スレッド): グローバルに直接 0.94 ms、shared を経由して 0.27 ms
- `barrier()` は 1 回あたり dispatch 全体で約 7 µs (GTX 1070、207 万スレッド)。ループの内側に入れない。`barrier()` は一様な制御の流れの中でだけ呼べる
- 同じパスの compute の間と、compute と次の描画の間には、Iris が `glMemoryBarrier` (image・テクスチャ読み・SSBO) を入れる (`allowConcurrentCompute = false` のとき)。SSBO を頂点属性や間接描画の引数として読む用途のバリアは入らない
- `setup` の compute は 1x1 の画面として dispatch されるので、`workGroupsRender` (画面比) は意味を持たない。`const ivec3 workGroups` で絶対の数を書く。`setup` は画面の大きさが変わったときにも走り直す

## Iris の書式

- `/* RENDERTARGETS: 0,1,2 */` の `,` の後に空白を入れない (Iris は空白を取り除かずに数として読み、失敗する)。`DRAWBUFFERS:` は 1 桁の番号しか書けないので使わない。1 つのパスで同時に書くバッファは、`size.buffer.*` の大きさを揃える
- `RENDERTARGETS` と `const int colortexNFormat` などの指令は前処理の後の本文から読むので、`#if` で選んだ側だけが効く
- colortex の形式・クリア・ミップの `const` は、shadowcomp・begin・prepare・gbuffers・deferred・composite・final の fragment シェーダーからだけ集める (compute の中は読まない)。同じ指令が複数あると後のプログラムが勝つ。Ray では `lib/buffers/formats.glsl` に集めてある
- colortex は既定で毎フレームの最初にクリアされる。前のフレームの値を読むバッファは `colortexNClear = false` にする。画面の大きさが変わると中身は 0 に戻る。SSBO は毎フレームはクリアされず、再読み込みと (画面比の大きさなら) 画面の大きさの変更で 0 に戻る
- 全画面のパスは、書いたバッファを書き終わった後に入れ替える (読む側と書く側の 2 枚の ping-pong)。入れ替えを止めるのは `flip.<パス>.<バッファ> = false`
- compute の `X_a.csh` から `X_z.csh` は `_a` から順に読み、欠番があるとそこで止まる。`_a` を飛ばして `_b` を置かない
- `iris_`・`irisMain`・`moj_import` で始まる識別子は Iris が使うので、書くと読み込みが失敗する
- Iris の前処理器では `__VERSION__` は定義されない。`#line` は捨てられ、`#error` は読み込みを止めずログに出るだけ。前処理で止めたい条件は `#error` に頼らず、validate_shaders.py の静的チェックにする
- `IRIS_FEATURE_<名前>` のマクロは、`iris.features.optional` に書いた機能だけに付く。`required` に書いた機能 (Ray の SSBO・CUSTOM_IMAGES・COMPUTE_SHADERS) には付かないので、`#ifdef IRIS_FEATURE_SSBO` は常に偽
- ディメンションを表すマクロは Iris には無い。Ray のラッパーが定義する
- 頂点属性 (`mc_Entity`、`mc_midTexCoord`、`at_tangent`、`at_midBlock`) は、使うと Sodium の地形の頂点の形式が大きくなる。使わない属性は宣言しない
- `const float drynessHalflife` は、Iris 1.11.4 では `wetnessHalflife` の値を上書きし、乾く側の半減期は Iris の既定 (200) のまま変わらない。Ray は `wetness` を使わず、カスタム uniform の `smooth(id, 値, 上がりの半減期, 下がりの半減期)` で濡れを作る (`rainWetness`)。`smooth` の半減期も 0.1 秒単位で、最初の値は平滑化せずにそのまま使う

## 資源の上限

| 資源 | 上限 | Ray の使用数 | 確かめ方 |
|---|---|---|---|
| sampler (1 プログラム) | GL の `GL_MAX_TEXTURE_IMAGE_UNITS` = 32 (NVIDIA、Mesa)。gbuffers と shadow は Iris が 3 ユニットを使うので 29 | composite1 が 26 | `gl_compile_check.py --gpu 1070 --report` |
| image (1 ステージ、1 プログラム) | 8 (NVIDIA。GL の最小保証も 8) | opt-in で 8 以下に抑える ([architecture.md](architecture.md) の「image の宣言は opt-in」) | 同上 |
| カスタム image (`image.*`) | 16 (Iris) | 16 (空きなし) | `shaders.properties` |
| colortex | 32 (Iris) | 16 | `lib/buffers/formats.glsl` |
| SSBO (`bufferObject.N`) | 番号 0〜12 (Iris)、1 ステージ 16 ブロック (NVIDIA) | 0〜4 | `shaders.properties`、`lib/buffers/` |
| UBO の大きさ | 64 KB (NVIDIA)。GL の最小保証は 16 KB | 使っていない | - |
| compute のスレッド (1 グループ) | 1024 (NVIDIA) | - | `gl_compile_check.py` が検査する |
| shared memory (1 グループ) | 48 KB (NVIDIA)。32 KB の GPU もある | - | 同上 |
| ローカル配列 | 約 4000 要素 (NVIDIA、文書化されていない) | - | 実機のリンクでしか分からない |
| fragment の入力 (varying) | 128 成分 (NVIDIA、GL の最小保証と同じ) | - | 実機のリンク |

- カスタム image に空きは無い。新しい image が要るときは、既存の image を分け合うか、colortex か SSBO で代えられないかを先に考える
- Iris の文書と Iris のコードで上限が違う所がある (SSBO の番号、カスタム image の数)。上の表はコードの値

## 移植性

- glslang が通しても NVIDIA で落ちるもの、NVIDIA が通しても仕様では誤りのものがある。両方を通す (validate_shaders.py と gl_compile_check.py)
- NVIDIA だけが通す書き方 (AMD・Intel・Mesa では落ちうる)
  - グローバルの `const` を uniform で初期化する (`const float K = someUniform;`)。関数の中の `const` なら仕様上も正しい
  - グローバルの `const int` を uniform から作って配列の大きさに使う
- glslang が通して NVIDIA が落とすもの: `[[unroll]]`、4095 要素以上のローカル配列、`gl_FragData` と `layout(location = N) out` の併用、再帰、予約語の `packed` を名前に使う
- 予約語を変数名や関数名に使わない。間違えやすいもの: `sample`、`input`、`output`、`filter`、`common`、`partition`、`active`、`half`、`fixed`、`inline`、`long`、`short`、`packed`、`buffer`、`shared`、`patch`、`resource`
- `float16_t`、subgroup の関数、浮動小数の `atomicAdd` は拡張 (`GL_NV_gpu_shader5`、`GL_KHR_shader_subgroup_*`、`GL_NV_shader_atomic_float` など) が要る。使うときは `#extension` を書き、Iris が対応する拡張ごとに定義する `MC_<拡張名>` のマクロ (例 `MC_GL_NV_shader_atomic_float`) で分岐して、無い GPU 向けの経路を残す
- 精度の修飾子 (`mediump` など) は GLSL 4.60 では効かない。軽くする手段にしない
- 定数の 0 除算や、値を返さない非 void の関数は、どちらも通るが結果は未定義

## ドライバのキャッシュ

- NVIDIA のシェーダーのディスクキャッシュは、プログラムの全ステージのソースの文字列をそのまま鍵にしている。コメントの 1 文字、空白 1 つ、別のステージのコメントだけの違いでも外れる (GTX 1070 で確かめた)。Iris もドライバのプログラムバイナリは使っていない
- そのため、多くのプログラムが読む lib を 1 文字変えると、読むプログラムがすべてコンパイルし直しになる。設定の値が前処理後の本文に残るファイルも同じで、その設定を変えると読むプログラムがすべてやり直しになる。設定で変わる値は、それを使うプログラムだけが読むファイルに置く ([architecture.md](architecture.md) の SSBO の節)
- 生成するファイル (ラッパー、include の生成ブロック、ID の表) は、入力が同じなら同じ文字列になるようにする (並び順・日付・コメントを毎回変えない)
- 時間を測るとき、`#define` やコメントを足して作った「キャッシュの外れ」は、コードを変えたときより短く出る。GTX 1070 での例: composite1 のリンクが `#define` だけの違いで 7.3〜8.2 秒、定数を 1 つ変えると 12.0〜12.9 秒。編集の後の実際の待ち時間を見積もるなら、定数を 1 つ変えて測る

## エラーを調べる

- ゲームのドライバのエラーの行番号は、Iris が前処理と変換をした後の本文の行で、Ray の元のファイルの行とは合わない (`#line` も捨てられる)
- 元のファイルの行は、`uv run tools/gl_compile_check.py --gpu 1070` (または `validate_shaders.py`) で同じ設定・ディメンションを再現して見る。どちらも元のファイルの行番号で表示する
- それでも再現しないときは、Iris のデバッグオプション (`iris.properties` の `enableDebugOptions=true`、またはシェーダーの選択画面で Ctrl+D) を有効にする。ゲームのフォルダの `patched_shaders/` に、Iris がドライバに渡した本文が書き出され、エラーの行をそのまま見られる
- `latest.log` で見る行: `Shader compilation log for`、`Program link log for` (警告とエラー)、`Failed to create shader rendering pipeline` (リンクの失敗)、`Failed to load the shaderpack` (読み込みの失敗。`#include` の失敗、include の循環、UTF-8 でないファイル)
- GLSL のファイルは UTF-8 で書く。不正なバイトがあると読み込みが失敗する

## 出典

Iris (1.11.4、ブランチ 26.1 のソース)

- include の展開: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/include/IncludeProcessor.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/include/IncludeGraph.java
- 前処理器: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/preprocessor/JcppProcessor.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/preprocessor/PropertiesPreprocessor.java 、Iris が使う前処理器 JCPP 1.4.14: https://github.com/shevek/jcpp
- 環境マクロ: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/gl/shader/StandardMacros.java
- 設定の検出: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/option/OptionAnnotatedSource.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/option/OptionSet.java
- プログラムと指令: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/programs/ProgramSet.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/properties/PackDirectives.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/properties/PackRenderTargetDirectives.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/parsing/CommentDirectiveParser.java
- 変換と識別子の制限: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/pipeline/transform/TransformPatcher.java
- パイプラインの作成と compute のバリア: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/pipeline/IrisRenderingPipeline.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/pipeline/CompositeRenderer.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/gl/program/ComputeProgram.java
- 資源: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/gl/IrisLimits.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/samplers/IrisSamplers.java 、https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/shaderpack/properties/ShaderProperties.java
- ShaderKey: https://github.com/IrisShaders/Iris/blob/26.1/common/src/main/java/net/irisshaders/iris/pipeline/programs/ShaderKey.java
- 機能の文書: https://github.com/IrisShaders/ShaderDoc/blob/master/iris-features.md 、https://github.com/IrisShaders/ShaderDoc/blob/master/passes/compute.md
- デバッグオプション: https://github.com/IrisShaders/Iris/blob/trunk/docs/usage/debugging.md

Khronos

- GLSL 4.60 仕様 (定数式、精度、暗黙の変換、関数の呼び出し、動的に一様な式、予約語、組み込み定数): https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html
- KHR_parallel_shader_compile: https://registry.khronos.org/OpenGL/extensions/KHR/KHR_parallel_shader_compile.txt
- ARB_get_program_binary: https://registry.khronos.org/OpenGL/extensions/ARB/ARB_get_program_binary.txt

ベンダー

- NVIDIA, Fast Dynamic Indexing of Private Arrays in CUDA: https://developer.nvidia.com/blog/fast-dynamic-indexing-private-arrays-cuda/
- NVIDIA, Identifying Shader Limiters with the Shader Profiler in NVIDIA Nsight Graphics: https://developer.nvidia.com/blog/identifying-shader-limiters-with-the-shader-profiler-in-nvidia-nsight-graphics/
- NVIDIA Nsight Graphics, Shader Profiler: https://docs.nvidia.com/nsight-graphics/UserGuide/shader-profiler.html
- NVIDIA Linux ドライバ README, OpenGL のシェーダーのディスクキャッシュ: https://download.nvidia.com/XFree86/Linux-x86_64/580.65.06/README/openglenvvariables.html
- Mesa の環境変数 (シェーダーキャッシュ): https://docs.mesa3d.org/envvars.html
