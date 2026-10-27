/*
 * フォグ (sky モジュール)
 * 3 つの層を同じパラメータから作る
 *   1. 空中遠近 (aerial perspective): 遠景が空の色 (SkyView LUT) に溶ける。空との境目が必ず一致する
 *   2. 高さフォグ: もや (海面からの指数減衰, Kappa / Nostalgia の 2 成分モデル) + 地表の霧 (FOG_MIST, 3D ノイズ)
 *      VL ON なら composite10 が影マップ空間でマーチ、OFF なら解析積分 (指数高さフォグの閉形式)
 *   3. 描画距離端のフォグ: 地形の端を空へ溶かす
 * 景色の成分 (もやと空中遠近) は、遠景が同じ方位の地平線の空の色へ収束するように内散乱を空の色から作り、
 * 描画距離 R の端で光学的深さが FOG_EDGE_DEPTH になるよう距離を d (1 + d / D) に写して縮める (手前の霞み方は R によらない)。
 * 地表の霧は縮めない (霧の中の距離は本当の距離で見える)
 * 不透明・半透明の大半は composite10/11 (sky のパス) でまとめて掛ける
 * 前方シェーディングのパーティクル・雨もまとめ掛けに含まれる (個別のフォグは掛けない)
 */
#ifndef SKY_FOG_GLSL
#define SKY_FOG_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/sky/sky_color.glsl"

#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"

/*
 * もや: 上端のある混合層 (上端は FOG_T_HAZE_TOP、ロジスティックで柔らかく) + 上に残る薄いもや (FOG_HAZE_FREE_SHARE)
 * 上端は朝と夜に低く、昼に雲底の 3/4 まで上がる (現実の混合層は朝夜 100-500 m、昼 1-2 km で積雲の雲底とほぼ同じ)
 */
const float FOG_HAZE_DENSITY = 5.0e-4;   // 晴れた昼の海面のもやの消散係数 (1/ブロック, 視程 約 8 km 相当)
const float FOG_HAZE_FREE_SHARE = 0.1;   // 上端より上に残る薄いもやの割合
// 時間帯の倍率 (夜明け前・朝・夕・夜) はスタイルごと (fog_styles.glsl)
// 上端の高さ (昼の厚みに対する割合)
const float FOG_HAZE_TOP_MORNING = 0.5;
const float FOG_HAZE_TOP_EVENING = 0.75;
const float FOG_HAZE_TOP_NIGHT = 0.5;
// 太陽が低い (朝夕) とみなす高さ (sin 15 度) と、夜とみなす高さ (sin -12 度)
const float FOG_LOW_SUN_Y = 0.26;
const float FOG_NIGHT_SUN_Y = -0.21;
// 雨・雪のもやの倍率。5 では雨の中景 (50-150 ブロック) の地形が白いもやに埋もれ、空の重さに対して地上だけ明るく白っぽく見えた
const float FOG_HAZE_RAIN = 1.6;
const float FOG_HAZE_SNOW = 2.5;
const float FOG_CAVE_DENSITY = 2.5;      // 海面より深い所 (洞窟) の空気の濁りの倍率
const float FOG_CAVE_DEPTH = 32.0;       // 海面からこの深さで洞窟の倍率に達する
/*
 * 中くらいの高さの霧の層 (霧の土手): 上下の面のある帯。濃さ FOG_LAYER_DENSITY に、時間帯で変わる雲量の割合だけ
 * FOG_LAYER_SCALE ブロックの大きさの塊が浮かぶ。光学的深さ 0.3-1.5 で光芒が最もよく見える
 */
const float FOG_LAYER_DENSITY = 4.0e-3;
const float FOG_LAYER_SCALE = 450.0;
const float FOG_LAYER_DRIFT = 0.6;       // 塊の流れる速さ (ブロック/秒)
// 時間帯ごとの雲量 (朝 / 昼 / 夕 / 夜 / 雨)
const float FOG_LAYER_COVER_MORNING = 0.4;
const float FOG_LAYER_COVER_NOON = 0.15;
const float FOG_LAYER_COVER_EVENING = 0.3;
const float FOG_LAYER_COVER_NIGHT = 0.3;
const float FOG_LAYER_COVER_RAIN = 0.7;
// 塊の縁の柔らかさ (雲量の閾値の幅)
const float FOG_LAYER_EDGE = 0.18;
/*
 * 地表の霧 (放射霧・谷霧): 海面から FOG_T_GROUND_TOP までに溜まる。夜に増え、明け方に最大、日の出から約 2 時間 (sunAngle 0.08) で消える
 * 晴れて湿った日ほど濃い (日替わりの湿度)
 */
