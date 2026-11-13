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
  textures/                                 blue_noise.png, lens_dirt.png, moon_phases.png (SUN_MOON_STYLE=2 の月の写真、満ち欠け 8 段のアトラス), cloud_*.dat, lens_starburst.dat, water_waves.dat (+ .mcmeta)
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
| 1 | setup.csh | light | 光源・形状・透過色・ブロックの平均の色・光源の面の光り方の表を SSBO に構築、FrameData 初期化 | `lib/light/light_table.glsl`, `light_table_data.glsl`, `light_mask_data.glsl` | SSBO1 BlockData, SSBO0 | local 256, groups (1,1,1) | 常時 |
| 2 | setup1.csh | sky | 大気の透過率 LUT (Hillaire 2020) | - | skyTransmittanceImg 256x64 | local 8x8, (32,8,1) | ATMOSPHERE_MODE=1, world0 |
| 3 | setup2.csh | sky | 多重散乱 LUT | skyTransmittance | skyMultiScatterImg 32x32 | local 8x8, (4,4,1) | 同上 |
| 4 | begin.csh | light | 光源リストとライトビン (前フレームに使った枠) とエンティティ光源の蓄積表のクリア | - | SSBO2 カウンタ, SSBO3 binCount/binLights/entityAcc | local 256, (160,1,1) | 常時 |
| 5 | shadow.vsh/fsh | light | 地形の太陽影マップ + 地形ボクセル化 (頂点シェーダーで imageStore) | mc_Entity, at_midBlock | shadowtex0/1, shadowcolor0/1, voxelBlockImg | shadowMapResolution | 常時 |
| 6 | shadow_entities.vsh/gsh/fsh | light | エンティティのボクセル化 (GS で表面サンプル)・エンティティ光源登録・影マップ | entityId, currentRenderedItemId | voxelEntityImg, voxelEmitImg, SSBO2, 影マップ | 同上 | shadowEntities |
| 7 | shadow_block.vsh/gsh/fsh | light | ブロックエンティティ版 (本体共通, `PROGRAM_SHADOW_BLOCK`) | blockEntityId | voxelEntityImg, 影マップ | 同上 | shadowBlockEntities |
| 8 | prepare.csh | sky | 太陽・月の直達照度、空の SH (全モジュールが使う光の色) | skyView / 解析式 | SSBO0 sun/moon/shadowLight/skySH | (1,1,1) | 常時 |
| 9 | prepare1.csh | sky | SkyView LUT | transmittance, multiScatter | skyViewImg 192x108 | local 8x4, (24,27,1) | ATMOSPHERE_MODE=1, world0 |
| 10 | prepare2.csh | sky | 雲の天気マップ (バニラの形は柱の表) と雲影マップ、カメラの位置の雲の中の霧と雨の空の置き換え (FrameData) | - | cloudWeatherImg, cloudShadowImg 512² | local 16², (32,32,1) | CLOUDS>=2, world0 |
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
| 24 | composite1.vsh/fsh | surface | 水面の光線を辿る部分: 屈折先の色と水の中の経路長 (画面の歩き + ボクセルの屈折、側面の水の厚み)、上向きの水面の太陽の可視率 (PCSS + 雲影)、鏡面の映り込みのフル解像度の SSR (映り込みを散らさない凪の水面だけ)。水の画素だけ書く。合成と分けるのは、光線を辿る処理と影が合成のシェーダーに入ると、合成の重い経路でレジスタの数が決まってワープが減り、水の画素の全部の処理が遅くなるため | colortex0/5, depthtex0/1, voxel, 影マップ | colortex18, colortex21, colortex20 (REFLECTIONS>0) | 画面 | 常時 |
| 25 | composite2.vsh/fsh | surface | 半透明合成 (水中吸収・反射・太陽の鏡面・泡、ガラスの透過) | colortex0/4/5/18-21, reflectionImg | colortex0 | 画面 | 常時 |
| 26 | composite12.vsh/fsh | sky | 画面空間の光芒 1/3: 空のマスク (深度 x 雲の透過率 x 光源からの角度) をタップごとに求め、光源へ向かう最短のスパンでぼかす | depthtex2, colortex11 | colortex16 | 画面 (1/GODRAYS_RES) | GODRAYS, world0 |
| 27 | composite13.vsh/fsh | sky | 同 2/3: 中のスパン | colortex16 | colortex16 | 同上 | 同上 |
| 28 | composite14.vsh/fsh | sky | 同 3/3: 全長のスパン | colortex16 | colortex16 | 同上 | 同上 |
| 29 | composite19.vsh/fsh | sky | フォグ / VL の適用 (バイラテラルアップサンプル)、水中フォグ、画面空間の光芒の加算 (カメラの位置の霧の濃さで強さを決める)、カメラが雲より上のときの手前の雲 (高さフォグと光芒の後に重ねる。半透明が手前の画素は `cloudFrontPart` でカメラから半透明までの分に割り引く) | colortex0/12/16 | colortex0 | 画面 | 常時 |
| 30 | composite20.vsh/fsh | post | TAA (LENS_WARP_TAA の時は歪曲・魚眼の組み立ても) | colortex0/13/15/17 | colortex0, colortex13, colortex17 | 画面 | TAA |
| 31 | composite21.vsh/fsh | post | モーションブラー | colortex0/15 | colortex0 | 画面 | MOTION_BLUR |
| 32 | composite22.vsh/fsh | post | DoF (MIP-Bokeh, colortex0 ミップ) | colortex0, SSBO0 focus | colortex0 | 画面 | DOF |
| 33 | composite23.vsh/fsh | post | ブルーム縮小タイル | colortex0 ミップ | colortex14 | 画面 | BLOOM |
| 34 | composite24.vsh/fsh | post | ブルームぼかし | colortex14 | colortex14 | 画面 | BLOOM |
| 35 | composite25.csh | post | 自動露出 (ヒストグラム。屋外の夜の持ち上げは画面の暗い側の計測で決める) + オートフォーカス | colortex0, centerDepthSmooth | SSBO0 exposure/focus/histogram | local 16², (1,1,1) | 常時 |
| 36 | final.vsh/fsh | post | 歪曲と魚眼の再投影・ブルーム合成・点像の芯と裾・フレア・露出・AgX・色調整・CAS・ディザ・デバッグ表示 | colortex0/14/17, SSBO0 | 画面 | 画面 | 常時 |

補足
- shadowcomp は使わない。floodfill を deferred に置くのは、gbuffers_entities (deferred より前) が登録した画面内のエンティティ光源を同じフレームで取り込むため (voxelEmitImg は毎フレームクリアされる)
- Iris は同じパスの compute (composite1_a) を fragment (composite1) の前に走らせる。VL の有効条件は `program.<world>/composite1_a.enabled` で、composite1 の fragment (水の光線を辿る処理) は止まらない
- ネザー・エンドは大気 LUT と雲のパスを外す (shaders.properties)。shadow パスはボクセル化のため全ディメンションで回す
- `particles.ordering = mixed`: 不透明パーティクルは G バッファ (gbuffers_particles)、半透明は前方 (gbuffers_particles_translucent)
- DH (Distant Horizons) は未対応 (dh_* プログラムなし)。DH の水 (dh_water) を足す時の入口は `lib/common/water_lod.glsl` の `waterLod`: DH の深度から求めた距離と視線の cos を渡し (1 画素の角度は dhProjection も同じ画角なので `waterPixelAngle()` のまま)、返った `WaterLod` で `getWaterNormal` と合成 (composite2) の粗さ・フレネル・鏡の重みを決める。描画距離の先も遠い層 (`farAmp`) が残るので鏡にはならない。遠景を軽くする段 (層を読まない・視差なし・鏡の SSR を辿らない) とその移り変わりも、waterLod に足して決める。層 0-4 を読まない段でも遠い層 (`WaterLod.farAmp`) は残す (止めると鏡に戻る。読むのは遠い層の 2 本、移り変わりで 3 本だけ)。波頭・泡・WATER_GLITTER のむらの高さの読みは `heights` を 0 にすると止まる

---

## バッファ設計

### colortex (22 枚。正本は `lib/buffers/formats.glsl`)

