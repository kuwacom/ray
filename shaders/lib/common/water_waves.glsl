/*
 * 水面の波: 海 / 湖 / 川のスペクトル・層・吸収と散乱の係数・画素より細かい波の粗さ・反射の持ち上げ
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_WAVES_GLSL
#define COMMON_WATER_WAVES_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/dimension.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/frame_data.glsl"

uniform sampler3D waterWaveTex;
// カメラのバイオームが川 (shaders.properties の smooth)。海は distantOcean を使う
uniform float waterRiver;

const float WATER_IOR = 1.333;
const float WATER_GRAVITY = 9.81;
// 横向きの面 (滝・流れの側面) には海のスペクトルを貼らず、側面専用の落ちる水の乱れ (waterFallNormal) を使う

// 波テクスチャ (gen_water_waves.py と揃える)
const int WATER_LAYERS = 5;
const float WATER_LAYER_RATIO = 2.9;
// 最大の層のタイルの大きさ (ブロック)。帯の中心の波長はタイル / WATER_BAND_CENTER (既定で 22, 7.8, 2.7, 0.93, 0.32 ブロック)
const float WATER_LAYER0_TILE = 192.0;
const float WATER_BAND_CENTER = 8.5;
const float WATER_TEX_SIZE = 128.0;
const float WATER_LOD_FADE_START = 1.5;  // 細かい波の層を画素の大きさ (footprint) で薄める範囲 (側面の滝の層)
// 近い所 (画素の大きさがこの範囲) の海の層は 1 テクセルが 2 画素になるまで残して波を細かく保ち、遠くは今までの範囲に戻す (遠くの費用を増やさない)
const float WATER_WAVE_FADE_START = 2.0;
const vec2 WATER_WAVE_NEAR = vec2(0.004, 0.02);
const float WATER_LOD_FADE_END = 4.0;
const float WATER_TEX_SLOPE_RANGE = 3.0;
const float WATER_TEX_HEIGHT_RANGE = 0.085259;
const float WATER_TEX_HEIGHT_SIGMA = 0.021315;
const float WATER_TEX_JACOBIAN_RANGE = 4.0;
const float WATER_TIME_HARMONIC_LO = 4.0;
const float WATER_TIME_N_LO = 3.0;
// 層ごとの風向きのずれと位置のずれ。タイルの格子の向きと繰り返しを揃えないため
const float WATER_LAYER_ANGLE[WATER_LAYERS] = float[](0.0, 0.41, -0.33, 0.57, -0.47);
const vec2 WATER_LAYER_OFFSET[WATER_LAYERS] = vec2[](vec2(0.0), vec2(0.37, 0.71), vec2(0.13, 0.29), vec2(0.83, 0.51), vec2(0.61, 0.07));
const float WATER_WIND_ANGLE = 0.6;            // 風下の向き (ワールド x 軸から, ラジアン)

// スペクトル
// 吹送距離 (m)。海は十分に発達した波 (Pierson-Moskowitz)、湖・川は JONSWAP の吹送距離で頭打ち
const float WATER_FETCH_OCEAN = 1e6;
const float WATER_FETCH_LAKE = 1500.0;
const float WATER_FETCH_RIVER = 500.0;
// JONSWAP のピークの持ち上げ (gamma 3.3 の余分なエネルギーを層の幅に均した近似)
const float WATER_PEAK_BOOST = 1.0;
const float WATER_PEAK_WIDTH = 0.35;           // 対数波長での幅
// 海のうねり (遠くの風で立った長い波) の傾きの分散。最大と 2 番目の層に足す
const float WATER_SWELL_VAR0 = 0.0006;
const float WATER_SWELL_VAR1 = 0.0002;
// さざ波 (WATER_RIPPLES を掛ける) とみなす帯の中心の波長 (ブロック)
const float WATER_RIPPLE_WAVELENGTH = 1.2;
// 表面張力波の最短の波長 (m)。最小の層より短い波は全部粗さへ回す
const float WATER_CAPILLARY_WAVELENGTH = 0.016;
// 屋根の下・洞窟 (スカイライトが少ない所) は風が当たらない
const float WATER_SHELTER_WIND = 0.15;
// 風が弱まり始めるスカイライトと、全部当たるスカイライト
const vec2 WATER_SHELTER_SKYLM = vec2(0.3, 0.9);

// 波頭・流れ
const float WATER_JACOBIAN_MIN = 0.3;          // 勾配を割る Jacobian の下限 (勾配は最大でこの逆数倍)
const float WATER_FLOW_SPEED = 2.5;            // 流れの速さ (ブロック/秒, 面の傾き 1 あたり)
const float WATER_FLOW_MAX = 3.0;
const float WATER_FALL_SPEED = 4.0;            // 側面 (滝) の流れ落ちる速さ
const float WATER_FLOW_CYCLE = 1.6;            // 流れの 2 相の切り替えの周期 (秒)

/*
 * 吸収 a と散乱 b (1/ブロック)。水中フォグ (sky モジュール) もこの関数を使って見た目を揃える
 * WATER_TYPE 0: Jerlov IB 相当。純水の吸収 (Pope & Fry 1997) に少量のクロロフィルと粒子散乱を足した値
 *            1: 沿岸 (Jerlov 3C 寄り)。溶存有機物とプランクトンが青を吸い、粒子散乱が多いので緑に濁る
 *            2: 澄んだ水。ほぼ純水の吸収で散乱が少なく、遠くまで見通せる
 */
