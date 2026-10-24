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
 * 前方シェーディングで個別に掛ける必要があるもの (パーティクル・雨) だけが applyForwardFog を使う
 */
#ifndef SKY_FOG_GLSL
#define SKY_FOG_GLSL

#include "/lib/sky/fog_template.glsl"

/*
 * もや: 上端のある混合層 (上端は FOG_T_HAZE_TOP、ロジスティックで柔らかく) + 上に残る薄いもや (FOG_HAZE_FREE_SHARE)
 * 上端は朝と夜に低く、昼に雲底の 3/4 まで上がる (現実の混合層は朝夜 100-500 m、昼 1-2 km で積雲の雲底とほぼ同じ)
 */
const float FOG_HAZE_DENSITY = 5.0e-4;   // 晴れた昼の海面のもやの消散係数 (1/ブロック, 視程 約 8 km 相当)
const float FOG_HAZE_FREE_SHARE = 0.1;   // 上端より上に残る薄いもやの割合
// 時間帯の倍率: 夜明け前 (太陽 -12 度から 0 度)、朝 (0 度から 15 度)、夕、夜
const float FOG_HAZE_DAWN = 1.5;
const float FOG_HAZE_MORNING = 1.6;
const float FOG_HAZE_EVENING = 1.3;
const float FOG_HAZE_NIGHT = 1.2;
// 上端の高さ (昼の厚みに対する割合)
const float FOG_HAZE_TOP_MORNING = 0.5;
const float FOG_HAZE_TOP_EVENING = 0.75;
const float FOG_HAZE_TOP_NIGHT = 0.5;
// 太陽が低い (朝夕) とみなす高さ (sin 15 度) と、夜とみなす高さ (sin -12 度)
const float FOG_LOW_SUN_Y = 0.26;
const float FOG_NIGHT_SUN_Y = -0.21;
// 雨・雪のもやの倍率。5 では雨の中景 (50-150 ブロック) の地形が白いもやに埋もれ、空の重さに対して地上だけ明るく白っぽく見えた
const float FOG_HAZE_RAIN = 4.0;
const float FOG_HAZE_SNOW = 6.0;
const float FOG_CAVE_DENSITY = 2.5;      // 海面より深い所 (洞窟) の空気の濁りの倍率
const float FOG_CAVE_DEPTH = 32.0;       // 海面からこの深さで洞窟の倍率に達する
const float FOG_MIST_DENSITY = 0.012;    // 地表の霧の最大消散係数
const vec3 FOG_HAZE_TINT = vec3(0.88, 0.94, 1.0); // もやの散乱色 (わずかにレイリー寄りの青)
const float FOG_ALBEDO = 0.95;
// 空中遠近を実際の大気の何倍の濃さで掛けるか (描画距離は数百ブロックしかないので誇張する)
const float AERIAL_PERSPECTIVE_SCALE = 10.0;
const float AERIAL_PERSPECTIVE_RAIN = 3.0;
// 描画距離に対する割合。端の霞みは景色の成分の写像 (FOG_EDGE_DEPTH) が作り、その先は虚空 (skyBelowHorizon) が同じ式で続けるので、
// 端のフォグは地形の切れ目を隠すだけにする
const float BORDER_FOG_START = 0.95;

/*
 * 景色の成分の距離の写像
 * FOG_EDGE_DEPTH: 晴れた昼に y FOG_SCENIC_REF_Y から水平に見た描画距離の端の光学的深さ (透過率 0.4)。尾根の重なりが読める濃さ
 * FOG_SCENIC_SIGMA0: その高さの景色の成分の消散 (もや + 空中遠近の緑)。D はこれと R から決める
 */
const float FOG_EDGE_DEPTH = 0.9;
const float FOG_SCENIC_REF_Y = 70.0;
const float FOG_SCENIC_SIGMA0 = FOG_HAZE_DENSITY * (1.0 + FOG_HAZE_FREE_SHARE)
    + (13.558e-3 + ATMO_MIE_EXTINCT * exp(-(FOG_SCENIC_REF_Y - FOG_T_SEA) * FOG_T_LIGHT_SCALE * 1e-3 / ATMO_MIE_HEIGHT)) * 1e-3 * AERIAL_PERSPECTIVE_SCALE;