| buf | フォーマット | 内容 | 書く | 読む | クリア |
|---|---|---|---|---|---|
| 0 | RGBA16F | シーン HDR。空テクスチャ (skybasic/skytextured) -> deferred30 -> composite* -> final | sky(空), surface, sky, post | 全 | 毎フレーム |
| 1 | RGBA8 | G: rgb アルベド (sRGB エンコード), a マテリアル ID | surface (gbuffers) | 全 | 毎フレーム |
| 2 | RGBA16 | G: rg テクスチャ法線 (oct), b 幾何法線 (oct 8+8), a ライトマップ (8+8) | surface | 全 | 毎フレーム |
| 3 | RGBA16 | G: r smoothness+f0, g sss+emission, b ao+wetness, a 予備 | surface | 全 | 毎フレーム |
| 4 | RGBA16F | 半透明の色 (乗算済みアルファ, 既定ブレンドで自然にそうなる) | surface, sky(雨) | surface (composite2) | 毎フレーム |
| 5 | RGBA16 | 半透明のデータ: rg 法線, b ライトマップ, a マテリアル ID + 予備 8bit (ガラスの透過色の index、金属の防具は滑らかさ) | surface | surface, sky | 毎フレーム |
| 6 | RGBA16F | light: ブロックライト直接光 (拡散照度, デノイズ済み) | light (deferred2) | surface (light の関数経由) | 毎フレーム |
| 7 | RGBA16F | light: ブロックライト履歴 | light | light | 永続 |
| 8 | RGBA16F | surface: rgb 間接光照度, a AO | surface (deferred11) | surface, post(debug) | 毎フレーム |
| 9 | RGBA16F | surface: GI 履歴 | surface | surface | 永続 |
| 10 | RGBA16F | sky: 雲 (低解像度) rgb 散乱, a 透過率 | sky | sky | 永続 |
| 11 | RGBA16F | sky: 雲 (フル解像度, 時間蓄積) | sky | surface (sky の関数経由), sky | 永続 |
| 12 | RGBA16F | sky: VL / フォグ (低解像度) rgb 内散乱, a 透過率 | sky | sky | 永続 |
| 13 | RGBA16F | post: TAA 履歴 | post | post | 永続 |
| 14 | RGBA16F | post: ブルームタイル | post | post | 毎フレーム |
| 15 | RGBA16F | 速度: rg = 前フレーム UV - 今の UV, a = 1 なら有効 (エンティティ・手)。a = 0 の金属の防具の画素だけ rgb = 環境光の鏡面の重み x 1e-4 (gbuffers_entities_translucent -> composite2。双線形で読まれても速度がずれないよう小さくする) | surface (gbuffers, post の関数) | post | 毎フレーム |
| 16 | R16F | sky: 画面空間の光芒 (低解像度 `size.buffer.colortex16` = 1/GODRAYS_RES)。composite12 -> 13 -> 14 で同じバッファをピンポンして読み書きし、composite19 が足す | sky | sky | 毎フレーム |
| 17 | RGBA16F | post: 鏡面の白飛び分の履歴 (rgb = 露出前の線形, a 予備)。SPECULAR_SPARKLE の時だけ composite20 が読み書きし、final がミップで読んで点像の芯と裾を作る (LENS_POINT_SPREAD_STRENGTH) | post | post | 永続 |
| 18 | RGBA16F | surface: 水の屈折先の色 (rgb、吸収の前) + 水の中の経路長 (a)。水の画素だけ書き、ほかは前の値のまま | surface (composite1) | surface (composite2) | なし |
| 20 | RGBA16F | surface: 水の鏡面の映り込みのフル解像度の SSR (rgb = 当たりの色 x 画面端の重み, a = 重み、外れは 0)。水の画素のうち映り込みを散らさない凪の水面だけ、REFLECTIONS > 0 | surface (composite1) | surface (composite2) | なし |
| 21 | RGBA16F | surface: 上向きの水面の太陽の可視率 (影の PCSS + 雲影、rgb。内散乱・泡・波頭の透過光と太陽の照り返しに使う), a = 水の屈折先の白飛び分の輝度 (屈折先の deferred30 の a から)。水の画素だけ | surface (composite1) | surface (composite2) | なし |

- gbuffers では colortex0-3 を読めない (Iris の仕様)
- `shadowcolor0` RGBA8: 最も太陽側の面の色 (半透明は透過色 + a 不透明度、不透明は a=1)。`shadowcolor1` RGBA16: rg 法線 (oct), b スカイライト, a 種別 (0 不透明 / 0.5 半透明 / 1 水)。RSM (surface) と色付き影 (surface) と色付き光芒 (sky) が読む

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
| cloudWeatherImg | RGBA8 | 512x512 | 永続 | sky | 天気マップ (r 低層の被覆, g 低層の雲種, b 中層の被覆, a 上層の被覆。被覆は 1/1.4 倍して格納)。バニラの形 (CLOUD_VANILLA_SHAPE) のときは天気図を使わず、バニラの雲のマス (clouds.png の 1 画素) ごとの柱の表 (r 柱の頭の高さ (ブロック。0 は雲のないマス), a 4x4 マスの区画に雲があるか) |
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
| 0 | FrameDataBuffer (`frameData`) | `frame_data.glsl` | 4096 | post: exposure, exposureTarget, averageLuminance, focusDistance, histogram[256], postParams[] (4 個) / sky: sunIrradiance, moonIrradiance, shadowLightIrradiance, skySH[9], skyParams[8] (`[3]` = 目の位置の太陽の見え方: x 今フレーム (フレア用)、y 平滑化済み (影マップより遠いフォグ用)、z 太陽が影マップの範囲より遠い地形に隠れている割合 (post が書く)。`[4]` = (カメラの位置の雲の中の太陽の光 rgb, 雲の濃さ。0 なら雲の外)、`[5]` = (雲の中の空の光 rgb, 雲の中の霧の消散係数 1/ブロック)、`[6]` = (雨の日の雲の向こうの空を置き換える灰色の放射輝度 rgb, 置き換える割合)、`[7]` = (カメラのいる板の上面までの高さ, 下面までの高さ。0 なら板の外) (`[4]` `[5]` `[6]` `[7]` は prepare2 が書く)) / light: lightStats / surface: surfaceParams[6] (`[0..2]` = 開けた水面 (スカイライトが風の当たる上限以上) の海の状態。層の傾き 5・表面張力波の傾き 2・風速・高さの RMS。prepare が毎フレーム書く。`[3]` = WATER_GLITTER の点の寿命に使うフレームの長さ (x 平滑化した frameTime, y 半オクターブの段に丸めた長さ (秒), z 段の番号)。WATER_GLITTER の時だけ prepare が書く。`[4]` = (水の吸収 rgb, 波頭の尖り)、`[5]` = (水の散乱 rgb, 映り込みの散らしの割合)。海・湖・川の設定をカメラのバイオームの重みで混ぜた値で、prepare が毎フレーム書く。prepare より前の shadow パスは 1 フレーム前の値を読む) | `FRAME_DATA`: setup (初期値), begin・deferred_a (lightStats), prepare (sky、surfaceParams[0..5]), prepare2 (skyParams[4..7]), composite25 (post) |
| 1 | BlockDataBuffer (`blockData`) | `block_data.glsl` | 65536 | `LightDef lightDefs[256]`, `uvec4 shapes[128]`, `vec4 tints[128]`, `uint albedo[4096]` (ブロックの平均の色), `uint albedoUp[4096]` (上向きの面の色), `uvec4 lightMasks[]` (光るブロックの面の光り方、128 光源 x 上・下・側面・前面の 512 個) | `BLOCK_DATA`: setup のみ |
| 2 | GlobalLightsBuffer (`globalLights`) | `global_lights.glsl` | 295200 | `count/blockCount/entityCount/overflow`, `cullDistance/culled` + `cullHist[64]` (間引き距離と距離の分布), `LightInstance lights[8192]` (posRadius: ボクセル空間位置 + 到達半径, colorSize: 放射 + 光源半径), `lightPower[]` (揺らぎ前の放射の輝度、8192 個)。使うのは LIGHT_MAX_COUNT 個まで | `GLOBAL_LIGHTS`: setup, begin, deferred, deferred_a |
| 3 | LightBinsBuffer (`lightBins`) | `light_bins.glsl` | 10944512 (LIGHT_BIN_LIGHTS > 64 で 21430272) | `binCount[40960]`, `entityAcc[32768]` (エンティティ光源の蓄積表), `binLights[]` (40960 x 65 個、> 64 で x 129)。ビン = 8³ ブロック、1 ビン LIGHT_BIN_LIGHTS + 1 枠。枠のキー = 重要度 19 bit + 光源インデックス 13 bit | `LIGHT_BINS`: setup, begin, deferred_a, shadow_entities・shadow_block の gsh と gbuffers_entities・gbuffers_entities_translucent の vsh (蓄積表) |
| 4 | EntityTriangleBuffer (`entityTris`) | `entity_tris.glsl` | 838672 | `counts[4]`, `groupBounds`, `clusterBounds` + `EntityTriangle tris[]` (16384 個) (ボクセル空間の三角形 v0/e1/e2 + アルファマスク + テクスチャ x 頂点色の平均の色) | `ENTITY_TRIS`: begin (クリア), shadow_entities・shadow_block の gsh |
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
| 200-299 | 半透明 (透過色 index = id - 200) | 200 水, 201 氷, 202 ガラス, 203 ガラス板, 204 スライム, 205 ハチミツ, 206 遮光ガラス, 207 流れる水 (level 1-7。頂点で 200 に戻し、ボクセルの発光の欄に印 `VOXEL_WATER_FLOWING` だけ残す), 210-225 色付きガラス, 230-245 色付きガラス板 |
| 300-399 | 部分形状 (形状 index = id - 300) | 300/301 ハーフ下/上, 304 フェンス, 305 塀, 306 鉄格子, 307 背の低いブロック, 308 雪の層, 309 閉じたドア・トラップドア, 320-335 階段 (向き 4 x 外角 4 の形 x 下/上。内角は直線に含める) |
| 1001-1255 | 光源 (光源インデックス = id - 1000) | 1001 たいまつ … 1062 トライアルスポナー |
| 1257-1895 | 向きのある光源の東・南・西 (id = 1000 + 256 x 向き + 光源インデックス。向き 1 東 2 南 3 西。北は向きなしと同じ ID) | かまど・燻製器・溶鉱炉 (点灯) 1305 / 1561 / 1817、ジャック・オ・ランタン 1267 / 1523 / 1779 |
| 2000-4095 | 色の付いた固体 (遮蔽・マテリアルは未登録の固体と同じ)。上の帯に無いブロックを平均の色ごとにまとめたもの | 羊毛・コンクリート・石・板材 (使用中は 2000-2351) |
| 元の ID + 4096 x 判定の番号 (1-5) | 一部だけ金属のブロック。下位 12bit が元の ID (ボクセル・光源・形はそのまま)、上が金属の画素を選ぶ判定 (`METAL_GATE_*`)。Iris の頂点の ID は符号付き 16bit なので 32767 以下 | 1 全体 (銅の鉄格子・鎖・ドア・避雷針・鉄のドア・鎖・鉄格子・感圧板), 2 灰色 (ホッパー・大釜), 3 青みの暗い画素 (ランタンの枠), 4 線路 (レール 4 種。灰色+明るい金、滑らかさ 0.7 (粗さ 0.3) で一定、F0 を持ち上げ、自動法線なし。雨では水たまりを溜めず、金属と枕木を濡らすだけ), 5 金 (鐘) |

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
        / lightMasks[384] (lib/light/light_mask_data.glsl から。データのある光源に LIGHT_FLAG_EMISSION_MASK を立てる)
        | 実行時 (lib/light/block_data.glsl)
        v