const float FOG_GROUND_DAWN = 6.0e-3;
const float FOG_GROUND_EVENING = 2.0e-3;
const float FOG_GROUND_NIGHT = 4.0e-3;
const float FOG_GROUND_RAIN = 3.0e-3;
const float FOG_GROUND_BURN_OFF = 0.08;  // 日の出からこの sunAngle で消える
// 3D ノイズの濃淡で薄い所が抜けるので、ノイズの閾値を超えた所の濃さはこの倍率にする (平均で上の値に近くなる)
const float FOG_GROUND_PEAK = 2.0;
// ノイズの濃淡を含めた地表の霧の平均の割合 (解析積分で使う)
const float FOG_GROUND_NOISE_MEAN = 0.35;
const vec3 FOG_HAZE_TINT = vec3(0.88, 0.94, 1.0); // もやの散乱色 (わずかにレイリー寄りの青)
const float FOG_ALBEDO = 0.95;
// 空中遠近を実際の大気の何倍の濃さで掛けるか (描画距離は数百ブロックしかないので誇張する)
const float AERIAL_PERSPECTIVE_SCALE = 10.0;
const float AERIAL_PERSPECTIVE_RAIN = 1.5;
// 描画距離に対する割合。端の霞みは景色の成分の写像 (FOG_EDGE_DEPTH) が作り、その先は虚空 (skyBelowHorizon) が同じ式で続けるので、
// 端のフォグは地形の切れ目を隠すだけにする
const float BORDER_FOG_START = 0.95;

/*
 * 景色の成分の距離の写像 d (1 + (d / D)^2)
 * 手前から描画距離の中ほどまではほぼ本当の距離のまま霞み、端に近づくほど強く縮めて、描画距離の外の遠景の霞みを端の手前に入れる。
 * d (1 + d / D) では D が描画距離の 1/4 ほどになり、高い所から見下ろす中景 (描画距離の半分前後) まで白く霞んだ
 * FOG_EDGE_DEPTH: 晴れた昼に y FOG_SCENIC_REF_Y から水平に見た描画距離の端の光学的深さ。尾根の重なりが読める濃さ
 * FOG_SCENIC_SIGMA0: その高さの景色の成分の消散 (もや + 空中遠近の緑)。D はこれと R から決める
 */
const float FOG_EDGE_DEPTH = FS_EDGE;
const float FOG_SCENIC_REF_Y = 70.0;
const float FOG_SCENIC_SIGMA0 = FOG_HAZE_DENSITY * FS_HAZE * (1.0 + FOG_HAZE_FREE_SHARE)
    + (13.558e-3 + ATMO_MIE_EXTINCT * exp(-(FOG_SCENIC_REF_Y - FOG_T_SEA) * FOG_T_LIGHT_SCALE * 1e-3 / ATMO_MIE_HEIGHT)) * 1e-3 * AERIAL_PERSPECTIVE_SCALE;
// (R / D)^2 の上限。短い描画距離で中景まで急に霞まないように
const float FOG_SCENIC_MAX_STRETCH = 20.0;
// 遠景の空の色のうち、太陽の単散乱とみなして影で引いてよい割合の上限 (残りは多重散乱と空の光)
const float FOG_HAZE_SUN_SHARE = 0.8;
// 影の中のもやに残す空の色の割合の下限
const float FOG_HAZE_SHADOW_FLOOR = 0.1;
// 日の当たるもやと霧の太陽の分の強さ (光芒の強さ x スタイルの前方の輝き)
const float FOG_VL_STRENGTH = VL_STRENGTH * FS_FORWARD;
// もやの上端の柔らかさ (テンプレート x スタイル)
const float FOG_HAZE_SOFT = FOG_T_HAZE_SOFT * FS_HAZE_SOFT;

/*
 * バイオームのフォグの倍率 (FOG_BIOME): x = もや, y = 霧の層, z = 地表の霧
 * 湿地とジャングルは湿って霧が多く、砂漠・荒地は砂塵のもやだけ、雪原はもやが薄く明け方の氷霧、海は谷霧が少ない
 */
vec3 fogBiomeScale() {
#ifdef FOG_BIOME
    vec3 s = vec3(1.0);
    s = mix(s, vec3(1.3, 1.5, 2.5), saturate(fogSwamp));
    s = mix(s, vec3(1.5, 1.5, 1.5), saturate(fogJungle));
    s = mix(s, vec3(1.2, 0.3, 0.0), saturate(distantSand));
    s = mix(s, vec3(0.6, 0.8, 1.2), saturate(distantSnow));
    s = mix(s, vec3(1.1, 1.0, 0.5), saturate(distantOcean));
    return s;
#else
    return vec3(1.0);
#endif
}

