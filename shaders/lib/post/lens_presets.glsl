/*
 * レンズプリセット (post モジュール): LENS_PRESET から各効果の強さ LP_* を決める
 * 数値は docs/reference/techniques/lens-optics.md の「オールドレンズプリセット表」を起点にした推定 (実測ではない)
 * 強さ 1 の目安: ゴーストは物理量 (反射率から計算) そのもの、他は「はっきり分かるが破綻しない」程度
 * LENS_GHOST_TABLE はゴースト表 (lens_ghosts.glsl) の番号 = 設計 x 3 + コーティング
 * 番号: 0 = カスタム (最後の #else)、1 = 現代の単焦点 (既定)、2-6 = 推定値のオールドレンズとアナモルフィック、
 * 7-12 = 特許の処方から計算したレンズ。新しいレンズは後ろに足し、既存の番号は変えない (ユーザーの保存値を保つ)
 */
#ifndef POST_LENS_PRESETS_GLSL
#define POST_LENS_PRESETS_GLSL

#if LENS_PRESET == 1
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
const float LP_K3 = 0.0;
const float LP_CA = 0.15;
const float LP_AXIAL_CA = 0.0;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.15;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

#elif LENS_PRESET == 2
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
const float LP_K3 = 0.0;
const float LP_CA = 0.5;
const float LP_AXIAL_CA = 0.6;
const float LP_SOFT_FOCUS = 0.25;
const float LP_SWIRL = 1.0;
const float LP_FIELD_CURVATURE = 0.6;
const float LP_CATS_EYE = 0.55;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.25;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.25;

#elif LENS_PRESET == 3
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
const float LP_K3 = 0.0;
const float LP_CA = 0.6;
const float LP_AXIAL_CA = 1.0;
const float LP_SOFT_FOCUS = 0.45;
const float LP_SWIRL = 0.2;
const float LP_FIELD_CURVATURE = 0.2;
const float LP_CATS_EYE = 0.5;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.15;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.5;
const float LP_RINGING = 0.25;

#elif LENS_PRESET == 4
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
const float LP_K3 = 0.0;
const float LP_CA = 0.4;
const float LP_AXIAL_CA = 0.8;
const float LP_SOFT_FOCUS = 0.6;
const float LP_SWIRL = 2.0;
const float LP_FIELD_CURVATURE = 2.0;
const float LP_CATS_EYE = 0.9;
const float LP_HALATION = 0.1;
const float LP_BOKEH_RIM = 0.4;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;

#elif LENS_PRESET == 5
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
const float LP_K3 = 0.0;
const float LP_CA = 0.35;
const float LP_AXIAL_CA = 0.5;
const float LP_SOFT_FOCUS = 0.25;
const float LP_SWIRL = 0.15;
const float LP_FIELD_CURVATURE = 0.15;
const float LP_CATS_EYE = 0.45;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.1;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

#elif LENS_PRESET == 6
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
const float LP_K3 = 0.0;
const float LP_CA = 0.8;
const float LP_AXIAL_CA = 0.4;
const float LP_SOFT_FOCUS = 0.15;
const float LP_SWIRL = 0.2;
const float LP_FIELD_CURVATURE = 0.3;
const float LP_CATS_EYE = 0.4;
const float LP_HALATION = 0.1;
const float LP_BOKEH_RIM = 0.1;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.15;

/*
 * ---- 特許の処方から計算したオールドレンズ (7-12) ----
 * 歪曲 K1-K3・周辺光量の表・像面の焦点ずれの表・倍率色収差・ゴースト表は処方の光線追跡から求めた値
 * (docs/reference/techniques/vintage-lenses.md, 計算は .work/lens-research と tools/gen_lens_ghosts.py)
 * 表 (LP_RI_*, LP_FIELD_*) は正規化半径 rho = 0, 1/8, ..., 1 (画面の隅 = 135 判の隅, 魚眼は 89.5 度) の 9 点
 * LP_RI_OPEN / LP_RI_STOP: 周辺光量 (中心比) の開放と 2 段絞り。自然減光・瞳収差・口径食を含む
 * LP_FIELD_ZT / LP_FIELD_ZS: 子午・球欠の像面の焦点ずれ (mm, 負 = レンズ側)。±3mm で打ち切る
 * コーティング・絞り羽根・ボケや滲みの強さは処方に無いので、製品の資料と実写の評判から決めた
 */