#if WATER_TYPE == 1
    const vec3 WATER_ABSORPTION_COEFF = vec3(0.38, 0.085, 0.12);
    const vec3 WATER_SCATTERING_COEFF = vec3(0.075, 0.09, 0.085);
#elif WATER_TYPE == 2
    const vec3 WATER_ABSORPTION_COEFF = vec3(0.33, 0.05, 0.014);
    const vec3 WATER_SCATTERING_COEFF = vec3(0.010, 0.013, 0.018);
#else
    // 散乱は外洋の粒子散乱の下限寄り (0.03-0.05 では浅瀬が底まで透けて浅いプールに見える)
    // 吸収は純水 (Pope & Fry 1997) + 少量のクロロフィル。消散は緑 0.21 / 青 0.15 で 15-25 ブロック先まで見える
    // (緑 0.31 / 青 0.22 まで上げると水中の見通しが 10 ブロックほどしかなく、光源もすぐ水の色に埋もれる)。
    // 深い所の暗さは内散乱の光源を深さで弱める式 (composite1 の waterInscatter) で出す
    // 緑は青より強く吸わせて紺に寄せる (緑 0.09-0.10 では手前の水が底の砂の照り返しで明るいターコイズに浮く)
    const vec3 WATER_ABSORPTION_COEFF = vec3(0.38, 0.12, 0.05);
    const vec3 WATER_SCATTERING_COEFF = vec3(0.070, 0.085, 0.100);
#endif
vec3 waterAbsorption() { return WATER_ABSORPTION_COEFF * WATER_FOG_DENSITY; }
vec3 waterScattering() { return WATER_SCATTERING_COEFF * WATER_FOG_DENSITY; }
vec3 waterExtinction() { return waterAbsorption() + waterScattering(); }

float waterLayerTile(int i) { return WATER_LAYER0_TILE * WATER_WAVE_LENGTH / pow(WATER_LAYER_RATIO, float(i)); }

// 層のテクスチャのループの周期 (秒)。gen_water_waves.py の時間の丸めと同じ式
float waterLayerPeriod(float tile) { return WATER_TIME_HARMONIC_LO * sqrt(TAU * tile / (WATER_TIME_N_LO * WATER_GRAVITY)); }

/*
 * 表面張力波 (波長 0.11 / 0.038 ブロック) の 2 層。最小の層より短い波は、画素より細かい粗さにしか無く、近くの水面の
 * 太陽の照り返しが 1 つの柔らかい楕円になっていた。近くで画素より大きい間は法線で表し、照り返しを波の斜面ごとの
 * 小さな点に割る (表せない遠くは粗さへ回す)。同じ波テクスチャをタイル 0.934 / 0.322 ブロックで引く。
 * WATER_LAYERS は増やさない (視差・コースティクス・水たまりの波が層の番号に依存するため)
 */
const int WATER_CAPILLARY_LAYERS = 2;
const float WATER_CAPILLARY_ANGLE[WATER_CAPILLARY_LAYERS] = float[](0.23, -0.61);
const vec2 WATER_CAPILLARY_OFFSET[WATER_CAPILLARY_LAYERS] = vec2[](vec2(0.29, 0.83), vec2(0.71, 0.47));
float waterCapillaryTile(int i) { return waterLayerTile(WATER_LAYERS - 1) / pow(WATER_LAYER_RATIO, float(i + 1)); }

