/*
 * ルックのプリセット: LOOK_PRESET から基準値 LK_* を決める (settings.glsl の直後に読む。sky / surface / post のどれも使う)
 * 既存の設定は LK_* に掛ける微調整 (露出補正は足す)。ナチュラルの LK_* は掛ける値が 1・足す値が 0 なので、ナチュラルでは各設定の値がそのまま効く
 * Iris の profile は 1 組しか持てず、品質のプロファイルと別に選べないので、シェーダー内の #if で差し替える (LENS_PRESET と同じ方式)
 * 番号: 0 = カスタム (最後の #else, LOOK_C_*)、1 = ナチュラル (既定)、2 = ビビッド、3 = デイライト、4 = 夏の青空、5 = ゴールデンアワー、
 *       6 = ティール & オレンジ、7 = ブリーチバイパス、8 = クロスプロセス、9 = ゲーム (鮮やか)。新しいプリセットは後ろに足し、既存の番号は変えない
 * 3 以降は色と階調の多くをグレーディングの基準 (LKG_*) で作る
 */
#ifndef COMMON_LOOK_PRESETS_GLSL
#define COMMON_LOOK_PRESETS_GLSL

#include "/lib/settings.glsl"

#if LOOK_PRESET == 1
/*
 * ナチュラル: 素朴なマイクラらしさを残した、目の疲れないルック (各設定がそのまま効く基準)
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
 * - 空の環境光 0.8: 0.75 では白樺の林の日陰が暗く、HIGH (RSM) の草の明暗比が 35 まで上がる
 * - 空の光の遮蔽 1.6 倍 (既定で 0.8): 0.5 では洞窟の中が向きの無い空の光で青く満たされる
 * - 照り返し 1.6 倍・彩度 1.5: 空の光だけ下げると照り返しも暗くなり、草の照り返しが空の青と打ち消し合って洞窟・幹が青緑の灰色になる
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

#elif LOOK_PRESET == 3
/*
 * デイライト: 晴れた日中のパンチ。光はビビッドと同じで、色と階調をグレーディングで足す
 * - 空: 青を 0.35 EV 暗く・彩度 1.3 倍 (AgX は明るい青を白へ寄せるので、明るさを下げると濃さが出る)
 * - 草・葉: マイクラの草は黄緑なので黄を緑の側へ 6 度回し、緑の彩度 1.2 倍 (1.3 では森の草が蛍光色に見える)
 * - 日向: ミッドのコントラスト 1.12 で凹凸の陰影を出し、ハイライトの圧縮 0.3 で雲と白い面を飛ばさない
 */
const float LK_SKY_AMBIENT = 0.8;
const float LK_SKY_AMBIENT_SAT = 1.1;
const float LK_SKY_SAT = 1.12;
const float LK_SUN_WARMTH = 0.85;
const float LK_GI_BOUNCE = 1.6;
const float LK_GI_BOUNCE_SAT = 1.5;
const float LK_SKY_OCCLUSION = 1.6;
const float LK_EXPOSURE_EV = -0.15;
const float LK_HIGHLIGHT = 1.5;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.05;
const float LK_BLOOM = 1.1;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = 0.75;
const float LK_BLOOM_FOG_CLEAR = 0.3;
const float LK_FOG = 1.0;
#define LKG_ZONE_CONTRAST vec3(1.05, 1.12, 1.0)
#define LKG_HIGHLIGHT_COMPRESS 0.3
#define LKG_VIBRANCE 0.25
#define LKG_HUE_SHIFT_INIT float[8](0.0, 0.0, 6.0, 0.0, 3.0, 0.0, 0.0, 0.0)
#define LKG_HUE_SAT_INIT float[8](1.05, 1.1, 1.15, 1.2, 1.2, 1.3, 1.0, 1.0)
#define LKG_HUE_LUM_INIT float[8](0.0, 0.0, 0.0, 0.0, -0.15, -0.35, 0.0, 0.0)