#elif LENS_PRESET == 7
/*
 * Zeiss Sonnar 50mm F1.5 (Contax, 1932 / 3 群 7 枚, US 2,186,621 Fig. 1)
 * 空気との境界が 6 面だけでゴーストが少なくコントラストが高い。糸巻き歪曲 (隅で +3.3%)
 * 球面収差は補正不足で後ボケが柔らかい。戦後の単層コートと 11 枚羽根
 */
#define LENS_GHOST_TABLE 10
#define LENS_BLADES 11
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 1.5;
const float LP_BLADE_ROUNDNESS = 0.3;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 0.8;
const float LP_STARBURST = 0.6;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.15;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.3;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = -0.0512;
const float LP_K2 = 0.0188;
const float LP_K3 = 0.0004;
// 中間で青い像が大きく (+0.14%)、隅で符号が逆になる。r^2 の 1 項なので中間の値で合わせた
const float LP_CA = -0.28;
const float LP_AXIAL_CA = 1.2;
const float LP_SOFT_FOCUS = 0.3;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 1.0; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = -0.3;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.982, 0.917, 0.814, 0.691, 0.565, 0.437, 0.314, 0.196);
const float LP_RI_STOP[9] = float[9](1.000, 0.992, 0.961, 0.910, 0.851, 0.783, 0.701, 0.567, 0.413);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.012, -0.043, -0.086, -0.128, -0.157, -0.162, -0.145, -0.135);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.019, -0.070, -0.147, -0.234, -0.313, -0.357, -0.335, -0.201);

#elif LENS_PRESET == 8
/*
 * Leica Summilux 35mm F1.4 初代 (1961 / 5 群 7 枚, US 2,975,673 Table 1)
 * 開放のコマと帯状の球面収差による滲み (Leica glow)。歪曲は隅で +0.35% と無いに等しいので再投影しない
 * 強い口径食で周辺の玉ボケはレモン形。10 枚羽根、単層コート
 */
#define LENS_GHOST_TABLE 13
#define LENS_BLADES 10
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 1.4;
const float LP_BLADE_ROUNDNESS = 0.2;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.6;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.3;
const float LP_DIRT = 0.25;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.8;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_K3 = 0.0;
const float LP_CA = -0.18;
const float LP_AXIAL_CA = 0.2;
const float LP_SOFT_FOCUS = 0.6;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 1.25; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.35;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
// 隅の 1 点 (計算では開放 0.015 / 2 段 0.061) は有効半径の推定に引きずられるので、手前の点からなだらかに続く値にした
const float LP_RI_OPEN[9] = float[9](1.000, 0.946, 0.870, 0.764, 0.635, 0.494, 0.341, 0.164, 0.100);
const float LP_RI_STOP[9] = float[9](1.000, 0.988, 0.954, 0.900, 0.832, 0.751, 0.664, 0.460, 0.300);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.008, -0.029, -0.062, -0.103, -0.146, -0.174, -0.153, -0.018);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.020, -0.074, -0.149, -0.223, -0.265, -0.233, -0.074, 0.284);

#elif LENS_PRESET == 9
/*
 * Canon 50mm F1.2 (1956, L39 / 5 群 7 枚, US 2,836,102 Example 2)
 * 開放は低コントラストで柔らかい。周辺は非点隔差が大きく (隅で子午 +1.75mm)、像面が奥へ曲がって背景が流れる
 * 隅の周辺光量は開放で -3.4 EV。11 枚の内側に反った羽根 (丸みを負にして辺をへこませる)、単層コート
 */
