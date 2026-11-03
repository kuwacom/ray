/*
 * 雲の形のプリセット: CLOUD_STYLE から低層の雲の基準値 CS_* を決める (cloud_constants.glsl の先頭で読む)
 * 既存の CLOUD_* の設定は CS_* に掛ける微調整 (ルックのプリセット look_presets.glsl と同じ考え方)。Ray の CS_* は雲量以外 1 なので、
 * Ray では各設定の値がそのまま効く
 * 雨の日の扱い: バニラの形 (CLOUD_RAIN_KEEPS_SHAPE) は雨でも雷雨でも板の形・量・濃さ・光を保ち、雨天度は雲の光 (曇天の色と拡散) と濃さの倍率だけに効かせる。
 * ほかの形は雲量・濃さ・光の値を晴天の雲だけに効かせ、雨雲・雷雨は雨天度で Ray の値へ戻す (どの形でも雨の空は同じ)
 * 番号: 0 = カスタム (最後の #else, CLOUD_S_*)、1 = Ray (既定)。新しいスタイルは後ろに足し、既存の番号は変えない
 *
 * 値の意味
 *   CS_LOW_COVER / CS_MID_COVER / CS_HIGH_COVER: 低層・中層・上層の雲量の倍率 (バニラの形以外は、雨の日の雲量には掛けない)
 *   CS_SIZE: 低層の雲ひとつの水平の大きさ, CS_HEIGHT: 積雲の背丈, CS_CONVECTION: 対流の強さ (積雲の発達と雲種)
 *   CS_TYPE_SHIFT: 雲種のずらし (負で層積雲へ), CS_SPACING: 大きな雲のまわりの晴れ間の広さ
 *   CS_LOBES: こぶの段 (塔の塊・中間のこぶの削り), CS_EROSION: 縁の細かい浸食, CS_BASE_RAGGED: 雲底のちぎれ (小さいほど平らな底)
 *   CS_FRACTUS: 断片雲, CS_HAZE: 縁の外のもや, CS_EDGE: 縁の柔らかさ (立ち上がりの幅)
 *   CS_DENSITY: 雲全体の濃さ (バニラの形は、雨の濃さの倍率がこれを上回る分だけ雨で濃くなる), CS_CORE: 芯の濃さ
 *   CS_LOBE_SHADE: こぶの陰の深さ (置き換え), CS_SILVER: 逆光の銀の縁, CS_POWDER: 順光の縁の暗さ,
 *   CS_SUN: 雲に当たる日光の強さ (空に対する雲の明るさ), CS_MS: 多重散乱 (日向の明るさ), CS_AMBIENT: 空の光, CS_BASE_SHADE: 雲底の暗さ
 *   CLOUD_VANILLA_SHAPE (マクロ): バニラの雲と同じ場所・格子の角ばった体積雲。積雲の 3D の形・中層・上層・積乱雲は描かない。
 *   格子・厚み・高さ・流れはバニラで決まるので、CS_* には板の寸法を持たない。写実の層の値 (CS_*_COVER、CS_SIZE など) は効かない
 */
#ifndef SKY_CLOUD_STYLES_GLSL
#define SKY_CLOUD_STYLES_GLSL

//@include "/lib/settings.glsl"

#if CLOUDS == 3 && (CLOUD_STYLE == 3 || (CLOUD_STYLE == 0 && CLOUD_S_SHAPE == 1))
    #define CLOUD_VANILLA_SHAPE
    // バニラの形は雨でも板の形と量のまま、雨は光・濃さ・空・日差し・雲影で表す。ほかの形は雨で全天の雨雲へ移る
    #define CLOUD_RAIN_KEEPS_SHAPE
#endif

#if CLOUD_STYLE == 1
// Ray: 雲量のほかは各設定がそのまま効く基準
const float CS_LOW_COVER = 0.75;
const float CS_MID_COVER = 0.7;
const float CS_HIGH_COVER = 0.8;
const float CS_SIZE = 1.0;
const float CS_HEIGHT = 1.0;
const float CS_CONVECTION = 1.0;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.0;
const float CS_LOBES = 1.0;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = 1.0;
const float CS_FRACTUS = 1.0;
const float CS_HAZE = 1.0;
const float CS_EDGE = 1.0;
const float CS_DENSITY = 1.0;
const float CS_CORE = 1.0;
const float CS_LOBE_SHADE = 0.3;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.0;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.0;