#elif LOOK_PRESET == 4
/*
 * 夏の青空: 明るく抜けの良い真夏の日中。濃い青空・青寄りの水色・瑞々しい緑・暖かい日差し
 * - 露出はビビッドより 0.25 EV 明るく、シャドーを持ち上げてコントラストを少し下げ、軽く見せる
 * - 水色を青の側へ回して空の地平線の近くまで青を濃くし、青は 0.5 EV 暗く・彩度 1.4 倍
 * - ハイライトに暖色 (赤 +0.04, 青 -0.04 EV)
 */
const float LK_SKY_AMBIENT = 0.85;
const float LK_SKY_AMBIENT_SAT = 1.15;
const float LK_SKY_SAT = 1.15;
const float LK_SUN_WARMTH = 0.7;
const float LK_GI_BOUNCE = 1.6;
const float LK_GI_BOUNCE_SAT = 1.5;
const float LK_SKY_OCCLUSION = 1.6;
const float LK_EXPOSURE_EV = 0.1;
const float LK_HIGHLIGHT = 1.4;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.08;
const float LK_BLOOM = 1.2;
const float LK_BLOOM_FOG = 0.9;
const float LK_BLOOM_SPREAD = 0.75;
const float LK_BLOOM_FOG_CLEAR = 0.25;
const float LK_FOG = 0.85;
#define LKG_HIGHLIGHT vec4(0.04, 0.0, -0.04, 0.0)
#define LKG_ZONE_CONTRAST vec3(0.95, 1.02, 1.0)
#define LKG_HIGHLIGHT_COMPRESS 0.4
#define LKG_SHADOW_LIFT 0.3
#define LKG_VIBRANCE 0.3
#define LKG_HUE_SHIFT_INIT float[8](0.0, 0.0, 8.0, 0.0, 10.0, 0.0, 0.0, 0.0)
#define LKG_HUE_SAT_INIT float[8](1.05, 1.1, 1.15, 1.2, 1.35, 1.4, 1.0, 1.0)
#define LKG_HUE_LUM_INIT float[8](0.0, 0.0, 0.05, 0.0, -0.25, -0.5, 0.0, 0.0)

#elif LOOK_PRESET == 5
/*
 * ゴールデンアワー: 一日中が夕方前の低い日差しのような暖かさ
 * - 日向の暖かさ 1 (5000K の色)、ハイライトを暖色へ (EV とスプリットトーンの橙)、シャドーを少し青へ
 * - コントラストは少し下げ (ミッド 0.95)、ブルームと晴れのブルーミーフォグを強めて柔らかく
 */
const float LK_SKY_AMBIENT = 0.85;
const float LK_SKY_AMBIENT_SAT = 1.0;
const float LK_SKY_SAT = 1.0;
const float LK_SUN_WARMTH = 1.0;
const float LK_GI_BOUNCE = 1.5;
const float LK_GI_BOUNCE_SAT = 1.4;
const float LK_SKY_OCCLUSION = 1.5;
const float LK_EXPOSURE_EV = -0.1;
const float LK_HIGHLIGHT = 1.3;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.05;
const float LK_BLOOM = 1.5;
const float LK_BLOOM_FOG = 1.2;
const float LK_BLOOM_SPREAD = 0.82;
const float LK_BLOOM_FOG_CLEAR = 0.5;
const float LK_FOG = 1.1;
#define LKG_SHADOW vec4(-0.02, 0.0, 0.04, 0.0)
#define LKG_HIGHLIGHT vec4(0.06, 0.02, -0.08, 0.0)
#define LKG_ZONE_CONTRAST vec3(1.0, 0.95, 1.0)
#define LKG_HIGHLIGHT_COMPRESS 0.3
#define LKG_HUE_SAT_INIT float[8](1.1, 1.2, 1.1, 1.0, 0.95, 0.9, 1.0, 1.0)
#define LKG_SPLIT_SHADOW_HUE 210.0
#define LKG_SPLIT_SHADOW_AMOUNT 0.15
#define LKG_SPLIT_HIGHLIGHT_HUE 35.0
#define LKG_SPLIT_HIGHLIGHT_AMOUNT 0.35

