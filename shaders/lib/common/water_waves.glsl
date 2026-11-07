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
/*
 * 層ごとの横の鏡映 (1 か -1)。どの層も同じ波テクスチャの縮小なので、2 つ隔てた層 (タイル 8.4 倍) は向きが 8-9 度しか違わず、
 * 大きな波の中に同じ形の小さな波が同じ向きで入れ子になって、波が二重に見える。間の 2 層を鏡に映して同じ形にしない
 */
const float WATER_LAYER_MIRROR[WATER_LAYERS] = float[](1.0, 1.0, -1.0, -1.0, 1.0);
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
 * 海・湖・川の重み (x 海, y 湖, z 川。和は 1)。カメラのバイオームで決まり、shaders.properties の smooth で数秒かけて移る
 * 種類ごとの設定 (WATER_SEA_* / WATER_LAKE_* / WATER_RIVER_*) はこの重みで混ぜる。uniform で分岐せず値を混ぜるだけにする
 */
vec3 waterKindWeights() {
    float ocean = saturate(distantOcean);
    float river = saturate(waterRiver) * (1.0 - ocean);
    return vec3(ocean, 1.0 - ocean - river, river);
}

float waterKindMix(float sea, float lake, float river) { return dot(waterKindWeights(), vec3(sea, lake, river)); }

/*
 * 吸収 a と散乱 b (1/ブロック)。水中フォグ (sky モジュール) もこの関数を使って見た目を揃える
 * 水の色 (WATER_TYPE / WATER_LAKE_TYPE / WATER_RIVER_TYPE) ごとの係数
 * 0: Jerlov IB 相当。純水の吸収 (Pope & Fry 1997) に少量のクロロフィルと粒子散乱を足した値
 *    散乱は外洋の粒子散乱の下限寄り (0.03-0.05 では浅瀬が底まで透けて浅いプールに見える)
 *    吸収は純水 (Pope & Fry 1997) + 少量のクロロフィル。消散は緑 0.21 / 青 0.15 で 15-25 ブロック先まで見える
 *    (緑 0.31 / 青 0.22 まで上げると水中の見通しが 10 ブロックほどしかなく、光源もすぐ水の色に埋もれる)。
 *    深い所の暗さは内散乱の光源を深さで弱める式 (composite2 の waterInscatter) で出す
 *    緑は青より強く吸わせて紺に寄せる (緑 0.09-0.10 では手前の水が底の砂の照り返しで明るいターコイズに浮く)
 * 1: 沿岸 (Jerlov 3C 寄り)。溶存有機物とプランクトンが青を吸い、粒子散乱が多いので緑に濁る
 * 2: 澄んだ水。ほぼ純水の吸収で散乱が少なく、遠くまで見通せる
 */
#define WATER_TYPE_ABSORPTION(t) ((t) == 1 ? vec3(0.38, 0.085, 0.12) : (t) == 2 ? vec3(0.33, 0.05, 0.014) : vec3(0.38, 0.12, 0.05))
#define WATER_TYPE_SCATTERING(t) ((t) == 1 ? vec3(0.075, 0.09, 0.085) : (t) == 2 ? vec3(0.010, 0.013, 0.018) : vec3(0.070, 0.085, 0.100))
const vec3 WATER_SEA_ABSORPTION_COEFF = WATER_TYPE_ABSORPTION(WATER_TYPE) * WATER_SEA_ABSORPTION;
const vec3 WATER_LAKE_ABSORPTION_COEFF = WATER_TYPE_ABSORPTION(WATER_LAKE_TYPE) * WATER_LAKE_ABSORPTION;
const vec3 WATER_RIVER_ABSORPTION_COEFF = WATER_TYPE_ABSORPTION(WATER_RIVER_TYPE) * WATER_RIVER_ABSORPTION;
const vec3 WATER_SEA_SCATTERING_COEFF = WATER_TYPE_SCATTERING(WATER_TYPE) * WATER_SEA_TURBIDITY;
const vec3 WATER_LAKE_SCATTERING_COEFF = WATER_TYPE_SCATTERING(WATER_LAKE_TYPE) * WATER_LAKE_TURBIDITY;
const vec3 WATER_RIVER_SCATTERING_COEFF = WATER_TYPE_SCATTERING(WATER_RIVER_TYPE) * WATER_RIVER_TURBIDITY;