/*
 * 傾きの強さの調整 (現実のさざ波の写真に合わせた見た目の値)。細かい層ほど傾きを強めて、うねりの上に細かい
 * さざ波が重なる見え方にする。照り返しの点は表した波の斜面で決まるので、傾きが弱いと端の点がまばらにも出ない
 * 傾きの RMS への倍率。層 0-1 (長いうねり) は変えない
 */
const float WATER_LAYER_GAIN[WATER_LAYERS] = float[](1.0, 1.0, 1.1, 1.22, 1.38);
const float WATER_CAPILLARY_GAIN = 1.6;

// 海の状態: 層ごとの傾きの RMS (ブロック/ブロック) と、表面張力波の層の傾きの RMS
struct WaterSea {
    float amp[WATER_LAYERS];
    float capAmp[WATER_CAPILLARY_LAYERS];
    float wind;                                 // 実効の風速 (白波の量)
    float heightRms;                            // 高さの RMS (ブロック)
};

// 平衡域の傾きの分散 (波数の自然対数あたり)。ピークから表面張力波までの対数の幅で割ると Cox-Munk の 0.003 + 0.00512 U にほぼ合う
float waterSlopeDensity(float U) { return 0.0004 + 0.0006 * U; }

// ピーク波長 (m)。吹送距離が十分なら Pierson-Moskowitz (omega_p = 0.877 g / U)、短ければ JONSWAP (omega_p = 22 (g^2 / (U F))^(1/3))
float waterPeakWavelength(float U, float fetch) {
    U = max(U, 0.5);
    float omega = max(0.877 * WATER_GRAVITY / U, 22.0 * pow(WATER_GRAVITY * WATER_GRAVITY / (U * fetch), 1.0 / 3.0));
    return TAU * WATER_GRAVITY / (omega * omega);
}

/*
 * 1 種類の水 (風速 U, 吹送距離 fetch) の層の傾きの分散を weight 倍して足す
 * ピークより長い波は Pierson-Moskowitz の exp(-5/4 (omega_p / omega)^4) = exp(-5/4 (k_p / k)^2) で切る
 */
void waterAddSpectrum(inout WaterSea sea, float weight, float U, float fetch, float swell) {
    if (weight <= 0.0) return;
    float peak = waterPeakWavelength(U, fetch);
    float density = waterSlopeDensity(U) * log(WATER_LAYER_RATIO) * weight;
    for (int i = 0; i < WATER_LAYERS; i++) {
        float lambda = waterLayerTile(i) / WATER_BAND_CENTER;
        float r = lambda / peak;
        float v = density * exp(-1.25 * r * r) * (1.0 + WATER_PEAK_BOOST * exp(-sqr(log(r)) / (2.0 * sqr(WATER_PEAK_WIDTH))));
        if (lambda < WATER_RIPPLE_WAVELENGTH) v *= WATER_RIPPLES;
        sea.amp[i] += v * sqr(WATER_LAYER_GAIN[i]);
    }
    sea.amp[0] += WATER_SWELL_VAR0 * swell * weight;
    sea.amp[1] += WATER_SWELL_VAR1 * swell * weight;
    // 表面張力波の帯: 最小の層の次の帯の中心 (波長 smallest) から最短の波長 (WATER_CAPILLARY_WAVELENGTH) まで、2 層で分ける
    float edge = waterLayerTile(WATER_LAYERS - 1) / (WATER_BAND_CENTER * WATER_LAYER_RATIO);
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) {
        float low = max(edge / WATER_LAYER_RATIO, WATER_CAPILLARY_WAVELENGTH);
        sea.capAmp[i] += waterSlopeDensity(U) * log(max(edge / low, 1.0)) * WATER_RIPPLES * weight * sqr(WATER_CAPILLARY_GAIN);
        edge /= WATER_LAYER_RATIO;
    }
    sea.wind += U * weight;
}