getLightDef(index) -> lightEmission(d, level), lightRange(d, level), lightFalloff(dist, range)
```

- 色・明るさ・到達半径・光源サイズ・発光中心・フリッカー・フラグを 1 行で定義 (`tools/id_tables.py` の `LIGHTS`。`makeLight(...)` は `lib/light/light_def.glsl`)
- 実際の光源レベルは `at_midBlock.w` (Iris 1.7+, 状態込みの発光レベル: ロウソク本数・シーピクルス数・リスポーンアンカーの充填等) を優先し、0 ならテーブルの既定レベル
- 炎系の色は `BLOCKLIGHT_WARMTH` で中性 (sRGB 1.0, 0.86, 0.72) からバニラ寄りの暖色まで動かす。既定 0.6 (黒体で約 3100K。AgX が明るい面の彩度を落とすので見た目は 3500-4000K。0.5 以下ではたいまつの洞窟が中性すぎて炎の色に見えない)
- 新しい光源の追加 = `tools/id_tables.py` の `LIGHTS` に 1 行足して `uv run tools/gen_block_properties.py` (index の定数、ID、光源の表が生成される)
- 画面に見える発光の明るさを種類ごとに設定で変える分類は、`Light.kind` (たいまつ・炎・ランタン・ビーコン。フラグ `LIGHT_FLAG_KIND_*`) と、ブロック全体が光る光源 (`LIGHT_FLAG_OCCLUDES`) = 光源ブロック。deferred30 (`opaque_shading.fsh`) が発光の画素の位置のボクセルから光源の表を引いて `EMISSION_*_BRIGHTNESS` を掛ける。ビームはマテリアル、手持ちは持っているアイテムの光源で分ける。溶岩は `LAVA_BRIGHTNESS`。`EMISSION_GLARE` が ON のときは発光の倍率を点の光源 4・面の光源 1.5 にして、白を超えた分を鏡面の白飛び分と同じ経路で TAA の外へ渡す

### item.properties (`heldItemId` / `heldItemId2` / `currentRenderedItemId`)

- 光るアイテムだけを登録: ブロックアイテム (たいまつ等) は block と同じ 1000 + index、アイテム専用は 1128-1137
- 手持ち: `heldItemId` -> `getItemLightIndex()` -> 光源テーブル。強さは `heldBlockLightValue` (0-15)。テーブルに無い発光アイテム (MOD) は中性の炎色
- ドロップ: アイテムエンティティ (entity 5003) を描く時の `currentRenderedItemId` で同じ表を引く
- 一部だけ金属のアイテム (道具・防具・インゴット・バケツ・ランタンなど): ID = 4096 x 金属の判定の番号 (4096 全体, 8192 灰色, 20480 金, 24576 銅, 28672 ネザライト, 32768 宝石)。ランタンのように光るアイテムは光源の ID + 4096 x 判定の番号で、`getItemLightIndex()` が判定の分を外して光源を引く。手に持つ・落ちた・額縁・アーマースタンドやモブが身に着けた防具は `currentRenderedItemId` が同じ表を引く

### entity.properties (`entityId`)

| ID | エンティティ | 用途 |
|---|---|---|
| 5001 | minecraft:current_player (Iris 固定) | 手持ち光源の二重発光防止、自分専用の遮蔽ビット |
| 5002 | player | 他プレイヤー |
| 5003 | item | ドロップアイテム (光源化) |
| 5004 | item_frame, glow_item_frame | 中身を光源化しない |
| 5005-5007 | entity_shadow / name_tag / end_crystal_beam (Iris 固定) | 遮蔽・影から外す |
| 5100-5115 | blaze, magma_cube, glow_squid, allay, end_crystal, experience_orb, spectral_arrow, fireball+small_fireball, dragon_fireball, tnt, creeper, firework_rocket, lightning_bolt, entity_flame (Iris 固定), shulker_bullet, tnt_minecart | 光源エンティティ |
| 5201-5208 | 金属の判定の番号 (1-8) + 5200 | 一部だけ金属のエンティティ (トロッコ・銅のゴーレム) |

光源エンティティの分類フラグ (LightDef.info.x) で個別スイッチを判定する:
`LIGHT_FLAG_CAT_ITEM` (ITEM_LIGHTS) / `CAT_PROJECTILE` (PROJECTILE_LIGHTS) / `CAT_BURNING` (BURNING_ENTITY_LIGHTS) / `CAT_GLOWING` (GLOWING_ENTITY_LIGHTS)。
TNT・クリーパーは `LIGHT_FLAG_ENTITY_FLASH` で `entityColor.a` (点滅) が強い時だけ光る。

### マテリアル ID (G バッファ 8bit, `lib/ids/material_ids.glsl`)

0 空 / 1 地形 / 2 植物 / 3 葉 / 4 発光ブロック / 5 金属 / 6 光沢 / 7 雪 / 8 溶岩 / 9 水中植物 / 10 水 / 11 ガラス / 12 色付きガラス / 13 氷 / 14 スライム・ハチミツ / 15 ネザーポータル / 16 その他半透明 / 20 エンティティ / 21 プレイヤー / 22 ドロップアイテム / 23 発光エンティティ / 24 ブロックエンティティ / 25 ビーコンの光線 / 26 雷 / 27 金属・宝石の防具 (colortex5 だけ) / 30 手 / 31 光る物を持った手 / 40 パーティクル / 41 天候 / 42 バニラの雲 (予約。前方シェーディングなので G バッファには書かない) / 43 線など。
gbuffers で `blockIdToMaterial()` / `entityIdToMaterial()` (lib/ids/id_decode.glsl) により変換し、deferred 以降はマテリアル ID だけを見る。

一部だけ金属のもの (`AUTO_METAL_PARTS`): ID (ブロック・アイテム・エンティティ) に載せた判定の番号で、gbuffers が画素ごとにテクスチャの色から金属かを決める (`metalGatePixel`, lib/surface/material.glsl)。金属の画素は 5 金属ブロックと同じ質感 (アルベドを F0 に使い、明るい所ほど滑らか)、宝石は光沢のある誘電体 (F0 0.17)。labPBR の `_s` があるテクスチャはその値が優先で、判定は `_s` が無い (推定の) ときだけ。暗い金属は F0 の輝度を持ち上げる (`metalReflectance`。暗いほど強く、ネザライトの赤紫は弱める)。装備 (防具・道具) は、地の色が明るい画素の F0 を鉄・金ブロックの反射率まで更に持ち上げる (`gearMetalReflectance`。暗い画素は持ち上げず模様の明暗に残す)。ブロックの金属は同名のアイテム (手持ち・ドロップ・額縁) にも同じ判定を付ける (`gen_block_properties.py` が `metal_blocks()` から item.properties を出す)。防具・馬鎧は半透明の前方シェーディング経路 (gbuffers_entities_translucent) で描かれ、G バッファの金属が使えないので、同じ判定で太陽 (金属ブロックと同じ円盤の上限と強さ)・手持ち光源・設置光源の鏡面を前方で足し、拡散はほとんど残さない (周りの照度をそのまま映す項は足さない。夜の装備が拡散の白い面になるため)。環境の映り込みは水・ガラスと同じ半透明の表面として受ける: colortex5 にマテリアル 27 と滑らかさ、colortex15 の rgb に重み (方向アルベド x 補償) を書き、composite.csh が反射 (SSR・ボクセル・空) を辿り、composite2 が 反射 x 重み を前方の色に足す。全体が金属の防具の滑らかさは金属ブロックと同じ範囲で、自動法線 (`lib/surface/generated_normal.glsl`、ブロックの半分の強さ) を付ける。

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
- 近距離の面の放射 (`lightBoxNearField`): ブロック全体が光る光源 (グロウストーン・シーランタンなど) の、見える面ごとの形態係数を足す。形態係数には箱からの距離の係数 (`lightBoxGain`。根元で弱く、離れるほど強く、1.75〜3.5 ブロックで 0 に戻る) を掛け、根元の分 (箱から 1.25 ブロックまで) は deferred2 が影なしで足し、離れた所の広がり (GI の多重反射の分。0.25〜1.25 ブロックで影なしから移る) は光源の影 (中心へのトレースとデノイズの可視率) を掛ける側 (deferred2 の `full`、`evalLightIrradiance`) に入れるので、壁の裏へは漏れない。飾りの鉱物ブロック (ラピスラズリ・エメラルド・ダイヤモンド・金・レッドストーン・アメジスト。`DECORATIVE_BLOCK_LIGHTS` が発光の方式で、`DECOR_*` が種類ごとの ON/OFF。既定はダイヤモンドと金が OFF。発光 (gbuffers_solid) と光源 (`getBlockLightIndex`) は同じ `isDecorGlowBlock` に従う) の光源は、根元ではブロック自身の色の明るさで光らせ、離れるほど光源の表の明るさへ戻す。deferred2 は根元の分と同じ形態係数から求め、トレースの重みと反射・エンティティは箱からの距離だけの簡易式で求める (光源ごとに形態係数を求めるとトレースのパスが重くなる)。`LIGHT_EMISSION_MASK_MODE` は面の光り方を選ぶ。0 は面全体が一様、1 は面ごとの光る範囲の四角 (テクスチャの暗い縁は光らず、接地面の境目が暗くなる)、2 は四角を 4x4 のマスに分けて内側の模様も反映する (箱から 0.75 ブロックまで。遠くは四角。向きのある光源は火が炉の口の奥にあるので四角のまま)。点灯したかまど・燻製器・溶鉱炉とジャック・オ・ランタンは前面だけが光り (光源が見えるのは炉の口と顔だけ。向きはブロック ID の向き `blockLightFacing`)、どのモードでも前面の面だけを、光る範囲の四角 (かまどは炉の火の部分) で数える。色は光源の表の色 (かまどは火の橙)。ブロックそのものの発光 (gbuffers_solid) も同じで、前面の火の部分 (彩度の高い画素と芯の白熱) だけが光る。光り方は SSBO1 `lightMasks` (光源 x 上・下・側面・前面) で、バニラのテクスチャの発光 (gbuffers_solid の `estimateEmission` と同じ式) から `tools/gen_block_colors.py` が `tools/light_masks.json` に測る。割合は光源の最も明るい面の光る部分を 1 とするので、縁の多い光源は全体の光も減る。点に近い光源のうちランタンは、光らない面 (ふた) の向きで近距離の放射を弱める
- 半影: 光源半径 (LightDef.shape.w x LIGHT_SOURCE_SIZE) 内でターゲット点を時間的に揺らし (ブルーノイズ)、デノイズと TAA で均す。RV の SDF コーントレースは SDF 構築コストが大きいので採らない
- 接触影 (LIGHT_CONTACT_SHADOWS): ボクセルに入らない細部 (手・小さいエンティティ・草) を深度バッファのレイマーチで補う
- 低解像度 (LIGHT_TRACE_RES) + 時空間デノイズ (再投影 + 近傍の平均・分散によるクリップ + エッジ停止の空間フィルタ)。LIGHT_DENOISE=0 で最寄りの 1 サンプルのみ (フィルタなし)、1 で 2x2 + 時間、2 で 4x4 + 時間
- 鏡面 (LIGHT_SPECULAR): `getBlockLightSpecular()` が着色点のビンから照度の大きい順に最大 4 光源を `LightSample` の配列で surface に渡す (可視率は deferred2 の比を共通に掛ける。水・ガラスは光源ごとにトレースする)。代表 1 光源だと 2 光源の拡散が釣り合う線で照り返しが切れた

### 手持ち光源

- 両手独立 (`oldHandLight = false`)。強さ = `heldBlockLightValue(2)`、色 = `heldItemId(2)` -> 光源テーブル
- 位置: 一人称は view 空間の固定オフセット (利き手で左右反転)、三人称は `playerBodyVector` / `relativeEyePosition` から構築 (Shrimple basic_hand 相当)
- 影: HAND_LIGHT_RAYS = DDA (自分のビットは無視)、HAND_LIGHT_SS_SHADOWS = 深度バッファの短いレイ (手・武器・近くのモブ)。両方掛けると「壁 + エンティティ」の両方が遮る
- ピクセルごとの直接計算で floodfill には注入しない (二重加算防止)。フォグへの寄与は composite19.fsh が `getHandLightPosition` の位置から点光源の内散乱を視線に沿って解析積分して足す (影は無視。水中は水の吸収と散乱で弱まるので、角度を等分した数値積分にする)
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
| 太陽 / 月の影 | 歪み付き単一影マップ (`lib/common/shadow_space.glsl`) + PCSS (ブロッカー探索と PCF 分離) + スクリーンスペース接触影 + 色付き影 (shadowcolor0)。SHADOW_FILTER=0 でハード | surface |
| 雲影 | prepare2 で 512² の雲影マップを作り `getCloudShadow()` で地形・VL に渡す。マップは雲の下面の面の座標に固定した環状のタイル (面上のテクセル番号を 512 で割った余りがテクセルの位置) で、カメラが動いても同じ点は同じテクセルに残るので履歴をそのまま積み重ねられ、窓の端で新しく窓に入る列だけが入れ替わる (カメラに合わせて窓ごと動かすと、歩くたびに影の縁が 1 テクセルずつ引きずられてちらつく)。読み取りは 4 点の手動補間 (`cloudShadowFetch`)。光源の大きさは、毎フレーム光源の形 (丸い円盤 / バニラの四角、`lib/common/celestial_shape.glsl`) の中の 1 つの向き (R4 列、全テクセル共通) で雲を辿り、その向きの光が雲影を受ける面から雲の下面を通る点まで面の上でずらして積み重ねる。受ける面の高さはテクセルごとに影マップの深度から取る (影マップは光の向きの正射影なので、面上の点から光の向きに下ろした線の上で最初に光を受ける面が 1 回の読みで分かる。影マップの外と何も無い所は海面の高さで、カメラがそれより低ければカメラの高さ)。カメラの高さで代えると、雲の下面より上から見下ろした地面ではずらしが 0 になり、太陽が見えていても影になる。履歴の混合で、光源の面積のうち雲に隠れていない割合になる (夕日の大きな四角の一部が見えていれば、その割合だけ日が当たる)。読む側の重さは変わらない | sky |
| 雲の中の霧 | カメラが雲 (低層・バニラの形の板・中層) の中にいる間、雲のマーチの消散は外から見た雲のための薄い値で中にいても地面や遠景が透けるので、層を出るまでの一様な霧として fog_apply で掛ける (`CLOUD_INTERIOR_VISIBILITY`、既定 48 ブロック、0 で無効)。霧の消散係数は 3 / 視程 (その距離で 5% まで霞む) で、距離に比例して濃くなる。prepare2 の 1 スレッドが濃さ・雲のマーチと同じ光 (`cloudInscatter`)・マーチがすでに持つ消散を引いた霧の消散係数を求めて `skyParams[4]` `[5]` に書く。濃さは、体積の層ではカメラの周り 19 点 (中心・上下・水平の 2 つの輪。外側の輪の半径 12 ブロック) の平均から、雲の縁から十数ブロックかけて濃くなり、出るときも同じ距離で薄くなる。バニラの形の柱は半径 8 ブロックの円盤 48 点 (`cloudInteriorSlabCover`) の平均の濃さ (縁の外 4 ブロックで 0.14、縁で 0.44、縁を 3 ブロック越えて 0.66、8 ブロック越えて 1) を、0.12〜0.8 の間で 2 乗して立ち上げる (頭・底の面から 3 ブロックまで滑らかに立ち上がる)。縁では薄く、奥ほど濃い。fog_apply は `exp(-濃さ x min(距離, 霧の長さ) x 消散係数)` (`cloudInteriorFog`)。霧の長さは体積の層では層の出口までの距離で、バニラの形の板では板の上面・下面を抜けるまでの距離 (prepare2 が `skyParams[7]` に書くカメラから上面・下面までの高さ。真横に近い視線は視程の 2 倍で打ち切る)。バニラの形の柱では、雲のマーチが描く壁の消散を同じ円盤の濃さが 0.14〜0.55 の間 (縁の外 4 ブロックから縁を 1.5 ブロック越えるまで) に指数で弱め (倍率は prepare2 が `skyParams[7].z` に書く)、面から 3 ブロック内側では 0 にして、霧が視程どおりの消散を全部持つ。壁は縁の手前から透けて中の霧へつながり、縁で画面が白く閉じない。半透明 (ガラス) の向こうの背景には、ガラスから奥の面までの分を translucent_composite が先に掛け、ガラスまでの分は fog_apply が全体に掛ける。空の光は彩度を落として白灰にし、光源の光は `cloudInteriorPhase` で向きによる差を付ける。外から見た雲、雲の外のカメラは濃さ 0 で変わらない。手の深度には掛けない。レンズフレアの光源の見え具合にも濃さを掛ける | sky |
| AO | GTAO (AO_MODE=2), 軽量は SSAO | surface |
| GI | LOW/MED: なし、HIGH: RSM (shadowcolor0/1)、ULTRA: SSGI、EXTREME: ボクセル RT (light の `traceVoxelRay` + floodfill でヒット点を照らす。ボクセル体積の端では GI と空の環境光の置き換えを `GI_VOXEL_FADE` ブロックの幅で外の空の環境光へ `voxelEdgeFade` で溶かす) + SVGF 系デノイズ | surface |
| 空 / 大気 | Hillaire 2020 の 3 LUT (透過率・多重散乱・SkyView)。照度と空の SH を FrameData に書いて全パスで共有。薄明は SkyView を太陽が ±10 度の間 48 歩にし、成層圏のエアロゾル (20 km) で紫の光を出す。TWILIGHT_STRETCH は空の LUT と夜の度合いに使う太陽の高さだけ地平線より下を縮める (`atmoSkySunMu`)。ATMOSPHERE_MODE=0 は解析近似 | sky |
| 雲 | 3D 体積雲: Kappa の天気マップ事前計算 + 指数ライトマーチ + Nostalgia の 1 マーチ多重散乱近似 (位相の OD 依存非対称性) + チェッカーボード時間アップスケール。2D 押し出し (CLOUDS=2) は平面の被覆を縦に伸ばし、断面を角の丸い箱にする (`cloud2dShoulder`)。既定は被覆 1.1・スケール 3.0 | sky |
| フォグ / VL | Chocapic13 の指数分布ステップ + 影マップ空間マーチ + 区間解析積分。景色の成分 (上端のある混合層のもや + 空中遠近) は内散乱を空の色から作り (遠景は同じ方位の地平線の空に収束、影の中は太陽の単散乱を引いて光芒)、描画距離 R の端で光学的深さが FOG_EDGE_DEPTH になる距離の写像 d (1 + (d / D)^2) で縮める。局所の成分 (霧の層・地表の霧) は縮めない。高さは FOG_HEIGHT_PRESET (`lib/sky/fog_template.glsl`)、成分の形と比は FOG_STYLE (`lib/sky/fog_styles.glsl`。全体の濃さは LOOK_FOG_DENSITY)、湿地・ジャングルは `fogSwamp` / `fogJungle` (カスタム uniform の smooth 9, 10)、日替わりは `lib/sky/climate.glsl` (雲と同じ種)。地平線の下の虚空は同じ式で仮想の地面まで積み、太陽から 30 度以上の方位では地平線の空の 1.05 倍まで。仮想の地面までの距離が描画距離を超えるほど地面の色 (雪原の白など) を捨てて、見下ろした角度の分だけ上の空 (海は水面の映り) へ溶かし (SKY_VOID_AERIAL_LENGTH)、高所から見下ろした虚空が空の青に溶ける。端 (距離 = 描画距離) では 0 で、地平線のすぐ下は地平線の空とほぼ同じなので地上の見え方は変わらない。DH 対応時は `fogRenderDistance()` を DH の描画距離にし、縮めずに景色の成分の濃さを FOG_EDGE_DEPTH / R まで下げる (下限は晴天 1.5e-4)、虚空は DH の描画距離の外だけ、VL の解析区間と画面空間の光芒は DH の深度も見る。floodfill を VL マーチで読んで光源周りのフォグを照らす (FOG_BLOCKLIGHT)。洞窟の光漏れ防止 (スカイライトに加え、prepare が影マップで求める目の位置の太陽の見え方を、影マップの範囲より遠い光芒と画面の外の太陽のフレアに掛ける)。影マップに写らない遠い壁・山の裏では、画面空間の光芒 (VL_FAR) が画面の外へ出た点も端の画素の深度で判定して範囲内の点にも掛け、VL_FAR の無い構成 (VL なし・LOW) は composite25 が太陽の円盤の深度から求める「範囲より遠い地形に隠れている割合」を霧の太陽方向の光に掛ける。全面のブルーミーフォグは弱く。画面空間の光芒 (GODRAYS、`lib/sky/godrays.glsl`) は VL とは別に、空の画素 (深度 1、手を含まない) x 雲の透過率 x 光源からの角度の重みのマスクを、光源の画面の位置へ向かう放射状のぼかし (3 パスの入れ子で 1 パス N タップ、実効 N^3 タップ。低解像度の colortex16) でのばし、フォグの適用 (composite19) で光源の照度 x カメラの位置の霧の濃さの係数を掛けて足す。半透明は遮蔽にしない。画面の外のタップは 0、光源が画面の外へ出るほど弱め、外にある分には目の位置の太陽の見え方を掛ける。水中・溶岩・粉雪の中・ネザー・エンドでは足さない | sky |
| 水 | 前方シェーディング + 波 (FFT の波テクスチャを大きさの違う層で重ねる。層は帯の中心の波長が画面で 3.8 画素から 1.5 画素になる間で薄めて粗さへ回し、遠景も画素に近い細かさまで波の列の明暗を描く。落とした後の法線の傾きが 5 層の傾きの RMS の WATER_FAR_SLOPE_KEEP 倍を下回る遠くでは、足りない分をその距離で描ける最も細かい層の振幅に足し (足した分は粗さから引く)、傾きの多くが短い層にある湖・川も遠くまで波の帯で映り込みが揺れる。いちばん長い層も画素より細かくなる先は、層 0 のタイルを 2.9 倍ずつ大きくした遠い層 (5 本、振幅は床の分だけ、層 0 の周期で動かす) が床を受け持ち、描ける最も細かい遠い層の 4 割を 1 つ長い層へ回して縮尺と向きの違う 2 本を重ねる (同じ模様が並ばない)。距離の判断 (層の振幅・粗さ・画素の中の傾きの揺れ・フレネルと空の均し・視差の段・鏡の映り込みの重み) は `waterLod` (`lib/common/water_lod.glsl`) の 1 か所で、水面の 1 画素の大きさから決める。法線で描く最短の層はワールドで固定 (最小の層、波長 0.32 ブロック) し、表面張力波の 2 層はどの距離でも粗さ (WATER_GLITTER では点) にする (その波が画素より大きい近くでは、粗さへ回す分散を 2 割に抑える)。WATER_GLITTER では太陽 (月) の照り返しの粗さに、長い波と短い波の高さと風の息の値ノイズから作る場所ごとのさざ波の強さのむら (対数正規、平均 1) を掛け、凪いだ所は波の面のまま白く光り、粗い所に点が集まる (波の形が画素より細かい中景は凪に下限を付ける)。点は理論の数のうち明るい側の一部だけを置いて置かない点の光を寄せ (総量は同じ)、1 つの点を、点を生んだ面の波の稜線 (鎖より長い波だけの高さの等高線。勾配の小さい所は画面の横) に沿って 2〜7 個並ぶ子と、子の間をつなぐ細い光の鎖にする (かすめ角では奥行きが縮むので画面の横に寝て、波を横から見た所だけ縦寄りの短い列になる。子の明るさ・大きさ・間隔・向き・光る時刻はばらつかせ、特に明るい点は 1 つのまま。点の量・鎖の長さ・1 つのままの割合は設定 WATER_GLITTER_DENSITY / WATER_GLITTER_LENGTH / WATER_GLITTER_SINGLE。月が光源の夜は点の量に WATER_GLITTER_NIGHT_DENSITY を掛け、暗い月の道を少ない明るい点に集める)。波の形が見える近くは点の詰まった所を波の形の白い面に、中景は点のまま残す。近づいても波の形は遠目のまま拡大されるだけで、近景は 3 次の補間で滑らかに引く。層はどれも同じ波テクスチャなので、2 つ隔てて向きの近い層が同じ形で入れ子にならないよう間の 2 層を鏡映する) + 視差。上面の太陽・灯りの照り返しは傾きの分布をガウス (Beckmann) にし、WATER_GLITTER の点と同じ分布にする (GGX の長い裾は遠くの水面一面に薄い光を残す)。上向きの水面の映り込み (物と空) は、画素より細かい波の傾きの分 (海は WATER_REFLECT_SCATTER 倍で既定 0.3。湖・川は WATER_LAKE_REFLECT_SCATTER / WATER_RIVER_REFLECT_SCATTER で既定 0 の鏡) だけ粗い反射の経路 (半分の解像度の VNDF の 1 本と時間の蓄積) で散らし、かすめ角では縦に伸ばす。散らしの小さい水面 (凪・近く) は composite1 のフル解像度の鏡のまま (境は重みで混ぜる)。波頭の透過光は太陽の側を低く見た時だけ。composite1 (`water_trace.fsh`) で屈折 (SS / レイトレース)・上向きの水面の太陽の可視率 (PCSS)・凪の水面の鏡面のフル解像度の SSR を求め、composite2 で吸収 (Jerlov 風)・反射・合成 (風・波の高さ・波頭の尖り・映り込みの散らし・水の色・吸収・濁りは海・湖・川ごとの設定で、カメラのバイオームの重み distantOcean / waterRiver で混ぜる。波のスペクトルは種類ごとに足し、ほかの値は prepare が混ぜて FrameData に置く)、コースティクスは影マップ参照。水の上から見た内散乱は、深さで弱まる水面の照度を屈折した視線に沿って解析積分する。水中の VL は指数分布のステップで、floodfill の照度にライトビンの光源の向きから求めた前方散乱の位相関数を掛ける (光源の周りのにじみ) | surface |
| 反射 | SSR (階層なし線形 + 二分探索) + ラフ反射 (時間蓄積)、SSR 失敗時はボクセル補完 (REFLECTIONS=3, light の `traceVoxelRay`)、最後は空 (`getSkyRadiance`) | surface |
| TAA | Halton(2,3) 16 フレームのジッター (`lib/common/jitter.glsl`) + YCoCg 近傍クランプ + Catmull-Rom 履歴 + トーンマップ空間での混合 (HDR フリッカー対策。鏡面の白飛び分 (SPECULAR_SPARKLE、`colortex0.a` = 1 + 割合で deferred30 / composite2 から渡る) だけは箱と本体の履歴から外し、ジッターを外した位置で双線形に集めて、線形のまま専用の短い履歴 colortex17 (混合率 静止 0.4 / 動き 0.7、箱の切り詰めなし。上だけ今フレームの 3x3 の白飛び分の最大で抑え、消えた照り返しの点を尾で残さない) で時間方向に積分してから足し、ブルームとレンズへ HDR のまま届ける。TAA の後の `colortex0.a` は正 = 白飛び分の割合、負 = 溶岩の発光の割合) + 速度は colortex15 か深度再投影 | post |
| DoF | MIP-Bokeh (サンプル点で CoC を取り直す, 30/50/75 点)、物理カメラ (FOV から焦点距離)、オートフォーカス (速め)、手は除外、HDR 空間で実行。既定はボケ控えめ。軸上色収差は鏡面の白飛び分 (TAA の後の `colortex0.a`) には掛けず、緑のボケ半径で集める (明るい点の中心が緑・周りが紫に割れない。final の倍率色収差も同じ)。縁の明るいボケ (LP_BOKEH_RIM / LP_SA_RIM) はボケ半径 1.5-4 px で効かせ始める (数 px の玉ボケが中心の暗い輪にならない) | post |
| モーションブラー | 速度ベクトルに沿ったサンプル。既定 ON | post |
| ブルーム | colortex0 のミップからタイル縮小 -> ぼかし -> final で合成。既定 0.5 (控えめ) | post |
| 露出 | ヒストグラム (FrameData.histogram) + 非対称の順応速度 (明るい方へ 3 倍速) + 範囲制限。屋外の夜の持ち上げは、月が照らす夜 (満ち欠け x 晴れ x 夜。水中は 0) の度合い `moonLit` で、傾き 0.4 -> 0.5 に強め、持ち上げに使う計測を平均 (35..92%) から画面の暗い側 (5..50%) へ寄せる。上限は月夜も 1.3 EV のまま (上げると月の照る暗い草原が灰色に浮いて霧っぽくなる)。新月・雨の夜・水中は `moonLit` が 0 で、前と同じ平均・傾きのまま暗さを残す。EXPOSURE_MODE 1 (平均) は暗い側の計測が無く平均のままだが、傾きは `moonLit` で変わる。MODE 0 (マニュアル) は掛からない。持ち上げの量全体には `EXPOSURE_NIGHT_LIFT_STRENGTH` (既定 1、0 で持ち上げなし) を掛ける | post |
| トーンマップ | AgX (多項式近似, 公知) を既定、AgX Punchy / ACES / Reinhard-Jodie / AgX Golden / PBR Neutral を選択式 (TONEMAP 0-5)。後段で彩度・コントラスト・ホワイトバランス・CAS・ビネット・8bit ディザ | post |
| レンズフレア | 太陽・月のレンズフレア。既定 ON (全プロファイルで ON)。光源の形は `lib/common/celestial_shape.glsl` の影を落とす天体の形 (丸い円盤の半径、SUN_MOON_STYLE=0 はバニラのテクスチャの明るい 8x8 の四角: 太陽の半幅 0.075、月 0.05、板は日周運動の回転軸に沿う) を tan 座標の 2 軸に写して使う。見え具合 (composite25) は形の中の 256 点 (バニラは四角の 16x16 の格子)。ゴーストの縁は縁の向きの光源の幅 (支持関数) でぼかし、バニラの四角ではグレア・汚れを四角で畳み込んだ式 (長方形の立体角の閉じた式)、光条は四角の一番近い点から引いて四角で畳み込んだ明るさへ割り戻す。バニラのテクスチャは明るい四角だけを光源にし、周りの淡い光 (ゲームの描き方の暈) は放射にしない (`sun_moon.fsh`) | post |
| 点像の芯と裾 | 白を超えた鏡面の点 (1 画素ほど) をレンズの点光源に見せる。芯: final が colortex17 (白飛び分、DoF の前の線形) の一部 (`POINT_CORE_SHARE`) をガウス (`POINT_CORE_SIGMA` px) で配る (双線形 5x5 の読みで 9x9 の重み。2 px で切ると明るい点の周りに縁の立った四角い光が出る)。芯と裾の大きさは LENS_POINT_SPREAD_SIZE の 4 段 (小・中・大・特大。既定は大で、芯 40% / sigma 1.1 px、裾 0.40)。白をわずかに超えた点は 1-2 px のまま、白を大きく超えた点ほど芯の周りまで白く飛び、裾も合わせて明るい点ほど大きな光の塊になる。裾: ミップ 1〜4 段を B スプラインで読み、同じエネルギーずつ芯から周りへ配る (裾は r^-2、総量は変えない)。配る割合は `POINT_SPREAD_BASE + POINT_SPREAD_PER_GLARE x LP_VEILING_GLARE` (散乱の強いレンズほど大きい) に LENS_POINT_SPREAD_STRENGTH (既定 1.5) を掛ける。配る割合の和は 1 まで (強さで先に裾を増やし、芯は残り)。球面収差・ブルーム・ヘイズの mix の前に掛ける。DoF・モーションブラー・色収差の後の像には同じだけの白飛び分が残らないことがあるので、中心から引くのは TAA の出した白飛び分の外の色 (colortex13) を超えて残っている分まで (引きすぎると点の中心が黒・緑・紫に抜ける)。芯と裾は DoF のボケ半径 2 px で消える (ボケた点は玉ボケに任せる)。ミップは final の `colortex17MipmapEnabled` で作る。近くに白飛び分が無い画素は最粗に近い段 1 回で打ち切る。光条は別 (ブルームの帯域) | post |
| レンズプリセット | LENS_PRESET 0 はカスタム (LENS_C_*)、1 は現代の単焦点 (既定)、2-6 は推定値の味付け、7-18 は特許の処方から計算した値 (ゴースト表 `tools/gen_lens_ghosts.py`、歪曲 K1-K3、魚眼の写像、周辺光量と像面の焦点ずれの 9 点の表、STF のアポダイゼーション `LENS_APODIZATION_BETA` (composite22 のボケのサンプルに瞳の透過率を掛ける)、FA 28 Soft と Canon 50/0.95 の球面収差のハロー `LENS_SOFT_HALO_TABLE` (final で F 値ごとの半径に合うブルームのタイルを混ぜる))。新しいレンズは後ろに足し、既存の番号は変えない。歪曲と魚眼は TAA・DoF・ブルームの後、final の最初で出力 -> 元画像へ再投影し (`lensProjectUv`)、魚眼と歪曲の強い時 (LENS_WARP_IN_TAA の自動) は TAA (composite20) の中で出力の画面を組み立ててジッターで中央の細かさを戻す (以降の colortex0・colortex13・ブルームは出力の座標になり、深度・G バッファ・速度だけ `postSourceUv` で元画像の位置を読む)。太陽・月のフレアは光源を出力側へ写して (`lensForwardUv`) 出力の座標で描く。直線写像で歪曲 0 のプリセットでは再投影は定数畳み込みで消える | post |
| ルックのプリセット | LOOK_PRESET 0 はカスタム (LOOK_C_*)、1 はナチュラル (既定。明部の伸びだけ 1.1 で、ほかの基準値は掛ける値が 1・足す値が 0)、2 はビビッド、3 デイライト、4 夏の青空、5 ゴールデンアワー、6 ティール & オレンジ、7 ブリーチバイパス、8 クロスプロセス、9 ゲーム。3 以降は色と階調の多くをグレーディングの基準 LKG_* で作る。`lib/common/look_presets.glsl` の `#if` で基準値 LK_* を差し替え (Iris の profile は品質のプロファイルの 1 組しか持てないため)、既存の設定 (SATURATION, CONTRAST, EXPOSURE_BIAS, BLOOM_STRENGTH, BLOOM_FOG, GI_SKY_OCCLUSION, SKY_AMBIENT_SATURATION, FOG_DENSITY) は LK_* に掛ける (露出は足す)。効く所: 空の環境光の強さ (SH 全体。霧・粗い反射・フレアの判定では戻す)、日向の暖かさ (prepare の太陽の直達光だけ)、照り返しの強さと彩度 (GI のレイが当たった面だけ、`giBounceGrade`。多重反射の履歴は強さで割る)、明部の伸び (final、中間グレーより上の log2 の傾き)、暗部の持ち上げ (AgX の出力の復号を 2.2 乗から sRGB の曲線へ)、ブルームの広がりと晴れのブルーミーフォグ | 全モジュール |
| 雲の形のプリセット | CLOUD_STYLE 0 はカスタム (CLOUD_S_*)、1 は Ray (既定)、2 Bliss 風、3 バニラの形、4 現実に忠実、5 綿あめ、6 入道雲、7 まばらな晴天積雲、8 層積雲の曇り。`lib/sky/cloud_styles.glsl` の `#if` で基準値 CS_* (晴天の層ごとの雲量、低層の大きさ・背丈・対流・雲種・晴れ間・こぶ・浸食・雲底・断片雲・もや・縁・濃さ・芯、こぶの陰・銀の縁・powder・日光・多重散乱・空の光・雲底の暗さ) を差し替え、既存の CLOUD_* の設定は CS_* に掛ける。雲量・濃さ・光の値は雨天度で Ray の値へ戻り、雨は全天の雨雲へ移る (雨雲・雷雨はバニラの形を除いてどのスタイルもほぼ同じ。大きさ・こぶなど形の定数は雨雲にも効く)。バニラの形は雨雲へ作り替えず、板の形のまま、雨の強さ (`cloudRainAmount`) に応じて模様の外のマスをマスごとのハッシュの順に埋め、空をほとんど覆う (マクロ CLOUD_RAIN_KEEPS_SHAPE、`VANILLA_CLOUD_RAIN_COVER` 0.95。雷雨も雨と同じ)。この雨天度は、雲の光 (曇天の色・拡散・直達光の減衰) と濃さの倍率、雲の向こうの空を雨雲の層の灰色にする置き換え (雲の隙間から青空や太陽が見えない。カメラが雲の層の上端より上にいる間は掛けず、空の曇天も外して普通の空にする (`cloudRainBelowDeck`)。水面などの反射の空も同じ灰色にそろえ、太陽の円盤の鏡像は隠す。空中遠近で雲の上に戻す色も同じ灰色にして、描く距離の端で天井が向こうの空へ継ぎ目なく溶ける)、雲影マップ全域の太陽の遮りに効かせる。視線の濃さを上げたスタイルは、光源・真上方向の光学的深さを芯の実測の消散係数で頭打ちにする (CLOUD_STYLE_LIGHT_SIGMA_RATIO)。バニラの形 (CLOUD_STYLE=3 と、カスタムの形がバニラの形のとき。マクロ CLOUD_VANILLA_SHAPE) は、バニラの雲のテクスチャ (clouds.png。リソースパックのものに従う) を customTexture の vanillaCloudTex で読み、Iris の `cloudHeight` (下面の高さ) と `cloudTime` (流れ) でバニラと同じ高さ・模様・流れの向きで、バニラの 12 ブロックの 2 倍 (`VANILLA_CLOUD_CELL_SCALE`、24 ブロック) の格子に置く、板の体積雲 (`lib/sky/cloud_vanilla.glsl`、マーチは `cloudMarchVanilla`)。雲は模様のマスごとの同じ厚みの柱 (板雲) で、面はすべて軸に平行 (曲面・形のノイズを持たず、辺と角だけ `VANILLA_CLOUD_CORNER_RADIUS` (3 ブロック) で丸める。0 で四角いまま)。厚みは `CLOUD_VANILLA_THICKNESS` (既定 16 ブロック。格子を大きくしても絶対値のまま) でどのマスも同じ。柱の表 (`cloudWeatherImg`) は prepare2 が毎フレーム作る (マスの有無と空の区画の印。雨の埋まり方も入る)。表に出ている面 (隣のマスが雲でない側面・頭・底) から 2 ブロック (底は 1.8 ブロック) だけ密度を下げて縁を透かし (形は変えない。柔らかさは画素の大きさの 1.5 倍より細かくせず、側面は遠くほど画素の 4.5 倍まで広げる)、視線の消散は `VANILLA_CLOUD_OPACITY` 倍にする。マーチは表の 4x4 マスの区画が空なら区画の箱を、空のマスや頭より上ならマスの箱を DDA で飛ばし、柱の近くだけ細かく歩く。光源方向は光の向きへ表のマスを 1 つずつ渡り、柱の頭より下を通る長さを `VANILLA_CLOUD_LIGHT_REACH` ブロックまで足し (直方体なので長さは厳密。点で読むと影の境目がぎざぎざになる)、真上は柱の頭までの長さの解析値。日向の光には柱の頭の近くだけ緩いむら (`VANILLA_CLOUD_TOP_MOTTLE`) をかけ、上から見た上面に柔らかい明暗を付ける。カメラが柱の縁に近づく間 (縁の外 4 ブロックから) と中にいるときは、視線の消散を `skyParams[7].z` の倍率へ弱める (面から内側へ `VANILLA_CLOUD_INSIDE_DEPTH` (3 ブロック) 入るまでに 0。中の見通しは雲の中の霧が決めるので、縁で壁の消散が白く閉じない。どの段でも同じ)。陰と内散乱の濃さは既定の濃さで頭打ちにする (濃さを上げても底が暗くならない)。底は空の光の青みを抜いた灰白色にして (`VANILLA_CLOUD_SKY_SATURATION`・`VANILLA_CLOUD_BASE_SHADE`)、底は一様な厚みの板の底。雨雲の層の中 (`cloudRainBelowDeck` が 1) では板と雲の中の霧の光を曇天の暗さへ寄せ (`VANILLA_CLOUD_RAIN_SUN` `VANILLA_CLOUD_RAIN_AMBIENT`)、底の暗さを無くして (`VANILLA_CLOUD_RAIN_BASE`。層の中から見下ろす底が霧や地形より暗い影にならないように)、柱の明るさには雲の向こうの曇天の灰色の一定の割合を下限にし (`VANILLA_CLOUD_RAIN_FLOOR` 0.9。雨で空を覆う板が、隙間の曇天の灰色と同じ明るさになる。雷雨も雨と同じ曇天の暗さにする)、散乱の向きを横から見た値へ寄せ (`VANILLA_CLOUD_RAIN_DIFFUSE`)、雲の上に戻す空の色は太陽の暈の無い空の光にして (`VANILLA_CLOUD_RAIN_SKY`。暈が雲の上だけ茶色く浮かない)、雨粒 (weather.fsh) は層の上端より上で薄くして消す。写実の雲 (積雲・中層・上層・積乱雲・雨脚) は一切描かずバニラの形の段だけを描き (雨の日は板を濃くして底を暗くする)、雲影マップにも掛かる。下段の上に、同じ模様を回転・ずらし・間引き・引き伸ばしで別の雲に見せた上の段を重ねる (CLOUD_VANILLA_TIER_COUNT。中段は 8 ブロックの薄い直方体 (格子 36 ブロック、模様を 90 度回して間引く)、上段は 3 ブロックで横に 4 倍引き伸ばした細長いマス。段ごとに流れる向きと速さが違い、高さは下段の底から CLOUD_VANILLA_TIER_HEIGHT の案 (約 190 / 410 ブロック上、または約 70 / 120 ブロック上)。段の列は表を使わず模様から直接求める (vanillaTier)。視線は全段を 1 つの cloudMarchVanilla で入口の近い順に重ね、上の段は雨雲の層の下からは見えない。夜は上の段を暗く薄くし (VANILLA_TIER_NIGHT_GAIN と VANILLA_TIER_NIGHT_THIN。太陽が地平線の十分下で、月明かりの分だけ見えて星空より目立たない)、上段は間引きを 3 マスの塊ごとに決め、側面を広く柔らかくして斜めの辺の階段を薄い縁にぼかし、光のむらは掛けない (薄い板にまだらが出ない)。下段の最初の密度のある点で上の段の影を 1 回だけ求めて、その視線の残りに使う)。積乱雲 (塔と金床) は立てない (CLOUD_CUMULONIMBUS はほかのスタイルの設定)。板の高さにある雲の有無は、prepare2 が毎フレーム作る柱の表 (cloudWeatherImg。テクスチャが 512 より大きいリソースパックでは表を使わず、模様を直接読む) から読む | sky |
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
| LIGHT_SHAPE_TRACE | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_EMISSION_MASK_MODE | 0 | 0 | 0 | 0 | 0 | 0 | **1** | **2** | **2** | **2** |
| LIGHT_TRANSLUCENT_TINT | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_SPECULAR | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_DENOISE | 2 | **1** | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| LIGHT_ENTITY_OCCLUSION | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_PLAYER_OCCLUSION | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_OCCLUSION_MODE | 1 | **0** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| LIGHT_ENTITY_TRIANGLES | 4096 | **2048** | **2048** | 4096 | 4096 | 4096 | **8192** | **8192** | **16384** | **16384** |
| LIGHT_CONTACT_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| LIGHT_MAX_COUNT | 4096 | **2048** | 4096 | 4096 | 4096 | 4096 | 4096 | 4096 | **8192** | **8192** |
| LIGHT_BIN_LIGHTS | 64 | **32** | 64 | **48** | 64 | 64 | 64 | 64 | **96** | **96** |
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
| VL_RES | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | **1** |
| VL_COLORED_SHADOWS | OFF | OFF | OFF | OFF | OFF | OFF | **ON** | **ON** | **ON** | **ON** |
| FOG_BLOCKLIGHT | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| FOG_CLOUD_SHADOWS | ON | **OFF** | **OFF** | ON | ON | ON | ON | ON | ON | ON |
| VL_FAR | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| GODRAYS | ON | **OFF** | ON | ON | ON | ON | ON | ON | ON | ON |
| GODRAYS_RES | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| GODRAYS_SAMPLES | 8 | **6** | **6** | **6** | 8 | 8 | **12** | **12** | **16** | **16** |

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
| sky (空・大気・雲・フォグ・VL) | 大気 LUT、太陽/月の照度と空の SH、空の描画、星、雲 (体積・2D・影)、高さフォグ、VL、水中フォグ、雨 | `lib/sky/*`, `program/sky/*` (setup1, setup2, prepare, prepare1, prepare2, gbuffers_skybasic / skytextured / clouds / weather, deferred20, deferred21, composite1_a, composite12-14, composite19) |
| surface (太陽影・GI・マテリアル・水・反射) | gbuffers (不透明/半透明/オーバーレイ)、マテリアル (labPBR・自動法線・POM・揺れ)、BRDF、太陽影、AO・GI、不透明シェーディング (deferred30)、水、反射、半透明合成 | `lib/surface/*`, `lib/common/water.glsl`, `program/surface/*` (gbuffers_* が共有する solid / translucent / overlay, gbuffers_lightning, deferred10, deferred11, deferred30, composite, composite1, composite2) |
| post (ポストプロセス) | 速度ベクトルの関数、TAA、モーションブラー、DoF、ブルーム、露出、オートフォーカス、トーンマップ、色調整、CAS、レンズフレア、デバッグ表示 | `lib/post/*`, `program/post/*` (composite20-24, composite25, final) |

