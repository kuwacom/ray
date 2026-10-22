/*
 * Ray 設定定義 (全設定の唯一の定義場所)
 *
 * - 素の #define 値は HIGH プロファイルと同一 (iterationT 方式)
 * - プロファイル (LOW / MEDIUM / HIGH / ULTRA / EXTREME) は shaders.properties で定義
 * - 数値の値リストは "// [..]" の書式で Iris の設定画面に出る
 */
#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL

#define RAY_VERSION 1 // [1] 画面には lang の value.RAY_VERSION.1 (v0.1.0-alpha)

/*------------------------------------------------------------------------------
  ブロックライト / ボクセル (light モジュール)
------------------------------------------------------------------------------*/
#define VOXEL_VOLUME 2 // [0 1 2 3] 0=128x64x128 1=192x96x192 2=256x128x256 3=384x128x384
#define FLOODFILL // 色付き floodfill (間接光のベース)
#define FLOODFILL_STRENGTH 0.35 // [0.0 0.1 0.2 0.25 0.3 0.35 0.4 0.5 0.6 0.8 1.0 1.25 1.5 2.0] 光源シャドウ ON 時の間接光の強さ
#define BLOCKLIGHT_BRIGHTNESS 1.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0 5.0 6.0 8.0]
#define BLOCKLIGHT_WARMTH 0.6 // [0.0 0.25 0.4 0.5 0.6 0.7 0.75 1.0] 0=中性 1=バニラ寄りの暖色
#define LIGHT_FLICKER // 炎系光源の揺らぎ
#define DECORATIVE_BLOCK_LIGHTS 0 // [0 1 2] 光らない鉱物ブロック (ラピス・エメラルド・ダイヤ・金・レッドストーン・アメジスト) 0=そのまま 1=発光のみ 2=光源
#define LIGHT_SHADOWS // 設置光源の光源シャドウ (直接光のレイトレース)
#define LIGHT_TRACE_COUNT 4 // [1 2 3 4 6 8 12 16] 1 ピクセルあたりトレースする光源数
#define LIGHT_TRACE_RES 2 // [1 2 4] トレース解像度の分母 (1=フル 2=半分 4=1/4)
#define LIGHT_SHAPE_TRACE // ハーフブロック等の形状で遮蔽判定
#define LIGHT_SOURCE_SIZE 0.5 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0] 光源サイズ (半影の柔らかさ)
#define LIGHT_TRANSLUCENT_TINT // 色ガラス越しの光の色付け
#define LIGHT_SPECULAR // ブロックライトの鏡面反射
#define LIGHT_DENOISE 2 // [0 1 2] 0=なし 1=時間 2=時間+空間
#define LIGHT_ENTITY_OCCLUSION // エンティティがブロックライトを遮る
#define LIGHT_PLAYER_OCCLUSION // プレイヤーがブロックライトを遮る
#define LIGHT_OCCLUSION_MODE 1 // [0 1] エンティティ遮蔽の方式 0=ボクセル (0.5 ブロックの箱) 1=三角形 (形状どおり)
#define LIGHT_ENTITY_TRIANGLES 4096 // [2048 4096 8192 16384] 三角形方式で保持する三角形の上限
#define LIGHT_CONTACT_SHADOWS // スクリーンスペース接触影でボクセル外の細部を補う
#define HAND_LIGHT // 手持ち光源
#define HAND_LIGHT_RAYS // 手持ち光源のレイトレース影
#define HAND_LIGHT_SS_SHADOWS // 手持ち光源のスクリーンスペース影 (手・エンティティの遮蔽)
#define HAND_LIGHT_BRIGHTNESS 1.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define ENTITY_LIGHTS // 動的エンティティ光源の総スイッチ
#define ITEM_LIGHTS // ドロップした光源アイテム
#define PROJECTILE_LIGHTS // 投擲物 (光る矢・火の玉等)
#define BURNING_ENTITY_LIGHTS // 燃えているエンティティ
#define GLOWING_ENTITY_LIGHTS // 発光エンティティ (ブレイズ・グロウイカ等)

/*------------------------------------------------------------------------------
  太陽影 / GI (surface モジュール)
------------------------------------------------------------------------------*/
const int shadowMapResolution = 4096; // [1024 2048 3072 4096 6144 8192]
const float shadowDistance = 192.0; // [64.0 96.0 128.0 160.0 192.0 256.0 320.0 384.0 512.0 768.0 1024.0]
const float shadowDistanceRenderMul = 1.0; // [-1.0 1.0]
const float shadowIntervalSize = 2.0;
const float entityShadowDistanceMul = 0.5; // [0.25 0.5 0.75 1.0]
const float sunPathRotation = -30.0; // [-60.0 -50.0 -40.0 -30.0 -20.0 -10.0 0.0 10.0 20.0 30.0 40.0 50.0 60.0]
#define SHADOW_FILTER 2 // [0 1 2] 0=ハード 1=PCF 2=PCSS
#define SHADOW_SAMPLES 16 // [4 8 12 16 24 32]
#define SHADOW_SOFTNESS 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define SHADOW_COLORED // 半透明ブロックの色付き影
#define ENTITY_SHADOWS // エンティティの太陽影
#define BLOCK_ENTITY_SHADOWS // ブロックエンティティの太陽影
#define SCREEN_SPACE_SHADOWS // 太陽影のスクリーンスペース接触影
#define AO_MODE 2 // [0 1 2] 0=なし 1=SSAO 2=GTAO
#define AO_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]
#define GI_MODE 1 // [0 1 2 3] 0=なし 1=RSM 2=SSGI 3=ボクセル RT
#define GI_SAMPLES 2 // [1 2 4 8]
#define GI_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0]
#define GI_RES 2 // [1 2] GI 解像度の分母
#define GI_DENOISE 2 // [0 1 2] 0=なし 1=時間 2=時間+空間

