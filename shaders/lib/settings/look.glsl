#ifndef SETTINGS_LOOK_GLSL
#define SETTINGS_LOOK_GLSL

/*
  ルック (lib/common/look_presets.glsl)。プリセットが光の比と色・照り返し・露出・明部と暗部・ブルームの基準値 (LK_*) を決め、
  既存の設定 (SATURATION, CONTRAST, EXPOSURE_BIAS, BLOOM_STRENGTH, BLOOM_FOG, GI_SKY_OCCLUSION,
  SKY_AMBIENT_SATURATION, FOG_DENSITY) はその基準値に掛ける (露出補正は足す) 微調整として効く
  個別の値 (LOOK_C_*) は LOOK_PRESET = 0 (カスタム) の時だけ使う。番号は後ろに足していき、既存の番号は変えない
*/
#define LOOK_PRESET 1 // [0 1 2 3 4 5 6 7 8 9] 0=カスタム 1=ナチュラル 2=ビビッド 3=デイライト 4=夏の青空 5=ゴールデンアワー 6=ティール & オレンジ 7=ブリーチバイパス 8=クロスプロセス 9=ゲーム (鮮やか)
#define LOOK_LUT 0 // [0 1 2 3 4 5 6 7 8 9] 0=なし 1=ユーザーの LUT 2=日向と日陰の色の割れ 3=フィルム 4=Portra 風 5=Ektar 風 6=Vision3 500T 風 7=Velvia 風 8=Provia 風 9=Eterna 風
#define LOOK_LUT_STRENGTH 1.0 // [0.0 0.1 0.25 0.5 0.75 1.0]
#define LOOK_C_SKY_AMBIENT 1.0 // [0.5 0.6 0.7 0.75 0.8 0.85 0.9 1.0 1.1 1.25 1.5] 日陰を照らす空の環境光の強さ (空そのものの明るさは変えない)
#define LOOK_C_SKY_SATURATION 1.0 // [0.8 0.9 1.0 1.05 1.1 1.15 1.2 1.3] 空の色の彩度 (空の描画と空の環境光の両方)
#define LOOK_C_SUN_WARMTH 0.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.75 0.85 1.0] 日向 (太陽の直達光) を暖色に寄せる割合。1 で 6500K に対して 5000K の色 (空・雲の色は変えない)
#define LOOK_C_BOUNCE 1.0 // [0.5 0.75 1.0 1.25 1.5 1.6 1.75 2.0 2.5 3.0] 照り返しの強さ (GI のレイが当たった面からの光。空の光は変えない)
#define LOOK_C_BOUNCE_SATURATION 1.0 // [0.8 1.0 1.1 1.2 1.3 1.4 1.5 1.75 2.0] 照り返しの色の濃さ (草の照り返しの緑など。明るさは変えない)
#define LOOK_C_HIGHLIGHT 1.1 // [0.8 0.9 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.75 2.0] 明部の伸び: 中間グレーより明るい所の明るさの差を何倍に広げるか (暗い側は変えない)
#define LOOK_C_DARK_LIFT 0.0 // [0.0 0.25 0.5 0.75 1.0] 暗部の持ち上げ (AgX の出力を 2.2 乗のモニターで想定どおりに見せる割合)。1 で 2.2 乗のモニターの暗部が 1-3 EV 明るくなる
#define LOOK_C_BLOOM_SPREAD 0.82 // [0.5 0.6 0.65 0.7 0.75 0.82 0.9] ブルームの広がり (縮小の段ごとの重みの減り方)。下げるほど光の周りに締まる
#define LOOK_C_BLOOM_FOG_CLEAR 0.35 // [0.0 0.1 0.2 0.25 0.35 0.5 0.75 1.0] 晴れの日のブルーミーフォグの割合 (雨では 1)

#endif