vec3 waterKindMix(vec3 sea, vec3 lake, vec3 river) {
    vec3 w = waterKindWeights();
    return sea * w.x + lake * w.y + river * w.z;
}

/*
 * 混ぜた水の性質は prepare (sun_sky_light.csh) が毎フレーム 1 回求めて frameData.surfaceParams に置き、各パスは読むだけにする
 * 並び: [4] = (吸収 rgb, 波頭の尖り), [5] = (散乱 rgb, 映り込みの散らし)。吸収と散乱は WATER_FOG_DENSITY 込み
 * 読む所ごとに混ぜる式を入れると、大きいパス (composite2) がドライバの関数の展開の上限を超えて、展開しない呼び出しとローカルメモリの
 * 配列で組まれ、フレームが 1.5 倍に重くなった。prepare より前の shadow パスは 1 フレーム前の値を読む (重みは数秒かけて動くので差は出ない)
 */
const int WATER_MEDIUM_SLOT = 4;

vec3 waterAbsorption() { return frameData.surfaceParams[WATER_MEDIUM_SLOT].rgb; }
vec3 waterScattering() { return frameData.surfaceParams[WATER_MEDIUM_SLOT + 1].rgb; }
vec3 waterExtinction() { return waterAbsorption() + waterScattering(); }
const float WATER_MULTI_SCATTER = 2.0;         // 水の内散乱の多重散乱分の持ち上げ
// 上から見た水の内散乱は、水面から入った光が視線側 (上) へ戻る後方散乱だけ。海の粒子の位相関数は前方に強く尖っていて
// 後方散乱は散乱全体の数 % しかないので、等方散乱のままだと深い所が暗い紺にならず明るい水色に浮く
const float WATER_BACKSCATTER = 0.08;
float waterChoppiness() { return frameData.surfaceParams[WATER_MEDIUM_SLOT].a; }
float waterReflectScatter() { return frameData.surfaceParams[WATER_MEDIUM_SLOT + 1].a; }

#ifdef SSBO_FRAME_DATA_WRITE
void waterMediumStore() {
    vec3 a = waterKindMix(WATER_SEA_ABSORPTION_COEFF, WATER_LAKE_ABSORPTION_COEFF, WATER_RIVER_ABSORPTION_COEFF) * WATER_FOG_DENSITY;
    vec3 b = waterKindMix(WATER_SEA_SCATTERING_COEFF, WATER_LAKE_SCATTERING_COEFF, WATER_RIVER_SCATTERING_COEFF) * WATER_FOG_DENSITY;
    float chop = WATER_CHOPPINESS * waterKindMix(WATER_SEA_CHOPPINESS, WATER_LAKE_CHOPPINESS, WATER_RIVER_CHOPPINESS);
    float scatter = waterKindMix(WATER_REFLECT_SCATTER, WATER_LAKE_REFLECT_SCATTER, WATER_RIVER_REFLECT_SCATTER);
    frameData.surfaceParams[WATER_MEDIUM_SLOT] = vec4(a, chop);
    frameData.surfaceParams[WATER_MEDIUM_SLOT + 1] = vec4(b, scatter);
}
#endif

float waterLayerTile(int i) { return WATER_LAYER0_TILE * WATER_WAVE_LENGTH / pow(WATER_LAYER_RATIO, float(i)); }

// 層のテクスチャのループの周期 (秒)。gen_water_waves.py の時間の丸めと同じ式
float waterLayerPeriod(float tile) { return WATER_TIME_HARMONIC_LO * sqrt(TAU * tile / (WATER_TIME_N_LO * WATER_GRAVITY)); }

/*
 * 表面張力波 (波長 0.11 / 0.038 ブロック) の 2 層。最小の層より短い波は、画素より細かい粗さにしか無く、近くの水面の
 * 太陽の照り返しが 1 つの柔らかい楕円になっていた。この 2 層は法線では描かず、どの距離でも粗さ (と WATER_GLITTER の点) にする
 * (近くで画素より大きい間を法線で描くと、遠目では大きな波なのに近づくほど細かい波が現れ、同じ形の波が入れ子に見えた)。
 * 法線で描く最短の層はワールドで固定 (最小の層、波長 0.32 ブロック) なので、近づいても波の形は遠目のまま拡大されるだけ。
 * WATER_LAYERS は増やさない (視差・コースティクス・水たまりの波が層の番号に依存するため)
 */