// skyLm: スカイライト (0-1)。屋根の下や洞窟の水は風が当たらないので凪ぐ
WaterSea waterSeaStateEval(float skyLm) {
    WaterSea sea;
    for (int i = 0; i < WATER_LAYERS; i++) sea.amp[i] = 0.0;
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) sea.capAmp[i] = 0.0;
    sea.wind = 0.0;
    float ocean = saturate(distantOcean);
    float river = saturate(waterRiver) * (1.0 - ocean);
    float wind = WATER_WIND_SPEED * mix(WATER_SHELTER_WIND, 1.0, smoothstep(WATER_SHELTER_SKYLM.x, WATER_SHELTER_SKYLM.y, skyLm));
    waterAddSpectrum(sea, ocean, wind, WATER_FETCH_OCEAN, 1.0);
    waterAddSpectrum(sea, 1.0 - ocean - river, wind * WATER_LAKE_WAVES, WATER_FETCH_LAKE, 0.0);
    waterAddSpectrum(sea, river, wind * WATER_RIVER_WAVES, WATER_FETCH_RIVER, 0.0);
    float h2 = 0.0;
    for (int i = 0; i < WATER_LAYERS; i++) {
        sea.amp[i] = sqrt(sea.amp[i]) * WATER_WAVE_HEIGHT;
        h2 += sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
    }
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) sea.capAmp[i] = sqrt(sea.capAmp[i]) * WATER_WAVE_HEIGHT;
    sea.heightRms = sqrt(h2);
    return sea;
}

/*
 * 開けた水面 (スカイライト WATER_SHELTER_SKYLM.y 以上) の海の状態は uniform だけで決まる。スペクトルは超越関数が多く、
 * 水の画素ごと (水底のコースティクスでは 1 画素に数回) に解くと重いので、prepare (sun_sky_light.csh) が毎フレーム 1 回
 * 解いて frameData.surfaceParams に置く。並び: 層の傾き WATER_LAYERS 個, 表面張力波の傾き, 風速, 高さの RMS
 */
float waterSeaPacked(int k) { return frameData.surfaceParams[k >> 2][k & 3]; }

WaterSea waterSeaState(float skyLm) {
    if (skyLm < WATER_SHELTER_SKYLM.y) return waterSeaStateEval(skyLm);
    WaterSea sea;
    int k = 0;
    for (int i = 0; i < WATER_LAYERS; i++) sea.amp[i] = waterSeaPacked(k++);
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) sea.capAmp[i] = waterSeaPacked(k++);
    sea.wind = waterSeaPacked(k++);
    sea.heightRms = waterSeaPacked(k);
    return sea;
}

#ifdef SSBO_FRAME_DATA_WRITE
void waterSeaStoreOpen() {
    WaterSea sea = waterSeaStateEval(1.0);
    int k = 0;
    for (int i = 0; i < WATER_LAYERS; i++, k++) frameData.surfaceParams[k >> 2][k & 3] = sea.amp[i];
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++, k++) frameData.surfaceParams[k >> 2][k & 3] = sea.capAmp[i];
    frameData.surfaceParams[k >> 2][k & 3] = sea.wind;
    k++;
    frameData.surfaceParams[k >> 2][k & 3] = sea.heightRms;
}
#endif

/*
 * 近景の細かさ。最小の層 (波長 0.038 ブロック、帯の短い端 約 0.02) より短い波は表面張力波の下限 (WATER_CAPILLARY_WAVELENGTH)
 * を下回り、実際の水面では粘性ですぐ消えるので足さない。近づいても波の形 (スペクトル) はワールドで同じままにする
 * (画面の画素に合わせて細かい層を足すと、近づくほど波の中に波が現れ、同じ模様が縮んで重なってダブって見えた)
 * その代わり、1 テクセルが画素より大きい近景では、双線形の補間だと傾きがテクセルごとの折れ線になり、照り返しや映り込みが
 * 角の立った多角形の面に割れて見えるので、3 次の B スプラインで傾きを滑らかにつなぐ (双線形 4 回で引く。時間の軸は線形のまま)
 * B スプラインは短い波を弱める (周波数の応答 sinc^4)。弱まる分は帯の中心 (波長 9 テクセル) で約 8%、帯の短い端 (約 5 テクセル)
 * で約 2 割。効くのは 1 画素が 1 テクセルより小さい近景だけで、近いほど細かい傾きが少し弱まる
 */
const vec2 WATER_TEX_CUBIC_TEXELS = vec2(0.5, 1.0);   // 1 画素あたりのテクセル数: この範囲で 3 次から双線形へ移る

