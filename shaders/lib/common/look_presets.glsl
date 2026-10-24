/*
 * ルックのプリセット: LOOK_PRESET から基準値 LK_* を決める (settings.glsl の直後に読む。sky / surface / post のどれも使う)
 * 既存の設定は LK_* に掛ける微調整 (露出補正は足す)。ナチュラルの LK_* は全部「今までの値」なので、ナチュラルでは設定の意味も絵も変わらない
 * Iris の profile は 1 組しか持てず、品質のプロファイルと別に選べないので、シェーダー内の #if で差し替える (LENS_PRESET と同じ方式)
 * 番号: 0 = カスタム (最後の #else, LOOK_C_*)、1 = ナチュラル (既定)、2 = ビビッド。新しいプリセットは後ろに足し、既存の番号は変えない
 */
#ifndef COMMON_LOOK_PRESETS_GLSL
#define COMMON_LOOK_PRESETS_GLSL

#if LOOK_PRESET == 1
/*
 * ナチュラル: 素朴なマイクラらしさを残した、目の疲れないルック (ルックのプリセットを入れる前 (971f746) の見た目のまま)
 */
const float LK_SKY_AMBIENT = 1.0;        // 空の環境光の強さ (SH_SKY_GAIN に掛ける)
const float LK_SKY_AMBIENT_SAT = 1.0;    // 空の環境光の彩度 (SKY_AMBIENT_SATURATION に掛ける)
const float LK_SKY_SAT = 1.0;            // 空の色の彩度 (SKY_COLOR_SATURATION に掛ける)
const float LK_SUN_WARMTH = 0.0;         // 日向 (太陽の直達光) を暖色に寄せる割合 (sky_color.glsl lookSunTint)
const float LK_GI_BOUNCE = 1.0;          // 照り返し (GI のレイが当たった面からの光) の強さ。空へ抜けたレイ (空の光) には掛けない (gi.glsl giBounceGrade)
const float LK_GI_BOUNCE_SAT = 1.0;      // 照り返し (GI のレイが当たった面) の彩度 (gi.glsl giBounceGrade)
const float LK_SKY_OCCLUSION = 1.0;      // 空の光の遮蔽 (GI_SKY_OCCLUSION に掛ける, 上限 1)
const float LK_EXPOSURE_EV = 0.0;        // 露出 (EXPOSURE_BIAS に足す)
const float LK_HIGHLIGHT = 1.0;          // 明部の伸び: 中間グレーより明るい所だけ log2 で掛ける傾き (grading.glsl applyHighlightRange)
const float LK_DARK_LIFT = 0.0;          // AgX の出力の復号を 2.2 乗から sRGB の区分曲線へ寄せる割合 (暗部の持ち上げ, tonemap.glsl)
const float LK_CONTRAST = 1.0;           // CONTRAST に掛ける
const float LK_SATURATION = 1.0;         // SATURATION に掛ける
const float LK_BLOOM = 1.0;              // BLOOM_STRENGTH に掛ける
const float LK_BLOOM_FOG = 1.0;          // BLOOM_FOG に掛ける
const float LK_BLOOM_SPREAD = 0.82;      // ブルームの段ごとの重みの減り方 (置き換え)
const float LK_BLOOM_FOG_CLEAR = 0.35;   // 晴れの日のブルーミーフォグの割合 (置き換え)
const float LK_FOG = 1.0;                // FOG_DENSITY に掛ける

#elif LOOK_PRESET == 2
/*
 * ビビッド: SEUS Renewed / PTGI のような「見ているだけで美しい」ルック
 * 彩度を全体に盛るのではなく、日向の暖色と日陰の青緑の割れ (日向の暖かさ・空の環境光の彩度)、草の照り返しの緑 (照り返しの強さと彩度)、
 * 白近くまで伸びる明部 (明部の伸び) で出す。目の疲れを考えて、日陰は SEUS ほど暗くせず (空の環境光 0.8 倍、暗部の持ち上げ)、
 * コントラスト・ブルームは控えめにする
 * - 空の環境光 0.8: 0.75 では白樺の林の日陰が暗く、HIGH (RSM) の草の明暗比が 35 まで上がった
 * - 空の光の遮蔽 1.6 倍 (既定で 0.8): 0.5 では洞窟の中が向きの無い空の光で青く満たされた
 * - 照り返し 1.6 倍・彩度 1.5: 空の光だけ下げると照り返しも暗くなり、草の照り返しが空の青と打ち消し合って洞窟・幹が青緑の灰色だった
 * - 日向の暖かさ 0.85・明部の伸び 1.6: 草の色相の割れ (日陰 - 日向) がナチュラルの 4-9 度から 11-14 度に、屋外の p98 が 0.82-0.94 に
 */
const float LK_SKY_AMBIENT = 0.8;
const float LK_SKY_AMBIENT_SAT = 1.1;
const float LK_SKY_SAT = 1.08;
const float LK_SUN_WARMTH = 0.85;
const float LK_GI_BOUNCE = 1.6;
const float LK_GI_BOUNCE_SAT = 1.5;
const float LK_SKY_OCCLUSION = 1.6;
const float LK_EXPOSURE_EV = -0.15;
const float LK_HIGHLIGHT = 1.6;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.1;
const float LK_BLOOM = 1.2;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = 0.75;
const float LK_BLOOM_FOG_CLEAR = 0.35;
const float LK_FOG = 1.15;

#else
// カスタム (LOOK_PRESET 0): プリセットにしか無い値は LOOK_C_*、既存の設定があるものは基準 1 (設定がそのまま効く)
const float LK_SKY_AMBIENT = LOOK_C_SKY_AMBIENT;
const float LK_SKY_AMBIENT_SAT = 1.0;
const float LK_SKY_SAT = LOOK_C_SKY_SATURATION;
const float LK_SUN_WARMTH = LOOK_C_SUN_WARMTH;
const float LK_GI_BOUNCE = LOOK_C_BOUNCE;
const float LK_GI_BOUNCE_SAT = LOOK_C_BOUNCE_SATURATION;
const float LK_SKY_OCCLUSION = 1.0;
const float LK_EXPOSURE_EV = 0.0;
const float LK_HIGHLIGHT = LOOK_C_HIGHLIGHT;
const float LK_DARK_LIFT = LOOK_C_DARK_LIFT;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.0;
const float LK_BLOOM = 1.0;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = LOOK_C_BLOOM_SPREAD;
const float LK_BLOOM_FOG_CLEAR = LOOK_C_BLOOM_FOG_CLEAR;
const float LK_FOG = 1.0;
#endif

// 各モジュールが使う実効値 (既存の設定 x プリセットの基準値)
const float LOOK_SATURATION = SATURATION * LK_SATURATION;
const float LOOK_CONTRAST = CONTRAST * LK_CONTRAST;
const float LOOK_EXPOSURE_BIAS = EXPOSURE_BIAS + LK_EXPOSURE_EV;
const float LOOK_BLOOM_STRENGTH = BLOOM_STRENGTH * LK_BLOOM;
const float LOOK_BLOOM_FOG = BLOOM_FOG * LK_BLOOM_FOG;
const float LOOK_GI_SKY_OCCLUSION = min(GI_SKY_OCCLUSION * LK_SKY_OCCLUSION, 1.0);
const float LOOK_SKY_AMBIENT_SATURATION = SKY_AMBIENT_SATURATION * LK_SKY_AMBIENT_SAT;
const float LOOK_FOG_DENSITY = FOG_DENSITY * LK_FOG;

#endif