const int WATER_CAPILLARY_LAYERS = 2;
const float WATER_CAPILLARY_NEAR_ROUGH = 0.2;  // 表面張力波が画素より大きい近くで、粗さへ回す傾きの分散の割合
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

/*
 * 種類ごとの波の高さの倍率は分散の重みに 2 乗で掛ける (1 種類だけの時に振幅がちょうど倍率倍)。白波の量に使う風速の重みにも掛かるので、
 * 高い波ほど白波も増える。2 乗は定数で畳む (関数で書くと composite2 がドライバの関数の展開の上限を超える。waterMediumStore の注)
 */
const float WATER_SEA_WAVE_VAR = WATER_SEA_WAVE_HEIGHT * WATER_SEA_WAVE_HEIGHT;
const float WATER_LAKE_WAVE_VAR = WATER_LAKE_WAVE_HEIGHT * WATER_LAKE_WAVE_HEIGHT;
const float WATER_RIVER_WAVE_VAR = WATER_RIVER_WAVE_HEIGHT * WATER_RIVER_WAVE_HEIGHT;

// skyLm: スカイライト (0-1)。屋根の下や洞窟の水は風が当たらないので凪ぐ
WaterSea waterSeaStateEval(float skyLm) {
    WaterSea sea;
    for (int i = 0; i < WATER_LAYERS; i++) sea.amp[i] = 0.0;
    for (int i = 0; i < WATER_CAPILLARY_LAYERS; i++) sea.capAmp[i] = 0.0;
    sea.wind = 0.0;
    vec3 kind = waterKindWeights();
    float wind = WATER_WIND_SPEED * mix(WATER_SHELTER_WIND, 1.0, smoothstep(WATER_SHELTER_SKYLM.x, WATER_SHELTER_SKYLM.y, skyLm));
    waterAddSpectrum(sea, kind.x * WATER_SEA_WAVE_VAR, wind, WATER_FETCH_OCEAN, 1.0);
    waterAddSpectrum(sea, kind.y * WATER_LAKE_WAVE_VAR, wind * WATER_LAKE_WAVES, WATER_FETCH_LAKE, 0.0);
    waterAddSpectrum(sea, kind.z * WATER_RIVER_WAVE_VAR, wind * WATER_RIVER_WAVES, WATER_FETCH_RIVER, 0.0);
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
    vec2 side = vec2(-dir.y, dir.x) * WATER_LAYER_MIRROR[i];
    vec2 q = vec2(dot(p, dir), dot(p, side)) / tile + WATER_LAYER_OFFSET[i];
    vec4 s = waterWaveTexel(vec3(q, t / waterLayerPeriod(tile)), footprint * WATER_TEX_SIZE / tile) * 2.0 - 1.0;
    vec2 g = (dir * s.x + side * s.y) * WATER_TEX_SLOPE_RANGE;
    return amp * vec4(s.z * WATER_TEX_HEIGHT_RANGE * tile, g, s.w * WATER_TEX_JACOBIAN_RANGE);
}

vec4 waterLayer(vec2 p, int i, float amp, float t) {
    float tile = waterLayerTile(i);
    float a = WATER_WIND_ANGLE + WATER_LAYER_ANGLE[i];
    vec2 dir = vec2(cos(a), sin(a));
    vec2 side = vec2(-dir.y, dir.x) * WATER_LAYER_MIRROR[i];
    vec2 q = vec2(dot(p, dir), dot(p, side)) / tile + WATER_LAYER_OFFSET[i];
    vec4 s = texture(waterWaveTex, vec3(q, t / waterLayerPeriod(tile))) * 2.0 - 1.0;
    vec2 g = (dir * s.x + side * s.y) * WATER_TEX_SLOPE_RANGE;
    return amp * vec4(s.z * WATER_TEX_HEIGHT_RANGE * tile, g, s.w * WATER_TEX_JACOBIAN_RANGE);
}

