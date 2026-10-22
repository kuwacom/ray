/*
 * 物理ベースの大気 (sky モジュール)
 * Hillaire 2020 "A Scalable and Production Ready Sky and Atmosphere Rendering Technique" (EGSR 2020) の
 * 透過率 / 多重散乱 / SkyView の 3 LUT 構成を自前実装したもの。散乱係数は同論文と Bruneton 2017 の地球大気の値
 * 透過率 LUT のパラメータ化は Bruneton 2017 "Precomputed Atmospheric Scattering" (公開実装) と同じ式
 *
 * 距離の単位は km (惑星スケールで float 精度を保つため)。ブロック = 1m として変換する
 * ATMOSPHERE_MODE=0 (LUT なし) では解析近似 (Kasten-Young の空気量 + 2 空気量の単散乱式) に落とす
 */
#ifndef SKY_ATMOSPHERE_GLSL
#define SKY_ATMOSPHERE_GLSL

const float ATMO_GROUND_RADIUS = 6360.0;  // km
const float ATMO_TOP_RADIUS = 6460.0;     // km
const vec3 ATMO_RAYLEIGH_SCATTER = vec3(5.802, 13.558, 33.1) * 1e-3; // 1/km (海面)
const float ATMO_RAYLEIGH_HEIGHT = 8.0;   // km
/*
 * Mie (エアロゾル) は Hillaire の値 (3.996e-3, ごく澄んだ空) の 2.5 倍
 * 澄みすぎると夕方に太陽の周りの金色の輝きが小さく、空の大半が灰青のまま残った
 * 普通の晴天の霞 (Bruneton 既定 2.1e-2 の半分程度) にして、夕焼けの金色と昼の地平線の白みを出す
 */
const float ATMO_MIE_SCATTER = 1.0e-2;    // 1/km
const float ATMO_MIE_EXTINCT = 1.11e-2;   // 1/km (吸収 1 割)
const float ATMO_MIE_HEIGHT = 1.2;        // km
const float ATMO_MIE_G = 0.8;
const vec3 ATMO_OZONE_ABSORB = vec3(0.650, 1.881, 0.085) * 1e-3; // 1/km (層の中心)
const float ATMO_OZONE_CENTER = 25.0;     // km
const float ATMO_OZONE_HALF_WIDTH = 15.0; // km
const vec3 ATMO_GROUND_ALBEDO = vec3(0.3);

// Minecraft の海面 (この高さを大気の地表とみなす)
const float SKY_SEA_LEVEL = 63.0;
// 地平線のごく近く (視点高度による地平線の沈み込み + 太陽円盤の半径分) の滑らかな切り替え幅
const float ATMO_HORIZON_FADE = 0.01;

const ivec2 TRANSMITTANCE_LUT_SIZE = ivec2(256, 64);
const ivec2 MULTISCATTER_LUT_SIZE = ivec2(32, 32);
const ivec2 SKYVIEW_LUT_SIZE = ivec2(192, 108);

// 太陽・月の円盤の見かけの半径 (rad)。実際 (0.0047) の 2 倍にして画面上で読める大きさにする
const float SUN_ANGULAR_RADIUS = 0.0093;
const float MOON_ANGULAR_RADIUS = 0.0093;

/*------------------------------------------------------------------------------
  位相関数 (公知の式。名前の衝突を避けるため sky 接頭辞)
------------------------------------------------------------------------------*/
float skyPhaseRayleigh(float cosTheta) {
    return 3.0 / (16.0 * PI) * (1.0 + cosTheta * cosTheta);
}

// Henyey-Greenstein
float skyPhaseHG(float cosTheta, float g) {
    float gg = g * g;
    float denom = 1.0 + gg - 2.0 * g * cosTheta;
    return (1.0 - gg) / (4.0 * PI * denom * sqrt(denom));
}

// Cornette-Shanks (HG より後方が膨らみ、ミー散乱の実測に近い)
float skyPhaseCS(float cosTheta, float g) {
    float gg = g * g;
    float denom = 1.0 + gg - 2.0 * g * cosTheta;
    return 3.0 / (8.0 * PI) * (1.0 - gg) * (1.0 + cosTheta * cosTheta) / ((2.0 + gg) * denom * sqrt(denom));
}

const float SKY_PHASE_ISOTROPIC = 1.0 / (4.0 * PI);