/*------------------------------------------------------------------------------
  マテリアル / 水 / 反射 (surface モジュール)
------------------------------------------------------------------------------*/
#define PBR_FORMAT 0 // [0 1] 0=なし 1=labPBR
#define NORMAL_MAPPING // リソースパックの法線マップ
#define GENERATED_NORMALS // テクスチャからの法線自動生成 (PBR なしのとき)
//#define POM // 視差オクルージョンマッピング
#define POM_DEPTH 0.25 // [0.05 0.1 0.15 0.2 0.25 0.3 0.4 0.5 0.75 1.0]
#define POM_SAMPLES 32 // [16 32 48 64]
#define POM_SHADOW // POM の自己影
#define SSS // 表面下散乱 (葉・草)
#define SSS_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define WAVING_PLANTS
#define WAVING_LEAVES
#define RAIN_PUDDLES // 雨の水たまり
#define PUDDLE_AMOUNT 0.3 // [0.0 0.05 0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.5 0.6 0.7 0.8 1.0] 雨が降りきった時に水たまりが覆う地面の割合 (Nostalgia は 0.37 相当)
#define PUDDLE_SIZE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 水たまりの大きさの倍率 (1.0 で 1 つが 2-10 ブロック程度)
#define RAIN_WETNESS 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0] 雨に濡れた地面の暗さ・つやの強さ
#define PUDDLE_RIPPLES 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0 5.0] 水たまりに落ちる雨の波紋の強さ
#define EMISSION_STRENGTH 1.0 // [0.0 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0]
#define LAVA_BRIGHTNESS 2.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0 4.0 5.0] 溶岩の見た目の明るさ (表示だけ。0 で 2026-10-22 #40 の明るさ、1 増やすごとに +100%。周りへの光は変わらない)
#define LAVA_BLOOM 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0 4.0 5.0] 溶岩のブルームの強さ (0 で他の物と同じ、1.0 でブルームの元を 10 倍)
#define WATER_WAVES
#define WATER_WAVE_HEIGHT 1.0 // [0.0 0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0] 風速から決まる波の高さに掛ける倍率
#define WATER_WAVE_LENGTH 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 波長の倍率
#define WATER_WIND_SPEED 6.0 // [0.5 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 10.0 12.0 15.0 20.0 25.0] 海の風速 (m/s)。強いほど長く高い波と白波
#define WATER_CHOPPINESS 1.5 // [0.0 0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0] 波頭の尖り
#define WATER_RIPPLES 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] さざ波 (1 ブロックより短い波) の強さ
#define WATER_FOAM 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] 泡 (沖の白波) の量
#define WATER_GLINT 1.0 // [0.0 0.25 0.5 0.75 1.0] 太陽・月の照り返しのきらめき (0 = 滑らかな照り返し)
#define WATER_LAKE_WAVES 0.6 // [0.0 0.2 0.4 0.6 0.8 1.0 1.5 2.0] 湖 (海・川以外) の風の強さ (海に対する割合)
#define WATER_RIVER_WAVES 0.4 // [0.0 0.2 0.4 0.6 0.8 1.0 1.5 2.0] 川の風の強さ (海に対する割合)
#define WATER_PARALLAX // 水面の視差
#define WATER_REFRACTION 1 // [0 1 2] 0=なし 1=スクリーンスペース 2=レイトレース
#define WATER_REFRACTION_MODE 2 // [0 1 2] 上から見た水の屈折の方式 0=A 波で曲がった分だけ (水底は実際の深さ) 1=B 屈折のまま画面の端で弱める 2=D 屈折のまま画面外はボクセルで辿る (水底が浅く見える)
//#define WATER_CAUSTICS // 水中のコースティクス
//#define WATER_TEXTURE // バニラの水テクスチャを重ねる
#define WATER_FOG_DENSITY 1.0 // [0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0]
#define WATER_TYPE 0 // [0 1 2] 0=外洋 (青) 1=沿岸 (緑) 2=澄んだ水
#define REFLECTIONS 2 // [0 1 2 3] 0=空のみ 1=SSR 2=SSR+ラフ反射 3=SSR+ボクセル補完
#define SSR_STEPS 24 // [8 12 16 24 32 48 64]