- shadow パスの出力 (shadowcolor の内容) は surface (RSM・色付き影) と sky (色付き光芒) も使う。内容を変える時は「colortex」の節の定義を守り、docs/architecture.md も更新する
- 表面の光 (light / sky の関数) は surface の `gatherSurfaceLights` が呼ぶ。deferred30・半透明・composite2・二次ヒットは light / sky の照度の関数を直接呼ばない
- `program/surface/gbuffers_solid.vsh` から `injectEntityLight`、`program/surface/gbuffers_*` から `encodeVelocity` を呼び出す (関数本体は light / post モジュール)
- 本体のファイル名は役割名で、Iris のプログラム名との対応は `tools/gen_wrappers.py` の `BODIES` にある (例: composite2 は `program/surface/translucent_composite.fsh`)
- 大きな処理は 600 行以下を目安にファイルを分ける。体積雲は `lib/sky/cloud_volume.glsl` が `cloud_constants` / `cloud_weather` / `cloud_density` / `cloud_lighting` / `cloud_march` を読む。半透明の合成の水と鏡面は `lib/surface/water_shading.glsl` と `composite_specular.glsl`。水面の `lib/common/water.glsl` は `water_waves` / `water_glitter` (画素より細かい波が光源を映す点、WATER_GLITTER) / `water_lod` (距離の判断) / `water_normal`、鏡面の白飛び分は `lib/common/specular_sparkle.glsl`、レンズの `lib/post/lens.glsl` は `lens_optics` / `lens_flare` を読む。`lib/post/lens_presets.glsl` はレンズごとの値を 1 つの `#if` の連なりで持つ表なので分けない
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
| `vec3 getHandLightPosition(bool mainHand)` | sky (composite19 の手持ち光源のフォグ) | 手持ち光源の player 空間位置 |
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
| `float celestialDiscScale()` / `celestialSpecularStrength()` | surface (`composite_specular.glsl`, `opaque_shading.fsh`) | 天体の鏡面の上限に掛ける円盤の明るさの倍率 (夜の月は空に描く円盤 (`MOON_DISK_NIGHT_GAIN` を掛けた後) に合わせ、周縁減光の無い月には太陽用の `SPECULAR_DISC_PEAK` を掛けない。WATER_GLITTER の点は点に集めた分だけ実物の円盤まで上げ、円盤を超える点 (像が画素より大きい点) は SPECULAR_POINT_SPREAD_MAX 倍まで上限を上げてエネルギーを捨てない。1 より大きい強さで割り、強さを掛けても鏡のような面の鏡像は見えている円盤を超えない) と、設定 SPECULAR_SUN_STRENGTH / SPECULAR_MOON_STRENGTH |
| `vec3 getSkyIrradiance(vec3 n)` | surface (`gatherSurfaceLights`, 反射のフォールバック) | 空からの拡散照度 (SH) |
| `vec3 getSkyRadiance(vec3 dir)` | surface (反射のフォールバック), post | 方向の空の放射 (太陽円盤なし) |
| `vec3 renderSky(vec3 dir, vec3 vanillaSky)` | surface (deferred30 の空ピクセル) | 背景の空 (太陽月・星込み) |
| `vec4 getCloudLayer(ivec2 texel)` | surface (deferred30) | rgb 雲の散乱光, a 透過率 |
| `float getCloudShadow(vec3 playerPos)` | surface | 雲影の透過率 (光源の面積のうち雲に隠れていない割合) |
| `CelestialShape shadowLightShape()` / `celestialShapePoint` / `celestialShapeDir` (`lib/common/celestial_shape.glsl`) | sky (雲影マップ), post (フレアの見え具合と形) | 影を落とす天体の見かけの形 (向き・板の 2 軸・半径か半幅) と、形の中の一様な点。円盤の半径 SUN_ANGULAR_RADIUS / MOON_ANGULAR_RADIUS / MOON_DISK_SCALE もここにある |
| `float getBorderFog(vec3 playerPos)` / `vec3 applyForwardFog(vec3 color, vec3 playerPos)` | 前方シェーディング (パーティクル等) | composite19 と同じモデルのフォグ |
| `vec3 shEvalIrradiance(vec3 n)` | (内部) | SH 評価 |