#elif CLOUD_STYLE == 2
// Bliss 風: 小さめの塊がまばらに浮かび、縁はほつれて粉っぽい。芯は不透明で、日向の頂は白く陰の側は青灰色に沈む
const float CS_LOW_COVER = 0.6;
const float CS_MID_COVER = 1.0;
const float CS_HIGH_COVER = 0.8;
const float CS_SIZE = 0.7;
const float CS_HEIGHT = 0.65;
const float CS_CONVECTION = 1.0;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.25;
const float CS_LOBES = 1.1;
const float CS_EROSION = 1.2;
const float CS_BASE_RAGGED = 1.5;
const float CS_FRACTUS = 1.0;
const float CS_HAZE = 0.6;
const float CS_EDGE = 0.8;
const float CS_DENSITY = 1.0;
const float CS_CORE = 1.6;
const float CS_LOBE_SHADE = 0.38;
const float CS_SILVER = 1.3;
const float CS_POWDER = 1.2;
const float CS_SUN = 1.0;
const float CS_MS = 1.15;
const float CS_AMBIENT = 0.95;
const float CS_BASE_SHADE = 1.1;

#elif CLOUD_STYLE == 3
// バニラの形: バニラの雲と同じ高さ・12 ブロックの格子・模様・流れの、角ばった体積雲。
// 写実の層は描かないので、雲量・大きさ・こぶ・もや・濃さの値は使われない
// 光の絞りは cloud_vanilla.glsl の VANILLA_CLOUD_* (バニラの形ならどのスタイルでも同じ)
const float CS_LOW_COVER = 0.75;
const float CS_MID_COVER = 0.7;
const float CS_HIGH_COVER = 0.5;
const float CS_SIZE = 1.0;
const float CS_HEIGHT = 1.0;
const float CS_CONVECTION = 1.0;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.0;
const float CS_LOBES = 1.0;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = 1.0;
const float CS_FRACTUS = 1.0;
const float CS_HAZE = 1.0;
const float CS_EDGE = 1.0;
const float CS_DENSITY = 1.0;
const float CS_CORE = 1.0;
const float CS_LOBE_SHADE = 0.0;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.0;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.0;

#elif CLOUD_STYLE == 4
// 現実に忠実: 積雲の芯の実測に近い消散係数 (0.03-0.05 /m)、晴天積雲の雲量 3-5 割。見た目の押し出し (銀の縁・powder) は位相関数と多重散乱だけに任せる
const float CS_LOW_COVER = 0.7;
const float CS_MID_COVER = 0.6;
const float CS_HIGH_COVER = 1.0;
const float CS_SIZE = 1.0;
const float CS_HEIGHT = 0.85;
const float CS_CONVECTION = 1.0;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.0;
const float CS_LOBES = 1.0;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = 1.0;
const float CS_FRACTUS = 0.6;
const float CS_HAZE = 0.3;
const float CS_EDGE = 0.85;
const float CS_DENSITY = 3.5;
const float CS_CORE = 1.5;
const float CS_LOBE_SHADE = 0.3;
const float CS_SILVER = 0.0;
const float CS_POWDER = 0.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.0;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.0;

#elif CLOUD_STYLE == 5
// 綿あめ: 縁のもやが広く、芯まで柔らかく透ける丸い雲。陰は浅く、明るいパステル寄りの白
const float CS_LOW_COVER = 0.75;
const float CS_MID_COVER = 0.5;
const float CS_HIGH_COVER = 0.6;
const float CS_SIZE = 1.1;
const float CS_HEIGHT = 0.8;
const float CS_CONVECTION = 1.0;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.0;
const float CS_LOBES = 0.5;
const float CS_EROSION = 0.35;
const float CS_BASE_RAGGED = 0.5;
const float CS_FRACTUS = 0.5;
const float CS_HAZE = 2.5;
const float CS_EDGE = 1.8;
const float CS_DENSITY = 0.6;
const float CS_CORE = 0.5;
const float CS_LOBE_SHADE = 0.1;
const float CS_SILVER = 1.5;
const float CS_POWDER = 0.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.4;
const float CS_AMBIENT = 1.4;
const float CS_BASE_SHADE = 0.4;