// D の下限 (R に対する割合)。短い描画距離で手前まで急に霞まないように
const float FOG_SCENIC_MIN_D = 0.15;
// 遠景の空の色のうち、太陽の単散乱とみなして影で引いてよい割合の上限 (残りは多重散乱と空の光)
const float FOG_HAZE_SUN_SHARE = 0.8;
// 影の中のもやに残す空の色の割合の下限
const float FOG_HAZE_SHADOW_FLOOR = 0.1;

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

// 水中の係数は水面側 (surface モジュール) の waterAbsorption / waterScattering を共有する (上から見た水と潜った時の色を揃える)
#include "/lib/surface/water.glsl"
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

// 朝 (日の出前後) の度合い。もやと霧が濃くなる
float fogMorningFactor() {
    float beforeSunrise = smoothstep(0.90, 0.98, sunAngle);
    float afterSunrise = 1.0 - smoothstep(0.03, 0.14, sunAngle);
    return saturate(beforeSunrise + (sunAngle < 0.5 ? afterSunrise : 0.0));
}

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
    return min(max(ratio - 1.0, 0.0) / R, 1.0 / (FOG_SCENIC_MIN_D * R));
}

// 景色の成分の写像した距離 d (1 + d / D)
float fogScenicDistance(float d, float invD) { return d * (1.0 + d * invD); }

/*
 * 視線ごとに 1 回だけ決める媒質の量 (時間帯・天気・バイオームの湿度)
 * haze: もやの上端より下の消散係数 (1/ブロック), hazeTop: もやの上端 (y), mist: 地表の霧の最大消散係数
 */
struct FogMedium {
    float haze;
    float hazeTop;
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

    float k = mix(1.0, mix(FOG_HAZE_EVENING, FOG_HAZE_MORNING, rising), lowSun);
    k = mix(k, mix(FOG_HAZE_NIGHT, FOG_HAZE_DAWN, dawn), night);
    k *= mix(1.0, mix(FOG_HAZE_RAIN, FOG_HAZE_SNOW, saturate(distantSnow)), rain);
    k *= 0.8 + 0.4 * saturate(rainfall);
    m.haze = FOG_HAZE_DENSITY * LOOK_FOG_DENSITY * k;

    float top = mix(1.0, mix(FOG_HAZE_TOP_EVENING, FOG_HAZE_TOP_MORNING, rising), lowSun);
    top = mix(top, FOG_HAZE_TOP_NIGHT, night);
    // 雨の日は雲底まで混ざる
    top = mix(top, 1.0, rain);
    m.hazeTop = FOG_T_SEA + top * (FOG_T_HAZE_TOP - FOG_T_SEA);

#ifdef FOG_MIST
    m.mist = FOG_MIST_DENSITY * LOOK_FOG_DENSITY * saturate(fogMorningFactor() + rain * 1.5 + 0.12 * saturate(rainfall));
#else
    m.mist = 0.0;
#endif
    return m;
}

float fogSoftplus(float x) { return max(x, 0.0) + log(1.0 + exp(-abs(x))); }
// 上端 top、幅 w のロジスティック (下で 1、上で 0) と、その y の原始関数 (閉形式で光学的深さを出す)
float fogLogistic(float y, float top, float w) { return 1.0 / (1.0 + exp((y - top) / w)); }
float fogLogisticIntegral(float y, float top, float w) { return y - w * fogSoftplus((y - top) / w); }

// 海面より深い所 (洞窟) の空気の濁りの倍率
float fogCaveScale(float y) { return mix(1.0, FOG_CAVE_DENSITY, saturate((FOG_T_SEA - y) / FOG_CAVE_DEPTH)); }

// 上に残る薄いもやの y の原始関数 (海面より下は一定として連続につなぐ)
float fogHazeFreeIntegral(float y) {
    float h = y - FOG_T_SEA;
    return h <= 0.0 ? h - FOG_T_HAZE_FREE : -FOG_T_HAZE_FREE * exp(-h / FOG_T_HAZE_FREE);
}

float fogHazeProfile(float y, float top) {
    float free = FOG_HAZE_FREE_SHARE * exp(-max(y - FOG_T_SEA, 0.0) / FOG_T_HAZE_FREE);
    return (fogLogistic(y, top, FOG_T_HAZE_SOFT) + free) * fogCaveScale(y);
}

