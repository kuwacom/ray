#ifndef SETTINGS_SURFACE_GLSL
#define SETTINGS_SURFACE_GLSL

// 太陽影 / GI (surface モジュール)
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
#define SHADOW_LEAF_TINT // 葉を通った太陽光を葉の色で透過させる (木漏れ日・森の床が緑がかる)
#define SHADOW_LEAF_TRANSMISSION 0.15 // [0.05 0.1 0.15 0.2 0.25 0.3 0.4 0.5] 葉 1 枚 (1 ブロック) が通す光の割合。重なるほどこの累乗で暗くなる
#define ENTITY_SHADOWS // エンティティの太陽影
#define BLOCK_ENTITY_SHADOWS // ブロックエンティティの太陽影
#define SCREEN_SPACE_SHADOWS // 太陽影のスクリーンスペース接触影
#define AO_MODE 2 // [0 1 2] 0=なし 1=SSAO 2=GTAO
#define AO_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0]
#define GI_MODE 1 // [0 1 2 3] 0=なし 1=RSM 2=SSGI 3=ボクセル RT
#define GI_SAMPLES 2 // [1 2 4 8]
#define GI_STRENGTH 2.0 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0] 既定 2 は、地面の照り返しを GI に置き換える (GI_GROUND_REPLACE) と暗くなる日陰・地面を向く面の明るさを補うため。方式ごとの効きは lib/surface/gi.glsl GI_MODE_GAIN
#define GI_MULTI_BOUNCE 1.0 // [0.0 0.25 0.5 0.75 1.0] 多重反射: GI のレイが当たった面に前フレームの GI を返す量 (フレームを重ねて反射の回数が増える) 0=1 回だけ
#define GI_SKY_OCCLUSION 0.5 // [0.0 0.25 0.5 0.75 1.0] SSGI / ボクセル RT で空の光を GI のレイの遮蔽 (向きあり) にする割合 0=スカイライトだけ (向きなし)
#define GI_GROUND_REPLACE 1.0 // [0.0 0.25 0.5 0.75 1.0] 空の環境光の灰色の地面の照り返しを GI (実際の地面の色) に置き換える割合 0=置き換えない (二重に数える)
#define GI_RES 2 // [1 2] GI 解像度の分母
#define GI_DENOISE 2 // [0 1 2] 0=なし 1=時間 2=時間+空間

// マテリアル / 水 / 反射 (surface モジュール)
#define PBR_FORMAT 0 // [0 1] 0=なし 1=labPBR
#define NORMAL_MAPPING // リソースパックの法線マップ
#define GENERATED_NORMALS // テクスチャからの法線自動生成 (PBR なしのとき)
//#define POM // 視差オクルージョンマッピング
#define POM_DEPTH 0.25 // [0.05 0.1 0.15 0.2 0.25 0.3 0.4 0.5 0.75 1.0]
#define POM_SAMPLES 32 // [16 32 48 64]
#define POM_SHADOW // POM の自己影
#define SSS // 表面下散乱 (葉・草・雪・プレイヤーの肌を裏から透ける光)
#define SSS_STRENGTH 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define WAVING_PLANTS
#define WAVING_LEAVES
#define RAIN_PUDDLES // 雨の水たまり
#define PUDDLE_AMOUNT 0.3 // [0.0 0.05 0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.5 0.6 0.7 0.8 1.0] 雨が降りきった時に水たまりが覆う地面の割合 (Nostalgia は 0.37 相当)
#define PUDDLE_SIZE 1.0 // [0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0] 水たまりの大きさの倍率 (1.0 で 1 つが 2-10 ブロック程度)
#define RAIN_WETNESS 1.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0] 雨に濡れた地面の暗さ・つやの強さ
#define PUDDLE_RIPPLES 1.0 // [0.0 0.5 1.0 1.5 2.0 3.0 4.0 5.0] 水たまりに落ちる雨の波紋の強さ
// 濡れ (rainWetness) の半減期 (秒)。shaders.properties のカスタム uniform が読む。雨の雲とフォグもこの濡れに従う
#define RAIN_WET_HALFLIFE 30 // [5 10 15 20 30 40 60 90 120] 降り始めてから濡れが半分まで進む時間
#define RAIN_DRY_HALFLIFE 40 // [5 10 15 20 30 40 60 90 120] 止んでから濡れが半分まで乾く時間
#define EMISSION_STRENGTH 1.0 // [0.0 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0 8.0]
#define LAVA_BRIGHTNESS 2.0 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0 4.0 5.0] 溶岩の見た目の明るさ (表示だけ。0 で持ち上げなし、1 増やすごとに +100%。周りへの光は変わらない)
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
#define WATER_REFRACTION_MODE 2 // [0 1 2] 上から見た水の屈折の方式 0=波の分だけ (水底は実際の深さ) 1=端で弱める (屈折のまま画面の端で弱める) 2=ボクセルで辿る (屈折のまま画面外はボクセルで辿る。水底が浅く見える)
//#define WATER_CAUSTICS // 水中のコースティクス
//#define WATER_TEXTURE // バニラの水テクスチャを重ねる
#define WATER_FOG_DENSITY 1.0 // [0.05 0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0 6.0]
#define WATER_TYPE 0 // [0 1 2] 0=外洋 (青) 1=沿岸 (緑) 2=澄んだ水
#define REFLECTIONS 2 // [0 1 2 3] 0=空のみ 1=SSR 2=SSR+ラフ反射 3=SSR+ボクセル補完
#define SSR_STEPS 24 // [8 12 16 24 32 48 64]

#endif