/*
 * ネザーの霧は煤混じりの煙として、環境光より暗く (アルベド低め) 薄く掛ける。
 * 0.010 / 0.6 では 30 ブロック先で地形の倍の明るさの赤い霧になり、地面の細部と溶岩の色が消えた
 * 色と明るさはバイオームごと (sky_color.glsl getNetherPalette)。手前 NETHER_FOG_CLEAR_DIST までは濃さを 0 から立ち上げ、
 * 足元から中景の細部を残して奥だけを霞ませる (iterationT の霧も手前を抜いている)
 */
const float NETHER_FOG_EXTINCTION = 0.008;
const float NETHER_FOG_CLEAR_DIST = 32.0;
const float END_FOG_EXTINCTION = 0.0025;
const vec3 END_FOG_COLOR = vec3(0.30, 0.22, 0.45);

// 水中の係数は水面側 (lib/common/water.glsl) の waterAbsorption / waterScattering を共有する (上から見た水と潜った時の色を揃える)
const vec3 FOG_LAVA_EXTINCTION = vec3(1.6);
const vec3 FOG_LAVA_RADIANCE = vec3(1.0, 0.30, 0.04) * 1.5;
const vec3 FOG_POWDER_SNOW_EXTINCTION = vec3(1.2);
const float BLINDNESS_FOG_EXTINCTION = 0.6;

/*
 * VL の低解像度バッファ (composite10 -> composite11)
 * 低解像度テクセル q はフル解像度の q * VL_RES + VL_RES / 2 のピクセルで計算する (アップサンプル側が同じ深度を引けるように)
 * 時間蓄積は colortex12 と fogHistoryImg をフレームの偶奇で交互に書く (偶数フレームは colortex12)
 */
ivec2 vlLowResSize() { return (ivec2(viewWidth, viewHeight) + VL_RES - 1) / VL_RES; }
ivec2 vlSampleTexel(ivec2 lowTexel) { return min(lowTexel * VL_RES + VL_RES / 2, ivec2(viewWidth, viewHeight) - 1); }
bool vlWritesColortex12() { return (frameCounter & 1) == 0; }

float fogRainFactor() { return max(rainStrength, wetness * 0.4); }

/*
 * フォグを積む描画距離 R (空の画素はここまで積み、景色の成分の写像もこれで決まる)
 * Distant Horizons に対応する時は、ここを DH の描画距離にする。その時は σ0 R が FOG_EDGE_DEPTH を超えるので縮めず (D = 無限)、
 * 代わりに景色の成分の濃さを FOG_EDGE_DEPTH / R まで下げる (docs/architecture.md「フォグ」)
 */
float fogRenderDistance() { return far; }

// 景色の成分の写像の 1 / D。物理のままで端の光学的深さが FOG_EDGE_DEPTH に届くなら 0 (縮めない)
float fogScenicInvD() {
    float R = fogRenderDistance();
    float ratio = FOG_EDGE_DEPTH / (FOG_SCENIC_SIGMA0 * R);
    return sqrt(min(max(ratio - 1.0, 0.0), FOG_SCENIC_MAX_STRETCH)) / R;
}

// 景色の成分の写像した距離 d (1 + (d / D)^2) と、その d の微分 (レイマーチの 1 歩の重み)
float fogScenicDistance(float d, float invD) { return d * (1.0 + sqr(d * invD)); }
float fogScenicStretch(float d, float invD) { return 1.0 + 3.0 * sqr(d * invD); }

float fogSoftplus(float x) { return max(x, 0.0) + log(1.0 + exp(-abs(x))); }
// 上端 top、幅 w のロジスティック (下で 1、上で 0) と、その y の原始関数 (閉形式で光学的深さを出す)
float fogLogistic(float y, float top, float w) { return 1.0 / (1.0 + exp((y - top) / w)); }
float fogLogisticIntegral(float y, float top, float w) { return y - w * fogSoftplus((y - top) / w); }

/*
 * 視線ごとに 1 回だけ決める媒質の量 (時間帯・天気・バイオームの湿度)
 * haze: もやの上端より下の消散係数 (1/ブロック), hazeTop: もやの上端 (y)
 * layer: 霧の層の塊の中の消散係数, layerCover: 霧の層の雲量 (0..1), mist: 地表の霧の濃い所の消散係数
 */
struct FogMedium {
    float haze;
    float hazeTop;
    float layer;
    float layerCover;
    float mist;
};

