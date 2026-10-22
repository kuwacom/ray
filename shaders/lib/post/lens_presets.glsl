/*
 * レンズプリセット (post モジュール): LENS_PRESET から各効果の強さ LP_* を決める
 * 数値は docs/reference/techniques/lens-optics.md の「オールドレンズプリセット表」を起点にした推定 (実測ではない)
 * 強さ 1 の目安: ゴーストは物理量 (反射率から計算) そのもの、他は「はっきり分かるが破綻しない」程度
 * LENS_GHOST_TABLE はゴースト表 (lens_ghosts.glsl) の番号 = 設計 x 3 + コーティング
 */
#ifndef POST_LENS_PRESETS_GLSL
#define POST_LENS_PRESETS_GLSL

#if LENS_PRESET == 0
/*
 * 現代の大口径単焦点 (50mm F1.8 級, マルチコート, 丸い 9 枚羽根)
 * 収差はほぼ補正済み。既定なので控えめ (ゴーストは太陽を入れた時に淡く出る程度)
 */
#define LENS_GHOST_TABLE 3
#define LENS_BLADES 9
const float LP_F_OPEN = 1.8;
const float LP_BLADE_ROUNDNESS = 0.6;
const float LP_GHOSTS = 2.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.9;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.08;
const float LP_DIRT = 0.15;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.3;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_CA = 0.15;
const float LP_AXIAL_CA = 0.0;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.15;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

#elif LENS_PRESET == 1
/*
 * Helios 44-2 58mm F2 (Biotar 型 6 枚 4 群, 単層コート)
 * 後期の 44-2 は 8 枚羽根 (初期の 44 は 13 枚)。ぐるぐるボケと口径食の猫目、開放の柔らかさが特徴
 */
#define LENS_GHOST_TABLE 1
#define LENS_BLADES 8
const float LP_F_OPEN = 2.0;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.6;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.4;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.8;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = -0.01;
const float LP_K2 = 0.0;
const float LP_CA = 0.5;
const float LP_AXIAL_CA = 0.6;
const float LP_SOFT_FOCUS = 0.25;
const float LP_SWIRL = 1.0;
const float LP_FIELD_CURVATURE = 0.6;
const float LP_CATS_EYE = 0.55;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.25;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.25;

#elif LENS_PRESET == 2
/*
 * Super Takumar 50mm F1.4 (7 枚 6 群, 単層コート, 6 枚羽根)
 * 開放の強い滲みと色収差、トリウムガラスの黄変 (暖色寄り)。フードなしではフレアしやすい
 */
#define LENS_GHOST_TABLE 4
#define LENS_BLADES 6
const float LP_F_OPEN = 1.4;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.2;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.8;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.3;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 1.0;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_CA = 0.6;
const float LP_AXIAL_CA = 1.0;
const float LP_SOFT_FOCUS = 0.45;
const float LP_SWIRL = 0.2;
const float LP_FIELD_CURVATURE = 0.2;
const float LP_CATS_EYE = 0.5;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.15;
const float LP_YELLOWING = 0.5;
const float LP_RINGING = 0.25;

#elif LENS_PRESET == 3
/*
 * Petzval 85mm F2.2 相当 (2 群 4 枚, 単層コート, 円形絞り)
 * 強い像面湾曲で周辺が渦を巻いて溶ける。周辺減光も強い
 */
#define LENS_GHOST_TABLE 7
#define LENS_BLADES 0
const float LP_F_OPEN = 2.2;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.3;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.3;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 1.2;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_CA = 0.4;
const float LP_AXIAL_CA = 0.8;
const float LP_SOFT_FOCUS = 0.6;
const float LP_SWIRL = 2.0;
const float LP_FIELD_CURVATURE = 2.0;
const float LP_CATS_EYE = 0.9;
const float LP_HALATION = 0.1;
const float LP_BOKEH_RIM = 0.4;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;

#elif LENS_PRESET == 4
/*
 * Canon FD 50mm F1.4 S.S.C. (7 枚 6 群, 多層コート, 8 枚羽根)
 * フレアは少なく、開放でわずかに滲む。癖の弱いオールドレンズ
 */