#elif LOOK_PRESET == 6
/*
 * ティール & オレンジ: 映画の定番。暗い側を青緑、明るい側と肌・木・土を橙に寄せる
 * - 緑を水色の側へ 12 度回して彩度を下げ (草が青緑に)、青も水色の側へ寄せ、橙の彩度 1.25 倍
 * - スプリットトーン: シャドー 190 度 (青緑) 0.5、ハイライト 30 度 (橙) 0.4
 */
const float LK_SKY_AMBIENT = 0.8;
const float LK_SKY_AMBIENT_SAT = 1.1;
const float LK_SKY_SAT = 1.0;
const float LK_SUN_WARMTH = 0.85;
const float LK_GI_BOUNCE = 1.5;
const float LK_GI_BOUNCE_SAT = 1.3;
const float LK_SKY_OCCLUSION = 1.6;
const float LK_EXPOSURE_EV = -0.15;
const float LK_HIGHLIGHT = 1.4;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 0.95;
const float LK_BLOOM = 1.2;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = 0.75;
const float LK_BLOOM_FOG_CLEAR = 0.35;
const float LK_FOG = 1.1;
#define LKG_ZONE_CONTRAST vec3(1.05, 1.1, 1.0)
#define LKG_HUE_SHIFT_INIT float[8](3.0, 0.0, 0.0, 12.0, 0.0, -10.0, 0.0, 0.0)
#define LKG_HUE_SAT_INIT float[8](1.1, 1.25, 1.0, 0.85, 1.2, 1.0, 0.9, 0.9)
#define LKG_SPLIT_SHADOW_HUE 190.0
#define LKG_SPLIT_SHADOW_AMOUNT 0.5
#define LKG_SPLIT_HIGHLIGHT_HUE 30.0
#define LKG_SPLIT_HIGHLIGHT_AMOUNT 0.4

#elif LOOK_PRESET == 7
/*
 * ブリーチバイパス: 現像で銀を残したような、色の抜けた硬い絵 (コントラストが強いので長時間は目が疲れやすい)
 * - 彩度 0.6、ミッドのコントラスト 1.3・シャドー 1.2、カーブで黒を沈めて白を締める。明部は少し冷たい銀色
 * 光はナチュラルと同じ
 */
const float LK_SKY_AMBIENT = 1.0;
const float LK_SKY_AMBIENT_SAT = 1.0;
const float LK_SKY_SAT = 1.0;
const float LK_SUN_WARMTH = 0.0;
const float LK_GI_BOUNCE = 1.0;
const float LK_GI_BOUNCE_SAT = 1.0;
const float LK_SKY_OCCLUSION = 1.0;
const float LK_EXPOSURE_EV = 0.0;
const float LK_HIGHLIGHT = 1.0;
const float LK_DARK_LIFT = 0.0;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 0.6;
const float LK_BLOOM = 1.0;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = 0.82;
const float LK_BLOOM_FOG_CLEAR = 0.35;
const float LK_FOG = 1.0;
#define LKG_HIGHLIGHT vec4(-0.02, 0.0, 0.03, 0.0)
#define LKG_ZONE_CONTRAST vec3(1.2, 1.3, 1.0)
#define LKG_HIGHLIGHT_COMPRESS 0.3
#define LKG_CURVE_INIT float[7](0.0, -0.02, -0.02, 0.0, 0.01, 0.01, 0.0)