/*------------------------------------------------------------------------------
  空 / 雲 / フォグ (sky モジュール)
------------------------------------------------------------------------------*/
#define ATMOSPHERE_MODE 1 // [0 1] 0=解析近似 1=Hillaire 2020 LUT
#define SUN_BRIGHTNESS 1.0 // [0.25 0.5 0.75 1.0 1.1 1.25 1.5 2.0 3.0 4.0]
#define MOON_BRIGHTNESS 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0 6.0]
#define SKY_BRIGHTNESS 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define SUN_MOON_STYLE 1 // [0 1] 0=バニラテクスチャ 1=物理的な円盤
#define STARS
#define CLOUDS 3 // [0 1 2 3] 0=なし 1=バニラ 2=2D 押し出し体積雲 3=3D 体積雲
#define CLOUD_QUALITY 1 // [0 1 2 3]
#define CLOUD_RES 2 // [1 2 4] 雲解像度の分母
#define CLOUD_TEMPORAL // チェッカーボード + 時間アップスケール
#define CLOUD_COVERAGE 1.1 // [0.0 0.25 0.5 0.75 0.9 1.0 1.1 1.25 1.5 1.75 2.0 2.5 3.0]
#define CLOUD_SCALE 3.0 // [0.5 0.75 1.0 1.25 1.5 1.6 1.75 2.0 2.5 3.0 4.0 5.0 6.0]
#define CLOUD_HEIGHT_PRESET 0 // [0 1 2 3] 0=バニラ (-64..320) 1=高さ拡張ワールド 2=現実比 (1 ブロック 1 m) 3=カスタム (層ごとの高度・厚みのスライダー)
#define CLOUD_ALTITUDE 1500.0 // [64.0 96.0 128.0 160.0 192.0 256.0 320.0 500.0 750.0 1000.0 1250.0 1500.0 2000.0 2500.0 3000.0 4000.0 5000.0 6000.0 8000.0] カスタム時の低層の雲底 (ワールド y)
#define CLOUD_THICKNESS 4500.0 // [32.0 64.0 96.0 128.0 192.0 256.0 500.0 1000.0 1500.0 2000.0 2200.0 2500.0 3000.0 4000.0 4500.0 6000.0 8000.0] カスタム時の積雲の層の厚み (ブロック。既定 4500 で縦横 1:1)
#define CLOUD_REGION_PRESET 0 // [0 1 2 3 4 5] 0=温帯 1=熱帯 2=乾燥 3=寒冷・極域 4=海洋 5=カスタム
#define CLOUD_C_LOW 0.4 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0] カスタム地域: 低層の雲量の平均
#define CLOUD_C_CONVECTION 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0] カスタム地域: 積雲の発達しやすさ
#define CLOUD_C_STRATUS 0.45 // [0.0 0.15 0.3 0.45 0.6 0.8 1.0] カスタム地域: 層積雲の出やすさ
#define CLOUD_C_MID 0.65 // [0.0 0.2 0.4 0.65 0.8 1.0] カスタム地域: 中層の雲 (高積雲・高層雲) の量
#define CLOUD_C_HIGH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0] カスタム地域: 上層の雲 (巻雲) の量
#define CLOUD_C_STORMS 0.0 // [0.0 0.2 0.4 0.6 0.8 1.0] カスタム地域: 晴れた日の午後に遠くで積乱雲が立つ頻度
#define CLOUD_SPEED 1.0 // [0.0 0.25 0.5 1.0 1.5 1.8 2.0 3.0 5.0] (10 / 20 は TAA の履歴に流れる雲が残って流し撮りの筋になったので外した)
#define CLOUD_MULTISCATTER 4 // [2 4 8] 多重散乱オクターブ数
#define CLOUD_CIRRUS // 上層の雲 (巻雲・巻積雲・巻層雲) のレイヤー
#define CLOUD_CIRRUS_COVERAGE 0.1 // [0.0 0.05 0.1 0.2 0.3 0.5 0.75 1.0]
#define CLOUD_CUMULONIMBUS // 積乱雲 (雷雨と熱帯の午後。かなとこ・降水の柱)
#define CLOUD_SHADOWS
// 雲の層ごとの設定 (高度・厚みは高さテンプレートがカスタムの時だけ。0 = 低層から現実の比率で自動)
#define CLOUD_LOW_COVERAGE 1.0 // [0.0 0.25 0.5 0.75 0.9 1.0 1.1 1.25 1.5 2.0 3.0] 低層の雲量の倍率
#define CLOUD_LOW_DENSITY 0.25 // [0.05 0.1 0.15 0.2 0.25 0.35 0.5 0.75 1.0 1.5 2.0 3.0 4.0 5.0] 低層の濃さ (既定は 1.0 から 0.25 へ下げた。3.0 で初期の濃さ)
#define CLOUD_LOW_SCALE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 低層の水平の大きさの倍率
#define CLOUD_LOW_EROSION 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0] 低層の縁の浸食の強さ
#define CLOUD_LOW_WIND 10.0 // [0.0 2.0 5.0 10.0 15.0 20.0 30.0 50.0] 低層の風速 (m/s。75 / 100 は雲の速さと同じく筋になるので外した)
#define CLOUD_LOW_WIND_ANGLE 20 // [0 20 45 90 135 180 200 225 270 315] 低層の風向 (度, 0 = 東へ)
#define CLOUD_FRACTUS 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0] 濃い雲の周りの薄い断片雲の量
#define CLOUD_MID_ALTITUDE 0.0 // [0.0 200.0 256.0 320.0 400.0 500.0 750.0 1000.0 1500.0 2000.0 3000.0 4000.0 5000.0 6000.0] カスタム時の中層の雲底 (ワールド y, 0 = 自動)
#define CLOUD_MID_THICKNESS 0.0 // [0.0 16.0 32.0 64.0 128.0 256.0 500.0 900.0 1500.0] カスタム時の中層の厚み (ブロック, 0 = 自動)
#define CLOUD_MID_COVERAGE 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0] 中層の雲量の倍率
#define CLOUD_MID_DENSITY 1.0 // [0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 5.0] 中層の濃さ
#define CLOUD_MID_SCALE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 中層の水平の大きさの倍率
#define CLOUD_MID_EROSION 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0] 中層の縁の浸食の強さ
#define CLOUD_MID_WIND 18.0 // [0.0 5.0 10.0 18.0 25.0 35.0 50.0] 中層の風速 (m/s。75 / 100 は外した)
#define CLOUD_MID_WIND_ANGLE 7 // [0 7 45 90 135 180 187 225 270 315] 中層の風向 (度)
#define CLOUD_HIGH_ALTITUDE 0.0 // [0.0 300.0 400.0 500.0 750.0 1000.0 2000.0 4000.0 6000.0 8400.0 10000.0] カスタム時の上層の下端 (ワールド y, 0 = 自動)
#define CLOUD_HIGH_THICKNESS 0.0 // [0.0 16.0 32.0 64.0 128.0 256.0 500.0 1000.0 1400.0 2000.0] カスタム時の上層の厚み (ブロック, 0 = 自動)
#define CLOUD_HIGH_DENSITY 1.0 // [0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 5.0] 上層の濃さ
#define CLOUD_HIGH_SCALE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 上層の水平の大きさの倍率
#define CLOUD_HIGH_WIND 32.0 // [0.0 10.0 20.0 32.0 45.0 60.0] 上層の風速 (m/s。80 / 100 は外した)
#define CLOUD_HIGH_WIND_ANGLE 27 // [0 27 63 90 117 153 180 207 243 270 297 333] 上層の風向 (度。巻雲の筋の向き)
#define CLOUD_CB_HEIGHT 0.0 // [0.0 300.0 400.0 500.0 750.0 1000.0 2000.0 4000.0 6000.0 10200.0 12000.0] カスタム時の積乱雲の頂 (ワールド y, 0 = 自動)
#define CLOUD_CB_COVERAGE 1.0 // [0.0 0.5 0.75 1.0 1.25 1.5 2.0 3.0] 雷雨の嵐のセルの量
#define CLOUD_CB_DENSITY 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] 積乱雲の濃さ
#define CLOUD_CB_ANVIL 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0] かなとこの長さ
#define CLOUD_CB_RAIN_SHAFTS 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0] 雨脚の濃さ
#define CLOUD_EDGE_SOFTNESS 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0] 低層の縁の柔らかさ
#define CLOUD_EDGE_HAZE 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0 5.0] 晴天の積雲の縁の外に広がる薄いもやの濃さ (0 で輪郭のはっきりした雲)
#define CLOUD_CORE_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0] 晴天の積雲の芯の濃さ (3.0 でほぼ一様に濃い芯)
#define CLOUD_SILVER_LINING 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0] 逆光の銀の縁の強さ
#define CLOUD_POWDER 1.0 // [0.0 0.5 1.0 1.5 2.0 2.5] 順光の縁の暗さ (powder)
#define CLOUD_AMBIENT 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 雲の中の空の光の強さ
#define CLOUD_BASE_SHADE 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0] 雲底の暗さ
#define CLOUD_DRAW_DISTANCE 80.0 // [20.0 30.0 40.0 60.0 80.0 120.0 160.0] 低層・中層の雲の描画距離 (参照空間の km)
#define FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0]
//#define FOG_MIST // 地表の霧
#define FOG_MIST_ALTITUDE 72 // [32 48 63 64 72 80 96 128 160 192 256]
#define VL // ボリューメトリックライト (光芒)
#define VL_SAMPLES 8 // [4 6 8 12 16 24 32]
#define VL_RES 2 // [1 2 4] VL 解像度の分母
#define VL_STRENGTH 1.0 // [0.0 0.1 0.25 0.5 0.75 1.0 1.25 1.5 1.75 2.0 3.0 4.0]
//#define VL_COLORED_SHADOWS // 色付きガラス越しの光芒
#define FOG_BLOCKLIGHT // ブロックライトがフォグを照らす
#define FOG_BLOCKLIGHT_STRENGTH 0.5 // [0.0 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
//#define FOG_CLOUD_SHADOWS // 雲影を光芒に反映
#define CAVE_LEAK_PREVENTION // 洞窟内への太陽光芒の漏れを防ぐ
#define BORDER_FOG // 描画距離端のフォグ
#define NETHER_FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define END_FOG_DENSITY 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]