FogMedium fogMedium() {
    FogMedium m;
    float sunY = getSunDir().y;
    // 日の出から正午までと、真夜中から日の出までを「朝の側」とする (切り替わる正午と真夜中では下の重みが 0 か 1 なので段差は出ない)
    float rising = (sunAngle > 0.75 || sunAngle < 0.25) ? 1.0 : 0.0;
    float lowSun = 1.0 - smoothstep(0.0, FOG_LOW_SUN_Y, sunY);
    float night = 1.0 - smoothstep(FOG_NIGHT_SUN_Y, 0.0, sunY);
    float dawn = smoothstep(0.85, 0.97, sunAngle);
    float rain = fogRainFactor();
    vec3 region = climateFogRegion();
    float humidity = climateHumidity();
    vec3 biome = fogBiomeScale();

    float k = mix(1.0, mix(FS_HAZE_EVENING, FS_HAZE_MORNING, rising), lowSun);
    k = mix(k, mix(FS_HAZE_NIGHT, FS_HAZE_DAWN, dawn), night);
    k *= mix(1.0, mix(FOG_HAZE_RAIN, FOG_HAZE_SNOW, saturate(distantSnow)), rain);
    k *= 0.8 + 0.4 * saturate(rainfall);
    m.haze = FOG_HAZE_DENSITY * FS_HAZE * LOOK_FOG_DENSITY * k * region.x * biome.x;

    float top = mix(1.0, mix(FOG_HAZE_TOP_EVENING, FOG_HAZE_TOP_MORNING, rising), lowSun);
    top = mix(top, FOG_HAZE_TOP_NIGHT, night);
    // 雨の日は雲底まで混ざる
    top = mix(top, 1.0, rain);
    m.hazeTop = FOG_T_SEA + top * FS_HAZE_TOP * (FOG_T_HAZE_TOP - FOG_T_SEA);

#ifdef FOG_LAYER
    float cover = mix(FOG_LAYER_COVER_NOON, mix(FOG_LAYER_COVER_EVENING, FOG_LAYER_COVER_MORNING, rising), lowSun);
    cover = mix(cover, mix(FOG_LAYER_COVER_NIGHT, FOG_LAYER_COVER_MORNING, dawn), night);
    // 湿った日ほど多く、雨の日は一面に広がる
    cover = saturate(cover * mix(0.5, 1.5, humidity) * region.y * biome.y * FS_LAYER_COVER);
    m.layerCover = mix(cover, max(cover, FOG_LAYER_COVER_RAIN), rain);
    m.layer = FOG_LAYER_DENSITY * LOOK_FOG_DENSITY * FS_LAYER;
#else
    m.layerCover = 0.0;
    m.layer = 0.0;
#endif

#ifdef FOG_MIST
    // 朝の側の日中は日の出からの時間で消える。日の出前 (sunAngle が 1 に近い) は夜の側の値を使う
    float sinceSunrise = sunAngle < 0.5 ? sunAngle : 0.0;
    float dayMist = rising > 0.5 ? FOG_GROUND_DAWN * (1.0 - smoothstep(0.0, FOG_GROUND_BURN_OFF, sinceSunrise)) : FOG_GROUND_EVENING * FS_GROUND_EVENING * lowSun;
    float ground = mix(dayMist, mix(FOG_GROUND_NIGHT * FS_GROUND_NIGHT, FOG_GROUND_DAWN, dawn), night);
    // 放射霧は晴れて湿った夜にでき、雨の後の朝は濃い
    ground *= mix(0.25, 1.5, humidity) * (1.0 + 0.5 * climateClearDay()) * (1.0 + 0.5 * wetness);
    ground += FOG_GROUND_RAIN * rain;
    m.mist = ground * FOG_GROUND_PEAK * LOOK_FOG_DENSITY * region.z * biome.z * FS_GROUND;
#else
    m.mist = 0.0;
#endif
    return m;
}

// 霧の層の雲量の塊 (0..1)。平均が cover になるよう、2 オクターブの値ノイズを閾値で切る
float fogLayerCoverAt(vec2 worldXZ, float cover) {
    if (cover >= 0.999) return 1.0;
    vec2 q = (worldXZ + frameTimeCounter * FOG_LAYER_DRIFT) / FOG_LAYER_SCALE;
    float n = valueNoise3d(vec3(q, 0.5)) * 0.7 + valueNoise3d(vec3(q * 2.7 + 7.3, 1.5)) * 0.3;
    // 2 オクターブの和は中央に寄るので、閾値を雲量から分布の幅に合わせて決める
    float threshold = 0.5 + (0.5 - cover) * 0.6;
    return smoothstep(threshold - FOG_LAYER_EDGE, threshold + FOG_LAYER_EDGE, n);
}