#define LENS_GHOST_TABLE 16
#define LENS_BLADES 11
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 1.2;
const float LP_BLADE_ROUNDNESS = -0.3;
const float LP_GHOSTS = 1.6;
const float LP_SCREEN_GHOSTS = 1.3;
const float LP_STARBURST = 0.7;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.35;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 1.1;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = -0.0307;
const float LP_K2 = 0.0235;
const float LP_K3 = 0.0217;
const float LP_CA = 0.48;
const float LP_AXIAL_CA = 1.1;
const float LP_SOFT_FOCUS = 0.45;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 1.15; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.3;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.25;
const float LP_RI_OPEN[9] = float[9](1.000, 0.985, 0.944, 0.892, 0.794, 0.646, 0.473, 0.287, 0.095);
const float LP_RI_STOP[9] = float[9](1.000, 0.997, 0.972, 0.942, 0.901, 0.857, 0.813, 0.707, 0.321);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.014, -0.045, -0.069, -0.043, 0.091, 0.402, 0.961, 1.746);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.018, -0.066, -0.130, -0.185, -0.192, -0.098, 0.186, 0.813);

#elif LENS_PRESET == 10
/*
 * Zeiss Hologon 15mm F8 (1970 / 3 群 3 枚, US 3,661,447 Table I)
 * 対角 110 度の直線写像で歪曲はほぼ 0 (再投影しない)。隅の周辺光量は -2.5 EV (cos^3 に近い)
 * 絞りは中央のレンズの中にある固定 F8 の円形で、羽根は無い。ほぼパンフォーカス。コーティングは未確認 (単層とした)
 */
#define LENS_GHOST_TABLE 19
#define LENS_BLADES 0
#define LENS_FIXED_APERTURE
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 8.0;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.3;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.1;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.4;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_K3 = 0.0;
const float LP_CA = 0.06;
const float LP_AXIAL_CA = 0.4;
const float LP_SOFT_FOCUS = 0.05;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.0;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.950, 0.825, 0.666, 0.515, 0.390, 0.294, 0.223, 0.175);
const float LP_RI_STOP[9] = float[9](1.000, 0.954, 0.829, 0.668, 0.516, 0.391, 0.295, 0.222, 0.175);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.012, -0.037, -0.061, -0.077, -0.094, -0.124, -0.183, -0.276);
const float LP_FIELD_ZS[9] = float[9](0.000, 0.001, 0.001, -0.003, -0.020, -0.057, -0.119, -0.209, -0.324);

#elif LENS_PRESET == 11
/*
 * Carl Zeiss Jena Flektogon 20mm F4 (1963 / 6 群 10 枚のレトロフォーカス, DE 1,192,845 B 実施例 1)
 * 陣笠歪曲: 中ほどで樽型 (33 度で -2.3%)、隅で糸巻き型 (+1.5%) に戻り、水平線やブロックの列が波打つ
 * 隅は設計の画角の外で子午像面が崩れる (隅の流れ)。単層コート。羽根の枚数は未確認 (6 枚とした)
 */
#define LENS_GHOST_TABLE 22
#define LENS_BLADES 6
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 4.0;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.2;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.8;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.25;
const float LP_DIRT = 0.25;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.8;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.1188;
const float LP_K2 = -0.1590;
const float LP_K3 = 0.0250;
const float LP_CA = 0.38;
const float LP_AXIAL_CA = 1.2;
const float LP_SOFT_FOCUS = 0.1;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.25; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.2;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.994, 0.964, 0.896, 0.795, 0.677, 0.552, 0.424, 0.303);
const float LP_RI_STOP[9] = float[9](1.000, 0.989, 0.962, 0.918, 0.854, 0.772, 0.676, 0.555, 0.419);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.065, -0.215, -0.310, -0.037, 1.301, 3.000, 3.000, 3.000);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.030, -0.108, -0.207, -0.269, -0.198, 0.159, 1.060, 2.856);