/*------------------------------------------------------------------------------
  カメラ / ポストプロセス (post モジュール)
------------------------------------------------------------------------------*/
#define TAA
#define CAS_STRENGTH 0.5 // [0.0 0.25 0.5 0.75 1.0]
#define DOF // 被写界深度
#define DOF_QUALITY 0 // [0 1 2] 0=30 1=50 2=75 サンプル
#define DOF_STRENGTH 0.5 // [0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0] 絞りの決め方が 0 の時の絞り径 (0.5 = f/2.1 相当)
#define DOF_APERTURE_MODE 0 // [0 1 2] 0=ボケの量 1=レンズプリセットの開放 F 値 2=F 値を指定
#define DOF_F_NUMBER 1.4 // [0.7 0.95 1.2 1.4 1.8 2.0 2.8 4.0 5.6 8.0 11.0 16.0 22.0 32.0] DOF_APERTURE_MODE=2 の時の F 値
#define DOF_SENSOR 0 // [0 1 2 3 4 5] 0=フルサイズ 1=APS-C 2=中判 44x33 3=中判 6x7 4=大判 4x5 5=大判 8x10
#define DOF_FOCUS_MODE 0 // [0 1 2] 0=オート 1=マニュアル 2=オート+オフセット
#define DOF_MANUAL_FOCUS 8.0 // [0.1 0.15 0.2 0.3 0.5 0.75 1.0 2.0 4.0 6.0 8.0 10.0 16.0 32.0 64.0 128.0 256.0 512.0]
#define DOF_FOCUS_SPEED 2.5 // [0.1 0.25 0.5 1.0 1.5 2.0 2.5 3.0 5.0 10.0 15.0 20.0]
#define MOTION_BLUR
#define MOTION_BLUR_STRENGTH 1.0 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define VIGNETTE 0.3 // [0.0 0.1 0.2 0.3 0.4 0.5 0.75 1.0 1.5 2.0]