// 層が画素の大きさ footprint (ブロック) に対して表せる割合。帯の短い端 (タイルの約 5 テクセル) が 2 画素を切る前に消す
// (2.5-6 テクセル/画素では、帯の短い側が 1-2 画素の波になって中距離の水面が細かい白い砂目にざらついた)
// 表面張力波と風の息に使う。法線で描く 5 層は waterLayerResolved
float waterTileResolved(float tile, float footprint) {
    float fadeStart = mix(WATER_WAVE_FADE_START, WATER_LOD_FADE_START, smoothstep(WATER_WAVE_NEAR.x, WATER_WAVE_NEAR.y, footprint));
    return footprint > 0.0 ? 1.0 - smoothstep(fadeStart, WATER_LOD_FADE_END, footprint * WATER_TEX_SIZE / tile) : 1.0;
}

/*
 * 法線で描く 5 層を薄める範囲 (1 画素あたりのテクセル数)。帯の中心の波長 (15 テクセル) が画面で 3.8 画素から 1.5 画素になる間で消す
 * 表面張力波と同じ 1.5-4 テクセル (中心の波長 10-3.8 画素) で落とすと、中景〜遠景は数画素より大きい波の形だけになり、波の列ごとの
 * 照り返しがのっぺりした面に均された。画素に近い波の傾きの揺れは照り返しの粗さ (WaterLod の pixelSlopeVar) と映り込みの散らし
 * (waterReflectAlpha) が受け持つので、ここまで描いても白い砂目やちらつきにならない
 */
const vec2 WATER_LAYER_FADE = vec2(4.0, 10.0);

float waterLayerResolved(int i, float footprint) {
    return footprint > 0.0 ? 1.0 - smoothstep(WATER_LAYER_FADE.x, WATER_LAYER_FADE.y, footprint * WATER_TEX_SIZE / waterLayerTile(i)) : 1.0;
}

/*
 * 層 first .. last-1 の高さ (と勾配, 発散) の和。画素より細かい層は足さない (ちらつきの元になるため)
 * 視差・波頭・コースティクスの高さの位置に使う。法線は WaterLod の振幅で引く (lib/common/water_normal.glsl の waterWaveSum)
 */
vec4 waterWaveSum(WaterSea sea, vec2 p, int first, int last, float footprint) {
    float t = frameTimeCounter;
    vec4 sum = vec4(0.0);
    for (int i = first; i < last; i++) {
        float r = waterLayerResolved(i, footprint);
        // タイルは単調に小さくなるので、表せない層が出たら残りも全部表せない
        if (r <= 0.0) break;
        if (sea.amp[i] > 0.0) sum += waterLayer(p, i, sea.amp[i] * r, t);
    }
    return sum;
}

/*
 * 波頭を寄せた面 (x' = x - lambda D) の Jacobian。勾配はこれで割ると 1 次元では厳密 (dh/dx' = (dh/dx) / J)
 * 山 (発散が正) で J < 1 になって斜面が立ち、谷は寝る。J が小さい所は波が崩れかけ (白波)
 */
float waterJacobian(vec4 w) { return max(1.0 - waterChoppiness() * w.w, WATER_JACOBIAN_MIN); }
vec3 waterChoppy(vec4 w) { return vec3(w.x, w.yz / waterJacobian(w)); }

// 表面張力 / 密度 (m^3/s^2)。波長 2 cm 前後より短い波は表面張力で速く進む
const float WATER_SURFACE_TENSION = 7.28e-5;

// 波長 (ブロック = m) の波の位相の速さ (m/s)。分散関係 omega^2 = g k + (sigma / rho) k^3
float waterPhaseSpeed(float wavelength) {
    float k = TAU / wavelength;
    return sqrt(WATER_GRAVITY / k + WATER_SURFACE_TENSION * k);
}

/*
 * 画素より細かい波で粗くなった水面の反射 (slopeVar = WaterLod の unresolved.x)。画素の中で見える微小面は視線の側へ傾くので、
 * かすめ角でも実効の NoV は傾きの RMS ほどに留まり (フレネルが 1 に張り付かない)、反射は傾きの分だけ高い空を映す。
 * 平らな鏡のままだと、遠くの水面が地平線の空をそのまま映して地平線の手前に明るい帯ができ、水平線が消えていた
 */