#elif LENS_PRESET == 12
/*
 * Minolta MC Fish-eye Rokkor-OK 16mm F2.8 (1969- / 7 群 10 枚 + 内蔵フィルター, US 3,589,798 Embodiment II)
 * 対角 180 度の魚眼。像高は r = f sin(0.564 θ) / 0.564 (等立体角より少し正射影寄り)。周辺光量は平坦
 * 倍率色収差が大きい (90 度で -43 um)。コーティングと羽根の枚数は未確認 (単層・6 枚とした)
 */
#define LENS_GHOST_TABLE 25
#define LENS_BLADES 6
#define LENS_PROJECTION 1
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_FISHEYE_K = 0.564;
const float LP_F_OPEN = 2.8;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.7;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.2;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.6;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_K3 = 0.0;
const float LP_CA = 0.41;
const float LP_AXIAL_CA = 1.1;
const float LP_SOFT_FOCUS = 0.05;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.9; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.999, 0.990, 0.980, 0.961, 0.939, 0.891, 0.790, 0.491);
const float LP_RI_STOP[9] = float[9](1.000, 0.996, 0.990, 0.977, 0.959, 0.934, 0.904, 0.856, 0.730);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.016, -0.060, -0.118, -0.167, -0.172, -0.080, 0.154, 0.236);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.009, -0.033, -0.066, -0.096, -0.108, -0.081, -0.003, -0.017);

/*
 * ---- 第 2 弾 (13-18, #51)。値の出し方は 7-12 と同じ (docs/reference/techniques/vintage-lenses.md「第 2 弾」) ----
 * 新しい受け口:
 * LENS_APODIZATION_BETA: ボケの瞳の透過率 exp(-β ρp^2) (STF のアポダイゼーション)。0 なら一様
 * LENS_SOFT_HALO_TABLE: 球面収差のハロー。LP_HALO_SHARE (ハローに行く光の割合) と LP_HALO_RADIUS (半径, 画面の縦比) を
 *   開放から 0 / 1 / 2 / 3 段絞った F 値で持つ (処方の軸上の点像から)
 */
#elif LENS_PRESET == 13
/*
 * Nikon Gyogyotto 20mm F8 (1995 / 2 群 3 枚の魚眼, US 5,949,588 Table 8)
 * 正射影寄りの写像 (r = f sin(0.81 θ) / 0.81)。周辺が Rokkor より強く縮み、球を覗き込んだように写る
 * F8 固定で羽根なし、絞りはレンズの後ろ。空気との境界は 4 面だけ。コーティングは未確認 (マルチとした)
 */
#define LENS_GHOST_TABLE 27
#define LENS_BLADES 0
#define LENS_FIXED_APERTURE
#define LENS_PROJECTION 1
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_FISHEYE_K = 0.81;
const float LP_F_OPEN = 8.0;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.0;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.3;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.1;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.5;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0;
const float LP_K2 = 0.0;
const float LP_K3 = 0.0;
const float LP_CA = 0.43;
const float LP_AXIAL_CA = 0.52;
const float LP_SOFT_FOCUS = 0.05;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.0;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.993, 0.961, 0.911, 0.846, 0.769, 0.645, 0.529, 0.420);
const float LP_RI_STOP[9] = float[9](1.000, 0.993, 0.962, 0.910, 0.846, 0.769, 0.694, 0.627, 0.511);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.036, -0.128, -0.227, -0.248, -0.061, 0.506, 1.573, 2.369);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.017, -0.063, -0.124, -0.172, -0.171, -0.072, 0.154, 0.329);

