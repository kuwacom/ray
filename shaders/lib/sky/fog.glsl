/*
 * フォグ (sky モジュール)
 * 3 つの層を同じパラメータから作る
 *   1. 空中遠近 (aerial perspective): 遠景が空の色 (SkyView LUT) に溶ける。空との境目が必ず一致する
 *   2. 高さフォグ: もや (海面からの指数減衰, Kappa / Nostalgia の 2 成分モデル) + 地表の霧 (FOG_MIST, 3D ノイズ)
 *      VL ON なら composite10 が影マップ空間でマーチ、OFF なら解析積分 (指数高さフォグの閉形式)
 *   3. 描画距離端のフォグ: 地形の端を空へ溶かす
 * 不透明・半透明の大半は composite10/11 (sky のパス) でまとめて掛ける
 * 前方シェーディングで個別に掛ける必要があるもの (パーティクル・雨) だけが applyForwardFog を使う
 */
#ifndef SKY_FOG_GLSL
#define SKY_FOG_GLSL

const float FOG_HAZE_DENSITY = 3.5e-4;     // 晴れた昼の海面高度でのもやの消散係数 (1/ブロック)
const float FOG_HAZE_HEIGHT = 55.0;      // もやの高さ方向の減衰長 (ブロック)
const float FOG_HAZE_MORNING = 2.2;      // 朝のもやの倍率
const float FOG_HAZE_NIGHT = 1.4;
// 7 では雨の中景 (50-150 ブロック) の地形が白いもやに埋もれ、空の重さに対して地上だけ明るく白っぽく見えた
const float FOG_HAZE_RAIN = 5.0;
const float FOG_CAVE_DENSITY = 2.5;      // 海面より深い所 (洞窟) の空気の濁りの倍率
const float FOG_CAVE_DEPTH = 32.0;       // 海面からこの深さで洞窟の倍率に達する
const float FOG_MIST_DENSITY = 0.012;    // 地表の霧の最大消散係数
const vec3 FOG_HAZE_TINT = vec3(0.88, 0.94, 1.0); // もやの散乱色 (わずかにレイリー寄りの青)
const float FOG_ALBEDO = 0.95;
// 空中遠近を実際の大気の何倍の濃さで掛けるか (描画距離は数百ブロックしかないので誇張する)
const float AERIAL_PERSPECTIVE_SCALE = 10.0;
const float AERIAL_PERSPECTIVE_RAIN = 3.0;
// 描画距離に対する割合。0.78 では描画距離の 8-9 割にある島や岸がほぼ空の色に溶けて見えなかった。
// バニラのフォグの始まり (描画距離 - 約 1.4 チャンク) に近い 0.9 にする
const float BORDER_FOG_START = 0.9;

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

// もやの海面での消散係数 (時間帯・天気・バイオームの湿度で変わる)
float fogHazeAmount() {
    float night = smoothstep(0.02, -0.1, getSunDir().y);
    float amount = FOG_HAZE_DENSITY * FOG_DENSITY;
    amount *= mix(1.0, FOG_HAZE_MORNING, fogMorningFactor());
    amount *= mix(1.0, FOG_HAZE_NIGHT, night);
    amount *= mix(1.0, FOG_HAZE_RAIN, fogRainFactor());
    amount *= 0.8 + 0.4 * saturate(rainfall);
    return amount;
}

float fogMistAmount() {
#ifdef FOG_MIST
    return FOG_MIST_DENSITY * FOG_DENSITY * saturate(fogMorningFactor() + fogRainFactor() * 1.5 + 0.12 * saturate(rainfall));
#else
    return 0.0;
#endif
}

float fogHazeProfile(float y) {
    float above = exp(-max(y - SKY_SEA_LEVEL, 0.0) / FOG_HAZE_HEIGHT);
    float cave = mix(1.0, FOG_CAVE_DENSITY, saturate((SKY_SEA_LEVEL - y) / FOG_CAVE_DEPTH));
    return above * cave;
}