/*------------------------------------------------------------------------------
  レンズ (post モジュール)。プリセットが各効果の強さを決め、ON/OFF は常に効く
  個別の強さ (LENS_C_*) は LENS_PRESET = 0 (カスタム) の時だけ使う
  番号は後ろに足していき、既存の番号は変えない (ユーザーの保存値を保つ)
------------------------------------------------------------------------------*/
#define LENS_PRESET 1 // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18] 0=カスタム 1=現代の単焦点 2=Helios 44-2 3=Super Takumar 50/1.4 4=Petzval 5=Canon FD 50/1.4 6=アナモルフィック 7=Sonnar 50/1.5 8=Summilux 35/1.4 9=Canon 50/1.2 10=Hologon 15/8 11=Flektogon 20/4 12=Fish-eye Rokkor 16/2.8 13=Gyogyotto 20/8 14=Ultra Wide-Heliar 12/5.6 15=New FD 14/2.8L 16=STF 135/2.8 17=FA 28/2.8 Soft 18=Canon 50/0.95
#define LENS_QUALITY 2 // [0 1 2 3] ゴースト数と波長サンプル数
#define LENS_FLARE // 太陽・月のレンズフレア
#define LENS_FLARE_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 5.0 7.5 10.0] フレア全体の倍率
#define LENS_GHOSTS // 内面反射のゴースト (レンズ設計から計算)
#define LENS_SCREEN_FLARE // 明るい画素のゴーストと横ストリーク (ブルームが必要)
#define LENS_STARBURST // 絞りの回折による光条
//#define LENS_HALO
#define LENS_DIRT // レンズの汚れ
#define LENS_VEILING_GLARE // ベーリンググレア (フレアによるコントラスト低下)
#define LENS_DISTORTION // 歪曲収差と魚眼の写像
#define LENS_DISTORTION_SCALE 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0] 歪曲収差の強さ (1 = レンズの処方どおり。魚眼の写像には掛からない)
#define LENS_FISHEYE_FIT 0 // [0 1] 魚眼の画面への合わせ方 0=隅まで埋める 1=横幅を合わせる (隅は黒)
#define LENS_WARP_IN_TAA 0 // [0 1 2] 歪曲・魚眼を組み立てる所 0=自動 (魚眼と歪曲の強い時は TAA) 1=final (引き伸ばし) 2=TAA (ジッターで中央の細かさを戻す, TAA が必要)
#define LENS_CHROMATIC // 倍率色収差
#define LENS_AXIAL_CA // 軸上色収差 (被写界深度が必要)
#define LENS_SOFT_FOCUS // 球面収差の滲み (ブルームが必要)
#define LENS_SWIRL // 像面湾曲・非点収差のぐるぐるボケ (被写界深度が必要)
#define LENS_OPTICAL_VIGNETTING // 口径食 (周辺の減光と猫目ボケ)
#define LENS_HALATION // ハレーション (ブルームが必要)

