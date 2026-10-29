# アーキテクチャ

独自 Minecraft シェーダーパック Ray の設計。`shaders/` のパイプライン・バッファ・ID・モジュール構成と、各手法の選定理由を説明する。

- 対象: Iris 1.8+ / Minecraft 1.21.x 〜 26.x (Java)。OptiFine 非対応 (SSBO・カスタムイメージ・compute・`currentRenderedItemId`・`shadow_entities` を前提)
- GLSL: gbuffers / composite 系は `#version 460 compatibility`、compute は `#version 460`
- 画質優先 + 9 段階プリセット (LOW / MEDIUM / HIGH_FASTEST / HIGH_FAST / HIGH / ULTRA / EXTREME_LITE / EXTREME_BALANCED / EXTREME, 軽い順)。素の既定値 = HIGH

## 目次

- [全体方針](#全体方針)
- [ディレクトリ構成](#ディレクトリ構成)
- [レンダーパイプライン](#レンダーパイプライン)
- [バッファ設計](#バッファ設計)
- [ID 設計](#id-設計)
- [ボクセル化](#ボクセル化)
- [ブロックライト](#ブロックライト)
- [手法の選定](#手法の選定)
- [設定とプリセット](#設定とプリセット)
- [モジュール構成](#モジュール構成)
- [規約・単位・検証](#規約単位検証)
- [既知の制約と未決事項](#既知の制約と未決事項)

---

## 全体方針

| 方針 | 内容 |
|---|---|
| デファード | 不透明は G バッファ -> deferred でまとめて照明。半透明は前方シェーディングして composite で合成。Iris の標準構成で、光源計算 (ブロックライト・GI) を 1 回だけにできる |
| ボクセルが光の基盤 | shadow パスで地形 + エンティティをボクセル化し、floodfill・光源シャドウ・GI・反射の全部で共有 |
| 光は「間接 = floodfill、直接 = レイ」 | floodfill を色と広がり (間接光) に、上位 N 光源の DDA を影 (直接光) に使う二段構え |
| 計算する所と BRDF を掛ける所を分ける | 光源側 (light: ブロック/手持ち, sky: 太陽/空) は `LightSample` で照度と方向を返し、BRDF は surface だけが掛ける |
| 1 か所の本体 + 薄いラッパー | `shaders/program/<モジュール>/` に本体 1 セット、`world0/-1/1` は本体の include とマクロの定義だけ |
| 重い機能は丸ごと外せる | `#ifdef` + `program.<world>/<pass>.enabled` |
| ルック | AgX + 非対称自動露出 + 控えめブルーム (iterationT)、雲・フォグ・DoF は Nostalgia / Kappa、ブロックライトは中性色 |

---

## ディレクトリ構成

```
README.md / CREDITS.md / LICENSE / AGENTS.md / .gitignore
pyproject.toml / uv.lock / .python-version     tools 用の Python 環境 (uv)
docs/architecture.md
tools/
  gen_wrappers.py                           ディメンション別ラッパーと shaders.properties の program.*.enabled の生成 (プログラム一覧、プログラムごとの本体・マクロ、設定で止めるプログラムの正本)
  gen_block_properties.py, id_tables.py     ID の定数・block / item / entity.properties・光源の表のデータの生成 (正本)
  gen_blue_noise.py / gen_cloud_noise.py / gen_water_waves.py / gen_lens_textures.py
                                            shaders/textures/ のテクスチャの生成
  gen_lens_ghosts.py                        lib/post/lens_ghosts.glsl (レンズゴーストの定数表) の生成
  gen_look_lut.py, look_luts/*.json         ルックの LUT (textures/look/) の生成・.cube や PNG ストリップとの変換・確認
  validate_shaders.py                       Iris 前処理の簡易再現 + glslangValidator 検証 + 静的チェック
  gl_compile_check.py                       同じ前処理結果を実機の GL ドライバで compile + link、上限値との比較
  pass_preview.py                           パス 1 つ (または順に複数) を実機で描いて・dispatch して画像と数値で保存する
  lib/                                      スクリプト共通の部品 (リポジトリの場所、sRGB、PNG の書き出し、生成物の書き込み・確認、shaders.properties の読み取り)
  mc.py / run_scene.py / shader_options.py  ゲーム内デバッグのクライアント・定点シーン撮影・Iris の設定の読み書き
  minescript/ray_agent.py, ray_steps.py     ゲーム内に常駐して手順を実行する Minescript スクリプト
  scenes.example.json                       定点シーンの雛形
shaders/
  shaders.properties  block.properties  item.properties  entity.properties  dimension.properties
  lang/en_US.lang  lang/ja_JP.lang
  textures/                                 blue_noise.png, lens_dirt.png, cloud_*.dat, lens_starburst.dat, water_waves.dat (+ .mcmeta)
  textures/look/                            user_lut.png (ユーザーの LUT、恒等), split_tone.dat, film.dat, portra.dat, ektar.dat, vision3_500t.dat, velvia.dat, provia.dat, eterna.dat (同梱の LUT) (+ .mcmeta)
  lib/settings.glsl                         設定の入口 (lib/settings/ のファイルを宣言する)
  lib/settings/*                            全設定の定義 (look / light / surface / sky / post のモジュールごと)、導出値 (internal)、ブールの参照 (bool_refs、gen_settings.py が生成)
  lib/common/*   lib/buffers/*   lib/ids/*  共通基盤
  lib/light/*                               light モジュール
  lib/sky/*                                 sky モジュール
  lib/surface/*                             surface モジュール
  lib/post/*                                post モジュール
  program/common/fullscreen.vsh             全画面クアッドの頂点シェーダー (composite / deferred / final が共有)
  program/light/*  sky/*  surface/*  post/*   各パスの本体 (モジュールごと。ファイル名は役割名で、プログラム名との対応は tools/gen_wrappers.py の BODIES)
  program/surface/gbuffers_*.vsh|fsh        gbuffers_* が共有する本体 (GBUF_* マクロで分岐)
  world0/  world-1/  world1/                gen_wrappers.py が生成するラッパー (WORLD_* と本体のマクロを定義して本体を include)
```

`lib/settings.glsl` (`lib/settings/`) と共通基盤 (`lib/common`, `lib/buffers`, `lib/ids`) はパイプライン全体から参照される。変更すると全プログラムに影響するので、関数シグネチャを変えるときは呼び出し側もすべて直し、docs/architecture.md の表も更新する。

---

## レンダーパイプライン

Iris の実行順 (setup -> begin -> shadow -> shadowcomp -> prepare -> gbuffers 不透明 -> deferred -> gbuffers 半透明 -> composite -> final)。
番号はモジュールごとに帯を分けてある (deferred: light 0-9 / surface 10-19 / sky 20-29 / surface 30, composite: surface 0-9 / sky 10-19 / post 20-39)。VL の compute は使う所の直前に置くため composite1_a (sky)。空き番号は将来の追加用。

| # | プログラム | モジュール | 役割 | 主な入力 | 主な出力 | dispatch / 解像度 | 有効条件 |
|---|---|---|---|---|---|---|---|
| 1 | setup.csh | light | 光源・形状・透過色・ブロックの平均の色の表を SSBO に構築、FrameData 初期化 | `lib/light/light_table.glsl`, `light_table_data.glsl` | SSBO1 BlockData, SSBO0 | local 256, groups (1,1,1) | 常時 |
| 2 | setup1.csh | sky | 大気の透過率 LUT (Hillaire 2020) | - | skyTransmittanceImg 256x64 | local 8x8, (32,8,1) | ATMOSPHERE_MODE=1, world0 |
| 3 | setup2.csh | sky | 多重散乱 LUT | skyTransmittance | skyMultiScatterImg 32x32 | local 8x8, (4,4,1) | 同上 |
| 4 | begin.csh | light | 光源リストとライトビン (前フレームに使った枠) とエンティティ光源の蓄積表のクリア | - | SSBO2 カウンタ, SSBO3 binCount/binLights/entityAcc | local 256, (160,1,1) | 常時 |
| 5 | shadow.vsh/fsh | light | 地形の太陽影マップ + 地形ボクセル化 (頂点シェーダーで imageStore) | mc_Entity, at_midBlock | shadowtex0/1, shadowcolor0/1, voxelBlockImg | shadowMapResolution | 常時 |
| 6 | shadow_entities.vsh/gsh/fsh | light | エンティティのボクセル化 (GS で表面サンプル)・エンティティ光源登録・影マップ | entityId, currentRenderedItemId | voxelEntityImg, voxelEmitImg, SSBO2, 影マップ | 同上 | shadowEntities |
| 7 | shadow_block.vsh/gsh/fsh | light | ブロックエンティティ版 (本体共通, `PROGRAM_SHADOW_BLOCK`) | blockEntityId | voxelEntityImg, 影マップ | 同上 | shadowBlockEntities |
| 8 | prepare.csh | sky | 太陽・月の直達照度、空の SH (全モジュールが使う光の色) | skyView / 解析式 | SSBO0 sun/moon/shadowLight/skySH | (1,1,1) | 常時 |
| 9 | prepare1.csh | sky | SkyView LUT | transmittance, multiScatter | skyViewImg 192x108 | local 8x4, (24,27,1) | ATMOSPHERE_MODE=1, world0 |
| 10 | prepare2.csh | sky | 雲の天気マップと雲影マップ | - | cloudWeatherImg, cloudShadowImg 512² | local 16², (32,32,1) | CLOUDS>=2, world0 |
| 11 | gbuffers_* (不透明) | surface (空/雲は sky) | G バッファ書き込み、TAA ジッター、エンティティ光源登録 (light の関数) | アトラス | colortex1,2,3,15 / voxelEmitImg, SSBO2 | 画面 | 常時 |
| 12 | deferred.csh | light | floodfill 1 ステップ伝搬 + ブロック光源・エンティティ光源をグローバルリストへ | voxelBlock/Emit, flood(前) | flood(今), SSBO2 | local 8³, VOXEL_SIZE/8 | 常時 |
| 13 | deferred_a.csh | light | 光源をワールド空間ライトビン (8³ ブロック) に重要度の降順で振り分け (LIGHT_CULL_MODE)、次フレームの間引き距離を更新 | SSBO2 | SSBO3, SSBO2 cullDistance | local 64, (LIGHT_MAX_COUNT/64,1,1) | 常時 |
| 14 | deferred1.csh | light | LIGHT_TRACE_COUNT 光源 (上位 N-1 個 + 残りから確率的に 1 個) の DDA トレース (直接光) | SSBO3, voxel*, G バッファ | blockLightRawImg (影あり S), blockLightAuxImg (影なし U) (左上 1/RES) | local 8², workGroupsRender = 1/LIGHT_TRACE_RES | LIGHT_SHADOWS |
| 15 | deferred2.vsh/fsh | light | 可視率 S/U の時空間デノイズ + フル解像度の影なし照度に掛ける | blockLightRaw/Aux, colortex7 | colortex6, colortex7 | 画面 | LIGHT_SHADOWS |
| 16 | deferred10.csh | surface | GI / AO の生値 (RSM / SSGI / ボクセル RT)。多重反射は画面に映るヒット点の前フレームの GI (colortex9) | G バッファ, shadowcolor, voxel, flood, colortex9 | giRawImg | local 8², 1/GI_RES | GI_MODE>0 or AO_MODE>0 |
| 17 | deferred11.vsh/fsh | surface | GI / AO のデノイズ | giRaw, colortex9 | colortex8, colortex9 | 画面 | 同上 |
| 18 | deferred20.vsh/fsh | sky | 体積雲レイマーチ (低解像度 + チェッカーボード) | weather, skyView | colortex10 (左上 1/CLOUD_RES) | 画面 (範囲外は早期終了) | CLOUDS>=2, world0 |
| 19 | deferred21.vsh/fsh | sky | 雲の時間アップスケール | colortex10, 履歴 | colortex11 | 画面 | 同上 |
| 20 | deferred30.vsh/fsh | surface | 不透明シェーディング (全モジュールの光を合成) + 空の描画 | G バッファ, colortex6/8/11, SSBO0 | colortex0 | 画面 | 常時 |
| 21 | gbuffers_water / hand_water / particles_translucent / weather / clouds | surface (weather・clouds は sky) | 半透明の前方シェーディング (clouds は CLOUDS=1 のバニラの雲。deferred の後に描かれるので前方で色を決め、colortex4 だけに書く) | アトラス, 影, flood | colortex4 (乗算済み), colortex5 | 画面 | 常時 |
| 22 | composite.csh | surface | 反射 (SSR / ラフ / ボクセル補完) | colortex0/2/3/5, voxel | reflectionImg | local 8², 0.5 | REFLECTIONS>0 |
| 23 | composite1_a.csh | sky | VL / 高さフォグのレイマーチ (影マップ空間 + floodfill + 雲影) | 影マップ, flood, cloudShadow | colorimg12 (左上 1/VL_RES), fogHistoryImg | local 8², 1/VL_RES | VL |
| 24 | composite1.vsh/fsh | surface | 半透明合成 (屈折・水中吸収・反射) | colortex0/4/5, reflectionImg | colortex0 | 画面 | 常時 |
| 25 | composite11.vsh/fsh | sky | フォグ / VL の適用 (バイラテラルアップサンプル)、水中フォグ、カメラが雲より上のときの手前の雲 (半透明が手前の画素は `cloudFrontPart` でカメラから半透明までの分に割り引く) | colortex0/12 | colortex0 | 画面 | 常時 |
| 26 | composite20.vsh/fsh | post | TAA (LENS_WARP_TAA の時は歪曲・魚眼の組み立ても) | colortex0/13/15 | colortex0, colortex13 | 画面 | TAA |
| 27 | composite21.vsh/fsh | post | モーションブラー | colortex0/15 | colortex0 | 画面 | MOTION_BLUR |
| 28 | composite22.vsh/fsh | post | DoF (MIP-Bokeh, colortex0 ミップ) | colortex0, SSBO0 focus | colortex0 | 画面 | DOF |
| 29 | composite23.vsh/fsh | post | ブルーム縮小タイル | colortex0 ミップ | colortex14 | 画面 | BLOOM |
| 30 | composite24.vsh/fsh | post | ブルームぼかし | colortex14 | colortex14 | 画面 | BLOOM |
| 31 | composite25.csh | post | 自動露出 (ヒストグラム) + オートフォーカス | colortex0, centerDepthSmooth | SSBO0 exposure/focus/histogram | local 16², (1,1,1) | 常時 |
| 32 | final.vsh/fsh | post | 歪曲と魚眼の再投影・ブルーム合成・フレア・露出・AgX・色調整・CAS・ディザ・デバッグ表示 | colortex0/14, SSBO0 | 画面 | 画面 | 常時 |

補足
- shadowcomp は使わない。floodfill を deferred に置くのは、gbuffers_entities (deferred より前) が登録した画面内のエンティティ光源を同じフレームで取り込むため (voxelEmitImg は毎フレームクリアされる)
- Iris は同じパスの compute (composite1_a) を fragment (composite1) の前に走らせる。VL の有効条件は `program.<world>/composite1_a.enabled` で、composite1 の fragment は止まらない
- ネザー・エンドは大気 LUT と雲のパスを外す (shaders.properties)。shadow パスはボクセル化のため全ディメンションで回す
- `particles.ordering = mixed`: 不透明パーティクルは G バッファ (gbuffers_particles)、半透明は前方 (gbuffers_particles_translucent)
- DH (Distant Horizons) は未対応 (dh_* プログラムなし)

---

## バッファ設計

### colortex (16 枚。正本は `lib/buffers/formats.glsl`)

| buf | フォーマット | 内容 | 書く | 読む | クリア |
|---|---|---|---|---|---|
| 0 | RGBA16F | シーン HDR。空テクスチャ (skybasic/skytextured) -> deferred30 -> composite* -> final | sky(空), surface, sky, post | 全 | 毎フレーム |
| 1 | RGBA8 | G: rgb アルベド (sRGB エンコード), a マテリアル ID | surface (gbuffers) | 全 | 毎フレーム |
| 2 | RGBA16 | G: rg テクスチャ法線 (oct), b 幾何法線 (oct 8+8), a ライトマップ (8+8) | surface | 全 | 毎フレーム |
| 3 | RGBA16 | G: r smoothness+f0, g sss+emission, b ao+wetness, a 予備 | surface | 全 | 毎フレーム |
| 4 | RGBA16F | 半透明の色 (乗算済みアルファ, 既定ブレンドで自然にそうなる) | surface, sky(雨) | surface | 毎フレーム |
| 5 | RGBA16 | 半透明のデータ: rg 法線, b ライトマップ, a マテリアル ID | surface | surface, sky | 毎フレーム |
| 6 | RGBA16F | light: ブロックライト直接光 (拡散照度, デノイズ済み) | light (deferred2) | surface (light の関数経由) | 毎フレーム |
| 7 | RGBA16F | light: ブロックライト履歴 | light | light | 永続 |
| 8 | RGBA16F | surface: rgb 間接光照度, a AO | surface (deferred11) | surface, post(debug) | 毎フレーム |
| 9 | RGBA16F | surface: GI 履歴 | surface | surface | 永続 |
| 10 | RGBA16F | sky: 雲 (低解像度) rgb 散乱, a 透過率 | sky | sky | 永続 |
| 11 | RGBA16F | sky: 雲 (フル解像度, 時間蓄積) | sky | surface (sky の関数経由), sky | 永続 |
| 12 | RGBA16F | sky: VL / フォグ (低解像度) rgb 内散乱, a 透過率 | sky | sky | 永続 |
| 13 | RGBA16F | post: TAA 履歴 | post | post | 永続 |
| 14 | RGBA16F | post: ブルームタイル | post | post | 毎フレーム |
| 15 | RGBA16F | 速度: rg = 前フレーム UV - 今の UV, a = 1 なら有効 (エンティティ・手) | surface (gbuffers, post の関数) | post | 毎フレーム |

- gbuffers では colortex0-3 を読めない (Iris の仕様)
- `shadowcolor0` RGBA8: 最も太陽側の面の色 (半透明は透過色 + a 不透明度、不透明は a=1)。`shadowcolor1` RGBA16: rg 法線 (oct), b スカイライト, a 種別 (0 不透明 / 0.2 葉 / 0.5 半透明 / 1 水)。RSM (surface) と色付き影・葉の透過 (surface) と色付き光芒 (sky) が読む

### カスタムイメージ (16 枚すべて使用。正本は `lib/buffers/images.glsl` + shaders.properties。GLSL の宣言は下の「opt-in」を参照)

| イメージ / サンプラー | フォーマット | サイズ | クリア | モジュール | 内容 |
|---|---|---|---|---|---|
| voxelBlockImg / voxelBlockSampler | R16UI | VOXEL_SIZE | 毎フレーム | light | bits 0-11 ブロック ID (0 空気, 1 未登録固体), 12-15 発光レベル |
| voxelEntityImg / voxelEntitySampler | R32UI | VOXEL_SIZE | 毎フレーム | light | bits 0-7 エンティティ占有 (2x2x2 サブセル), 8-15 自分の占有 |
| voxelEmitImg / voxelEmitSampler | R32UI | VOXEL_SIZE | 毎フレーム | light | エンティティ光源キー `(level<<8)|lightIndex` を atomicMax |
| floodImgA / B (floodSamplerA / B) | R11F_G11F_B10F | VOXEL_SIZE | 永続 | light | floodfill ピンポン (偶数フレームは A に書く) |
| skyTransmittanceImg | RGBA16F | 256x64 | 永続 | sky | 透過率 LUT |
| skyMultiScatterImg | RGBA16F | 32x32 | 永続 | sky | 多重散乱 LUT |
| skyViewImg | RGBA16F | 192x108 | 永続 | sky | SkyView LUT (毎フレーム更新) |
| cloudShadowImg | R16F | 512x512 | 永続 | sky | 雲影マップ |
| cloudWeatherImg | RGBA8 | 512x512 | 永続 | sky | 天気マップ (R 下層被覆 / G 上層 / B アンビル / A 予備, Kappa 方式) |
| blockLightRawImg | RGBA16F | 画面 1.0 | 永続 | light | トレース生値: rgb 影あり照度 S, a 視線方向の距離 (左上 1/LIGHT_TRACE_RES を使用) |
| blockLightAuxImg | RGBA16F | 画面 1.0 | 永続 | light | rgb 同じ光源選択での影なし照度 U, a 寄与最大の光源インデックス (鏡面用) |
| giRawImg | RGBA16F | 画面 1.0 | 永続 | surface | GI / AO 生値 |
| reflectionImg | RGBA16F | 画面 1.0 | 永続 | surface | 反射 |
| fogHistoryImg | RGBA16F | 画面 1.0 | 永続 | sky | VL の時間蓄積 |
| debugImg | RGBA16F | 画面 1.0 | 毎フレーム | 全員 | デバッグ出力。IMG_DEBUG を定義したプログラムが書き、DEBUG_VIEW=12 で表示 (現在書いているプログラムはない) |

VOXEL_SIZE = VOXEL_VOLUME に応じて 128x64x128 / 192x96x192 / 256x128x256 / 384x128x384。
メモリ目安 (256x128x256): voxel 16MB + 32MB x2、flood 32MB x2 = 約 144MB。

#### image の宣言は opt-in (プログラムごとに 8 個まで)

NVIDIA は 1 ステージで宣言できる image uniform が 8 個まで (`GL_MAX_*_IMAGE_UNIFORMS` = 8、未使用でも宣言数で数えて `C7624` でリンク失敗)。
Iris も 1 プログラムに割り当てる image unit が `GL_MAX_IMAGE_UNITS` (= 8) まで。そのため `lib/buffers/images.glsl` は image を `#ifdef IMG_*` で囲み、
各プログラムが `common.glsl` を宣言 (`//@include`) する前に書く image だけを `#define` する (sampler 側は `#ifdef` で囲まず常に宣言している)。
image を使うライブラリ関数も同じマクロで囲む (`voxelizeTerrainVertex` = IMG_VOXEL_BLOCK, `voxelizeEntityTriangle` = IMG_VOXEL_ENTITY, `injectEntityLight` = IMG_VOXEL_EMIT)。

| マクロ | image | 定義しているプログラム |
|---|---|---|
| IMG_VOXEL_BLOCK | voxelBlockImg | shadow.vsh, deferred.csh |
| IMG_VOXEL_ENTITY | voxelEntityImg | shadow_entities.gsh / shadow_block.gsh |
| IMG_VOXEL_EMIT | voxelEmitImg | shadow_entities.gsh / shadow_block.gsh, surface/gbuffers_solid.vsh (GBUF_ENTITIES), deferred.csh |
| IMG_FLOOD | floodImgA + floodImgB | deferred.csh |
| IMG_SKY_TRANSMITTANCE / IMG_SKY_MULTISCATTER / IMG_SKY_VIEW | 大気 LUT | setup1 / setup2 / prepare1 |
| IMG_CLOUD_SHADOW + IMG_CLOUD_WEATHER | 雲 | prepare2 |
| IMG_BLOCKLIGHT_RAW + IMG_BLOCKLIGHT_AUX | ブロックライト | deferred1 |
| IMG_GI_RAW / IMG_REFLECTION | GI / 反射 | deferred10 / composite.csh |
| IMG_COLORIMG12 + IMG_FOG_HISTORY | VL | composite1_a.csh |
| IMG_DEBUG, IMG_COLORIMG0/6/8/10/14 | デバッグ / colortex への compute 書き込み | 使うモジュールが追加する |

`tools/gl_compile_check.py` がプログラムごとの宣言数・アクティブ数を実機の上限と比べる。

### SSBO (正本は `lib/buffers/` の binding ごとのファイル)

- 1 binding = 1 ファイルで、ファイル名はアクセサ名 (`frame_data.glsl`, `block_data.glsl`, `global_lights.glsl`, `light_bins.glsl`, `entity_tris.glsl`)。使うファイルだけが宣言し、使わないプログラムは宣言しない (NVIDIA は使っていない宣言もリンクで扱うので、宣言が減るとコンパイルが速くなる)。レイアウトは宣言するプログラムの間で同じでなければならない (Iris の仕様)。`tools/equiv_check.py --layout` で前後のオフセットを比べられる
- 既定は `readonly`。書くプログラムは最初の宣言の前に `SSBO_<名前>_WRITE` を定義する (下の表の「書く」)。書く関数 (`entityAccAdd`・`injectEntityLight`・`storeEntityTriangle` など) は同じマクロで囲み、書かないプログラムには入らない。`readonly` のブロックに書くとコンパイルエラーになるので、定義の漏れは検証で見つかる

- 各ブロックの最後の配列は大きさなし (`[]`) で宣言し、確保量は shaders.properties の `bufferObject.N` で決める。NVIDIA のリンクは、使っていなくても宣言された固定長の配列の要素数に比例して時間がかかり (`binLights` が 266 万要素あった時は main が空のプログラムでも vs+fs で 7-10 秒)、全プログラムに入るので読み込み全体が数倍になる
- 大きさなしの配列の要素数は宣言の行の注記 `// 要素数: <定数>` に書き、添字の上限もその定数で見る (`.length()` は使わない)。`tools/gl_compile_check.py` が注記を読み、配列の先頭 + 要素の間隔 x 要素数が `bufferObject.N` に収まるかをプログラムごとに確かめる
- `lib/buffers/` には設定の値を入れない (宣言を読む全プログラムで、設定の値が前処理後の本文に残ると、その設定を変えるたびにドライバのキャッシュが外れる)。設定で変わる大きさ (`GLOBAL_LIGHTS_MAX`, `LIGHT_BIN_CAPACITY` / `STRIDE` / `STRIDE_ALLOC` / `GRID`, `LIGHT_BIN_KEYS_ALLOC`) は `lib/light/light_bins.glsl` に置き、`lib/light/light.glsl` を宣言するプログラム (world0 で 23 個) だけが読む。LIGHT_BIN_LIGHTS・LIGHT_MAX_COUNT・LIGHT_CULL_MODE を変えた時に作り直すのはこの 23 個 (前は 53 個全部)。VOXEL_VOLUME は `lib/common/voxel_space.glsl` の `VOXEL_SIZE` が全プログラムに入るので、まだ全部作り直しになる
- ブロックの途中の配列 (`albedo`, `lights`, `binCount`, `entityAcc`, `groupBounds`, `clusterBounds`) は固定長のまま。合わせても 1 プログラム 0.4 秒程度で、並べ替えるとレイアウトが変わるので動かしていない

| binding | 名前 (アクセサ) | ファイル | サイズ | 内容 | 書くプログラム (`SSBO_<名前>_WRITE`) |
|---|---|---|---|---|---|
| 0 | FrameDataBuffer (`frameData`) | `frame_data.glsl` | 4096 | post: exposure, exposureTarget, averageLuminance, focusDistance, histogram[256], postParams[] (4 個) / sky: sunIrradiance, moonIrradiance, shadowLightIrradiance, skySH[9], skyParams[4] (`[3]` = 目の位置の太陽の見え方: x 今フレーム (フレア用)、y 平滑化済み (影マップより遠いフォグ用)) / light: lightStats / surface: surfaceParams[4] | `FRAME_DATA`: setup (初期値), begin・deferred_a (lightStats), prepare (sky), composite25 (post) |
| 1 | BlockDataBuffer (`blockData`) | `block_data.glsl` | 57344 | `LightDef lightDefs[256]`, `uvec4 shapes[128]`, `vec4 tints[128]`, `uint albedo[4096]` (ブロックの平均の色), `uint albedoUp[]` (上向きの面の色、4096 個) | `BLOCK_DATA`: setup のみ |
| 2 | GlobalLightsBuffer (`globalLights`) | `global_lights.glsl` | 295200 | `count/blockCount/entityCount/overflow`, `cullDistance/culled` + `cullHist[64]` (間引き距離と距離の分布), `LightInstance lights[8192]` (posRadius: ボクセル空間位置 + 到達半径, colorSize: 放射 + 光源半径), `lightPower[]` (揺らぎ前の放射の輝度、8192 個)。使うのは LIGHT_MAX_COUNT 個まで | `GLOBAL_LIGHTS`: setup, begin, deferred, deferred_a |
| 3 | LightBinsBuffer (`lightBins`) | `light_bins.glsl` | 10944512 (LIGHT_BIN_LIGHTS > 64 で 21430272) | `binCount[40960]`, `entityAcc[32768]` (エンティティ光源の蓄積表), `binLights[]` (40960 x 65 個、> 64 で x 129)。ビン = 8³ ブロック、1 ビン LIGHT_BIN_LIGHTS + 1 枠。枠のキー = 重要度 19 bit + 光源インデックス 13 bit | `LIGHT_BINS`: setup, begin, deferred_a, shadow_entities・shadow_block の gsh と gbuffers_entities・gbuffers_entities_translucent の vsh (蓄積表) |
| 4 | EntityTriangleBuffer (`entityTris`) | `entity_tris.glsl` | 838672 | `counts[4]`, `groupBounds`, `clusterBounds` + `EntityTriangle tris[]` (16384 個) (ボクセル空間の三角形 v0/e1/e2 + アルファマスク) | `ENTITY_TRIS`: begin (クリア), shadow_entities・shadow_block の gsh |
| 5-8 | - | - | - | 予備 | - |

world0 の既定値で SSBO を 1 つも宣言しないのは 17 プログラム (gbuffers の 14 と composite21/23・deferred11)。frameData だけを宣言するのは 13 プログラム (prepare・prepare1/2・setup1/2・composite20/22/24/25・deferred20/21・gbuffers_lightning/skytextured)。光源モジュール (`lib/light/light.glsl`) を読むプログラムは 5 つすべてを宣言する

```glsl
struct LightDef {
    vec4 color;   // rgb = 線形色 (最大成分 1), a = 明るさ倍率
    vec4 shape;   // xyz = ブロック内の発光中心, w = 光源半径 (半影用)
    vec4 params;  // x = レベル 15 時の到達半径, y = フリッカー量, z = 既定レベル, w = 予備
    uvec4 info;   // x = LIGHT_FLAG_*, y = 遮蔽形状, zw = 予備
};
struct LightInstance {
    vec4 posRadius;  // xyz = ボクセル空間位置 (今フレーム), w = 到達半径
    vec4 colorSize;  // rgb = 放射 (色 x 明るさ x レベル/15 x BLOCKLIGHT_ILLUMINANCE x BLOCKLIGHT_BRIGHTNESS), a = 光源半径
};
```

---

## ID 設計

### block.properties (`mc_Entity.x` / `blockEntityId`)

| 帯 | 意味 | 例 |
|---|---|---|
| (未登録 = -1) | ボクセルでは 1 (完全な固体) として扱う | 石・土 |
| 10-19 | マテリアルのヒント付き固体 | 10 金属, 11 光沢石, 12 雪 |
| 100-129 | 光を遮らない植物・小物 | 100 草花, 101/102 背の高い植物の下/上, 103 葉, 104 つる, 105 作物, 106 小物 (レール・ボタン・看板・開いたドア…), 107 クモの巣, 108 スイレンの葉, 109 サトウキビ, 110 水中植物 |
| 200-299 | 半透明 (透過色 index = id - 200) | 200 水, 201 氷, 202 ガラス, 203 ガラス板, 204 スライム, 205 ハチミツ, 206 遮光ガラス, 210-225 色付きガラス, 230-245 色付きガラス板 |
| 300-399 | 部分形状 (形状 index = id - 300) | 300/301 ハーフ下/上, 304 フェンス, 305 塀, 306 鉄格子, 307 背の低いブロック, 308 雪の層, 309 閉じたドア・トラップドア, 320-335 階段 (向き 4 x 外角 4 の形 x 下/上。内角は直線に含める) |
| 1001-1255 | 光源 (光源インデックス = id - 1000) | 1001 たいまつ … 1062 トライアルスポナー |
| 2000-4095 | 色の付いた固体 (遮蔽・マテリアルは未登録の固体と同じ)。上の帯に無いブロックを平均の色ごとにまとめたもの | 羊毛・コンクリート・石・板材 (使用中は 2000-2351) |

- ボクセルには下位 12bit しか入らないので 4095 を超える ID は作らない
- ブロックの平均の色は `tools/gen_block_colors.py` がクライアント jar のテクスチャから `tools/block_colors.json` に書き (面積と不透明度で重み付けした線形の平均。草・葉・水は平原の色で代表)、`gen_block_properties.py` が 2000 番台の ID と `lib/ids/block_albedo.glsl` (ID ごとの色の定数表) を作る。setup.csh が SSBO1 `blockData.albedo[4096]` に展開し、実行時は `getBlockAlbedo(voxelId)` で引く (floodfill の照り返し、ボクセル RT の画面外の当たり)。上面の色が全体の平均と違うブロック (草ブロック・原木など) は json の `top` に上面だけの平均を持ち、`blockData.albedoUp[4096]` に展開してレイの当たりで `getBlockAlbedo(voxelId, faceNormal)` が上向きの面に使う (草ブロックの全面の平均は側面の土で茶色)。2000 番台以外の ID はその ID に載せたブロックの平均、未登録 (1) は線形 0.3 の灰色
- ブロックの状態 (`lit=true`, `berries=true`, `waterlogged=true` 等) で光る状態だけを光源 ID に入れる。光らない状態は 106 等へ
- 正本は `tools/id_tables.py` (光源・エンティティ・ID の定数) と `tools/gen_block_properties.py` (光源でないブロックの表)。block / item / entity.properties と、GLSL 側の定数 `lib/ids/{block,light,entity}_ids.glsl` を同じ表から生成する
- 状態フィルタは 1 プロパティ 1 値の完全一致 (Iris `BlockMaterialMapping.checkState`)。`charges=1,2,3,4` のようなカンマ区切りは何にも一致しないので、値ごとに別エントリに展開する (`state_values()`)
- `*.properties` は ASCII だけで書く。Iris は ISO-8859-1 で読み、Java の `\R` (U+0085 を含む) で行分割してから C プリプロセッサに通すため、UTF-8 の日本語はコメント行でも途中で割れて `Bad token` になり、そのファイルの前処理全体が失敗する (shaders.properties なら設定・イメージ・SSBO がすべて無視される)

### 光源インデックスと光源テーブル

| 帯 | 種類 | 対応する ID |
|---|---|---|
| 0 | 光らない | - |
| 1-127 | ブロック光源 | block / item の 1000 + index |
| 128-191 | アイテム専用光源 (溶岩バケツ・グロウストーンダスト・ブレイズロッド…) | item の 1000 + index |
| 192-255 | エンティティ光源 | entity の 5100 + (index - 192) |

データの流れ:

```
lib/light/light_table_data.glsl  lightDefStatic(index)   (tools/id_tables.py から生成, sRGB で記述)
lib/light/light_table.glsl       shapeStatic(i) / tintStatic(i)   (正本)
        | setup.csh が起動時に評価
        v
SSBO1 blockData.lightDefs[256] / shapes[128] / tints[128] / albedo[4096] / albedoUp[4096] (lib/ids/block_albedo.glsl から)
        | 実行時 (lib/light/block_data.glsl)
        v
getLightDef(index) -> lightEmission(d, level), lightRange(d, level), lightFalloff(dist, range)
```

- 色・明るさ・到達半径・光源サイズ・発光中心・フリッカー・フラグを 1 行で定義 (`tools/id_tables.py` の `LIGHTS`。`makeLight(...)` は `lib/light/light_def.glsl`)
- 実際の光源レベルは `at_midBlock.w` (Iris 1.7+, 状態込みの発光レベル: ロウソク本数・シーピクルス数・リスポーンアンカーの充填等) を優先し、0 ならテーブルの既定レベル
- 炎系の色は `BLOCKLIGHT_WARMTH` で中性 (sRGB 1.0, 0.86, 0.72) からバニラ寄りの暖色まで動かす。既定 0.6 (黒体で約 3100K。AgX が明るい面の彩度を落とすので見た目は 3500-4000K。0.5 以下ではたいまつの洞窟が中性すぎて炎の色に見えない)
- 新しい光源の追加 = `tools/id_tables.py` の `LIGHTS` に 1 行足して `uv run tools/gen_block_properties.py` (index の定数、ID、光源の表が生成される)

### item.properties (`heldItemId` / `heldItemId2` / `currentRenderedItemId`)

- 光るアイテムだけを登録: ブロックアイテム (たいまつ等) は block と同じ 1000 + index、アイテム専用は 1128-1137
- 手持ち: `heldItemId` -> `getItemLightIndex()` -> 光源テーブル。強さは `heldBlockLightValue` (0-15)。テーブルに無い発光アイテム (MOD) は中性の炎色
- ドロップ: アイテムエンティティ (entity 5003) を描く時の `currentRenderedItemId` で同じ表を引く

### entity.properties (`entityId`)

| ID | エンティティ | 用途 |
|---|---|---|
| 5001 | minecraft:current_player (Iris 固定) | 手持ち光源の二重発光防止、自分専用の遮蔽ビット |
| 5002 | player | 他プレイヤー |
| 5003 | item | ドロップアイテム (光源化) |
| 5004 | item_frame, glow_item_frame | 中身を光源化しない |
| 5005-5007 | entity_shadow / name_tag / end_crystal_beam (Iris 固定) | 遮蔽・影から外す |
| 5100-5115 | blaze, magma_cube, glow_squid, allay, end_crystal, experience_orb, spectral_arrow, fireball+small_fireball, dragon_fireball, tnt, creeper, firework_rocket, lightning_bolt, entity_flame (Iris 固定), shulker_bullet, tnt_minecart | 光源エンティティ |

光源エンティティの分類フラグ (LightDef.info.x) で個別スイッチを判定する:
`LIGHT_FLAG_CAT_ITEM` (ITEM_LIGHTS) / `CAT_PROJECTILE` (PROJECTILE_LIGHTS) / `CAT_BURNING` (BURNING_ENTITY_LIGHTS) / `CAT_GLOWING` (GLOWING_ENTITY_LIGHTS)。
TNT・クリーパーは `LIGHT_FLAG_ENTITY_FLASH` で `entityColor.a` (点滅) が強い時だけ光る。

### マテリアル ID (G バッファ 8bit, `lib/ids/material_ids.glsl`)

0 空 / 1 地形 / 2 植物 / 3 葉 / 4 発光ブロック / 5 金属 / 6 光沢 / 7 雪 / 8 溶岩 / 9 水中植物 / 10 水 / 11 ガラス / 12 色付きガラス / 13 氷 / 14 スライム・ハチミツ / 15 ネザーポータル / 16 その他半透明 / 20 エンティティ / 21 プレイヤー / 22 ドロップアイテム / 23 発光エンティティ / 24 ブロックエンティティ / 25 ビーコンの光線 / 26 雷 / 30 手 / 31 光る物を持った手 / 40 パーティクル / 41 天候 / 42 バニラの雲 (予約。前方シェーディングなので G バッファには書かない) / 43 線など。
gbuffers で `blockIdToMaterial()` / `entityIdToMaterial()` (lib/ids/id_decode.glsl) により変換し、deferred 以降はマテリアル ID だけを見る。

---

## ボクセル化

| 項目 | 方式 |
|---|---|
| 範囲 | カメラ追従の直方体。VOXEL_VOLUME 0-3 = 128x64x128 / 192x96x192 / 256x128x256 / 384x128x384 ブロック。原点セル = `floor(camera) - VOXEL_HALF` (`lib/common/voxel_space.glsl`) |
| 解像度 | 地形: 1 ブロック = 1 セル (部分形状は形状テーブルの AABB で精度を補う, Shrimple 方式)。エンティティ: 1 セルを 2x2x2 サブセル (0.5 ブロック) のビットマスクで表す |
| 地形の更新 | shadow パスの頂点シェーダーで、`at_midBlock` からブロック中心を求めて `imageStore` (Photon / Shrimple 方式)。毎フレーム全量 (voxel イメージは毎フレームクリア)。`shadow.culling = reversed` + `voxelDistance` (= 水平半径) でカメラ周辺をカリングさせない |
| エンティティ | Iris 1.8 の `shadow_entities` / `shadow_block` のジオメトリシェーダーで三角形をサブセル間隔でサンプルし `imageAtomicOr` (閉じた箱は表面を埋めれば十分)。地形には GS を使わないので重くならない。RV の「ラスタライザ流用」より単純で、エンティティ限定なのでコストが小さい |
| 自分 | `minecraft:current_player` は別ビット (8-15) にも書く。一人称の手持ち光源のレイは自分を無視し、設置光源のレイは自分で遮る |
| 揺れ | ボクセルは揺れ適用前の位置で書く (影マップは揺れ適用後) |
| 発光 | 地形の発光は voxelBlockImg の ID + 発光レベル。エンティティ光源は voxelEmitImg (atomicMax で重複排除) |
| ON/OFF | プレイヤー: LIGHT_PLAYER_OCCLUSION、他エンティティ・ブロックエンティティ: LIGHT_ENTITY_OCCLUSION。shadowEntities / shadowBlockEntities は shaders.properties で必要な時だけ ON |
| 前フレームとの対応 | セル c の前フレーム値は `c + getVoxelFrameOffset()` (floodfill・履歴の再投影に使う) |

---

## ブロックライト

### 全体の流れ

```
[begin]   SSBO2 カウンタ / SSBO3 ビンを 0 に
[shadow]  地形 -> voxelBlockImg (ID + 発光レベル)
          エンティティ -> voxelEntityImg (占有), 光源エンティティ -> voxelEmitImg + SSBO2 (画面外も含む)
[gbuffers_entities.vsh]  画面内のエンティティ光源 -> voxelEmitImg + SSBO2 (同じセルは重複しない)
[deferred.csh]   floodfill 1 ステップ (6 近傍平均 x 減衰, 固体で止まる, 半透明で色付け)
                 発光ボクセル -> SSBO2 へ追加 (ブロック光源)
[deferred_a.csh] SSBO2 の各光源 -> 到達球が重なるライトビン (8³, ワールド格子) へ重要度の降順で (atomicMax の鎖)
[deferred1.csh]  ピクセル (1/LIGHT_TRACE_RES) ごとに: 所属ビンの光源を重み (影なし照度の輝度 = 放射 x 減衰 x NdotL) で評価 ->
                 上位 LIGHT_TRACE_COUNT - 1 個を確定で、残りからリザーバサンプリングで選んだ 1 個を 1/確率 倍で DDA トレース
                 -> blockLightRawImg (影あり S) / blockLightAuxImg (影なし U)
[deferred2.fsh]  可視率 S/U を空間 (法線/深度エッジ停止) + 時間 (再投影 + 分散クリップ) でデノイズし、
                 フル解像度で求めたビン内全光源の影なし照度に掛ける -> colortex6
[deferred30.fsh] gatherSurfaceLights で、直接光 colortex6 + floodfill x FLOODFILL_STRENGTH (+ 手持ち光源 + 鏡面) を集めて合成
```

### floodfill (間接光のベース)

- 手法: LPV 系の 6 近傍反復伝搬、ピンポン、1 フレーム 1 ステップ。カメラ移動はセルオフセットで追従
- 値は照度単位 (BLOCKLIGHT_ILLUMINANCE 倍済み)。R11F_G11F_B10F に直接格納 (HSV 圧縮は不要な精度)
- LIGHT_SHADOWS が OFF なら floodfill が全光量、ON なら間接光 (x FLOODFILL_STRENGTH)
- 壁の照り返し (BLOCKLIGHT_BOUNCE): 伝搬で隣の不透明セルを 0 の代わりに「自分の照度 x min(壁の平均の色 x BLOCKLIGHT_BOUNCE, 0.9)」として数える (1 面の反射率 < 1 なので発散しない。壁の向こうへは渡さない)。暗いセル (照度 1e-4 未満) は省く。LIGHT_SHADOWS ON では floodfill が控えめな重みで壁の色が見えないので、deferred30 の受け取り側でも法線に垂直な 4 方向 2 ブロック以内の壁の色 x 近さ x 形態係数 0.5 を着色点の照度に掛けて足す (`localWallBounce`)
- ボクセル体積の外は `voxelEdgeFade` でバニラのライトマップへ滑らかに戻す
- 改善の余地: 固体セルを避けた手動トリリニア (漏れ対策, Shrimple `LPV_VOXEL_TEST`)、部分形状の方向別透過

### 光源シャドウ (直接光)

- 光源の選別: ワールド空間ライトビン (Shrimple の bin) + ピクセルごとの重み (影なし照度の輝度) による選択。RV のタイル別リスト + ビットニックソートより単純で、GI・VL・反射からも同じビンを引ける
- 上限を超えた時 (LIGHT_CULL_MODE 1/2, deferred_a.csh / deferred.csh): ビンの枠を「atomicMax で大きい方を残し小さい方を次の枠へ運ぶ」鎖にして、到着順に関係なく重要度 (2 = 揺らぎ前の放射 x ビンの箱までの距離減衰、1 = 近さ) の上位 LIGHT_BIN_LIGHTS 個を残す。最後の 1 枠に外れたうち最大のキーを持ち、重要度がその 1.15 倍までの光源を弱める。ビンはワールドの 8 ブロック格子にそろえる。総数 LIGHT_MAX_COUNT は前フレームの距離の分布から間引き距離を決め (2 = 光の届く球の縁までの距離)、1 フレームに 0.5 ブロック広げ / 2 ブロック縮める速さで動かし、手前 8 ブロックで弱める。0 は到着順 (atomicAdd の先着。毎フレーム入れ替わってちらつく)
- 選び方 (N = LIGHT_TRACE_COUNT, deferred1.csh): 上位 N-1 個は確定でトレースし、残り全部からリザーバサンプリングで 1 個を重みに比例して選び、1/確率 倍してトレースする。選ばれなかった光源も影付きで不偏に寄与する。N = 1 の時は上位 1 個だけをトレースし、残りの光源の照度にはその可視率 (輝度) を掛けて近似する
- 比の推定 (Heitz et al. 2018, `lib/light/light_select.glsl`): deferred1 が同じ光源選択で影あり S と影なし U を低解像度で求め、deferred2 が可視率 S/U だけを時空間フィルタして、フル解像度で求めたビン内全光源の影なし照度に掛ける。減衰・法線の細部はフル解像度のまま残り、ノイズのある可視率だけがぼける
- 遮蔽判定: Amanatides & Woo DDA (自前実装) で voxelBlock を辿り、部分形状は AABB テスト (LIGHT_SHAPE_TRACE)、半透明は透過色を乗算 (LIGHT_TRANSLUCENT_TINT)、エンティティはサブセルのビット (LIGHT_ENTITY_OCCLUSION / LIGHT_PLAYER_OCCLUSION)。光源側・着色点側のセルは判定しない
- 半影: 光源半径 (LightDef.shape.w x LIGHT_SOURCE_SIZE) 内でターゲット点を時間的に揺らし (ブルーノイズ)、デノイズと TAA で均す。RV の SDF コーントレースは SDF 構築コストが大きいので採らない
- 接触影 (LIGHT_CONTACT_SHADOWS): ボクセルに入らない細部 (手・小さいエンティティ・草) を深度バッファのレイマーチで補う
- 低解像度 (LIGHT_TRACE_RES) + 時空間デノイズ (再投影 + 近傍の平均・分散によるクリップ + エッジ停止の空間フィルタ)。LIGHT_DENOISE=0 で最寄りの 1 サンプルのみ (フィルタなし)、1 で 2x2 + 時間、2 で 4x4 + 時間
- 鏡面 (LIGHT_SPECULAR): `getBlockLightSpecular()` が着色点のビンから照度の大きい順に最大 4 光源を `LightSample` の配列で surface に渡す (可視率は deferred2 の比を共通に掛ける。水・ガラスは光源ごとにトレースする)。代表 1 光源だと 2 光源の拡散が釣り合う線で照り返しが切れた

### 手持ち光源

- 両手独立 (`oldHandLight = false`)。強さ = `heldBlockLightValue(2)`、色 = `heldItemId(2)` -> 光源テーブル
- 位置: 一人称は view 空間の固定オフセット (利き手で左右反転)、三人称は `playerBodyVector` / `relativeEyePosition` から構築 (Shrimple basic_hand 相当)
- 影: HAND_LIGHT_RAYS = DDA (自分のビットは無視)、HAND_LIGHT_SS_SHADOWS = 深度バッファの短いレイ (手・武器・近くのモブ)。両方掛けると「壁 + エンティティ」の両方が遮る
- ピクセルごとの直接計算で floodfill には注入しない (二重加算防止)。フォグへの寄与は composite11.fsh が `getHandLightPosition` の位置から点光源の内散乱を視線に沿って解析積分して足す (影は無視。水中は水の吸収と散乱で弱まるので、角度を等分した数値積分にする)
- 受け渡し: `getHandLights(playerPos, geoNormal, dither, out mainHand, out offHand)` が `LightSample` を返す

### ドロップ・投擲・燃焼・発光エンティティ

- 判定: `resolveEntityLight(entityId, currentRenderedItemId, entityColor, out level)` (lib/light/entity_light.glsl)。自分と額縁は除外、個別スイッチはここで反映
- 登録: `injectEntityLight(playerPos, ...)` -> voxelEmitImg に `atomicMax` -> 最初の登録だけ SSBO2 へ追加。呼び出し元は gbuffers_entities.vsh (画面内, 4 頂点に 1 回) と shadow_entities.gsh (画面外, 三角形ごと)
- 以後はブロック光源と同じ経路 (floodfill へ注入 + ビン + トレース) なので、遮蔽も影も同じ品質で付く
- 燃えるエンティティは Iris の `entity_flame` が別ドローで来るのでそれを光源化
- ブロックエンティティの光源 (エンダーチェスト・コンジット・エンドゲートウェイ) は `blockEntityId` -> `getBlockLightIndex` で shadow_block.gsh から登録する

---

## 手法の選定

| 項目 | 方式 | モジュール |
|---|---|---|
| 太陽 / 月の影 | 歪み付き単一影マップ (`lib/common/shadow_space.glsl`) + PCSS (ブロッカー探索と PCF 分離) + スクリーンスペース接触影 + 色付き影 (shadowcolor0)。葉の透過 (SHADOW_LEAF_TINT): 不透明の影のうち葉で遮られた分を、影マップの葉の色 x 重なった枚数 (光源側の葉から受け点へボクセルを辿って数える) で透過させる。SHADOW_FILTER=0 でハード | surface |
| 雲影 | prepare2 で 512² の雲影マップを作り `getCloudShadow()` で地形・VL に渡す | sky |
| AO | GTAO (AO_MODE=2), 軽量は SSAO | surface |
| GI | LOW/MED: なし、HIGH: RSM (shadowcolor0/1)、ULTRA: SSGI、EXTREME: ボクセル RT (light の `traceVoxelRay` + floodfill でヒット点を照らす) + SVGF 系デノイズ | surface |
| 空 / 大気 | Hillaire 2020 の 3 LUT (透過率・多重散乱・SkyView)。照度と空の SH を FrameData に書いて全パスで共有。薄明は SkyView を太陽が ±10 度の間 48 歩にし、成層圏のエアロゾル (20 km) で紫の光を出す。TWILIGHT_STRETCH は空の LUT と夜の度合いに使う太陽の高さだけ地平線より下を縮める (`atmoSkySunMu`)。ATMOSPHERE_MODE=0 は解析近似 | sky |
| 雲 | 3D 体積雲: Kappa の天気マップ事前計算 + 指数ライトマーチ + Nostalgia の 1 マーチ多重散乱近似 (位相の OD 依存非対称性) + チェッカーボード時間アップスケール。2D 押し出し (CLOUDS=2) は平面の被覆を縦に伸ばし、断面を角の丸い箱にする (`cloud2dShoulder`)。既定は被覆 1.1・スケール 3.0 | sky |
| フォグ / VL | Chocapic13 の指数分布ステップ + 影マップ空間マーチ + 区間解析積分。景色の成分 (上端のある混合層のもや + 空中遠近) は内散乱を空の色から作り (遠景は同じ方位の地平線の空に収束、影の中は太陽の単散乱を引いて光芒)、描画距離 R の端で光学的深さが FOG_EDGE_DEPTH になる距離の写像 d (1 + (d / D)^2) で縮める。局所の成分 (霧の層・地表の霧) は縮めない。高さは FOG_HEIGHT_PRESET (`lib/sky/fog_template.glsl`)、成分の形と比は FOG_STYLE (`lib/sky/fog_styles.glsl`。全体の濃さは LOOK_FOG_DENSITY)、湿地・ジャングルは `fogSwamp` / `fogJungle` (カスタム uniform の smooth 9, 10)、日替わりは `lib/sky/climate.glsl` (雲と同じ種)。地平線の下の虚空は同じ式で仮想の地面まで積み、太陽から 30 度以上の方位では地平線の空の 1.05 倍まで。DH 対応時は `fogRenderDistance()` を DH の描画距離にし、縮めずに景色の成分の濃さを FOG_EDGE_DEPTH / R まで下げる (下限は晴天 1.5e-4)、虚空は DH の描画距離の外だけ、VL の解析区間と画面空間の光芒は DH の深度も見る。floodfill を VL マーチで読んで光源周りのフォグを照らす (FOG_BLOCKLIGHT)。洞窟の光漏れ防止 (スカイライトに加え、prepare が影マップで求める目の位置の太陽の見え方を、影マップの範囲より遠い光芒と画面の外の太陽のフレアに掛ける)。全面のブルーミーフォグは弱く | sky |
| 水 | 前方シェーディング + 波 (Gerstner 系) + 視差、composite1 で屈折 (SS / レイトレース) と吸収 (Jerlov 風)、コースティクスは影マップ参照。水の上から見た内散乱は、深さで弱まる水面の照度を屈折した視線に沿って解析積分する。水中の VL は指数分布のステップで、floodfill の照度にライトビンの光源の向きから求めた前方散乱の位相関数を掛ける (光源の周りのにじみ) | surface |
| 反射 | SSR (階層なし線形 + 二分探索) + ラフ反射 (時間蓄積)、SSR 失敗時はボクセル補完 (REFLECTIONS=3, light の `traceVoxelRay`)、最後は空 (`getSkyRadiance`) | surface |
| TAA | Halton(2,3) 16 フレームのジッター (`lib/common/jitter.glsl`) + YCoCg 近傍クランプ + Catmull-Rom 履歴 + トーンマップ空間での混合 (HDR フリッカー対策) + 速度は colortex15 か深度再投影 | post |
| DoF | MIP-Bokeh (サンプル点で CoC を取り直す, 30/50/75 点)、物理カメラ (FOV から焦点距離)、オートフォーカス (速め)、手は除外、HDR 空間で実行。既定はボケ控えめ | post |
| モーションブラー | 速度ベクトルに沿ったサンプル。既定 ON | post |
| ブルーム | colortex0 のミップからタイル縮小 -> ぼかし -> final で合成。既定 0.5 (控えめ) | post |
| 露出 | ヒストグラム (FrameData.histogram) + 非対称の順応速度 (明るい方へ 3 倍速) + 範囲制限 | post |
| トーンマップ | AgX (多項式近似, 公知) を既定、AgX Punchy / ACES / Reinhard-Jodie / AgX Golden / PBR Neutral を選択式 (TONEMAP 0-5)。後段で彩度・コントラスト・ホワイトバランス・CAS・ビネット・8bit ディザ | post |
| レンズフレア | 太陽・月のレンズフレア。既定 ON (全プロファイルで ON) | post |
| レンズプリセット | LENS_PRESET 0 はカスタム (LENS_C_*)、1 は現代の単焦点 (既定)、2-6 は推定値の味付け、7-18 は特許の処方から計算した値 (ゴースト表 `tools/gen_lens_ghosts.py`、歪曲 K1-K3、魚眼の写像、周辺光量と像面の焦点ずれの 9 点の表、STF のアポダイゼーション `LENS_APODIZATION_BETA` (composite22 のボケのサンプルに瞳の透過率を掛ける)、FA 28 Soft と Canon 50/0.95 の球面収差のハロー `LENS_SOFT_HALO_TABLE` (final で F 値ごとの半径に合うブルームのタイルを混ぜる))。新しいレンズは後ろに足し、既存の番号は変えない。歪曲と魚眼は TAA・DoF・ブルームの後、final の最初で出力 -> 元画像へ再投影し (`lensProjectUv`)、魚眼と歪曲の強い時 (LENS_WARP_IN_TAA の自動) は TAA (composite20) の中で出力の画面を組み立ててジッターで中央の細かさを戻す (以降の colortex0・colortex13・ブルームは出力の座標になり、深度・G バッファ・速度だけ `postSourceUv` で元画像の位置を読む)。太陽・月のフレアは光源を出力側へ写して (`lensForwardUv`) 出力の座標で描く。直線写像で歪曲 0 のプリセットでは再投影は定数畳み込みで消える | post |
| ルックのプリセット | LOOK_PRESET 0 はカスタム (LOOK_C_*)、1 はナチュラル (既定。既存の設定に掛ける基準値は 1)、2 はビビッド、3 デイライト、4 夏の青空、5 ゴールデンアワー、6 ティール & オレンジ、7 ブリーチバイパス、8 クロスプロセス、9 ゲーム。3 以降は色と階調の多くをグレーディングの基準 LKG_* で作る。`lib/common/look_presets.glsl` の `#if` で基準値 LK_* を差し替え (Iris の profile は品質のプロファイルの 1 組しか持てないため)、既存の設定 (SATURATION, CONTRAST, EXPOSURE_BIAS, BLOOM_STRENGTH, BLOOM_FOG, GI_SKY_OCCLUSION, SKY_AMBIENT_SATURATION, FOG_DENSITY) は LK_* に掛ける (露出は足す)。効く所: 空の環境光の強さ (SH 全体。霧・粗い反射・フレアの判定では戻す)、日向の暖かさ (prepare の太陽の直達光だけ)、照り返しの強さと彩度 (GI のレイが当たった面だけ、`giBounceGrade`。多重反射の履歴は強さで割る)、明部の伸び (final、中間グレーより上の log2 の傾き)、暗部の持ち上げ (AgX の出力の復号を 2.2 乗から sRGB の曲線へ)、ブルームの広がりと晴れのブルーミーフォグ | 全モジュール |
| 雲の形のプリセット | CLOUD_STYLE 0 はカスタム (CLOUD_S_*)、1 は Ray (既定)、2 Bliss 風、3 バニラの形、4 現実に忠実、5 綿あめ、6 入道雲、7 まばらな晴天積雲、8 層積雲の曇り。`lib/sky/cloud_styles.glsl` の `#if` で基準値 CS_* (晴天の層ごとの雲量、低層の大きさ・背丈・対流・雲種・晴れ間・こぶ・浸食・雲底・断片雲・もや・縁・濃さ・芯、こぶの陰・銀の縁・powder・日光・多重散乱・空の光・雲底の暗さ) を差し替え、既存の CLOUD_* の設定は CS_* に掛ける。雲量・濃さ・光の値は雨天度で Ray の値へ戻す (雨雲・雷雨はどのスタイルもほぼ同じ。大きさ・こぶなど形の定数は雨雲にも効く)。視線の濃さを上げたスタイルは、光源・真上方向の光学的深さを芯の実測の消散係数で頭打ちにする (CLOUD_STYLE_LIGHT_SIGMA_RATIO)。バニラの形 (CLOUD_STYLE=3 と、カスタムの形がバニラの形のとき。マクロ CLOUD_VANILLA_SHAPE) は、バニラの雲のテクスチャ (clouds.png。リソースパックのものに従う) を customTexture の vanillaCloudTex で読み、Iris の `cloudHeight` (下面の高さ) と `cloudTime` (流れ) でバニラと同じ高さ・12 ブロックの格子・模様・流れに置く、厚み 4 ブロックの平らな体積雲 (`lib/sky/cloud_vanilla.glsl`、マーチは `cloudMarchVanilla`)。マスの境目は隣のマスと補間して角を丸め、縁をノイズで揺らして透かす。晴天は低層の積雲のマーチを回さずこの板だけを描き、雨は降り始めのうちに雨雲 (積雲の形) へ移る。雲影マップにも掛かる | sky |
| ルックの LUT | LOOK_LUT 1 はユーザーの PNG ストリップ (`textures/look/user_lut.png`, 32^3, 1024x32, 上の行が緑 0)、2 以降は同梱の 3D LUT (`.dat`, 33^3 RGBA16)。shaders.properties の `#if LOOK_LUT` で `customTexture` を切り替え、final がトーンマップと sRGB エンコードの後、CDL の前に掛ける (sampler は final で 1 個)。作成・変換は `tools/gen_look_lut.py` | post |
| カラーグレーディング | `lib/post/color_grade.glsl` (final だけ)。Resolve のノードの考え方で、シーンの値 (露出後・トーンマップ前, EV) の段と表示値 (sRGB エンコード後) の段に分ける。シーン: WHITE_BALANCE -> ティント -> オフセット (チャンネルごとの EV) -> CONTRAST とピボット -> 明部の伸び (LK_HIGHLIGHT) -> ゾーン (中間グレーからの EV の境目と柔らかさで分けたシャドー・ミッド・ハイライトの RGB・輝度・コントラスト) -> ハイライトの圧縮・シャドーの持ち上げ (境目の外の EV の差 a を a / sqrt(1 + k a)) -> SATURATION -> ゾーンの彩度・バイブランス・色相ごと 8 色 (Oklab の色相で隣の中心の間を smoothstep で補間、a,b / L で色の薄い所を外す) -> トーンマップ。表示: リフト・ガンマ・ゲイン -> 7 点のトーンカーブ (Fritsch-Butland の単調 3 次エルミート) -> スプリットトーン (Oklab の a,b に L に比例して足す) -> LOOK_LUT -> CDL。設定 GRADE_* とルックのプリセットの基準 LKG_* は和 / 積で重ねる。段ごとの const bool で既定値の段を定数畳み込みで消すので、既定値では前の式と同じ画素 (GPU の格子で全一致を確認)。追加の sampler・パスなし | post |

---

## 設定とプリセット

以下の表はプロファイルで値の変わる設定を載せる。全設定の既定値と候補は [settings.md](settings.md)、定義は `lib/settings/` と shaders.properties (設定画面と `profile.*`) にある。

- 全設定は `lib/settings/` の `#define` / `const`。プロファイルは shaders.properties の `profile.*` (ULTRA = HIGH + 差分、EXTREME = ULTRA + 差分、HIGH_FAST = HIGH + 差分、HIGH_FASTEST = HIGH_FAST + 差分、EXTREME_LITE / EXTREME_BALANCED = EXTREME + 差分の継承)。Iris は設定の数でプロファイルを並べ替えてから巡回するので、宣言順 (軽い順) で巡回させるために全プロファイルが同じ設定の組を持つ (新しいプロファイルは全部入りのプロファイルを継承して値だけ上書きする)
- HIGH_FASTEST / HIGH_FAST: HIGH と同じ手法・見た目のまま、内部の解像度 (光源トレース・VL・雲) とサンプル数 (PCSS・RSM・SSR・光源) を下げ、時間方向の積み重ねとデノイズで補う
- EXTREME_LITE / EXTREME_BALANCED: EXTREME と同じ手法 (ボクセル RT の GI・ボクセル補完の反射・レイトレースの屈折・コースティクス・POM・色付き光芒) のまま。EXTREME_LITE は範囲 (ボクセルの体積・影の距離と解像度・光源の上限) と解像度・サンプル数を ULTRA にそろえ、EXTREME_BALANCED は範囲を EXTREME のまま光源トレース・GI・雲・VL を半解像度にする
- 素の既定値 = HIGH (iterationT 方式。`tools/validate_shaders.py` が不一致を検出する)
- 個別スイッチ (プロファイルと独立に ON/OFF 可): LIGHT_SHADOWS (光源シャドウ) / LIGHT_ENTITY_OCCLUSION / LIGHT_PLAYER_OCCLUSION (エンティティ遮蔽) / HAND_LIGHT・HAND_LIGHT_RAYS・HAND_LIGHT_SS_SHADOWS (手持ちレイ) / ENTITY_LIGHTS と ITEM_LIGHTS・PROJECTILE_LIGHTS・BURNING_ENTITY_LIGHTS・GLOWING_ENTITY_LIGHTS (ドロップ等の光源)
- shadowDistance は常にボクセル半径 (voxelDistance) 以上 (reversed culling の制約)
- 雲の形と陰影は MEDIUM 以上で同じ。CLOUD_QUALITY は視線方向の歩数だけを変え (光源方向・真上方向の歩数は品質 0 でも 1 と同じ)、中層は全品質で描く。CLOUD_MULTISCATTER が 8 より少ない時は残りのオクターブの寄与 (等比の和) を最後のオクターブにまとめる

太字は既定値 (= HIGH) と異なる値。

#### ルック (プロファイルに含めない)

| 設定 | 既定 | 内容 |
|---|---|---|
| LOOK_PRESET | 1 | 0 = カスタム、1 = ナチュラル、2 = ビビッド、3 = デイライト、4 = 夏の青空、5 = ゴールデンアワー、6 = ティール & オレンジ、7 = ブリーチバイパス、8 = クロスプロセス、9 = ゲーム (値は README の「ルック」と `lib/common/look_presets.glsl`) |
| LOOK_LUT | 0 | 0 = なし、1 = ユーザーの LUT、2 = 日向と日陰の色の割れ、3 = フィルム、4 = Portra 風、5 = Ektar 風、6 = Vision3 500T 風、7 = Velvia 風、8 = Provia 風、9 = Eterna 風 (`tools/look_luts/*.json` から焼く) |
| LOOK_LUT_STRENGTH | 1.0 | LUT と元の色の混ぜ具合 |
| LOOK_C_* | ナチュラルの値 | カスタムの時だけ使う (空の環境光の強さ・空の色の彩度・日向の暖かさ・照り返しの強さと彩度・明部の伸び・暗部の持ち上げ・ブルームの広がり・晴れのブルーミーフォグ) |
| GRADING / GRADE_* | 有効 / 恒等 | カラーグレーディング (`lib/post/color_grade.glsl`)。既定値ではどの段も何もしない。画面は「ポストプロセス」の「カラーグレーディング」の下の入れ子 (基本・シャドー・ミッド・ハイライト・リフト・ガンマ・ゲイン・色相ごと・トーンカーブ・スプリットトーン・CDL) |

#### 雲の形 (プロファイルに含めない)

| 設定 | 既定 | 内容 |
|---|---|---|
| CLOUD_STYLE | 1 | 0 = カスタム、1 = Ray、2 = Bliss 風、3 = バニラの形、4 = 現実に忠実、5 = 綿あめ、6 = 入道雲、7 = まばらな晴天積雲、8 = 層積雲の曇り (値は `lib/sky/cloud_styles.glsl`) |
| CLOUD_S_* | Ray の値 | カスタムの時だけ使う (形 (積雲 / 板)・積雲の背丈・対流・雲種のずらし・雲の間隔・こぶの段・雲底のちぎれ・こぶの陰・多重散乱) |

<!-- BEGIN GENERATED settings (tools/gen_settings.py) -->
#### light (`lib/settings/light.glsl`)

| 設定 | 既定 | LOW | MEDIUM | HIGH_FASTEST | HIGH_FAST | HIGH | ULTRA | EXTREME_LITE | EXTREME_BALANCED | EXTREME |
|---|---|---|---|---|---|---|---|---|---|---|
| VOXEL_VOLUME | 2 | **0** | **1** | 2 | 2 | 2 | 2 | 2 | **3** | **3** |
| FLOODFILL | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_SHADOWS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_TRACE_COUNT | 4 | **1** | **2** | **2** | 4 | 4 | **8** | **8** | **16** | **16** |
| LIGHT_TRACE_RES | 2 | **4** | 2 | **4** | **4** | 2 | **1** | 2 | 2 | **1** |
| LIGHT_SHAPE_TRACE | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_TRANSLUCENT_TINT | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_SPECULAR | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_DENOISE | 2 | **1** | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| LIGHT_ENTITY_OCCLUSION | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_PLAYER_OCCLUSION | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_OCCLUSION_MODE | 1 | **0** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| LIGHT_ENTITY_TRIANGLES | 4096 | **2048** | **2048** | 4096 | 4096 | 4096 | **8192** | **8192** | **16384** | **16384** |
| LIGHT_CONTACT_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_MAX_COUNT | 4096 | **2048** | 4096 | 4096 | 4096 | 4096 | 4096 | 4096 | **8192** | **8192** |
| LIGHT_BIN_LIGHTS | 64 | **32** | **48** | **48** | 64 | 64 | 64 | 64 | **96** | **96** |
| LIGHT_TRACE_STEPS | 96 | **64** | 96 | 96 | 96 | 96 | 96 | 96 | **128** | **128** |
| LIGHT_SPECULAR_COUNT | 4 | **2** | **2** | **2** | **2** | 4 | 4 | 4 | 4 | 4 |
| LIGHT_CONTACT_SHADOW_COUNT | 4 | **1** | **2** | **2** | **2** | 4 | 4 | 4 | 4 | 4 |
| HAND_LIGHT | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| HAND_LIGHT_RAYS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| HAND_LIGHT_SS_SHADOWS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| ENTITY_LIGHTS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |

#### surface (`lib/settings/surface.glsl`)

| 設定 | 既定 | LOW | MEDIUM | HIGH_FASTEST | HIGH_FAST | HIGH | ULTRA | EXTREME_LITE | EXTREME_BALANCED | EXTREME |
|---|---|---|---|---|---|---|---|---|---|---|
| shadowMapResolution | 4096 | **1024** | **2048** | 4096 | 4096 | 4096 | 4096 | 4096 | **8192** | **8192** |
| shadowDistance | 192.0 | **96.0** | **128.0** | 192.0 | 192.0 | 192.0 | **256.0** | **256.0** | **512.0** | **512.0** |
| SHADOW_FILTER | 2 | **1** | **1** | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| SHADOW_SAMPLES | 16 | **4** | **8** | **8** | **12** | 16 | **24** | **24** | **32** | **32** |
| SHADOW_COLORED | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| SHADOW_LEAF_TINT | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| ENTITY_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| BLOCK_ENTITY_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| SCREEN_SPACE_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| AO_MODE | 2 | **0** | **1** | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| GI_MODE | 1 | **0** | **0** | 1 | 1 | 1 | **2** | **3** | **3** | **3** |
| GI_SAMPLES | 2 | **1** | **1** | **1** | **1** | 2 | **4** | **4** | **4** | **8** |
| GI_RES | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **1** |
| GI_DENOISE | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| GENERATED_NORMALS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| POM | OFF | OFF | OFF | OFF | OFF | OFF | **ON** | **ON** | **ON** | **ON** |
| SSS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| RAIN_PUDDLES | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| WATER_PARALLAX | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| WATER_REFRACTION | 1 | **0** | 1 | 1 | 1 | 1 | **2** | **2** | **2** | **2** |
| WATER_REFRACTION_MODE | 2 | **0** | **0** | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| WATER_CAUSTICS | OFF | OFF | OFF | OFF | OFF | OFF | **ON** | **ON** | **ON** | **ON** |
| REFLECTIONS | 2 | **0** | **1** | 2 | 2 | 2 | 2 | **3** | **3** | **3** |
| SSR_STEPS | 24 | **8** | **12** | **16** | 24 | 24 | **32** | **32** | **48** | **48** |

#### sky (`lib/settings/sky.glsl`)

| 設定 | 既定 | LOW | MEDIUM | HIGH_FASTEST | HIGH_FAST | HIGH | ULTRA | EXTREME_LITE | EXTREME_BALANCED | EXTREME |
|---|---|---|---|---|---|---|---|---|---|---|
| ATMOSPHERE_MODE | 1 | **0** | **0** | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| CLOUDS | 3 | **0** | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| CLOUD_QUALITY | 1 | **0** | **0** | 1 | 1 | 1 | **2** | **2** | **3** | **3** |
| CLOUD_RES | 2 | **4** | **4** | **4** | 2 | 2 | 2 | 2 | 2 | **1** |
| CLOUD_TEMPORAL | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| CLOUD_MULTISCATTER | 4 | **2** | 4 | 4 | 4 | 4 | **8** | **8** | **8** | **8** |
| CLOUD_CIRRUS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| CLOUD_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| FOG_LAYER | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| FOG_MIST | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| VL | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| VL_SAMPLES | 8 | **4** | **6** | **6** | 8 | 8 | **12** | **12** | **16** | **16** |
| VL_RES | 2 | **4** | **4** | **4** | **4** | 2 | 2 | 2 | 2 | **1** |
| VL_COLORED_SHADOWS | OFF | OFF | OFF | OFF | OFF | OFF | **ON** | **ON** | **ON** | **ON** |
| FOG_BLOCKLIGHT | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| FOG_CLOUD_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| VL_FAR | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |

#### post (`lib/settings/post.glsl`)

| 設定 | 既定 | LOW | MEDIUM | HIGH_FASTEST | HIGH_FAST | HIGH | ULTRA | EXTREME_LITE | EXTREME_BALANCED | EXTREME |
|---|---|---|---|---|---|---|---|---|---|---|
| TAA | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| DOF | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| DOF_QUALITY | 0 | 0 | 0 | 0 | 0 | 0 | **1** | **1** | **2** | **2** |
| MOTION_BLUR | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LENS_QUALITY | 2 | **0** | **1** | **1** | 2 | 2 | 2 | 2 | **3** | **3** |
| LENS_FLARE | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_GHOSTS | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_SCREEN_FLARE | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_STARBURST | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_HALO | OFF | OFF | OFF | OFF | OFF | OFF | **ON** | **ON** | **ON** | **ON** |
| LENS_DIRT | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_VEILING_GLARE | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_DISTORTION | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_CHROMATIC | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_AXIAL_CA | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LENS_SOFT_FOCUS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_SWIRL | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_OPTICAL_VIGNETTING | ON | ON | ON | ON | ON | ON | ON | ON | ON | ON |
| LENS_HALATION | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| BLOOM | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| EXPOSURE_MODE | 2 | **1** | **1** | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
<!-- END GENERATED settings -->

DEBUG_VIEW の値 (0-12) と表示内容の対応は `shaders/lang/ja_JP.lang` / `en_US.lang` の `value.DEBUG_VIEW.*` にあり、表示の実装は `shaders/program/post/final.fsh` の `#if DEBUG_VIEW == N` の分岐。

---

## モジュール構成

### モジュールと範囲

| モジュール | 範囲 | ファイル |
|---|---|---|
| light (ボクセル・ブロックライト) | ボクセル化、floodfill、光源リスト・ビン、光源シャドウ (DDA)、デノイズ、手持ち光源、エンティティ光源、`traceVoxelRay` (surface の GI / 反射が使う) | `lib/light/*`, `program/light/*` (setup, begin, shadow, shadow_entities / shadow_block, deferred, deferred_a, deferred1, deferred2) |
| sky (空・大気・雲・フォグ・VL) | 大気 LUT、太陽/月の照度と空の SH、空の描画、星、雲 (体積・2D・影)、高さフォグ、VL、水中フォグ、雨 | `lib/sky/*`, `program/sky/*` (setup1, setup2, prepare, prepare1, prepare2, gbuffers_skybasic / skytextured / clouds / weather, deferred20, deferred21, composite1_a, composite11) |
| surface (太陽影・GI・マテリアル・水・反射) | gbuffers (不透明/半透明/オーバーレイ)、マテリアル (labPBR・自動法線・POM・揺れ)、BRDF、太陽影、AO・GI、不透明シェーディング (deferred30)、水、反射、半透明合成 | `lib/surface/*`, `lib/common/water.glsl`, `program/surface/*` (gbuffers_* が共有する solid / translucent / overlay, gbuffers_lightning, deferred10, deferred11, deferred30, composite, composite1) |
| post (ポストプロセス) | 速度ベクトルの関数、TAA、モーションブラー、DoF、ブルーム、露出、オートフォーカス、トーンマップ、色調整、CAS、レンズフレア、デバッグ表示 | `lib/post/*`, `program/post/*` (composite20-24, composite25, final) |

- shadow パスの出力 (shadowcolor の内容) は surface (RSM・色付き影) と sky (色付き光芒) も使う。内容を変える時は「colortex」の節の定義を守り、docs/architecture.md も更新する
- 表面の光 (light / sky の関数) は surface の `gatherSurfaceLights` が呼ぶ。deferred30・半透明・composite1・二次ヒットは light / sky の照度の関数を直接呼ばない
- `program/surface/gbuffers_solid.vsh` から `injectEntityLight`、`program/surface/gbuffers_*` から `encodeVelocity` を呼び出す (関数本体は light / post モジュール)
- 本体のファイル名は役割名で、Iris のプログラム名との対応は `tools/gen_wrappers.py` の `BODIES` にある (例: composite1 は `program/surface/translucent_composite.fsh`)
- 大きな処理は 600 行以下を目安にファイルを分ける。体積雲は `lib/sky/cloud_volume.glsl` が `cloud_constants` / `cloud_weather` / `cloud_density` / `cloud_lighting` / `cloud_march` を読む。半透明の合成の水と鏡面は `lib/surface/water_shading.glsl` と `composite_specular.glsl`。水面の `lib/common/water.glsl` は `water_waves` / `water_glint` / `water_normal`、レンズの `lib/post/lens.glsl` は `lens_optics` / `lens_flare` を読む。`lib/post/lens_presets.glsl` はレンズごとの値を 1 つの `#if` の連なりで持つ表なので分けない
- 各モジュールの補助ファイルはそのモジュールのディレクトリに置く (例: DDA は `lib/light/trace.glsl`)

### モジュール間インターフェース

共通型 (`lib/common/shading_types.glsl`):

```glsl
struct LightSample {
    vec3 direction;    // 着色点 -> 光源 (player 空間, 単位)
    vec3 irradiance;   // 光源方向に垂直な面での照度 (減衰・遮蔽込み)。NdotL と BRDF は受け取り側
    float angularSize; // 光源の見かけの半径 (rad)
};
LightSample noLight();
```

light モジュールが提供 (`//@include "/lib/light/light.glsl"`):

| 関数 | 呼ぶ側 | 内容 |
|---|---|---|
| `void voxelizeTerrainVertex(vec3 playerPos, vec3 midOffset, int blockId, float emissionLevel)` | shadow.vsh | 地形の頂点をボクセルへ |
| `void voxelizeEntityTriangle(vec3 p0, vec3 p1, vec3 p2, bool isCurrentPlayer)` | shadow_entities.gsh | エンティティの三角形をサブセル占有へ |
| `int resolveEntityLight(int entId, int itemId, vec4 entColor, out float level)` | light 内部 (entity_light.glsl) | 光源インデックス (個別スイッチ反映済み) |
| `void injectEntityLight(vec3 playerPos, int entId, int itemId, vec4 entColor)` | surface/gbuffers_solid.vsh (GBUF_ENTITIES), shadow_entities.gsh | エンティティ光源の登録 |
| `vec3 getBlockLightOpaque(ivec2 texel, vec3 playerPos, vec3 geoNormal, vec3 normal, float lm)` | surface (`gatherSurfaceLights`) | 不透明面のブロックライト照度 (直接 + 間接 + 体積外フォールバック) |
| `vec3 getBlockLightForward(vec3 playerPos, vec3 normal, float lm)` | surface (`gatherSurfaceLights`)、パーティクル・雨 | トレースなし版 |
| `int getBlockLightSpecular(ivec2 texel, vec3 playerPos, vec3 geoNormal, bool traced, out LightSample s[BLOCKLIGHT_SPECULAR_LIGHTS])` | surface (`gatherSurfaceLights`) | ブロックライトの鏡面用の光 (個数を返す)。traced = 半透明の面で、可視率を光源ごとにトレースする |
| `void getHandLights(vec3 playerPos, vec3 geoNormal, float dither, out LightSample mainHand, out LightSample offHand)` | surface (`gatherSurfaceLights`) | 両手の光 |
| `vec3 getHandLightPosition(bool mainHand)` | sky (composite11 の手持ち光源のフォグ) | 手持ち光源の player 空間位置 |
| `vec3 sampleFloodfill(vec3 playerPos, vec3 normal)` / `vec3 sampleFloodfillVolume(vec3 playerPos)` / `float floodCoverage(vec3 playerPos)` | surface (GI), sky | floodfill 照度 |
| `vec3 sampleBlockLightVolume(vec3 playerPos)` | sky (FOG_BLOCKLIGHT) | 体積内の点のブロックライト |
| `vec3 traceVisibility(vec3 fromVoxel, vec3 toVoxel, uint flags, float dither, float entSkipStart, float entSkipEnd)` | light 内部, surface (lighting の最強の光源) | 2 点間の色付き透過率。flags = TRACE_ENTITIES / TRACE_PLAYER / TRACE_TINT / TRACE_SHAPES |
| `bool traceVoxelRay(vec3 originVoxel, vec3 dir, float maxDist, out vec3 hitVoxel, out vec3 hitNormal, out int hitBlockId)` | surface (GI_MODE=3, REFLECTIONS=3) | 最初に当たる固体ボクセル |
| `LightDef getLightDef(int index)` ほか `block_data.glsl` の関数 | 全員 (読み取り) | 光源テーブル |

sky モジュールが提供 (`//@include "/lib/sky/sky.glsl"`):

| 関数 | 呼ぶ側 | 内容 |
|---|---|---|
| `vec3 getSunIrradiance()` / `vec3 getMoonIrradiance()` | 全員 | 地表での直達照度 (FrameData) |
| `LightSample getCelestialLight()` | surface (`gatherSurfaceLights`), sky (VL) | 影を落とす天体の光 (昼は太陽, 夜は月) |
| `vec3 getSkyIrradiance(vec3 n)` | surface (`gatherSurfaceLights`, 反射のフォールバック) | 空からの拡散照度 (SH) |
| `vec3 getSkyRadiance(vec3 dir)` | surface (反射のフォールバック), post | 方向の空の放射 (太陽円盤なし) |
| `vec3 renderSky(vec3 dir, vec3 vanillaSky)` | surface (deferred30 の空ピクセル) | 背景の空 (太陽月・星込み) |
| `vec4 getCloudLayer(ivec2 texel)` | surface (deferred30) | rgb 雲の散乱光, a 透過率 |
| `float getCloudShadow(vec3 playerPos)` | surface | 雲影の透過率 |
| `float getBorderFog(vec3 playerPos)` / `vec3 applyForwardFog(vec3 color, vec3 playerPos)` | 前方シェーディング (パーティクル等) | composite11 と同じモデルのフォグ |
| `vec3 shEvalIrradiance(vec3 n)` | (内部) | SH 評価 |

surface モジュールが提供 (`//@include "/lib/surface/surface.glsl"`):

| 関数 | 呼ぶ側 | 内容 |
|---|---|---|
| `Material decodeMaterial(GBufferData g)` | surface, light (鏡面の重み付け) | labPBR -> シェーディング値 |
| `vec3 evalDirectLight(Material m, vec3 N, vec3 V, LightSample L)` | surface | 直接光 1 つの出射放射 |
| `vec3 evalDiffuseIrradiance(Material m, vec3 irradiance)` | surface | 方向のない照度の出射放射 |
| `SurfaceLights gatherSurfaceLights(SurfacePoint p, int sunMode, int blockMode, uint terms)` (`lib/surface/surface_lights.glsl`) | deferred30, 半透明, composite1, 二次ヒット (`lib/surface/lighting.glsl`) | 表面の光 (太陽の影・空・ブロックライト・手持ち光源・GI) を、取り方 (`SL_SUN_*` / `SL_BLOCK_*`) と足す項 (`SL_*`) を指定して集める。返すのは照度と `LightSample` だけで、BRDF・AO・溶岩・水たまり・SSS の厚みの減衰は呼ぶ側が掛ける |
| `vec3 getSunShadow(vec3 playerPos, vec3 geoNormal, float dither)` | surface (`gatherSurfaceLights`), light (GI 的な用途) | 太陽影 (色付き透過率) |
| `vec3 sampleShadowVolume(vec3 playerPos)` (`lib/common/shadow_volume.glsl`) | sky (VL), light (floodfill のスカイライト等) | 1 タップの色付き影 |
| `vec4 getIndirectLight(ivec2 texel)` | surface | rgb 間接光, a AO |
| `vec3 applyWaving(vec3 playerPos, int blockId, bool isTopVertex, float skyLight)` | gbuffers, shadow.vsh (light) | 植物の揺れ (影と一致させる) |
| `vec3 getWaterNormal(vec3 worldPos, vec3 geoNormal)` (`lib/common/water_normal.glsl`) | surface, sky (水中の光芒等) | 水面の法線 |

表面の光の集め方 (`gatherSurfaceLights`)。呼ぶ側は使う取り方と項を const で書き、省く項をコメントに残す:

| 項 | deferred30 (不透明) | 半透明の前方シェーディング | composite1 (水・ガラス) | 二次ヒット (GI・反射・屈折先) |
|---|---|---|---|---|
| 太陽の影 | PCSS + 葉の透過。影マップの外と一人称の手はスカイライトで近似 (`SL_SUN_SHADOW_MAP_FALLBACK`) | PCSS。外は 1 (`SL_SUN_SHADOW_MAP`) | PCSS。外は 1 (影の距離より遠い地下の水・ガラスは日向になる)。水の側面は雲影とスカイライトで近似、水中は 0 | ボクセル体積の 1 タップ (`SL_SUN_VOLUME`) |
| 接触影・POM の自己影 | ○ | - | - | - |
| 空 (SH x スカイライト) | ○ (GI が運ぶ分を引く) | ○ | 内散乱・泡 | ○ |
| GI・AO | ○ | - | - | 前フレームの GI を多重反射に使う |
| ブロックライト | `SL_BLOCK_OPAQUE` | `SL_BLOCK_FORWARD` (エンティティは `SL_BLOCK_FORWARD_ENTITY`) | 泡・内散乱 `SL_BLOCK_FORWARD` | floodfill (`SL_BLOCK_HIT_FLOOD`) + 直接光 (`secondaryHitBlockLight`) |
| 手持ち光源 | 拡散・鏡面・SSS (`SSS_STRENGTH` を掛ける) | 拡散 | 鏡面・内散乱・泡 | `secondaryHitBlockLight` が影なしで足す |
| 手持ち光源の照り返し | ○ | ○ | - | GI が受け持つ |
| ブロックライトの鏡面 | ○ (`SL_BLOCK_SPECULAR`) | - | ○ (光源ごとにトレース `SL_BLOCK_SPECULAR_TRACED`) | - |
| 最低限の環境光と暗視 (`minAmbientIrradiance`) | ○ | ○ | - | ○ |
| 発光 | ○ | ネザーポータル・発光エンティティ | - | GI のレイが拾う。登録した光源は直接光が数えるので除き、登録していない発光 (溶岩・テクスチャの発光) を足す |

post モジュールが提供 (`//@include "/lib/post/post.glsl"`):

| 関数 | 呼ぶ側 | 内容 |
|---|---|---|
| `vec4 encodeVelocity(vec3 viewPos)` (カメラの動きのみ。Iris 26.1 に at_velocity は無い) / `vec4 encodeHandVelocity()` | gbuffers (surface) | colortex15 へ書く値 |
| `vec2 getPreviousUv(vec2 uv, float depth)` | light / sky / surface の時間蓄積 | 前フレームの UV (速度 or 深度再投影) |
| `vec3 tonemap(vec3 x)` | post, デバッグ表示 | トーンマップ |
| `float getExposure()` (`lib/common/exposure.glsl`) | 全員 | FrameData.exposure |

共通基盤: `lib/common/*` (座標変換・ボクセル空間・影空間・ノイズ・ブルーノイズ・色空間・数学・G バッファ pack/unpack・ジッター・水面 (`water.glsl`)・影マップの 1 点の読み取り (`shadow_volume.glsl`)・露出 (`exposure.glsl`)・時間方向の蓄積の共通部 (`temporal.glsl`)・深度/法線の重み (`joint_bilateral.glsl`)・低解像度のジッターの並び (`frame_offset.glsl`)), `lib/buffers/*`, `lib/ids/*`。`common.glsl` 自体は核 (settings・dimension・constants・uniforms・samplers・math・shading_types) だけを読み、ほかは使うファイルが自分で宣言する (SSBO と images も)。

### バッファの読み書き権

| リソース | light | sky | surface | post |
|---|---|---|---|---|
| voxelBlock / Entity / Emit | 書く | 読む | 読む | 読む (debug) |
| floodImgA/B | 書く | 読む (関数経由) | 読む (関数経由) | 読む (debug) |
| SSBO1 BlockData, SSBO2, SSBO3, SSBO4 | 書く | 読む | 読む | 読む |
| SSBO0 FrameData | lightStats を書く | sun/moon/SH/skyParams を書く | surfaceParams を書く | exposure/focus/histogram/postParams を書く |
| shadowtex / shadowcolor | 書く (shadow パス) | 読む | 読む | - |
| colortex1/2/3/15 | 読む | 読む | 書く | 読む |
| colortex4/5 | - | colortex4 に雨を書く | 書く | - |
| colortex6/7, blockLightRaw/Aux | 書く | 読む (6) | 読む (6, 関数経由) | 読む (debug) |
| colortex8/9, giRaw, reflection | 読む (8) | 読む | 書く | 読む (debug) |
| colortex10/11/12, sky LUT, cloud*, fogHistory | 読む | 書く | 読む (11, 関数経由) | 読む (debug) |
| colortex0 | - | 空テクスチャ (gbuffers), composite11 で書く | deferred30 / composite1 で書く | composite20 以降で書く |
| colortex13/14 | - | - | - | 書く |
| debugImg | 書ける (IMG_DEBUG) | 書ける (IMG_DEBUG) | 書ける (IMG_DEBUG) | 表示 (DEBUG_VIEW=12) |

---

## 規約・単位・検証

### 座標と単位

- 座標: screen (UV + 深度), view, player (カメラ原点のワールド軸, 法線もこの空間), world, voxel (`lib/common/transforms.glsl`, `voxel_space.glsl`)
- 手の深度は `fixHandDepth()` で戻してから再構成する
- 光の量は線形 HDR の相対値。基準は `lib/common/constants.glsl` の `SUN_ILLUMINANCE` (6.0) / `MOON_ILLUMINANCE` / `SKY_ILLUMINANCE` / `BLOCKLIGHT_ILLUMINANCE` (レベル 15 の光源から 1 ブロック) / `EMISSION_LUMINANCE` / `MIN_AMBIENT`。各モジュールが独自のスケールを作らない。最終的な明るさは自動露出が吸収する
- アルベドは G バッファでは sRGB エンコード、シェーディングは線形

### コーディング規約

- マジックナンバーは定数化
- 設定は `lib/settings/` にしかない
- 重い機能は `#ifdef` で丸ごと外す。プログラム単位は shaders.properties の `program.<world>/<pass>.enabled` (`tools/gen_wrappers.py` の `DISABLED` の表から生成する。止める条件は表に 1 行足す)
- compute の `workGroups` / `workGroupsRender` はリテラルで書く (式・マクロは不可。`#if` で分岐)。validate_shaders.py が検査する
- 他のシェーダーパックのコードは持ち込まない。手法を参考にした場合は CREDITS.md に出典を書く

### 命名

保存した設定 (設定の名前・値・プリセットの番号) は変えない。次の規約は新しく足す名前に使う

- 設定の接頭辞は機能のまとまり (`LIGHT_`、`CLOUD_`、`FOG_`、`LENS_`、`GRADE_`、`LOOK_` など)。既にあるまとまりはその接頭辞を使う
- プリセットは `<まとまり>_PRESET`。0 = カスタム、1 = 既定、新しいプリセットは末尾に足し、番号は並べ替えない
- カスタムの値は `<プリセットの名前から _PRESET を除いたもの>_C_<名前>`。プリセットが 0 の時だけ読み、既定値はプリセット 1 の値にそろえる。画面は `<まとまり>_CUSTOM`
- ブールは機能の名前だけ (`_ENABLED` などを付けない)。強さは `X_STRENGTH`、方式の選択は `_MODE`、品質の段は `_QUALITY`、解像度の分母は `_RES`、数は `_COUNT` / `_SAMPLES` / `_STEPS`
- 関数は lowerCamelCase。モジュールの内部の関数は機能の接頭辞 + 名詞 (`cloudLowDensity`)。動詞は `fetch` (texelFetch)、`sample` (補間あり)、`read` (符号化したデータの復号)、`eval` (光や BRDF の式)、`apply` (色を変えて返す)、`trace` (レイを辿る)、`is` / `has` (bool)、`aToB` (座標空間の変換)。前フレームは `Previous`。`get` は新しい関数に付けない
- 型は PascalCase。ファイルスコープの定数は UPPER_SNAKE で、接頭辞は同じ機能の関数・ファイルと同じ語。確保量は `_ALLOC`、上限は `_MAX`
- ファイルは snake_case。include ガードはパスから決める。lib は依存を `//@include` の宣言だけで書き、本体の `#include` は `tools/gen_includes.py` が宣言の閉包を依存が先の順に 1 回ずつ並べて生成する (Iris は `#include` をガードを見ずに毎回差し込むので、lib 同士の include は本文を膨らませる)

保存した設定との互換のため、次の名前は規約に合わないまま使う

| 名前 | 規約との違い |
|---|---|
| `CLOUD_S_*` / `CLOUD_C_*` / `FOG_C_*` | `CLOUD_STYLE` / `CLOUD_REGION_PRESET` / `FOG_STYLE` と `FOG_HEIGHT_PRESET` のカスタムの値 |
| `CLOUD_ALTITUDE` などの雲の高さ、`FOG_MIST_ALTITUDE`、`DOF_APERTURE_BLADES` | カスタムの時だけ使う値で `_C_` なし |
| `FOG_STYLE`、`CLOUD_HEIGHT_PRESET`、`FOG_HEIGHT_PRESET`、`CLOUD_REGION_PRESET` | カスタムの番号が末尾 (3 / 3 / 3 / 5) で、`FOG_HEIGHT_PRESET` の既定は 4 |
| `CLOUD_STYLE`、`FOG_STYLE`、`SUN_MOON_STYLE` | `_STYLE` のプリセット・方式 |
| `PBR_FORMAT`、`CLOUD_S_SHAPE`、`LENS_FISHEYE_FIT`、`LENS_C_PROJECTION`、`CLOUDS`、`REFLECTIONS`、`WATER_REFRACTION` | 方式の選択で `_MODE` なし |
| `LIGHT_BIN_LIGHTS`、`LIGHT_ENTITY_TRIANGLES`、`CLOUD_MULTISCATTER` | 数で `_COUNT` なし |
| `GRADE_*_SAT` | `_SATURATION` の略 |
| `VIGNETTE`、`FILM_GRAIN`、`BLOOM_FOG` | 強さで接尾辞なし |
| 画面の名前 (`*_SCREEN`、`*_OPTIONS`) | 混在 |

### 検証

```powershell
# glslangValidator (glslang.exe) の場所を指定
$env:RAY_GLSLANG = "<glslang のパス>\bin\glslang.exe"
uv run tools/validate_shaders.py             # 既定値・world0、前回成功から変わったものだけ
uv run tools/validate_shaders.py --full      # 既定値 x 3 ディメンション + 全プロファイル
uv run tools/gl_compile_check.py             # 実機ドライバで compile + link
uv run tools/gl_compile_check.py --full      # 同上を既定値 x 3 ディメンション + 全プロファイル
# キャッシュ (tools/.cache/) を無視するのは --no-cache
uv run tools/gen_wrappers.py --check         # プログラム本体とラッパー、program.*.enabled の生成の対応
```

validate_shaders.py は include 展開・設定差し替え・Iris マクロ注入をしてからコンパイルし、エラーを元ファイルの行番号で表示する。
静的チェック: プロファイルの値の妥当性、HIGH = 既定値、screen と lang の網羅、workGroups のリテラル性、`*.properties` が ASCII だけか、block/item の状態値にカンマ区切りが無いか、ラッパーと `program.*.enabled` の生成が最新か。

gl_compile_check.py は同じ前処理結果を不可視ウィンドウの OpenGL 4.6 compatibility コンテキストで実際にコンパイル・リンクする (glfw + PyOpenGL)。
glslang が通しても実ドライバで落ちるもの (NVIDIA の image uniform 8 個制限 `C7624`、予約語 `packed` 等) を検出し、info log を元ファイルの行番号で表示する。
shaders.properties の `#if` を評価して `program.*.enabled = false` のプログラムは Iris と同じく飛ばす。
実機の上限値 (`--limits`) と比べる項目: ステージごとの image / SSBO の宣言数、プログラムのアクティブ image 数 (GL_MAX_IMAGE_UNITS)、アクティブ sampler 数 (GL_MAX_TEXTURE_IMAGE_UNITS - Iris の予約ユニット)、SSBO ブロックの大きさと bufferObject.N、compute の local size・workGroups・shared メモリ、カスタムイメージの寸法と枚数 (Iris は 16 枚まで)。

参考: RTX 2080 Ti / ドライバ 581.57 の実測値は image uniform 8 (各ステージ) / image unit 8 / combined image 48、texture unit 32 (各ステージ) / combined 192、SSBO 16 (各ステージ) / binding 96、compute shared 48KB / invocations 1024、3D テクスチャ 16384。

---

## 既知の制約と未決事項

- 光源: ReSTIR 的な時間再利用はない。1 ビンに 64 光源を超えるとちらつく可能性がある。半透明面は floodfill のみで暗め。一人称の手の光源位置は固定
- 空・雲: aerial perspective は SkyView の地平線色で近似。フォグの透過率は灰色 1ch。雨粒は深度を書かない。上層雲は 160 km まで描くので、地平線際が単調になりうる
- 影・GI・反射: 水の後ろのガラスが手前に見える。半透明越しの環境反射は空のみ。RSM に可視性はない。F82 は未実装。自動法線は地形のみ
- ポスト: TAAU は見送り (Iris では gbuffers の解像度を下げられない)
- エンティティのボクセル化は Iris 1.8 の `shadow_entities` / `shadow_block` に依存。影パスの距離 (`entityShadowDistanceMul`) とフラスタムの外のエンティティは遮蔽物にならない
- 階段は向き・上下・外角を ID に持ち、ハーフ + 段の箱 2 個で遮る。内角 (段が 3/4) は箱 2 個に収まらないので同じ向きの直線で近似する (1/8 ブロック小さい)
- `minecraft:light` (ライトブロック) の実際のレベルは `at_midBlock.w` が 0 で来る可能性があり、その場合は既定 15 になる (未対処)
- MOD ブロックは未登録 = 完全な固体扱い。光る MOD ブロックはタグ (`%c:...`) か個別登録が必要
- エンダーチェスト等ブロックエンティティの光源はボクセル地形に乗らない (shadow_block から登録する必要がある。「ドロップ・投擲・燃焼・発光エンティティ」参照)
- DH / Voxy / Photonics 連携は未対応。DH を入れていると Iris は「DH シェーダーなし」として扱う (LOD の見た目は保証しない)
- Iris 26.1 は半透明エンティティ (プレイヤーのスキン・マネキン・文字・旗の模様等) を deferred の後 (`renderTranslucentFeatures`) に gbuffers_entities_translucent / gbuffers_block_translucent で描く。G バッファ経路のフォールバック (gbuffers_entities) だと deferred30 で照明されず消えるので、両者は半透明の前方シェーディング (`program/surface/gbuffers_translucent.*`) で用意した。速度は書かず深度再投影に任せる (並べ替えで at_velocity が使えないため)。画面空間の影 (手持ち光源の SS 影等) には写らないので、三人称の自分の影は手持ち光源のボクセル DDA で落とす
- gbuffers_item は未用意 (gbuffers_entities にフォールバック)
- macOS (compute 非対応) は動かない