/*------------------------------------------------------------------------------
  幾何 (惑星中心原点, r = 中心からの距離, mu = 天頂角の余弦)
------------------------------------------------------------------------------*/
float atmoDistanceToTop(float r, float mu) {
    float disc = r * r * (mu * mu - 1.0) + ATMO_TOP_RADIUS * ATMO_TOP_RADIUS;
    return max(-r * mu + sqrt(max(disc, 0.0)), 0.0);
}

float atmoDistanceToGround(float r, float mu) {
    float disc = r * r * (mu * mu - 1.0) + ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS;
    return max(-r * mu - sqrt(max(disc, 0.0)), 0.0);
}

bool atmoRayHitsGround(float r, float mu) {
    return mu < 0.0 && r * r * (mu * mu - 1.0) + ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS >= 0.0;
}

// 半径 r から見た地平線の天頂角余弦 (負)
float atmoHorizonMu(float r) {
    return -sqrt(max(1.0 - sqr(ATMO_GROUND_RADIUS / r), 0.0));
}

// 視点の惑星中心からの距離 (km)。海面より下は海面に貼り付ける (洞窟で空が地面の下にならないように)
float atmoViewerRadius() {
    return ATMO_GROUND_RADIUS + max(cameraPosition.y - SKY_SEA_LEVEL, 0.0) * 1e-3 + 0.002;
}

/*------------------------------------------------------------------------------
  媒質
------------------------------------------------------------------------------*/
void atmoMedium(float altitude, out vec3 rayleighScatter, out float mieScatter, out vec3 extinction) {
    float h = max(altitude, 0.0);
    float rayleighDensity = exp(-h / ATMO_RAYLEIGH_HEIGHT);
    float mieDensity = exp(-h / ATMO_MIE_HEIGHT);
    float ozoneDensity = max(1.0 - abs(h - ATMO_OZONE_CENTER) / ATMO_OZONE_HALF_WIDTH, 0.0);
    rayleighScatter = ATMO_RAYLEIGH_SCATTER * rayleighDensity;
    mieScatter = ATMO_MIE_SCATTER * mieDensity;
    extinction = rayleighScatter + ATMO_MIE_EXTINCT * mieDensity + ATMO_OZONE_ABSORB * ozoneDensity;
}

/*------------------------------------------------------------------------------
  LUT のパラメータ化
------------------------------------------------------------------------------*/
// テクセル中心が [0,1] の端に来るようにする (LUT の端でクランプされた値を読まないため)
vec2 atmoUnitToSubUv(vec2 unit, vec2 size) { return (unit * (size - 1.0) + 0.5) / size; }
vec2 atmoSubUvToUnit(vec2 uv, vec2 size) { return (uv * size - 0.5) / (size - 1.0); }

vec2 atmoTransmittanceUv(float r, float mu) {
    float H = sqrt(ATMO_TOP_RADIUS * ATMO_TOP_RADIUS - ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS);
    float rho = sqrt(max(r * r - ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS, 0.0));
    float d = atmoDistanceToTop(r, mu);
    float dMin = ATMO_TOP_RADIUS - r;
    float dMax = rho + H;
    vec2 unit = vec2((d - dMin) / max(dMax - dMin, EPS), rho / H);
    return atmoUnitToSubUv(saturate(unit), vec2(TRANSMITTANCE_LUT_SIZE));
}

void atmoTransmittanceParams(vec2 uv, out float r, out float mu) {
    vec2 unit = atmoSubUvToUnit(uv, vec2(TRANSMITTANCE_LUT_SIZE));
    float H = sqrt(ATMO_TOP_RADIUS * ATMO_TOP_RADIUS - ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS);
    float rho = H * unit.y;
    r = sqrt(rho * rho + ATMO_GROUND_RADIUS * ATMO_GROUND_RADIUS);
    float dMin = ATMO_TOP_RADIUS - r;
    float dMax = rho + H;
    float d = dMin + unit.x * (dMax - dMin);
    mu = d < EPS ? 1.0 : (H * H - rho * rho - d * d) / (2.0 * r * d);
    mu = clamp(mu, -1.0, 1.0);
}

vec2 atmoMultiScatterUv(float r, float muSun) {
    vec2 unit = vec2(muSun * 0.5 + 0.5, (r - ATMO_GROUND_RADIUS) / (ATMO_TOP_RADIUS - ATMO_GROUND_RADIUS));
    return atmoUnitToSubUv(saturate(unit), vec2(MULTISCATTER_LUT_SIZE));
}