surface モジュールが提供 (`//@include "/lib/surface/surface.glsl"`):

| 関数 | 呼ぶ側 | 内容 |
|---|---|---|
| `Material decodeMaterial(GBufferData g)` | surface, light (鏡面の重み付け) | labPBR -> シェーディング値 |
| `vec3 evalDirectLight(Material m, vec3 N, vec3 V, LightSample L, float discScale, out vec3 spec)` | surface | 直接光 1 つの拡散の出射放射 (spec に鏡面) |
| `vec3 evalDiffuseIrradiance(Material m, vec3 irradiance)` | surface | 方向のない照度の出射放射 |
| `SurfaceLights gatherSurfaceLights(SurfacePoint p, int sunMode, int blockMode, uint terms)` (`lib/surface/surface_lights.glsl`) | deferred30, 半透明, composite2, 二次ヒット (`lib/surface/lighting.glsl`) | 表面の光 (太陽の影・空・ブロックライト・手持ち光源・GI) を、取り方 (`SL_SUN_*` / `SL_BLOCK_*`) と足す項 (`SL_*`) を指定して集める。返すのは照度と `LightSample` だけで、BRDF・AO・溶岩・水たまり・SSS の厚みの減衰は呼ぶ側が掛ける |
| `vec3 getSunShadow(vec3 playerPos, vec3 geoNormal, float dither)` | surface (`gatherSurfaceLights`), light (GI 的な用途) | 太陽影 (色付き透過率) |
| `vec3 sampleShadowVolume(vec3 playerPos)` (`lib/common/shadow_volume.glsl`) | sky (VL), light (floodfill のスカイライト等) | 1 タップの色付き影 |
| `vec4 getIndirectLight(ivec2 texel)` | surface | rgb 間接光, a AO |
| `vec3 applyWaving(vec3 playerPos, int blockId, bool isTopVertex, float skyLight)` | gbuffers, shadow.vsh (light) | 植物の揺れ (影と一致させる) |
| `WaterLod waterLod(WaterSea sea, float dist, float NoV[, float pixelAngle])` (`lib/common/water_lod.glsl`) | surface (gbuffers_water・composite1・composite2・反射) | 水面の距離の判断: 層ごとの法線の振幅 (層 0 より長い遠い層を含む)・波の高さを読むか・粗さへ回す傾き・画素の中の傾きの揺れ・フレネルと空の均し・視差の段・鏡の映り込みの重み |
| `vec3 getWaterNormal(WaterLod lod, vec3 worldPos, vec3 geoNormal, vec2 flow)` (`lib/common/water_normal.glsl`) | surface | 水面の法線 |