// 霧の層の帯 (下面と上面の間で 1)
float fogLayerBand(float y) {
    return fogLogistic(y, FOG_T_LAYER_TOP, FOG_T_LAYER_SOFT) - fogLogistic(y, FOG_T_LAYER_BASE, FOG_T_LAYER_SOFT);
}

// 海面より深い所 (洞窟) の空気の濁りの倍率
float fogCaveScale(float y) { return mix(1.0, FOG_CAVE_DENSITY, saturate((FOG_T_SEA - y) / FOG_CAVE_DEPTH)); }

// 上に残る薄いもやの y の原始関数 (海面より下は一定として連続につなぐ)
float fogHazeFreeIntegral(float y) {
    float h = y - FOG_T_SEA;
    return h <= 0.0 ? h - FOG_T_HAZE_FREE : -FOG_T_HAZE_FREE * exp(-h / FOG_T_HAZE_FREE);
}

float fogHazeProfile(float y, float top) {
    float free = FOG_HAZE_FREE_SHARE * exp(-max(y - FOG_T_SEA, 0.0) / FOG_T_HAZE_FREE);
    return (fogLogistic(y, top, FOG_HAZE_SOFT) + free) * fogCaveScale(y);
}

// 高さ y0 から y1 までの直線上でのもや密度の平均
float fogHazeProfileMean(float y0, float y1, float top) {
    if (abs(y1 - y0) < 0.05) return fogHazeProfile(0.5 * (y0 + y1), top);
    float layer = fogLogisticIntegral(y1, top, FOG_HAZE_SOFT) - fogLogisticIntegral(y0, top, FOG_HAZE_SOFT);
    float free = FOG_HAZE_FREE_SHARE * (fogHazeFreeIntegral(y1) - fogHazeFreeIntegral(y0));
    return (layer + free) / (y1 - y0) * fogCaveScale(0.5 * (y0 + y1));
}

// 地表の霧の高さの範囲 (テンプレートの上端で頭打ち、谷に溜まる。海面より深い洞窟には入れない)
float fogMistHeightFade(float y) {
    return fogLogistic(y, FOG_T_GROUND_TOP, FOG_T_GROUND_SOFT) * smoothstep(FOG_T_SEA - 24.0, FOG_T_SEA - 4.0, y);
}

/*
 * ワールド位置での消散係数: x = もや, y = 霧
 * playerPos: player 空間 (ノイズの座標にはカメラ位置を足す)
 */
vec2 fogDensityAt(vec3 playerPos, FogMedium m) {
    float y = playerPos.y + cameraPosition.y;
    vec2 density = vec2(m.haze * fogHazeProfile(y, m.hazeTop), 0.0);
#ifdef FOG_LAYER
    float band = fogLayerBand(y);
    if (m.layerCover > 0.0 && band > 1e-3) {
        density.y += m.layer * band * fogLayerCoverAt(playerPos.xz + cameraPosition.xz, m.layerCover);
    }
#endif
#ifdef FOG_MIST
    float fade = fogMistHeightFade(y);
    float mist = m.mist;
    if (mist > 0.0 && fade > 0.01) {
        vec3 p = playerPos + cameraPosition + vec3(frameTimeCounter * 0.7, 0.0, frameTimeCounter * 0.35);
        float n = valueNoise3d(p * 0.035) * 0.65 + valueNoise3d(p * 0.09 + 13.0) * 0.35;
        density.y += mist * fade * smoothstep(0.38, 0.72, n + fade * 0.2);
    }
#endif
    return density;
}

// 区間の高さ y0..y1 での平均 (ロジスティックの閉形式)
float fogLogisticMean(float y0, float y1, float top, float w) {
    if (abs(y1 - y0) < 0.05) return fogLogistic(0.5 * (y0 + y1), top, w);
    return (fogLogisticIntegral(y1, top, w) - fogLogisticIntegral(y0, top, w)) / (y1 - y0);
}

// 局所の成分 (縮めない霧の層と地表の霧) の高さ y0 から y1、長さ len の区間の光学的深さ (塊とノイズは平均の濃さで近似)
float fogLocalDepth(FogMedium m, float y0, float y1, float len) {
    float od = 0.0;
#ifdef FOG_LAYER
    float band = fogLogisticMean(y0, y1, FOG_T_LAYER_TOP, FOG_T_LAYER_SOFT) - fogLogisticMean(y0, y1, FOG_T_LAYER_BASE, FOG_T_LAYER_SOFT);
    od += m.layer * m.layerCover * band * len;
#endif
#ifdef FOG_MIST
    float ground = fogLogisticMean(y0, y1, FOG_T_GROUND_TOP, FOG_T_GROUND_SOFT) * smoothstep(FOG_T_SEA - 24.0, FOG_T_SEA - 4.0, 0.5 * (y0 + y1));
    od += m.mist * FOG_GROUND_NOISE_MEAN * ground * len;
#endif
    return od;
}