/*
 * SkyView LUT: x = 太陽との方位角差 (sqrt で太陽側を細かく), y = 天頂角 (地平線付近を細かく)
 * 地平線より下は LUT に持たない (下半分は地平線の色で代用するので、全行を上半球に使って解像度を倍にする)
 * 月は Minecraft では常に太陽の対蹠点にあるので、太陽基準の方位角だけで太陽と月の両方の散乱を 1 枚に入れられる
 */
vec2 atmoSkyViewUv(float r, float viewMu, float cosAzimuth) {
    float horizonZenith = PI - acos(sqrt(max(1.0 - sqr(ATMO_GROUND_RADIUS / r), 0.0)));
    float zenith = acos(clamp(viewMu, -1.0, 1.0));
    float c = saturate(zenith / horizonZenith);
    float v = 1.0 - sqrt(1.0 - c);
    float u = sqrt(acos(clamp(cosAzimuth, -1.0, 1.0)) / PI);
    return atmoUnitToSubUv(vec2(u, v), vec2(SKYVIEW_LUT_SIZE));
}

void atmoSkyViewParams(vec2 uv, float r, out float viewMu, out float azimuth) {
    vec2 unit = atmoSubUvToUnit(uv, vec2(SKYVIEW_LUT_SIZE));
    float horizonZenith = PI - acos(sqrt(max(1.0 - sqr(ATMO_GROUND_RADIUS / r), 0.0)));
    float c = 1.0 - sqr(1.0 - unit.y);
    viewMu = cos(c * horizonZenith);
    azimuth = unit.x * unit.x * PI;
}

/*------------------------------------------------------------------------------
  解析近似 (ATMOSPHERE_MODE=0 と、LUT が無いディメンション用)
------------------------------------------------------------------------------*/
// Kasten & Young 1989 の相対空気量 (天頂 = 1)。地平線下はなめらかに大きくする
float atmoAirMass(float mu) {
    float elevationDeg = degrees(asin(clamp(mu, -1.0, 1.0)));
    return 1.0 / (max(mu, 0.0) + 0.50572 * pow(max(elevationDeg + 6.07995, 0.5), -1.6364));
}

const vec3 ATMO_ZENITH_OD_RAYLEIGH = ATMO_RAYLEIGH_SCATTER * ATMO_RAYLEIGH_HEIGHT;
const float ATMO_ZENITH_OD_MIE = ATMO_MIE_EXTINCT * ATMO_MIE_HEIGHT;
const vec3 ATMO_ZENITH_OD_OZONE = ATMO_OZONE_ABSORB * ATMO_OZONE_HALF_WIDTH;

vec3 atmoTransmittanceAnalytic(float r, float mu) {
    float h = r - ATMO_GROUND_RADIUS;
    float m = atmoAirMass(mu);
    vec3 od = ATMO_ZENITH_OD_RAYLEIGH * exp(-h / ATMO_RAYLEIGH_HEIGHT) + ATMO_ZENITH_OD_MIE * exp(-h / ATMO_MIE_HEIGHT) + ATMO_ZENITH_OD_OZONE;
    return exp(-od * m);
}

/*
 * 点 (r, mu) から大気上端までの透過率 (地面に当たる方向でも上端までの値を返す。地面の影は呼び出し側で)
 * LUT は setup1 が作る。LUT の無い設定・ディメンションでは解析近似
 */
vec3 atmoTransmittance(float r, float mu) {
#if ATMOSPHERE_MODE == 1 && defined HAS_SKY
    return texture(skyTransmittanceSampler, atmoTransmittanceUv(r, mu)).rgb;
#else
    return atmoTransmittanceAnalytic(r, mu);
#endif
}

// 地平線で滑らかに 0 にした光源方向の透過率 (太陽円盤が地平線に沈む分を含む)
vec3 atmoTransmittanceToLight(float r, float mu) {
    float horizonMu = atmoHorizonMu(r);
    float visible = smoothstep(horizonMu - ATMO_HORIZON_FADE, horizonMu + ATMO_HORIZON_FADE, mu);
    return atmoTransmittance(r, max(mu, horizonMu)) * visible;
}

vec3 atmoMultiScatter(float r, float muSun) {
#if ATMOSPHERE_MODE == 1 && defined HAS_SKY
    return texture(skyMultiScatterSampler, atmoMultiScatterUv(r, muSun)).rgb;
#else
    return vec3(0.0);
#endif
}