#elif LENS_PRESET == 14
/*
 * Voigtländer Ultra Wide-Heliar 12mm F5.6 Aspherical (2000 / 8 群 10 枚, JP 2001-124985 A 実施例 1)
 * 121° の直線写像。単純な樽型 (隅で -2.2%)。隅の周辺光量は -3.1 EV で、自然減光が主なので絞っても戻らない
 * 羽根の枚数とコーティングは未確認 (6 枚・マルチとした)
 */
#define LENS_GHOST_TABLE 30
#define LENS_BLADES 6
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 5.6;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.8;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.15;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.4;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0939;
const float LP_K2 = -0.1411;
const float LP_K3 = 0.0710;
const float LP_CA = 0.51;
const float LP_AXIAL_CA = 0.11;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.4; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.955, 0.823, 0.655, 0.497, 0.367, 0.267, 0.188, 0.119);
const float LP_RI_STOP[9] = float[9](1.000, 0.958, 0.825, 0.657, 0.499, 0.370, 0.269, 0.194, 0.146);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.053, 0.005, 0.262, 0.439, 0.439, 0.507, 0.969, 1.740);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.043, -0.106, -0.117, -0.089, -0.054, -0.025, -0.003, 0.005);

#elif LENS_PRESET == 15
/*
 * Canon New FD 14mm F2.8L (1982 / 10 群 14 枚, JP S57-64716 A 実施例 1)
 * 114° の大口径。中ほどで樽型 (48° で -2.8%) のまま隅で -1.5% に戻る陣笠型 (Flektogon と違い糸巻きにならない)
 * 隅は口径食で開放 -3.0 EV、2 段絞ると -1.7 EV。6 枚羽根、マルチコート (S.S.C. の世代、未確認)
 */
#define LENS_GHOST_TABLE 33
#define LENS_BLADES 6
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 2.8;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.8;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.2;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.6;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.1612;
const float LP_K2 = -0.2674;
const float LP_K3 = 0.1232;
const float LP_CA = 0.61;
const float LP_AXIAL_CA = 0.92;
const float LP_SOFT_FOCUS = 0.1;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.6; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 1.001, 0.975, 0.930, 0.904, 0.769, 0.573, 0.321, 0.122);
const float LP_RI_STOP[9] = float[9](1.000, 0.994, 0.968, 0.930, 0.876, 0.815, 0.748, 0.602, 0.303);
const float LP_FIELD_ZT[9] = float[9](0.000, 0.001, -0.041, -0.190, -0.357, -0.349, -0.272, -0.015, 1.625);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.017, -0.071, -0.159, -0.246, -0.277, -0.207, -0.004, 0.305);

#elif LENS_PRESET == 16
/*
 * Minolta AF 135mm F2.8 [T4.5] STF (1999 / 6 群 8 枚 + アポダイゼーションフィルター, JP H11-231209 A 実施例 1)
 * 絞りの後ろの ND ガラスの凹レンズで瞳の周辺ほど暗く、点光源のボケが縁へ向かって溶けて輪郭が出ない (前後とも同じ)
 * 瞳の透過率は製品の T 値 (T4.5 / T6.7) に合う吸収 0.378 /mm のガウス近似 β = 1.96 (特許どおりなら 2.85)
 * 歪曲・周辺光量・像面湾曲はほぼ無い。10 枚の円形絞り、マルチコート
 */
#define LENS_GHOST_TABLE 36
#define LENS_BLADES 10
#define LENS_APODIZATION_BETA 1.96
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 2.8;
const float LP_BLADE_ROUNDNESS = 1.0;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.3;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.1;
const float LP_DIRT = 0.15;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.4;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = -0.0087;
const float LP_K2 = 0.0007;
const float LP_K3 = 0.0;
const float LP_CA = -0.13;
const float LP_AXIAL_CA = 0.78;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.0;
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
const float LP_RI_OPEN[9] = float[9](1.000, 0.995, 0.994, 0.986, 0.980, 0.968, 0.956, 0.942, 0.929);
const float LP_RI_STOP[9] = float[9](1.000, 0.997, 0.994, 0.988, 0.982, 0.970, 0.957, 0.942, 0.925);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.001, -0.003, -0.006, -0.010, -0.015, -0.021, -0.027, -0.034);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.002, -0.010, -0.021, -0.036, -0.053, -0.071, -0.087, -0.101);