#ifdef WORLD_NETHER
// ネザーの霧の消散係数 (手前の立ち上げを掛ける前)
float netherFogExtinction() { return NETHER_FOG_EXTINCTION * NETHER_FOG_DENSITY * getNetherPalette().density; }
// カメラからの距離 t での濃さの倍率 (手前を抜く)
float netherFogNearFade(float t) { return saturate(t / NETHER_FOG_CLEAR_DIST); }
// 距離 t0..t1 の光学的厚さ / 消散係数 (netherFogNearFade の積分)
float netherFogPathLength(float t0, float t1) {
    float L = NETHER_FOG_CLEAR_DIST;
    float a = min(t0, L), b = min(t1, L);
    return (b * b - a * a) / (2.0 * L) + max(t1 - L, 0.0) - max(t0 - L, 0.0);
}
#endif

/*
 * 視線ごとのフォグの光 (サンプル間で変わらない部分)
 * light: 影を落とす天体の照度, ambient: 全方位から入る光の平均放射 (等方位相を掛けた後の値)
 */
struct FogLighting {
    vec3 light;
    float phaseHaze;
    float phaseMist;
    vec3 ambient;
    vec3 air;      // 景色の成分の飽和した放射 (同じ方位の空の色。地平線より下は地平線の色)
    vec3 airSun;   // air のうち太陽の単散乱の分 (影の中で引く)
};

// もやの位相: g を半分ずつにしたオクターブ和 (多重散乱で位相が丸くなる近似, Kappa の 4 オクターブと同じ考え方)
float fogPhaseHaze(float cosTheta) {
    return (phaseCS(cosTheta, FS_PHASE_G1) + FS_PHASE_W2 * phaseCS(cosTheta, FS_PHASE_G2) + FS_PHASE_W3 * phaseCS(cosTheta, FS_PHASE_G3))
         / (1.0 + FS_PHASE_W2 + FS_PHASE_W3);
}

// 霧は粒が大きく前方に鋭い。後方散乱を少し混ぜる (Nostalgia の fogMistPhase と同じ構成)
float fogPhaseMist(float cosTheta) {
    return mix(phaseCS(cosTheta, FS_MIST_G), phaseHG(cosTheta, -0.25), 0.19);
}

#if defined HAS_SKY
/*
 * 地平線より下の視線の空気の色を読む方向: 地平線の上 (高さ mu) で、太陽との角度が視線と同じになる方位
 * 同じ方位の地平線を読むと、太陽の真下の地形や虚空が太陽のすぐ横の地平線の輝きで光る柱になる
 */
vec3 fogAirSkyDir(vec3 dir, float mu) {
    vec3 sunDir = getSunDir();
    float cosSun = dot(dir, sunDir);
    float sinMu = sqrt(max(1.0 - mu * mu, 0.0));
    float sunHorizontal = max(length(sunDir.xz), 1e-3);
    // 地平線の上の点と太陽の角: cos = sinMu sunHorizontal cos(方位差) + mu sunDir.y
    float cosAz = clamp((cosSun - mu * sunDir.y) / (sinMu * sunHorizontal), -1.0, 1.0);
    vec2 sunXZ = sunDir.xz / sunHorizontal;
    vec2 side = vec2(-sunXZ.y, sunXZ.x);
    float sinAz = sqrt(max(1.0 - cosAz * cosAz, 0.0)) * (dot(dir.xz, side) < 0.0 ? -1.0 : 1.0);
    return vec3((sunXZ * cosAz + side * sinAz) * sinMu, mu).xzy;
}

/*
 * 景色の成分 (もや・空中遠近) の飽和した放射: 空の色 (地平線より下は fogAirSkyDir の地平線の色)
 * sunPart: そのうち太陽の単散乱とみなす分 (影の中で引く。上限は空の色の FOG_HAZE_SUN_SHARE)
 */