/*
 * 視線レイに沿った単散乱 + 多重散乱の積分 (SkyView LUT と多重散乱 LUT の生成で共用)
 * origin: 惑星中心原点の位置 (km), dir: 視線, lightDir/lightIlluminance: 太陽と月 (2 光源)
 * 多重散乱は LUT (Hillaire 2020 の Psi_ms) を引く
 */
vec3 atmoIntegrateScattering(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunIlluminance, vec3 moonDir, vec3 moonIlluminance, int steps, out vec3 transmittance) {
    float r = length(origin);
    float mu = dot(origin, dir) / r;
    float tMax = atmoRayHitsGround(r, mu) ? atmoDistanceToGround(r, mu) : atmoDistanceToTop(r, mu);

    float cosSun = dot(dir, sunDir);
    float cosMoon = dot(dir, moonDir);
    float rayleighPhaseSun = skyPhaseRayleigh(cosSun), miePhaseSun = skyPhaseCS(cosSun, ATMO_MIE_G);
    float rayleighPhaseMoon = skyPhaseRayleigh(cosMoon), miePhaseMoon = skyPhaseCS(cosMoon, ATMO_MIE_G);

    vec3 luminance = vec3(0.0);
    transmittance = vec3(1.0);
    float tPrev = 0.0;
    for (int i = 0; i < steps; i++) {
        // 2 乗分布: 視点近く (密度が高く変化の大きい低層) を細かく刻む
        float tNext = tMax * sqr(float(i + 1) / float(steps));
        float dt = tNext - tPrev;
        float t = 0.5 * (tPrev + tNext);
        tPrev = tNext;

        vec3 p = origin + dir * t;
        float pr = length(p);
        vec3 up = p / pr;
        vec3 rayleighScatter, extinction;
        float mieScatter;
        atmoMedium(pr - ATMO_GROUND_RADIUS, rayleighScatter, mieScatter, extinction);
        vec3 scatter = rayleighScatter + mieScatter;

        float muS = dot(up, sunDir);
        float muM = dot(up, moonDir);
        vec3 sunT = atmoTransmittanceToLight(pr, muS);
        vec3 moonT = atmoTransmittanceToLight(pr, muM);

        vec3 inscatter = sunIlluminance * (sunT * (rayleighScatter * rayleighPhaseSun + mieScatter * miePhaseSun) + atmoMultiScatter(pr, muS) * scatter)
                       + moonIlluminance * (moonT * (rayleighScatter * rayleighPhaseMoon + mieScatter * miePhaseMoon) + atmoMultiScatter(pr, muM) * scatter);

        // Hillaire 2015 のエネルギー保存の区間積分
        vec3 stepT = exp(-extinction * dt);
        luminance += transmittance * inscatter * (1.0 - stepT) / max(extinction, vec3(1e-9));
        transmittance *= stepT;
    }
    return luminance;
}

/*
 * 解析近似の空 (ATMOSPHERE_MODE=0)。視線と光源の 2 空気量で単散乱を閉形式に解き、多重散乱は定数倍で足す
 * 光源 1 つ分の放射 (照度 1 あたり)
 */
vec3 atmoAnalyticSkyForLight(vec3 dir, vec3 lightDir) {
    float viewMu = max(dir.y, 0.0);
    float cosTheta = dot(dir, lightDir);
    float mView = atmoAirMass(viewMu);
    float mLight = atmoAirMass(lightDir.y);
    vec3 odRayleigh = ATMO_ZENITH_OD_RAYLEIGH;
    float odMie = ATMO_ZENITH_OD_MIE;
    vec3 odTotal = odRayleigh + odMie + ATMO_ZENITH_OD_OZONE;

    // 視線上の各点で光源側の減衰を一様と仮定: ∫ exp(-od (mView s + mLight)) ds の形
    vec3 viewT = exp(-odTotal * mView);
    vec3 lightT = exp(-odTotal * mLight);
    vec3 singleScatter = (odRayleigh * skyPhaseRayleigh(cosTheta) + odMie * skyPhaseCS(cosTheta, ATMO_MIE_G))
                       * mView * lightT * (1.0 - viewT) / max(odTotal * mView, vec3(1e-6));
    // 多重散乱の寄与 (Hillaire 2020 で晴天時に単散乱の 2-3 割程度) を等方で近似
    vec3 multiScatter = odRayleigh * 0.35 * (1.0 - viewT) * smoothstep(-0.2, 0.3, lightDir.y) * SKY_PHASE_ISOTROPIC * 4.0;
    float horizon = smoothstep(-0.12, 0.02, lightDir.y);
    return (singleScatter + multiScatter) * horizon;
}

#endif