// カスタムレンズ (LENS_PRESET = 0 の時だけ有効)
#define LENS_C_DESIGN 1 // [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14] 0=ダブルガウス 6 枚 1=ダブルガウス 7 枚 2=Petzval 3=Sonnar 4=Summilux 35 5=Canon 50/1.2 6=Hologon 7=Flektogon 8=魚眼 Rokkor 9=Gyogyotto 10=UWH 12 11=FD 14 12=STF 135 13=FA 28 Soft 14=Canon 50/0.95 (ゴーストの設計)
#define LENS_C_COATING 0 // [0 1 2] 0=マルチコート 1=単層コート 2=コート無し
#define LENS_C_F_OPEN 1.8 // [0.95 1.2 1.4 1.8 2.0 2.8 4.0 5.6 8.0] 開放 F 値
#define DOF_APERTURE_BLADES 0 // [0 5 6 7 8 9 10 13] 0=円形
#define LENS_C_BLADE_ROUNDNESS 0.15 // [0.0 0.15 0.3 0.5 0.75 1.0]
#define LENS_C_GHOSTS 1.0 // [0.0 0.25 0.5 1.0 2.0 4.0 8.0]
#define LENS_C_SCREEN_GHOSTS 1.0 // [0.0 0.25 0.5 1.0 2.0 4.0 8.0]
#define LENS_C_STARBURST 1.0 // [0.0 0.25 0.5 1.0 2.0 4.0 6.0 8.0]
#define LENS_C_STAR_SIZE 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define LENS_C_HALO 0.5 // [0.0 0.25 0.5 1.0 2.0 3.0 4.0]
#define LENS_C_DIRT 0.5 // [0.0 0.25 0.5 1.0 2.0 4.0 6.0 8.0]
#define LENS_C_DIRT_CONTRAST 0.5 // [0.0 0.25 0.5 0.75 1.0]
#define LENS_C_VEILING_GLARE 0.5 // [0.0 0.25 0.5 1.0 2.0 4.0 6.0 8.0]
#define LENS_C_STREAK 0.0 // [0.0 0.25 0.5 1.0 2.0 4.0 6.0 8.0]
#define LENS_C_SQUEEZE 1.0 // [1.0 1.33 1.5 1.8 2.0] アナモルフィックの圧縮率 (楕円ボケ)
#define LENS_C_DISTORTION 0.0 // [-0.3 -0.2 -0.15 -0.1 -0.06 -0.03 0.0 0.03 0.06 0.1 0.15 0.2 0.3] 正=樽型 負=糸巻き型
#define LENS_C_DISTORTION2 0.0 // [-0.3 -0.2 -0.15 -0.1 -0.06 -0.03 0.0 0.03 0.06 0.1 0.15 0.2 0.3] 4 次の歪曲。LENS_C_DISTORTION と逆符号で陣笠型
#define LENS_C_PROJECTION 0 // [0 1] 0=直線写像 1=魚眼
#define LENS_C_FISHEYE_K 0.5 // [-0.5 0.0 0.25 0.5 0.564 0.75 1.0] 魚眼の写像 r = f sin(k θ) / k。-0.5=立体射影 0=等距離 0.5=等立体角 1=正射影
#define LENS_C_CA 0.3 // [-1.0 -0.5 -0.3 -0.15 0.0 0.15 0.3 0.5 0.75 1.0 1.5 2.0 3.0 4.0] 正=赤い像が大きい 負=青い像が大きい
#define LENS_C_AXIAL_CA 0.0 // [0.0 0.25 0.5 1.0 1.5 2.0 3.0 4.0]
#define LENS_C_SOFT_FOCUS 0.0 // [0.0 0.1 0.2 0.3 0.5 0.75 1.0]
#define LENS_C_SWIRL 0.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define LENS_C_FIELD_CURVATURE 0.0 // [-2.0 -1.0 -0.5 -0.25 0.0 0.25 0.5 1.0 2.0 3.0 4.0] 正=周辺ほどピントが手前 負=奥
#define LENS_C_CATS_EYE 0.2 // [0.0 0.2 0.4 0.6 0.8 1.0]
#define LENS_C_HALATION 0.0 // [0.0 0.1 0.2 0.3 0.5 0.75 1.0]
#define LENS_C_BOKEH_RIM 0.0 // [-0.5 -0.25 0.0 0.25 0.5 0.75 1.0] 正=縁の明るいボケ 負=中心の明るいボケ
#define LENS_C_APODIZATION 0.0 // [0.0 0.5 1.0 1.96 3.0 4.0] ボケの縁を溶かす瞳の透過率 exp(-β ρ^2) の β (1.96 = STF 135)
#define LENS_C_YELLOWING 0.0 // [0.0 0.25 0.5 0.75 1.0] トリウムレンズの黄変
#define BLOOM
#define BLOOM_STRENGTH 0.5 // [0.0 0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0]
#define BLOOM_FOG 0.15 // [0.0 0.05 0.1 0.15 0.25 0.5 1.0 1.5 2.0]
#define EXPOSURE_MODE 2 // [0 1 2] 0=マニュアル 1=平均 2=ヒストグラム
#define EXPOSURE_BIAS 0.0 // [-5.0 -4.0 -3.0 -2.5 -2.0 -1.5 -1.0 -0.5 0.0 0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0]
#define EXPOSURE_MANUAL_EV 0.0 // [-8.0 -6.0 -4.0 -3.0 -2.0 -1.0 0.0 1.0 2.0 3.0 4.0 6.0 8.0 10.0 12.0]
#define EXPOSURE_SPEED_BRIGHT 3.0 // [0.1 0.25 0.5 1.0 2.0 3.0 5.0 10.0 15.0 20.0] 明るい場面へ順応する速さ
#define EXPOSURE_SPEED_DARK 1.0 // [0.05 0.1 0.25 0.5 1.0 2.0 3.0 5.0 7.5 10.0] 暗い場面へ順応する速さ
#define EXPOSURE_MIN_EV -4.0 // [-10.0 -8.0 -6.0 -5.0 -4.0 -3.0 -2.0 -1.0 0.0]
#define EXPOSURE_MAX_EV 6.0 // [1.0 2.0 4.0 6.0 8.0 10.0 12.0 14.0 16.0]
#define TONEMAP 0 // [0 1 2 3 4 5] 0=AgX 1=AgX Punchy 2=ACES 3=Reinhard-Jodie 4=AgX Golden 5=PBR Neutral
#define SATURATION 1.0 // [0.0 0.25 0.5 0.75 0.9 1.0 1.1 1.2 1.3 1.5 1.75 2.0]
#define CONTRAST 1.0 // [0.5 0.6 0.7 0.8 0.9 1.0 1.05 1.1 1.2 1.3 1.5 1.75 2.0]
#define WHITE_BALANCE 6500 // [2500 3000 3500 4000 4500 5000 5500 6000 6500 7000 7500 8000 9000 10000 12000]
#define CDL_SLOPE 1.0 // [0.5 0.6 0.7 0.8 0.85 0.9 0.95 1.0 1.05 1.1 1.15 1.2 1.4 1.6 2.0] ASC CDL (トーンマップ後の表示値に掛ける)
#define CDL_OFFSET 0.0 // [-0.1 -0.05 -0.03 -0.02 -0.01 0.0 0.01 0.02 0.03 0.05 0.1]
#define CDL_POWER 1.0 // [0.5 0.6 0.7 0.8 0.85 0.9 0.95 1.0 1.05 1.1 1.15 1.2 1.4 1.6 2.0]
#define CDL_SATURATION 1.0 // [0.0 0.5 0.8 0.9 1.0 1.1 1.2 1.5 2.0]
#define PURKINJE_STRENGTH 0.3 // [0.0 0.1 0.2 0.3 0.5 0.75 1.0] 暗所の青シフト
#define FILM_GRAIN 0.008 // [0.0 0.004 0.008 0.015 0.03 0.05 0.1]
//#define SELECTION_OUTLINE // ブロック選択枠
#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7 8 9 10 11 12]