#elif LENS_PRESET == 17
/*
 * Pentax SMC FA 28mm F2.8 Soft (1997 / 5 群 5 枚, US 5,822,132 Example 1)
 * 意図的な補正不足の球面収差 (開放で -6.0 mm) で、ピントの合った点にも大きなハローが付く。絞ると急に消える (F5.6 で芯だけ)
 * 補正不足なので後ボケは中心の明るいにじんだ円、前ボケは縁の明るい輪。像面湾曲も強く周辺ほど柔らかい。6 枚羽根、SMC
 */
#define LENS_GHOST_TABLE 39
#define LENS_BLADES 6
#define LENS_SOFT_HALO_TABLE
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 2.8;
const float LP_BLADE_ROUNDNESS = 0.0;
const float LP_GHOSTS = 1.5;
const float LP_SCREEN_GHOSTS = 1.0;
const float LP_STARBURST = 0.6;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.2;
const float LP_DIRT = 0.2;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 0.6;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = 0.0586;
const float LP_K2 = -0.0284;
const float LP_K3 = -0.0028;
const float LP_CA = 0.23;
const float LP_AXIAL_CA = 0.81;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 0.45; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = -0.5;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.2;
// ハロー (F2.8 / 4 / 5.6 / 8): 最良のピント位置での芯の外のエネルギーと、近軸のピント面での 95% 半径 (画面の縦比)
const vec4 LP_HALO_SHARE = vec4(0.72, 0.48, 0.0, 0.0);
const vec4 LP_HALO_RADIUS = vec4(0.0551, 0.0175, 0.0058, 0.0019);
const float LP_RI_OPEN[9] = float[9](1.000, 0.993, 0.972, 0.910, 0.833, 0.748, 0.653, 0.551, 0.448);
const float LP_RI_STOP[9] = float[9](1.000, 0.990, 0.963, 0.927, 0.871, 0.809, 0.739, 0.665, 0.621);
const float LP_FIELD_ZT[9] = float[9](-0.002, -0.037, -0.141, -0.308, -0.534, -0.818, -1.168, -1.610, -2.057);
const float LP_FIELD_ZS[9] = float[9](-0.002, -0.022, -0.079, -0.167, -0.278, -0.397, -0.506, -0.582, -0.599);

#elif LENS_PRESET == 18
/*
 * Canon 50mm F0.95 (1961 / 5 群 7 枚, JP S39-10178 実施例 1)
 * 開放の隅は -4.0 EV (実測 -4.2 EV) と最も暗く、2 段絞ると -2.1 EV に戻る。樽型の歪曲、隅の倍率色収差 -99 um
 * 開放のグローはコマなど軸外の収差によるもので処方の軸上の点像からは出ないので、実写に合わせて目で決め F1.4 で 0 にした
 * 10 枚羽根、単層コート (未確認)
 */