vec3 fogAirRadiance(vec3 dir, out vec3 sunPart) {
    float horizonMu = atmoHorizonMu(atmoViewerRadius());
    // 地平線より下は虚空 (skyBelowHorizon) と同じ高さの地平線の色を読む (虚空ともやの色を揃える)
    vec3 sky = getSkyRadiance(dir.y > horizonMu ? dir : fogAirSkyDir(dir, horizonMu + SKY_HORIZON_SAMPLE_MU));
    LightSample celestial = getCelestialLight();
    vec3 sunScatter = celestial.irradiance * fogPhaseHaze(dot(dir, celestial.direction)) * (FOG_HAZE_TINT * FOG_ALBEDO);
    sunPart = sunScatter * min(1.0, FOG_HAZE_SUN_SHARE * luminance(sky) / max(luminance(sunScatter), 1e-9));
    return sky;
}

vec3 fogAirRadiance(vec3 dir) {
    vec3 sunPart;
    return fogAirRadiance(dir, sunPart);
}
#endif

FogLighting fogLightingSetup(vec3 dir) {
    FogLighting f;
    LightSample celestial = getCelestialLight();
    float cosTheta = dot(dir, celestial.direction);
    f.light = celestial.irradiance;
    f.phaseHaze = fogPhaseHaze(cosTheta);
    f.phaseMist = fogPhaseMist(cosTheta);
#if defined HAS_SKY
    // 上半球 (空) と下半球 (地面の照り返し) から等方に入る光: (E_up + E_down) / 2pi
    vec3 skyUp = shEvalIrradiance(vec3(0.0, 1.0, 0.0));
    vec3 skyDown = shEvalIrradiance(vec3(0.0, -1.0, 0.0));
    f.ambient = (skyUp + skyDown) * (SH_LOOK_UNDO / TAU);
    // SH は日陰の見た目のために彩度を落としてあるので、霧の光としては空の彩度に戻す (灰色の霧にしない)
    float ambientLum = luminance(f.ambient);
    f.ambient = max(vec3(ambientLum) + (f.ambient - ambientLum) / max(SH_SKY_SATURATION, 0.05), 0.0);
    /*
     * もやと空中遠近は消散と内散乱を組にし、内散乱は同じ方位の空の色にする (遠い霞は地平線の空に収束する)。
     * 空の色は太陽の単散乱を含むので、影の中の点ではその分を引いて光芒にする。引く分は空の色の FOG_HAZE_SUN_SHARE までに留める
     */
    f.air = fogAirRadiance(dir, f.airSun);
#elif defined WORLD_END
    f.ambient = END_FOG_COLOR * 0.05;
    f.air = vec3(0.0);
    f.airSun = vec3(0.0);
#else
    f.ambient = getNetherFogRadiance();
    f.air = vec3(0.0);
    f.airSun = vec3(0.0);
#endif
    return f;
}

/*
 * もや (景色の成分) の内散乱の放射 (消散 1 あたり)
 * sunVisibility: 太陽の見え方 (影), ambientVisibility: 空の見え方 (洞窟)
 * 日の当たる所は空の色そのもの (VL_STRENGTH で太陽の分を増減)、影の中は太陽の単散乱を引いた空の光だけ
 */
vec3 fogHazeRadiance(FogLighting fl, float sunVisibility, float ambientVisibility) {
    vec3 lit = fl.air * ambientVisibility + fl.airSun * (sunVisibility * FOG_VL_STRENGTH - 1.0);
    return max(lit, fl.air * (FOG_HAZE_SHADOW_FLOOR * ambientVisibility));
}

/*
 * 解析的な高さフォグ (VL OFF の時と、VL のマーチ範囲より遠い区間)
 * dir: 視線, startDist/endDist: 区間, sunVisibility: 区間の太陽の見え方 (影マップが無いので洞窟度などで近似)
 * 戻り値: rgb = 内散乱, a = 透過率
 */