/*------------------------------------------------------------------------------
  Iris の定数 (設定画面には出さない)
------------------------------------------------------------------------------*/
const float ambientOcclusionLevel = 1.0;
const float eyeBrightnessHalflife = 4.0;
const float centerDepthHalflife = 0.6;
// 濡れの半減期 (Iris は 0.1 秒単位)。300 (30 秒) では雨が 1 分降っても水たまりがほとんど出なかった。
// 濡れは 10 秒で半分 (1 分でほぼ全面)、乾きは 30 秒で半分 (雨上がりもしばらく濡れて雲が残る)
const float wetnessHalflife = 100.0;
const float drynessHalflife = 300.0;
const int noiseTextureResolution = 256;

// reversed shadow culling の非カリング半径。ボクセル体積の水平半径に合わせる
// shadowDistance がこれより小さいとボクセル化範囲が欠けるので、プロファイルでは常に shadowDistance >= voxelDistance にしている
#if VOXEL_VOLUME == 0
    const float voxelDistance = 64.0;
#elif VOXEL_VOLUME == 1
    const float voxelDistance = 96.0;
#elif VOXEL_VOLUME == 2
    const float voxelDistance = 128.0;
#else
    const float voxelDistance = 192.0;
#endif

/*------------------------------------------------------------------------------
  設定から導出される値 (ここだけで定義し、各モジュールはこれを参照する)
------------------------------------------------------------------------------*/
#if VOXEL_VOLUME == 0
    #define VOXEL_SIZE_X 128
    #define VOXEL_SIZE_Y 64
    #define VOXEL_SIZE_Z 128
#elif VOXEL_VOLUME == 1
    #define VOXEL_SIZE_X 192
    #define VOXEL_SIZE_Y 96
    #define VOXEL_SIZE_Z 192