#elif CLOUD_STYLE == 6
// 入道雲: 背の高い雄大積雲が間を空けて立つ。輪郭がくっきりし、日向の白と陰の青灰色の差が大きく、底は平らで暗い
const float CS_LOW_COVER = 0.55;
const float CS_MID_COVER = 0.3;
const float CS_HIGH_COVER = 0.6;
const float CS_SIZE = 1.0;
const float CS_HEIGHT = 1.6;
const float CS_CONVECTION = 1.6;
const float CS_TYPE_SHIFT = 0.1;
const float CS_SPACING = 1.3;
const float CS_LOBES = 1.0;
const float CS_EROSION = 0.5;
const float CS_BASE_RAGGED = 0.7;
const float CS_FRACTUS = 0.3;
const float CS_HAZE = 0.15;
const float CS_EDGE = 0.5;
const float CS_DENSITY = 1.5;
const float CS_CORE = 1.5;
const float CS_LOBE_SHADE = 0.5;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.4;
const float CS_AMBIENT = 1.2;
const float CS_BASE_SHADE = 1.3;

#elif CLOUD_STYLE == 7
// まばらな晴天積雲: 背の低い小さな扁平雲が広い青空に散らばる
const float CS_LOW_COVER = 0.4;
const float CS_MID_COVER = 0.3;
const float CS_HIGH_COVER = 0.7;
const float CS_SIZE = 0.6;
const float CS_HEIGHT = 0.45;
const float CS_CONVECTION = 0.6;
const float CS_TYPE_SHIFT = 0.0;
const float CS_SPACING = 1.4;
const float CS_LOBES = 0.9;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = 1.0;
const float CS_FRACTUS = 0.6;
const float CS_HAZE = 0.7;
const float CS_EDGE = 1.0;
const float CS_DENSITY = 1.0;
const float CS_CORE = 1.0;
const float CS_LOBE_SHADE = 0.3;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.0;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.0;

#elif CLOUD_STYLE == 8
// 層積雲の曇り: 平たい塊とロールが空の大半を覆い、所々の切れ間から青空がのぞく
const float CS_LOW_COVER = 1.35;
const float CS_MID_COVER = 1.2;
const float CS_HIGH_COVER = 0.4;
const float CS_SIZE = 1.2;
const float CS_HEIGHT = 1.0;
const float CS_CONVECTION = 0.4;
const float CS_TYPE_SHIFT = -0.6;
const float CS_SPACING = 1.0;
const float CS_LOBES = 1.0;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = 1.0;
const float CS_FRACTUS = 1.0;
const float CS_HAZE = 1.0;
const float CS_EDGE = 1.0;
const float CS_DENSITY = 1.3;
const float CS_CORE = 1.0;
const float CS_LOBE_SHADE = 0.2;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = 1.0;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.2;

#else
// カスタム (CLOUD_STYLE 0): スタイルにしか無い値は CLOUD_S_*、既存の設定があるものは Ray の基準 (設定がそのまま効く)
const float CS_LOW_COVER = 0.75;
const float CS_MID_COVER = 0.7;
const float CS_HIGH_COVER = 0.8;
const float CS_SIZE = 1.0;
const float CS_HEIGHT = CLOUD_S_HEIGHT;
const float CS_CONVECTION = CLOUD_S_CONVECTION;
const float CS_TYPE_SHIFT = CLOUD_S_TYPE_SHIFT;
const float CS_SPACING = CLOUD_S_SPACING;
const float CS_LOBES = CLOUD_S_LOBES;
const float CS_EROSION = 1.0;
const float CS_BASE_RAGGED = CLOUD_S_BASE_RAGGED;
const float CS_FRACTUS = 1.0;
const float CS_HAZE = 1.0;
const float CS_EDGE = 1.0;
const float CS_DENSITY = 1.0;
const float CS_CORE = 1.0;
const float CS_LOBE_SHADE = CLOUD_S_LOBE_SHADE;
const float CS_SILVER = 1.0;
const float CS_POWDER = 1.0;
const float CS_SUN = 1.0;
const float CS_MS = CLOUD_S_MULTISCATTER;
const float CS_AMBIENT = 1.0;
const float CS_BASE_SHADE = 1.0;
#endif

#endif