表面の光の集め方 (`gatherSurfaceLights`)。呼ぶ側は使う取り方と項を const で書き、省く項をコメントに残す:

| 項 | deferred30 (不透明) | 半透明の前方シェーディング | composite2 (水・ガラス) | 二次ヒット (GI・反射・屈折先) |
|---|---|---|---|---|
| 太陽の影 | PCSS。影マップの外と一人称の手はスカイライトで近似 (`SL_SUN_SHADOW_MAP_FALLBACK`) | PCSS。外は 1 (`SL_SUN_SHADOW_MAP`) | PCSS。外は 1 (影の距離より遠い地下の水・ガラスは日向になる)。水の側面は雲影とスカイライトで近似、水中は 0 | ボクセル体積の 1 タップ (`SL_SUN_VOLUME`) |
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
| SSBO0 FrameData | lightStats を書く | sun/moon/SH/skyParams[0..3] と surfaceParams[0..5] (開けた水面の海の状態、きらめきのフレームの長さ、海・湖・川を混ぜた水の性質) を書く (prepare2 が skyParams[4..7] を書く) | surfaceParams[0..5] を読む | exposure/focus/histogram/postParams と skyParams[3].z を書く |
| shadowtex / shadowcolor | 書く (shadow パス) | 読む | 読む | - |
| colortex1/2/3/15 | 読む | 読む | 書く | 読む |
| colortex4/5 | - | colortex4 に雨を書く | 書く | - |
| colortex6/7, blockLightRaw/Aux | 書く | 読む (6) | 読む (6, 関数経由) | 読む (debug) |
| colortex8/9/18-21, giRaw, reflection | 読む (8) | 読む | 書く | 読む (debug) |
| colortex10/11/12/16, sky LUT, cloud*, fogHistory | 読む | 書く | 読む (11, 関数経由) | 読む (debug) |
| colortex0 | - | 空テクスチャ (gbuffers), composite19 で書く | deferred30 / composite2 で書く | composite20 以降で書く |
| colortex13/14/17 | - | - | - | 書く |
| debugImg | 書ける (IMG_DEBUG) | 書ける (IMG_DEBUG) | 書ける (IMG_DEBUG) | 表示 (DEBUG_VIEW=12) |