#elif LOOK_PRESET == 8
/*
 * クロスプロセス: リバーサルフィルムをネガの現像液で処理したような、黄緑に転んだ明部・青い暗部・強い彩度 (色とコントラストが強い)
 * - リフトで黒を青へ、ゲインで白の青を下げて黄色へ、緑のガンマを上げて中間を黄緑へ。チャンネルごとのカーブの転びを再現する
 */
const float LK_SKY_AMBIENT = 0.9;
const float LK_SKY_AMBIENT_SAT = 1.0;
const float LK_SKY_SAT = 1.0;
const float LK_SUN_WARMTH = 0.3;
const float LK_GI_BOUNCE = 1.3;
const float LK_GI_BOUNCE_SAT = 1.2;
const float LK_SKY_OCCLUSION = 1.3;
const float LK_EXPOSURE_EV = -0.1;
const float LK_HIGHLIGHT = 1.3;
const float LK_DARK_LIFT = 0.25;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.2;
const float LK_BLOOM = 1.0;
const float LK_BLOOM_FOG = 1.0;
const float LK_BLOOM_SPREAD = 0.82;
const float LK_BLOOM_FOG_CLEAR = 0.35;
const float LK_FOG = 1.0;
#define LKG_ZONE_CONTRAST vec3(1.1, 1.2, 1.0)
#define LKG_HUE_SAT_INIT float[8](1.0, 1.0, 1.2, 1.1, 1.1, 1.0, 1.0, 1.0)
#define LKG_LIFT vec4(-0.02, 0.0, 0.05, 0.0)
#define LKG_GAMMA vec4(0.0, 0.08, -0.05, 0.0)
#define LKG_GAIN vec4(1.03, 1.02, 0.85, 1.0)

#elif LOOK_PRESET == 9
/*
 * ゲーム (鮮やか): 色をはっきり出す、遊びやすい鮮やかなルック
 * - 彩度 1.12 とバイブランス 0.35、色ごとの彩度を広く上げ、青を暗くして空を濃く (草の緑は蛍光色にならない程度)
 * - 暗い所を持ち上げ (シャドーの持ち上げ 0.3) 洞窟や日陰も見やすく、ハイライトの圧縮で白飛びを抑える
 */
const float LK_SKY_AMBIENT = 0.9;
const float LK_SKY_AMBIENT_SAT = 1.15;
const float LK_SKY_SAT = 1.15;
const float LK_SUN_WARMTH = 0.6;
const float LK_GI_BOUNCE = 1.7;
const float LK_GI_BOUNCE_SAT = 1.6;
const float LK_SKY_OCCLUSION = 1.5;
const float LK_EXPOSURE_EV = -0.05;
const float LK_HIGHLIGHT = 1.4;
const float LK_DARK_LIFT = 0.5;
const float LK_CONTRAST = 1.0;
const float LK_SATURATION = 1.12;
const float LK_BLOOM = 1.2;
const float LK_BLOOM_FOG = 0.9;
const float LK_BLOOM_SPREAD = 0.75;
const float LK_BLOOM_FOG_CLEAR = 0.3;
const float LK_FOG = 0.9;
#define LKG_ZONE_CONTRAST vec3(1.0, 1.1, 1.0)
#define LKG_HIGHLIGHT_COMPRESS 0.5
#define LKG_SHADOW_LIFT 0.3
#define LKG_VIBRANCE 0.35
#define LKG_HUE_SHIFT_INIT float[8](0.0, 0.0, 6.0, 0.0, 5.0, 0.0, 0.0, 0.0)
#define LKG_HUE_SAT_INIT float[8](1.15, 1.15, 1.1, 1.1, 1.2, 1.25, 1.15, 1.15)
#define LKG_HUE_LUM_INIT float[8](0.0, 0.0, 0.0, 0.0, -0.1, -0.3, 0.0, 0.0)

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

/*
 * プリセットのグレーディングの基準 (LKG_*, lib/post/color_grade.glsl)。プリセットは変えたいものだけを上の #if の中で #define し、
 * 残りはここで恒等の値になる。設定 (GRADE_*) は足す値なら和、掛ける値なら積で重なる
 */