vec4 waterWaveTexCubic(vec3 q) {
    vec2 x = fract(q.xy) * WATER_TEX_SIZE - 0.5;
    vec2 i = floor(x);
    vec2 f = x - i;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 g0 = w0 + w1;
    vec2 g1 = 1.0 - g0;
    // 隣り合う 2 テクセルの重みの比の位置を双線形で引くと、2 つの重み付きの和になる
    vec2 c0 = (i - 0.5 + w1 / g0) / WATER_TEX_SIZE;
    vec2 c1 = (i + 1.5 + w3 / g1) / WATER_TEX_SIZE;
    return g0.y * (g0.x * texture(waterWaveTex, vec3(c0.x, c0.y, q.z)) + g1.x * texture(waterWaveTex, vec3(c1.x, c0.y, q.z)))
         + g1.y * (g0.x * texture(waterWaveTex, vec3(c0.x, c1.y, q.z)) + g1.x * texture(waterWaveTex, vec3(c1.x, c1.y, q.z)));
}

// 波テクスチャを引く。texels: 1 画素あたりのテクセル数 (0 以下は双線形のまま)
vec4 waterWaveTexel(vec3 q, float texels) {
    float c = texels > 0.0 ? 1.0 - smoothstep(WATER_TEX_CUBIC_TEXELS.x, WATER_TEX_CUBIC_TEXELS.y, texels) : 0.0;
    vec4 s = c < 1.0 ? texture(waterWaveTex, q) : vec4(0.0);
    if (c > 0.0) s = mix(s, waterWaveTexCubic(q), c);
    return s;
}

/*
 * 層 i を引く。戻り値 x = 高さ (ブロック), yz = 勾配 (ワールドの 2D), w = 水平変位の発散 (Jacobian の 1 次の項)
 * テクスチャの +x を風下に向け、タイルの長さで割った座標で引く。勾配はタイルの大きさによらず振幅 (傾きの RMS) 倍
 * footprint: 画素の大きさ (ブロック)。正なら近景を 3 次で補間する
 */
vec4 waterLayer(vec2 p, int i, float amp, float t, float footprint) {
    float tile = waterLayerTile(i);
    float a = WATER_WIND_ANGLE + WATER_LAYER_ANGLE[i];
    vec2 dir = vec2(cos(a), sin(a));
    vec2 side = vec2(-dir.y, dir.x);
    vec2 q = vec2(dot(p, dir), dot(p, side)) / tile + WATER_LAYER_OFFSET[i];
    vec4 s = waterWaveTexel(vec3(q, t / waterLayerPeriod(tile)), footprint * WATER_TEX_SIZE / tile) * 2.0 - 1.0;
    vec2 g = (dir * s.x + side * s.y) * WATER_TEX_SLOPE_RANGE;
    return amp * vec4(s.z * WATER_TEX_HEIGHT_RANGE * tile, g, s.w * WATER_TEX_JACOBIAN_RANGE);
}

vec4 waterLayer(vec2 p, int i, float amp, float t) {
    float tile = waterLayerTile(i);
    float a = WATER_WIND_ANGLE + WATER_LAYER_ANGLE[i];
    vec2 dir = vec2(cos(a), sin(a));
    vec2 side = vec2(-dir.y, dir.x);
    vec2 q = vec2(dot(p, dir), dot(p, side)) / tile + WATER_LAYER_OFFSET[i];
    vec4 s = texture(waterWaveTex, vec3(q, t / waterLayerPeriod(tile))) * 2.0 - 1.0;
    vec2 g = (dir * s.x + side * s.y) * WATER_TEX_SLOPE_RANGE;
    return amp * vec4(s.z * WATER_TEX_HEIGHT_RANGE * tile, g, s.w * WATER_TEX_JACOBIAN_RANGE);
}

// 層が画素の大きさ footprint (ブロック) に対して表せる割合。帯の短い端 (タイルの約 5 テクセル) が 2 画素を切る前に消す
// (2.5-6 テクセル/画素では、帯の短い側が 1-2 画素の波になって中距離の水面が細かい白い砂目にざらついた)
float waterTileResolved(float tile, float footprint) {
    float fadeStart = mix(WATER_WAVE_FADE_START, WATER_LOD_FADE_START, smoothstep(WATER_WAVE_NEAR.x, WATER_WAVE_NEAR.y, footprint));
    return footprint > 0.0 ? 1.0 - smoothstep(fadeStart, WATER_LOD_FADE_END, footprint * WATER_TEX_SIZE / tile) : 1.0;
}

float waterLayerResolved(int i, float footprint) { return waterTileResolved(waterLayerTile(i), footprint); }