#define LENS_GHOST_TABLE 3
#define LENS_BLADES 8
const float LP_F_OPEN = 1.4;
const float LP_BLADE_ROUNDNESS = 0.1;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.7;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.2;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.5;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_CA = 0.35;
const float LP_AXIAL_CA = 0.5;
const float LP_SOFT_FOCUS = 0.25;
const float LP_SWIRL = 0.15;
const float LP_FIELD_CURVATURE = 0.15;
const float LP_CATS_EYE = 0.45;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.1;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

#elif LENS_PRESET == 5
/*
 * アナモルフィック (シネマ用, 2x 前玉アナモ相当の見た目)
 * 青い横ストリーク, 縦長の楕円ボケとゴースト, 樽型歪曲, 強めの倍率色収差
 */
#define LENS_GHOST_TABLE 3
#define LENS_BLADES 0
const float LP_F_OPEN = 2.0;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.0;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.3;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.6;
const float LP_STREAK = 1.5;
const vec3 LP_STREAK_TINT = vec3(0.3, 0.55, 1.0);
const float LP_SQUEEZE = 1.8;
const float LP_K1 = 0.05;
const float LP_K2 = 0.0;
const float LP_CA = 0.8;
const float LP_AXIAL_CA = 0.4;
const float LP_SOFT_FOCUS = 0.15;
const float LP_SWIRL = 0.2;
const float LP_FIELD_CURVATURE = 0.3;
const float LP_CATS_EYE = 0.4;
const float LP_HALATION = 0.1;
const float LP_BOKEH_RIM = 0.1;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

#else
// カスタム: 個別スライダー (LENS_C_*) をそのまま使う
#define LENS_GHOST_TABLE (LENS_C_DESIGN * 3 + LENS_C_COATING)
#define LENS_BLADES DOF_APERTURE_BLADES
const float LP_F_OPEN = LENS_C_F_OPEN;
const float LP_BLADE_ROUNDNESS = LENS_C_BLADE_ROUNDNESS;
const float LP_GHOSTS = LENS_C_GHOSTS;
const float LP_SCREEN_GHOSTS = LENS_C_SCREEN_GHOSTS;
const float LP_STARBURST = LENS_C_STARBURST;
const float LP_STAR_SIZE = LENS_C_STAR_SIZE;
const float LP_HALO = LENS_C_HALO;
const float LP_DIRT = LENS_C_DIRT;
const float LP_DIRT_CONTRAST = LENS_C_DIRT_CONTRAST;
const float LP_VEILING_GLARE = LENS_C_VEILING_GLARE;
const float LP_STREAK = LENS_C_STREAK;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = LENS_C_SQUEEZE;
const float LP_K1 = LENS_C_DISTORTION;
const float LP_K2 = 0.0;
const float LP_CA = LENS_C_CA;
const float LP_AXIAL_CA = LENS_C_AXIAL_CA;
const float LP_SOFT_FOCUS = LENS_C_SOFT_FOCUS;
const float LP_SWIRL = LENS_C_SWIRL;
const float LP_FIELD_CURVATURE = LENS_C_FIELD_CURVATURE;
const float LP_CATS_EYE = LENS_C_CATS_EYE;
const float LP_HALATION = LENS_C_HALATION;
const float LP_BOKEH_RIM = LENS_C_BOKEH_RIM;
const float LP_YELLOWING = LENS_C_YELLOWING;
const float LP_RINGING = 0.2;
#endif

// スターバーストのテクスチャのタイル (tools/gen_lens_textures.py の BLADES = 0, 5, 6, 7, 8, 9, 10, 13 の順)
#if LENS_BLADES == 5
const int LENS_STAR_TILE = 1;
#elif LENS_BLADES == 6
const int LENS_STAR_TILE = 2;
#elif LENS_BLADES == 7
const int LENS_STAR_TILE = 3;
#elif LENS_BLADES == 8
const int LENS_STAR_TILE = 4;
#elif LENS_BLADES == 9
const int LENS_STAR_TILE = 5;
#elif LENS_BLADES == 10
const int LENS_STAR_TILE = 6;
#elif LENS_BLADES >= 11
const int LENS_STAR_TILE = 7;
#else
const int LENS_STAR_TILE = 0;
#endif

#endif