vec4 fogAnalyticSegment(vec3 dir, float startDist, float endDist, FogLighting fl, float sunVisibility, float ambientVisibility) {
    float len = max(endDist - startDist, 0.0);
    if (len <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
#if defined HAS_SKY
    float y0 = cameraPosition.y + dir.y * startDist;
    float y1 = cameraPosition.y + dir.y * endDist;
    float invD = fogScenicInvD();
    float scenicLen = fogScenicDistance(endDist, invD) - fogScenicDistance(startDist, invD);
    FogMedium m = fogMedium();
    float odHaze = m.haze * scenicLen * fogHazeProfileMean(y0, y1, m.hazeTop);
    float odMist = fogLocalDepth(m, y0, y1, len);
    float od = odHaze + odMist;
    if (od <= 1e-6) return vec4(0.0, 0.0, 0.0, 1.0);
    float transmittance = exp(-od);
    vec3 mistRadiance = (fl.light * fl.phaseMist * sunVisibility * FOG_VL_STRENGTH + fl.ambient * ambientVisibility) * FOG_ALBEDO;
    vec3 radiance = (odHaze * fogHazeRadiance(fl, sunVisibility, ambientVisibility) + odMist * mistRadiance) / od;
    return vec4(radiance * (1.0 - transmittance), transmittance);
#elif defined WORLD_END
    float transmittance = exp(-END_FOG_EXTINCTION * END_FOG_DENSITY * len);
    vec3 radiance = (fl.light * fl.phaseHaze * sunVisibility + fl.ambient) + END_FOG_COLOR * 0.02;
    return vec4(radiance * (1.0 - transmittance), transmittance);
#else
    float transmittance = exp(-netherFogExtinction() * netherFogPathLength(startDist, endDist));
    return vec4(fl.ambient * (1.0 - transmittance), transmittance);
#endif
}

/*
 * 空中遠近: カメラから playerPos までの大気の減衰と、その方向の地平線の空の色への溶け込み
 * 洞窟の中では空の色に溶かさない (遠い洞窟の壁が青くならないように)
 */
#if defined HAS_SKY
/*
 * 空中遠近の消散係数 (1/ブロック)。高さ y0 から y1 までの直線上の平均
 * ミー散乱 (エアロゾル) は高さで速く減るので閉形式の平均にする (山頂どうしの視線は霞まず、谷底は霞む)
 */
vec3 fogAerialExtinction(float y0, float y1) {
    float h0 = max(y0 - FOG_T_SEA, 0.0) * (FOG_T_LIGHT_SCALE * 1e-3);
    float h1 = max(y1 - FOG_T_SEA, 0.0) * (FOG_T_LIGHT_SCALE * 1e-3);
    float mie = abs(h1 - h0) < 1e-4 ? exp(-0.5 * (h0 + h1) / ATMO_MIE_HEIGHT)
              : ATMO_MIE_HEIGHT * (exp(-h0 / ATMO_MIE_HEIGHT) - exp(-h1 / ATMO_MIE_HEIGHT)) / (h1 - h0);
    vec3 extinction = ATMO_RAYLEIGH_SCATTER * exp(-0.5 * (h0 + h1) / ATMO_RAYLEIGH_HEIGHT)
                    + ATMO_MIE_EXTINCT * mie * (1.0 + AERIAL_PERSPECTIVE_RAIN * fogRainFactor());
    return extinction * (1e-3 * AERIAL_PERSPECTIVE_SCALE * LOOK_FOG_DENSITY);
}

/*
 * 地平線より下の虚空 (描画距離の外) の視線の透過率。仮想の地面までの距離 groundDist まで、描画距離の中の地形と同じ式で積む
 * 空中遠近は全区間、もやと地表の霧は描画距離の外の区間だけ (中の区間は composite10/11 が空の画素に積む)
 */
vec3 fogVoidTransmittance(vec3 dir, float groundDist) {
    float R = min(fogRenderDistance(), groundDist);
    float invD = fogScenicInvD();
    float yC = cameraPosition.y;
    float yR = yC + dir.y * R;
    float yG = yC + dir.y * groundDist;
    float scenicG = fogScenicDistance(groundDist, invD);
    vec3 od = fogAerialExtinction(yC, yG) * scenicG;
    FogMedium m = fogMedium();
    od += m.haze * (scenicG - fogScenicDistance(R, invD)) * fogHazeProfileMean(yR, yG, m.hazeTop);
    od += fogLocalDepth(m, yR, yG, groundDist - R);
    return exp(-od);
}
#endif

vec3 applyAerialPerspective(vec3 color, vec3 playerPos) {
#if defined HAS_SKY
    float dist = length(playerPos);
    vec3 dir = playerPos / max(dist, EPS);
    vec3 extinction = fogAerialExtinction(cameraPosition.y, cameraPosition.y + playerPos.y);
    float outdoor = 1.0 - getCaveFactor();
    vec3 transmittance = exp(-extinction * fogScenicDistance(dist, fogScenicInvD()) * mix(0.2, 1.0, outdoor));
    return color * transmittance + fogAirRadiance(dir) * (1.0 - transmittance) * outdoor;
#else
    return color;
#endif
}

// 描画距離端のフォグ率 [0,1] (1 = 完全に空へ溶ける)
float getBorderFog(vec3 playerPos) {
#ifdef BORDER_FOG
    float d = length(playerPos.xz) / far;
    return smoothstep(BORDER_FOG_START, 1.0, d);
#else
    return 0.0;
#endif
}

// 地形が描画距離端で溶ける先の色 (空のピクセルと同じ値)
vec3 getBorderFogColor(vec3 dir) {
    return skyBelowHorizon(dir, getSkyRadiance(dir));
}

#endif