// 高さ y0 から y1 までの直線上でのもや密度の平均 (指数の不定積分の差。海面より下は一定として連続につなぐ)
float fogHazeProfileMean(float y0, float y1) {
    if (abs(y1 - y0) < 0.05) return fogHazeProfile(0.5 * (y0 + y1));
    float f0 = y0 <= SKY_SEA_LEVEL ? (y0 - SKY_SEA_LEVEL) - FOG_HAZE_HEIGHT : -FOG_HAZE_HEIGHT * exp(-(y0 - SKY_SEA_LEVEL) / FOG_HAZE_HEIGHT);
    float f1 = y1 <= SKY_SEA_LEVEL ? (y1 - SKY_SEA_LEVEL) - FOG_HAZE_HEIGHT : -FOG_HAZE_HEIGHT * exp(-(y1 - SKY_SEA_LEVEL) / FOG_HAZE_HEIGHT);
    float cave = mix(1.0, FOG_CAVE_DENSITY, saturate((SKY_SEA_LEVEL - 0.5 * (y0 + y1)) / FOG_CAVE_DEPTH));
    return (f1 - f0) / (y1 - y0) * cave;
}

// 地表の霧の高さの範囲 (FOG_MIST_ALTITUDE で頭打ち、谷に溜まる)
float fogMistHeightFade(float y) {
    return (1.0 - smoothstep(FOG_MIST_ALTITUDE - 14.0, FOG_MIST_ALTITUDE + 6.0, y)) * smoothstep(SKY_SEA_LEVEL - 24.0, SKY_SEA_LEVEL - 4.0, y);
}

/*
 * ワールド位置での消散係数: x = もや, y = 霧
 * playerPos: player 空間 (ノイズの座標にはカメラ位置を足す)
 */
vec2 fogDensityAt(vec3 playerPos, float haze, float mist) {
    float y = playerPos.y + cameraPosition.y;
    vec2 density = vec2(haze * fogHazeProfile(y), 0.0);
#ifdef FOG_MIST
    float fade = fogMistHeightFade(y);
    if (mist > 0.0 && fade > 0.0) {
        vec3 p = playerPos + cameraPosition + vec3(frameTimeCounter * 0.7, 0.0, frameTimeCounter * 0.35);
        float n = valueNoise3d(p * 0.035) * 0.65 + valueNoise3d(p * 0.09 + 13.0) * 0.35;
        density.y = mist * fade * smoothstep(0.38, 0.72, n + fade * 0.2);
    }
#endif
    return density;
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
    f.ambient = (skyUp + skyDown) / TAU;
#elif defined WORLD_END
    f.ambient = END_FOG_COLOR * 0.05;
#else
    f.ambient = getNetherFogRadiance();
#endif
    return f;
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
    float odHaze = fogHazeAmount() * len * fogHazeProfileMean(y0, y1);
    float odMist = fogMistAmount() * len * 0.35 * fogMistHeightFade(0.5 * (y0 + y1));
    float od = odHaze + odMist;
    if (od <= 1e-6) return vec4(0.0, 0.0, 0.0, 1.0);
    float transmittance = exp(-od);
    float phase = (odHaze * fl.phaseHaze + odMist * fl.phaseMist) / od;
    vec3 radiance = (fl.light * phase * sunVisibility + fl.ambient * ambientVisibility) * FOG_HAZE_TINT * FOG_ALBEDO;
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
vec3 applyAerialPerspective(vec3 color, vec3 playerPos) {
#if defined HAS_SKY
    float dist = length(playerPos);
    vec3 dir = playerPos / max(dist, EPS);
    float hKm = max(cameraPosition.y + 0.5 * playerPos.y - SKY_SEA_LEVEL, 0.0) * 1e-3;
    vec3 extinction = ATMO_RAYLEIGH_SCATTER * exp(-hKm / ATMO_RAYLEIGH_HEIGHT)
                    + ATMO_MIE_EXTINCT * exp(-hKm / ATMO_MIE_HEIGHT) * (1.0 + AERIAL_PERSPECTIVE_RAIN * fogRainFactor());
    float outdoor = 1.0 - getCaveFactor();
    vec3 transmittance = exp(-extinction * (1e-3 * AERIAL_PERSPECTIVE_SCALE * FOG_DENSITY) * dist * mix(0.2, 1.0, outdoor));
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