// 反射の仰角の持ち上げ (傾きの RMS あたり)。1.6 では中景 (層を落とした傾きの RMS 0.15 前後) の空の反射が R によらず
// 仰角 0.25 付近の 1 行になり、夕方の雲が上下の切れた四角い縦縞に並んだ
const float WATER_ROUGH_REFLECT_LIFT = 1.0;

// roughFar: フレネルを均す割合 (WaterLod の roughFar)
float waterRoughNoV(float NoV, float slopeVar, float roughFar) {
    return sqrt(NoV * NoV + slopeVar * roughFar);
}

/*
 * 持ち上げた方向は空を引く時だけ使い、SSR (島・岸) は持ち上げない元の方向で辿る。SSR まで持ち上げると、
 * 中景の水面に入る島・地平線の地形の映り込みが全部空に置き換わって消えていた
 */
vec3 waterRoughReflectDir(vec3 R, float slopeVar) {
    if (R.y < 0.0) return R;
    return normalize(vec3(R.x, sqrt(R.y * R.y + sqr(WATER_ROUGH_REFLECT_LIFT) * slopeVar), R.z));
}

/*
 * 映り込み (物と空) を、画素より細かい波の傾きの分だけ散らす粗さ (知覚の粗さ)。散らさないと遠くとかすめ角の水面は表した長い波だけで
 * 映り込みの向きが決まり、細かい波の多い湖・川では十数ブロック先から映り込みが揺れない平らな鏡になる
 * 散らすのは GGX の可視法線 (VNDF) なので、長い裾の分を設定 WATER_REFLECT_SCATTER で詰める (傾きの RMS に対する alpha の比)。
 * かすめ角では散らしが仰角の向きに大きく方位の向きに小さく出るので、映り込みは縦に伸びる
 * 1 で傾きの分の全部、小さいほど鏡に近い。0.5 以上では池の十数ブロック先の木や海の氷山の映り込みがほぼ消えて、
 * 空の色の一様なすりガラスになった
 */
/*
 * 散らしの alpha がこの範囲より小さい水面 (凪・風の無い表面張力波だけ・近くの水面) は、フル解像度の鏡のまま辿る
 * (数度より小さいぼけのために半分の解像度へ落とすと、凪の水面の映り込みがぼけて鏡でなくなった)。範囲の中は鏡と散らした映り込みを混ぜる
 */
const vec2 WATER_REFLECT_MIRROR_ALPHA = vec2(0.02, 0.03);

/*
 * 散らしの割合 (waterReflectScatter) は海・湖・川ごと (WATER_REFLECT_SCATTER が海)。湖と川の既定は 0 で鏡にする。散らすと、望遠で対岸を
 * 見た時に、法線で描けない手前の細かい波が画面で縦に詰まって平らに見えるのに映り込みだけがにじみ、水面がのっぺりした面に見えた
 */
float waterReflectAlpha(float slopeVar) {
#if REFLECTIONS >= 2
    return sqrt(slopeVar) * waterReflectScatter();
#else
    // 粗い反射の経路が無い (SSR だけ) 設定では鏡のまま
    return 0.0;
#endif
}

// 映り込みの知覚の粗さ。鏡のまま辿る水面は 0
float waterReflectRoughness(float slopeVar) {
    float a = waterReflectAlpha(slopeVar);
    return a < WATER_REFLECT_MIRROR_ALPHA.x ? 0.0 : sqrt(a);
}

// フル解像度の鏡の映り込みの重み (1 で鏡のまま、0 で散らした映り込みだけ)
float waterReflectMirror(float slopeVar) {
    return 1.0 - smoothstep(WATER_REFLECT_MIRROR_ALPHA.x, WATER_REFLECT_MIRROR_ALPHA.y, waterReflectAlpha(slopeVar));
}

// 散らした向きで空を引く時に、散らしきらなかった傾きの分だけ仰角を持ち上げる分散
float waterReflectLiftVar(float slopeVar, bool scattered) {
    return scattered ? slopeVar * (1.0 - sqr(waterReflectScatter())) : slopeVar;
}

#endif