#ifndef LKG_TINT
#define LKG_TINT 0.0                 // ティント (+ でマゼンタ)
#endif
#ifndef LKG_OFFSET
#define LKG_OFFSET vec3(0.0)         // チャンネルごとの露出 (EV)
#endif
#ifndef LKG_PIVOT
#define LKG_PIVOT 0.0                // コントラストの軸 (中間グレーからの EV)
#endif
#ifndef LKG_SHADOW
#define LKG_SHADOW vec4(0.0)         // シャドーの色 (rgb) と明るさ (a) (EV)
#endif
#ifndef LKG_MID
#define LKG_MID vec4(0.0)
#endif
#ifndef LKG_HIGHLIGHT
#define LKG_HIGHLIGHT vec4(0.0)
#endif
#ifndef LKG_ZONE_SAT
#define LKG_ZONE_SAT vec3(1.0)       // シャドー・ミッド・ハイライトの彩度
#endif
#ifndef LKG_ZONE_CONTRAST
#define LKG_ZONE_CONTRAST vec3(1.0)  // シャドー・ミッド・ハイライトのコントラスト
#endif
#ifndef LKG_HIGHLIGHT_COMPRESS
#define LKG_HIGHLIGHT_COMPRESS 0.0
#endif
#ifndef LKG_SHADOW_LIFT
#define LKG_SHADOW_LIFT 0.0
#endif
#ifndef LKG_VIBRANCE
#define LKG_VIBRANCE 0.0
#endif
// 色相ごと (赤, 橙, 黄, 緑, 水色, 青, 紫, マゼンタ) の色相の回転 (度)・彩度の倍率・明るさ (EV)
#ifndef LKG_HUE_SHIFT_INIT
#define LKG_HUE_SHIFT_INIT float[8](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
#endif
#ifndef LKG_HUE_SAT_INIT
#define LKG_HUE_SAT_INIT float[8](1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0)
#endif
#ifndef LKG_HUE_LUM_INIT
#define LKG_HUE_LUM_INIT float[8](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
#endif
const float LKG_HUE_SHIFT[8] = LKG_HUE_SHIFT_INIT;
const float LKG_HUE_SAT[8] = LKG_HUE_SAT_INIT;
const float LKG_HUE_LUM[8] = LKG_HUE_LUM_INIT;
// リフト・ガンマ・ゲイン (rgb = 色, a = 輝度。トーンマップ後の表示値)
#ifndef LKG_LIFT
#define LKG_LIFT vec4(0.0)
#endif
#ifndef LKG_GAMMA
#define LKG_GAMMA vec4(0.0)
#endif
#ifndef LKG_GAIN
#define LKG_GAIN vec4(1.0)
#endif
// トーンカーブの 7 点 (0, 10, 25, 50, 75, 90, 100 %) の出力のずらし
#ifndef LKG_CURVE_INIT
#define LKG_CURVE_INIT float[7](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
#endif
const float LKG_CURVE[7] = LKG_CURVE_INIT;
// スプリットトーン (色相は HSV の度)
#ifndef LKG_SPLIT_SHADOW_HUE
#define LKG_SPLIT_SHADOW_HUE 210.0
#endif
#ifndef LKG_SPLIT_SHADOW_AMOUNT
#define LKG_SPLIT_SHADOW_AMOUNT 0.0
#endif
#ifndef LKG_SPLIT_HIGHLIGHT_HUE
#define LKG_SPLIT_HIGHLIGHT_HUE 30.0
#endif
#ifndef LKG_SPLIT_HIGHLIGHT_AMOUNT
#define LKG_SPLIT_HIGHLIGHT_AMOUNT 0.0
#endif
#ifndef LKG_SPLIT_BALANCE
#define LKG_SPLIT_BALANCE 0.0
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