#elif VOXEL_VOLUME == 2
    #define VOXEL_SIZE_X 256
    #define VOXEL_SIZE_Y 128
    #define VOXEL_SIZE_Z 256
#else
    #define VOXEL_SIZE_X 384
    #define VOXEL_SIZE_Y 128
    #define VOXEL_SIZE_Z 384
#endif

// ENTITY_LIGHTS は個別スイッチの総スイッチ。外れていれば個別スイッチも全部無効にする
#ifndef ENTITY_LIGHTS
    #undef ITEM_LIGHTS
    #undef PROJECTILE_LIGHTS
    #undef BURNING_ENTITY_LIGHTS
    #undef GLOWING_ENTITY_LIGHTS
#endif

// 手持ち光源が OFF ならレイ・影も無効
#ifndef HAND_LIGHT
    #undef HAND_LIGHT_RAYS
    #undef HAND_LIGHT_SS_SHADOWS
#endif

// 三角形方式のエンティティ遮蔽 (lib/light/entity_tri.glsl)。遮蔽が両方 OFF なら三角形も書かない
// 値付きにして Iris のブール設定として拾われないようにする
#if LIGHT_OCCLUSION_MODE == 1 && (defined LIGHT_ENTITY_OCCLUSION || defined LIGHT_PLAYER_OCCLUSION)
    #define ENTITY_TRI_OCCLUSION 1
#endif

/*------------------------------------------------------------------------------
  Iris にブール設定として認識させるための参照
  (Iris は #ifdef / #ifndef で一度も参照されない define をブール設定として扱わないため)
------------------------------------------------------------------------------*/
#ifdef FLOODFILL
#endif
#ifdef LIGHT_FLICKER
#endif
#ifdef LIGHT_SHADOWS
#endif
#ifdef LIGHT_SHAPE_TRACE
#endif
#ifdef LIGHT_TRANSLUCENT_TINT
#endif
#ifdef LIGHT_SPECULAR
#endif
#ifdef LIGHT_ENTITY_OCCLUSION
#endif
#ifdef LIGHT_PLAYER_OCCLUSION
#endif
#ifdef LIGHT_CONTACT_SHADOWS
#endif
#ifdef HAND_LIGHT
#endif
#ifdef HAND_LIGHT_RAYS
#endif
#ifdef HAND_LIGHT_SS_SHADOWS
#endif
#ifdef ENTITY_LIGHTS
#endif
#ifdef ITEM_LIGHTS
#endif
#ifdef PROJECTILE_LIGHTS
#endif
#ifdef BURNING_ENTITY_LIGHTS
#endif
#ifdef GLOWING_ENTITY_LIGHTS
#endif
#ifdef SHADOW_COLORED
#endif
#ifdef ENTITY_SHADOWS
#endif
#ifdef BLOCK_ENTITY_SHADOWS
#endif
#ifdef SCREEN_SPACE_SHADOWS
#endif
#ifdef NORMAL_MAPPING
#endif
#ifdef GENERATED_NORMALS
#endif
#ifdef POM
#endif
#ifdef POM_SHADOW
#endif
#ifdef SSS
#endif
#ifdef WAVING_PLANTS
#endif
#ifdef WAVING_LEAVES
#endif
#ifdef RAIN_PUDDLES
#endif
#ifdef WATER_WAVES
#endif
#ifdef WATER_PARALLAX
#endif
#ifdef WATER_CAUSTICS
#endif
#ifdef WATER_TEXTURE
#endif
#ifdef STARS
#endif
#ifdef CLOUD_TEMPORAL
#endif
#ifdef CLOUD_CIRRUS
#endif
#ifdef CLOUD_CUMULONIMBUS
#endif
#ifdef CLOUD_SHADOWS
#endif
#ifdef FOG_MIST
#endif
#ifdef VL
#endif
#ifdef VL_COLORED_SHADOWS
#endif
#ifdef FOG_BLOCKLIGHT
#endif
#ifdef FOG_CLOUD_SHADOWS
#endif
#ifdef CAVE_LEAK_PREVENTION
#endif
#ifdef BORDER_FOG
#endif
#ifdef TAA
#endif
#ifdef DOF
#endif
#ifdef MOTION_BLUR
#endif
#ifdef LENS_FLARE
#endif
#ifdef LENS_HALO
#endif
#ifdef LENS_GHOSTS
#endif
#ifdef LENS_SCREEN_FLARE
#endif
#ifdef LENS_STARBURST
#endif
#ifdef LENS_DIRT
#endif
#ifdef LENS_VEILING_GLARE
#endif
#ifdef LENS_DISTORTION
#endif
#ifdef LENS_CHROMATIC
#endif
#ifdef LENS_AXIAL_CA
#endif
#ifdef LENS_SOFT_FOCUS
#endif
#ifdef LENS_SWIRL
#endif
#ifdef LENS_OPTICAL_VIGNETTING
#endif
#ifdef LENS_HALATION
#endif
#ifdef BLOOM
#endif
#ifdef SELECTION_OUTLINE
#endif

#endif // SETTINGS_GLSL