// 波テクスチャの 1 層の勾配 (ワールドの 2D)。風下から angle ずらして引く
vec2 waterSlopeLayer(vec2 p, float tile, float angle, vec2 offset, float amp, float t, float footprint) {
    float a = WATER_WIND_ANGLE + angle;
    vec2 dir = vec2(cos(a), sin(a));
    vec2 side = vec2(-dir.y, dir.x);
    vec2 q = vec2(dot(p, dir), dot(p, side)) / tile + offset;
    vec4 s = waterWaveTexel(vec3(q, t / waterLayerPeriod(tile)), footprint * WATER_TEX_SIZE / tile) * 2.0 - 1.0;
    return amp * (dir * s.x + side * s.y) * WATER_TEX_SLOPE_RANGE;
}

// 表面張力波の層 i を引く。戻り値は勾配 (ワールドの 2D)。層の引き方は waterLayer と同じ
vec2 waterCapillaryLayer(vec2 p, int i, float amp, float t, float footprint) {
    return waterSlopeLayer(p, waterCapillaryTile(i), WATER_CAPILLARY_ANGLE[i], WATER_CAPILLARY_OFFSET[i], amp, t, footprint);
}

// 表面張力波の勾配の和。画素より細かい層は足さない。表せない距離では 1 回も引かない
vec2 waterCapillaryGradient(WaterSea sea, vec2 p, float footprint, vec2 flow) {
    vec2 g = vec2(0.0);
    float t = frameTimeCounter;
    bool moving = dot(flow, flow) >= 1e-4;
    float phase = fract(t / WATER_FLOW_CYCLE);
    float wa = 1.0 - abs(1.0 - 2.0 * phase);
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) {
        float r = waterTileResolved(waterCapillaryTile(i), footprint);
        if (r <= 0.0) break;
        float amp = sea.capAmp[i] * r;
        if (!moving) {
            g += waterCapillaryLayer(p, i, amp, t, footprint);
        } else {
            // 流れのある面は waterWaveSumFlow と同じ 2 相
            vec2 a = waterCapillaryLayer(p - flow * (phase * WATER_FLOW_CYCLE), i, amp, t, footprint);
            vec2 b = waterCapillaryLayer(p - flow * (fract(phase + 0.5) * WATER_FLOW_CYCLE) + 0.37, i, amp, t, footprint);
            g += (a * wa + b * (1.0 - wa)) * inversesqrt(sqr(wa) + sqr(1.0 - wa));
        }
    }
    return g;
}

/*
 * 層 first .. last-1 の和 (高さ, 勾配, 発散)。画素より細かい層は足さない (ちらつきの元になるため)
 * cubicFootprint: 正なら近景を 3 次で補間する (法線だけ。視差・コースティクスは高さの位置しか使わないので双線形のまま)
 */
vec4 waterWaveSum(WaterSea sea, vec2 p, int first, int last, float footprint, float cubicFootprint) {
    float t = frameTimeCounter;
    vec4 sum = vec4(0.0);
    for (int i = first; i < last; i++) {
        float r = waterLayerResolved(i, footprint);
        // タイルは単調に小さくなるので、表せない層が出たら残りも全部表せない
        if (r <= 0.0) break;
        if (sea.amp[i] > 0.0) sum += waterLayer(p, i, sea.amp[i] * r, t, cubicFootprint);
    }
    return sum;
}

vec4 waterWaveSum(WaterSea sea, vec2 p, int first, int last, float footprint) {
    float t = frameTimeCounter;
    vec4 sum = vec4(0.0);
    for (int i = first; i < last; i++) {
        float r = waterLayerResolved(i, footprint);
        if (r <= 0.0) break;
        if (sea.amp[i] > 0.0) sum += waterLayer(p, i, sea.amp[i] * r, t);
    }
    return sum;
}

/*
 * 流れのある面: 2 つの位相で流れの向きへずらした波を交互に混ぜる (flow map の定番)。flow は速度 (ブロック/秒)
 * 無相関な 2 つを重み w, 1 - w で混ぜると分散が w^2 + (1 - w)^2 倍に落ちるので戻す
 */
vec4 waterWaveSumFlow(WaterSea sea, vec2 p, int first, int last, float footprint, vec2 flow) {
    if (dot(flow, flow) < 1e-4) return waterWaveSum(sea, p, first, last, footprint, footprint);
    float phase = fract(frameTimeCounter / WATER_FLOW_CYCLE);
    vec4 a = waterWaveSum(sea, p - flow * (phase * WATER_FLOW_CYCLE), first, last, footprint, footprint);
    vec4 b = waterWaveSum(sea, p - flow * (fract(phase + 0.5) * WATER_FLOW_CYCLE) + 0.37, first, last, footprint, footprint);
    float wa = 1.0 - abs(1.0 - 2.0 * phase);
    return (a * wa + b * (1.0 - wa)) * inversesqrt(sqr(wa) + sqr(1.0 - wa));
}