// 高さ y0 から y1 までの直線上でのもや密度の平均
float fogHazeProfileMean(float y0, float y1, float top) {
    if (abs(y1 - y0) < 0.05) return fogHazeProfile(0.5 * (y0 + y1), top);
    float layer = fogLogisticIntegral(y1, top, FOG_T_HAZE_SOFT) - fogLogisticIntegral(y0, top, FOG_T_HAZE_SOFT);
    float free = FOG_HAZE_FREE_SHARE * (fogHazeFreeIntegral(y1) - fogHazeFreeIntegral(y0));
    return (layer + free) / (y1 - y0) * fogCaveScale(0.5 * (y0 + y1));
}

// 地表の霧の高さの範囲 (テンプレートの上端で頭打ち、谷に溜まる)
float fogMistHeightFade(float y) {
    return (1.0 - smoothstep(FOG_T_GROUND_TOP - 14.0, FOG_T_GROUND_TOP + 6.0, y)) * smoothstep(FOG_T_SEA - 24.0, FOG_T_SEA - 4.0, y);
}

/*
 * ワールド位置での消散係数: x = もや, y = 霧
 * playerPos: player 空間 (ノイズの座標にはカメラ位置を足す)
 */
vec2 fogDensityAt(vec3 playerPos, FogMedium m) {
    float y = playerPos.y + cameraPosition.y;
    vec2 density = vec2(m.haze * fogHazeProfile(y, m.hazeTop), 0.0);
#ifdef FOG_MIST
    float fade = fogMistHeightFade(y);
    float mist = m.mist;
    if (mist > 0.0 && fade > 0.0) {
        vec3 p = playerPos + cameraPosition + vec3(frameTimeCounter * 0.7, 0.0, frameTimeCounter * 0.35);
        float n = valueNoise3d(p * 0.035) * 0.65 + valueNoise3d(p * 0.09 + 13.0) * 0.35;
        density.y = mist * fade * smoothstep(0.38, 0.72, n + fade * 0.2);
    }
#endif
    return density;
}

// 局所の成分 (縮めない霧) の高さ y0 から y1、長さ len の区間の光学的深さ (ノイズは平均の濃さで近似)
float fogLocalDepth(FogMedium m, float y0, float y1, float len) {
    return m.mist * len * 0.35 * fogMistHeightFade(0.5 * (y0 + y1));
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
    return (skyPhaseCS(cosTheta, 0.72) + 0.5 * skyPhaseCS(cosTheta, 0.36) + 0.25 * skyPhaseCS(cosTheta, 0.18)) / 1.75;
}

// 霧は粒が大きく前方に鋭い。後方散乱を少し混ぜる (Nostalgia の fogMistPhase と同じ構成)
float fogPhaseMist(float cosTheta) {
    return mix(skyPhaseCS(cosTheta, 0.82), skyPhaseHG(cosTheta, -0.25), 0.19);
}

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
    f.air = getSkyRadiance(dir);
    vec3 sunScatter = f.light * f.phaseHaze * FOG_HAZE_TINT * FOG_ALBEDO;
    f.airSun = sunScatter * min(1.0, FOG_HAZE_SUN_SHARE * luminance(f.air) / max(luminance(sunScatter), 1e-9));
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
    vec3 lit = fl.air * ambientVisibility + fl.airSun * (sunVisibility * VL_STRENGTH - 1.0);
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
    vec3 mistRadiance = (fl.light * fl.phaseMist * sunVisibility * VL_STRENGTH + fl.ambient * ambientVisibility) * FOG_ALBEDO;
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
    return color * transmittance + getSkyRadiance(dir) * (1.0 - transmittance) * outdoor;
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

/*
 * 前方シェーディング用のフォグ適用 (composite11 の VL OFF 時と同じモデル)
 * 水中・溶岩の中などカメラ側の媒質は composite11 がまとめて掛けるのでここでは扱わない
 */
vec3 applyForwardFog(vec3 color, vec3 playerPos) {
    float dist = length(playerPos);
    vec3 dir = playerPos / max(dist, EPS);
    color = applyAerialPerspective(color, playerPos);
    color = mix(color, getBorderFogColor(dir), getBorderFog(playerPos));
    float outdoor = 1.0 - getCaveFactor();
    vec4 fog = fogAnalyticSegment(dir, 0.0, dist, fogLightingSetup(dir), outdoor, max(outdoor, 0.05));
    return color * fog.a + fog.rgb;
}

#endif