#define LENS_GHOST_TABLE 43
#define LENS_BLADES 10
#define LENS_SOFT_HALO_TABLE
#define LENS_RI_TABLE
#define LENS_FIELD_TABLE
const float LP_F_OPEN = 0.95;
const float LP_BLADE_ROUNDNESS = 0.3;
const float LP_GHOSTS = 1.6;
const float LP_SCREEN_GHOSTS = 1.3;
const float LP_STARBURST = 0.7;
const float LP_STAR_SIZE = 1.0;
const float LP_HALO = 0.35;
const float LP_DIRT = 0.3;
const float LP_DIRT_CONTRAST = 0.5;
const float LP_VEILING_GLARE = 1.1;
const float LP_STREAK = 0.0;
const vec3 LP_STREAK_TINT = vec3(0.4, 0.65, 1.0);
const float LP_SQUEEZE = 1.0;
const float LP_K1 = -0.0237;
const float LP_K2 = 0.0123;
const float LP_K3 = 0.0319;
const float LP_CA = 0.96;
const float LP_AXIAL_CA = 0.86;
const float LP_SOFT_FOCUS = 0.0;
const float LP_SWIRL = 0.0;
const float LP_FIELD_CURVATURE = 0.0;
const float LP_CATS_EYE = 1.1; // 処方の開放の光束の縦横比 (隅の手前) から
const float LP_HALATION = 0.0;
const float LP_BOKEH_RIM = 0.0;
const float LP_SA_RIM = 0.15;
const float LP_YELLOWING = 0.0;
const float LP_RINGING = 0.25;
// グロー (F0.95 / 1.34 / 1.9 / 2.7): 目で決めた値。1 段 (F1.4 付近) で 0
const vec4 LP_HALO_SHARE = vec4(0.35, 0.0, 0.0, 0.0);
const vec4 LP_HALO_RADIUS = vec4(0.012, 0.006, 0.003, 0.002);
const float LP_RI_OPEN[9] = float[9](1.000, 0.993, 0.929, 0.829, 0.716, 0.594, 0.461, 0.278, 0.061);
const float LP_RI_STOP[9] = float[9](1.000, 0.996, 0.978, 0.951, 0.923, 0.890, 0.860, 0.720, 0.227);
const float LP_FIELD_ZT[9] = float[9](0.000, -0.027, -0.100, -0.193, -0.265, -0.249, -0.037, 0.552, 1.438);
const float LP_FIELD_ZS[9] = float[9](0.000, -0.023, -0.087, -0.172, -0.247, -0.259, -0.123, 0.330, 1.186);

#else
// カスタム (LENS_PRESET 0): 個別スライダー (LENS_C_*) をそのまま使う
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
#define LENS_PROJECTION LENS_C_PROJECTION
const float LP_FISHEYE_K = LENS_C_FISHEYE_K;
const float LP_K1 = LENS_C_DISTORTION;
const float LP_K2 = LENS_C_DISTORTION2;
const float LP_K3 = 0.0;
const float LP_CA = LENS_C_CA;
const float LP_AXIAL_CA = LENS_C_AXIAL_CA;
const float LP_SOFT_FOCUS = LENS_C_SOFT_FOCUS;
const float LP_SWIRL = LENS_C_SWIRL;
const float LP_FIELD_CURVATURE = LENS_C_FIELD_CURVATURE;
const float LP_CATS_EYE = LENS_C_CATS_EYE;
const float LP_HALATION = LENS_C_HALATION;
const float LP_BOKEH_RIM = LENS_C_BOKEH_RIM;
const float LP_SA_RIM = 0.0;
const float LP_YELLOWING = LENS_C_YELLOWING;
const float LP_RINGING = 0.2;
#define LENS_APODIZATION_BETA LENS_C_APODIZATION
#endif

// 写像: 0 = 直線 (ゲームの描画のまま + 歪曲収差), 1 = 魚眼 (final で再投影する)
#ifndef LENS_PROJECTION
#define LENS_PROJECTION 0
#endif

// ボケの瞳の透過率 exp(-β ρp^2) の β (0 = 一様。DoF の composite22 が使う)
#ifndef LENS_APODIZATION_BETA
#define LENS_APODIZATION_BETA 0.0
#endif
const float LP_APODIZATION = LENS_APODIZATION_BETA;

/*
 * 太陽・月のフレアを出力 (再投影の後) の座標で描く。ゴーストは像面の現象なので、光源の位置も出力へ写す
 * 処方以前からのプリセット (0 カスタム, 1-6) は見た目を変えないため、元画像の座標のまま描く
 */
#if LENS_PROJECTION == 1 || LENS_PRESET >= 7
#define LENS_FLARE_OUTPUT_SPACE
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