/*
 * 波頭を寄せた面 (x' = x - lambda D) の Jacobian。勾配はこれで割ると 1 次元では厳密 (dh/dx' = (dh/dx) / J)
 * 山 (発散が正) で J < 1 になって斜面が立ち、谷は寝る。J が小さい所は波が崩れかけ (白波)
 */
float waterJacobian(vec4 w) { return max(1.0 - WATER_CHOPPINESS * w.w, WATER_JACOBIAN_MIN); }
vec3 waterChoppy(vec4 w) { return vec3(w.x, w.yz / waterJacobian(w)); }

/*
 * 法線で表せなかった傾きの分散 (GGX の alpha^2 に足す)。画素の中で平均された波は面を粗くする (LEAN / Toksvig と同じ考え)
 * 遠くの水面で太陽の照り返しが縦に広がる帯になるのはこの分
 */
/*
 * y は同じ層の曲率の 2 乗の和。1 層を振幅 (傾きの RMS) a・波数 k の正弦とみなした (a k)^2 を足す。画素より細かい波が太陽を映す
 * 点の数 (傾きの確率密度 x ガウス曲率の絶対値の平均) に使う (WATER_GLITTER)。使わない呼び出しでは消える
 */
vec2 waterUnresolvedSlopeCurvature(WaterSea sea, float footprint) {
    vec2 v = vec2(0.0);
    for (int i = 0; i < WATER_LAYERS; i++) {
        float tile = waterLayerTile(i);
        float r = waterTileResolved(tile, footprint);
        // 法線側に r 倍を残すので、分散の合計が保たれるよう 1 - r^2 を回す
        float w = (1.0 - r * r) * sqr(sea.amp[i]);
        v += w * vec2(1.0, sqr(TAU * WATER_BAND_CENTER / tile));
    }
    // 表面張力波は近くでは法線で表すので、表せない分だけが粗さになる
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) {
        float tile = waterCapillaryTile(i);
        float r = waterTileResolved(tile, footprint);
        float w = (1.0 - r * r) * sqr(sea.capAmp[i]);
        v += w * vec2(1.0, sqr(TAU * WATER_BAND_CENTER / tile));
    }
    return v;
}

float waterUnresolvedSlopeVar(WaterSea sea, float footprint) { return waterUnresolvedSlopeCurvature(sea, footprint).x; }

// 表面張力 / 密度 (m^3/s^2)。波長 2 cm 前後より短い波は表面張力で速く進む
const float WATER_SURFACE_TENSION = 7.28e-5;

// 波長 (ブロック = m) の波の位相の速さ (m/s)。分散関係 omega^2 = g k + (sigma / rho) k^3
float waterPhaseSpeed(float wavelength) {
    float k = TAU / wavelength;
    return sqrt(WATER_GRAVITY / k + WATER_SURFACE_TENSION * k);
}

/*
 * 表せた層の、画素の中と露光の間での法線 (傾き) の揺れの分散。1 層の傾きは波長 lambda で振幅 a の正弦に近く、画素の幅 f の中で
 * a x 2 pi f / lambda ほど変わる (画素の中の一様な位置の標準偏差は幅の 1 / sqrt(12))
 * GGX の alpha^2 に足すと、細い鋭いローブが画素の当たり外れにならず、エネルギーを保ったままジッターのちらつきが消える
 * 画面微分は使わず (gbuffers_solid.fsh の鏡面 AA を入れない理由と同じ)、層ごとの解析式で足す
 */
const float WATER_PIXEL_SLOPE_SCALE = TAU / sqrt(12.0);

/*
 * 同じ式で、1 フレームの露光の間の法線の変化も足す (シャッターの時間積分)。層の傾きは時間の最も遅い倍音の周期
 * P (= ループの周期 / WATER_TIME_HARMONIC_LO) で回り、露光 dt の間に a x 2 pi dt / P ほど変わる (一様な時刻の標準偏差も 1 / sqrt(12))
 * さざ波の照り返しがフレームごとに別の画素へ跳ばず、露光の間の軌跡に沿ってエネルギーを保ったまま広がる。細かく速い層ほど効く
 * 画素の幅と露光の間の変化は独立なので分散の和 (層ごとの係数は定数に畳まれる)
 */