---

## 規約・単位・検証

### 座標と単位

- 座標: screen (UV + 深度), view, player (カメラ原点のワールド軸, 法線もこの空間), world, voxel (`lib/common/transforms.glsl`, `voxel_space.glsl`)
- 手の深度は `fixHandDepth()` で戻してから再構成する
- 光の量は線形 HDR の相対値。基準は `lib/common/constants.glsl` の `SUN_ILLUMINANCE` (6.0) / `MOON_ILLUMINANCE` / `SKY_ILLUMINANCE` / `BLOCKLIGHT_ILLUMINANCE` (レベル 15 の光源から 1 ブロック) / `EMISSION_LUMINANCE` / `MIN_AMBIENT`。各モジュールが独自のスケールを作らない。最終的な明るさは自動露出が吸収する
- 夜の月: 地面の拡散と照り返しのローブは照度 `MOON_ILLUMINANCE` (太陽の 1/500) のまま。空に描く円盤だけ見た目のために暗くしてあり、放射は照度どおりの値 (`MOON_DISK_SCALE` 2.5 倍の大きさ) の `MOON_NIGHT_BRIGHTNESS` 0.004 x `MOON_DISK_NIGHT_GAIN` 32 = 0.128 倍 (実寸の円盤の放射の 1/49)。鏡像の上限はこの円盤で、太陽と同じく強さ 1 で円盤の鏡像どおり。地上の不透明で金属でない面 (草・葉・土・石) だけは見た目のため照り返しのローブを `MOON_DIELECTRIC_SPECULAR_GAIN` 8 倍にし (上限は同じ倍率で割る)、月の方を見た草の先を白く光らせる。地球照とフレアの強さは `MOON_NIGHT_BRIGHTNESS` だけ (32 倍しない) を基準にする
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
- 影・GI・反射: 水の後ろのガラスが手前に見える。半透明越しの環境反射は空のみ。RSM に可視性はない。F82 は未実装。自動法線は地形とエンティティ (手持ちと植物は対象外)
- ポスト: TAAU は見送り (Iris では gbuffers の解像度を下げられない)
- エンティティのボクセル化は Iris 1.8 の `shadow_entities` / `shadow_block` に依存。影パスの距離 (`entityShadowDistanceMul`) とフラスタムの外のエンティティは遮蔽物にならない
- 階段は向き・上下・外角を ID に持ち、ハーフ + 段の箱 2 個で遮る。内角 (段が 3/4) は箱 2 個に収まらないので同じ向きの直線で近似する (1/8 ブロック小さい)
- `minecraft:light` (ライトブロック) の実際のレベルは `at_midBlock.w` が 0 で来る可能性があり、その場合は既定 15 になる (未対処)
- MOD ブロックは未登録 = 完全な固体扱い。光る MOD ブロックはタグ (`%c:...`) か個別登録が必要
- エンダーチェスト等ブロックエンティティの光源はボクセル地形に乗らない (shadow_block から登録する必要がある。「ドロップ・投擲・燃焼・発光エンティティ」参照)
- DH / Voxy / Photonics 連携は未対応。DH を入れていると Iris は「DH シェーダーなし」として扱う (LOD の見た目は保証しない)
- Iris 26.1 は半透明エンティティ (プレイヤーのスキン・マネキン・文字・旗の模様等) を deferred の後 (`renderTranslucentFeatures`) に gbuffers_entities_translucent / gbuffers_block_translucent で描く。G バッファ経路のフォールバック (gbuffers_entities) だと deferred30 で照明されず消えるので、両者は半透明の前方シェーディング (`program/surface/gbuffers_translucent.*`) で用意した。速度は書かず深度再投影に任せる (並べ替えで at_velocity が使えないため)。画面空間の影 (手持ち光源の SS 影等) には写らないので、三人称の自分の影は手持ち光源のボクセル DDA で落とす。この層は水より先に描かれ、水の合成が水の中の自分を水面の上に重ねるので、カメラが水の上の時は、水面より下の自分の画素を捨て、composite1 (`water_trace.fsh`) が屈折した視線を自分の三角形 (光源シャドウ用に影のパスで持っている) に当てて、三角形ごとの平均の色を当たった点で照らして描く (屈折・波の揺れ・水の吸収が付く。一人称は体を描かないので当てない)。三角形を持たない設定 (LIGHT_OCCLUSION_MODE 0 か LIGHT_PLAYER_OCCLUSION OFF か屈折なし) では、捨てずに水の吸収と内散乱だけを掛ける (`lib/surface/water_self.glsl`。水面の高さはボクセルの水のブロックから)。上に水のある水のセルは面が描かれずボクセルに空気として残るので、空気は上に水がある限り水とみなして水面まで辿る。足のあるセルだけは水の入ったハーフブロック・階段などでも上の水を探す。三角形の当たりは捨てる判定と同じ関数で確かめ、捨てた所だけ描く (水面のすぐ下の帯などで二重にならない)。乗り物に乗っている間 (`isRiding`) は捨てない (ボートの中は水を描かず、捨てた脚が消える)。一番上の水が流れる水 (上面が水源より低い) の時も捨てない (高さが分からず、水面より上の体を捨てると欠ける。屈折は付かない)。カメラが水の中の時は逆に、水面より上の自分の画素を捨てる (この層に残すと水面の手前に貼り付き、水の中の色と霧が掛かり、スネルの窓の外でも見える)。composite1 が水面の上へ屈折した視線を三角形に当てて水面越しに描き、全反射の画素は反射した視線を水の中の体に当てて鏡面の映り込み (colortex20) に重ねる (自分は画面の像に無く SSR では映らない。SSR の当たりが体より手前ならそちら。REFLECTIONS 0 では映らない)。高さは真下へ空気のセルを辿った最初の水のセルの水面からで、流れる水・足場のブロックの上・乗り物の中は対象外。ガラス・氷・ほかの半透明の物越しに見た水の中の自分は欠ける (一番手前の半透明が水でない画素は composite1 が三角形を当てず、水の画素も無い。直すには半透明の層の下の水にも三角形を当てる必要があり重い)
- gbuffers_item は未用意 (gbuffers_entities にフォールバック)
- macOS (compute 非対応) は動かない