const float WATER_EXPOSURE_SHUTTER = 0.5;   // 1 フレームのうち露光している割合 (モーションブラーのシャッターと同じ)
const float WATER_EXPOSURE_MAX_DT = 0.05;   // 低いフレームレートで照り返しが流れすぎない上限 (秒)

float waterLayerSlopeChange(float tile, float footprint, float dt) {
    return sqr(footprint * WATER_BAND_CENTER / tile) + sqr(dt * WATER_TIME_HARMONIC_LO / waterLayerPeriod(tile));
}

float waterPixelSlopeVar(WaterSea sea, float footprint) {
    float dt = min(frameTime, WATER_EXPOSURE_MAX_DT) * WATER_EXPOSURE_SHUTTER;
    float v = 0.0;
    for (int i = 0; i < WATER_LAYERS; i++) {
        float tile = waterLayerTile(i);
        v += sqr(waterTileResolved(tile, footprint) * sea.amp[i] * WATER_PIXEL_SLOPE_SCALE) * waterLayerSlopeChange(tile, footprint, dt);
    }
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) {
        float tile = waterCapillaryTile(i);
        v += sqr(waterTileResolved(tile, footprint) * sea.capAmp[i] * WATER_PIXEL_SLOPE_SCALE) * waterLayerSlopeChange(tile, footprint, dt);
    }
    return v;
}

/*
 * 水面上の 1 画素の大きさ (ブロック)。かすめ角では視線方向に伸びるので、伸びた辺 (1 / NoV) 寄りで測る
 * 波は全方向を向くので、視線方向に伸びた辺で 2 画素を切る波は画面の縦に折り返す。幾何平均 (NoV^-0.5) では
 * 中景 (かすめ角 0.05-0.1) で縦に 2 画素ほどの波が残り、反射が画素ごとに空と水の色で斑になる白い砂目になった
 */
const float WATER_FOOTPRINT_STRETCH = 1.0;

float waterFootprint(float dist, float NoV) {
    float pixelAngle = 2.0 / (gbufferProjection[1][1] * viewSize().y);
    return dist * pixelAngle * pow(max(NoV, 0.02), -WATER_FOOTPRINT_STRETCH);
}

/*
 * 画素より細かい波で粗くなった水面の反射 (slopeVar = waterUnresolvedSlopeVar)。画素の中で見える微小面は視線の側へ傾くので、
 * かすめ角でも実効の NoV は傾きの RMS ほどに留まり (フレネルが 1 に張り付かない)、反射は傾きの分だけ高い空を映す。
 * 平らな鏡のままだと、遠くの水面が地平線の空をそのまま映して地平線の手前に明るい帯ができ、水平線が消えていた
 */
// 反射の仰角の持ち上げ (傾きの RMS あたり)。1.6 では中景 (層を落とした傾きの RMS 0.15 前後) の空の反射が R によらず
// 仰角 0.25 付近の 1 行になり、夕方の雲が上下の切れた四角い縦縞に並んだ
const float WATER_ROUGH_REFLECT_LIFT = 1.0;
/*
 * フレネルを均すのは描画距離 (far) に対してこの範囲より遠い水面だけ。近景・中景まで均すと、層を落とし始める
 * 10-30 ブロックからフレネルが 0.7 -> 0.45 に下がり、つやの無いマットな水面になった。遠くは像を残したまま暗くして、
 * 地平線の手前の明るい帯 (水面が地平線の空と同じ明るさになり水平線が消える) を抑える
 */
const vec2 WATER_ROUGH_FRESNEL_RANGE = vec2(0.2, 0.7);

float waterRoughNoV(float NoV, float slopeVar, float dist) {
    slopeVar *= smoothstep(WATER_ROUGH_FRESNEL_RANGE.x, WATER_ROUGH_FRESNEL_RANGE.y, dist / far);
    return sqrt(NoV * NoV + slopeVar);
}

/*
 * 持ち上げた方向は空を引く時だけ使い、SSR (島・岸) は持ち上げない元の方向で辿る。SSR まで持ち上げると、
 * 中景の水面に入る島・地平線の地形の映り込みが全部空に置き換わって消えていた
 */
vec3 waterRoughReflectDir(vec3 R, float slopeVar) {
    if (R.y < 0.0) return R;
    return normalize(vec3(R.x, sqrt(R.y * R.y + sqr(WATER_ROUGH_REFLECT_LIFT) * slopeVar), R.z));
}

#endif
