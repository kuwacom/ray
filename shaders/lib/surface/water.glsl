/*
 * 水面 (surface モジュール)
 * - 波: FFT で焼いた周期タイル (tools/gen_water_waves.py, Tessendorf 2001) を無理数比 (2.9 倍) で 5 層に重ねる
 *       テクスチャは対数波数の cos^2 窓の帯で、隣の層と足すと切れ目のないスペクトルになる。時間方向もループしていて、
 *       層ごとに周期を sqrt(タイルの大きさ) に比例させるので、どの層も深水の分散関係 (omega = sqrt(g k)) で動く
 *       層の重み (傾きの分散) は風速と吹送距離から決める: 平衡域の傾きの分散は波数の対数あたり一定 (Phillips) で、
 *       それより長い波はピーク (Pierson-Moskowitz / JONSWAP) で切る。全体は Cox-Munk (1954) の傾きの分散に合わせる
 *       波頭の尖りは水平変位の Jacobian で勾配を割って出す (チョッピネス)。画素より細かい層は粗さへ回す
 * - 海 / 湖 / 川 はカメラのバイオームで切り替える (湖・川は吹送距離が短く、波が短く低い)。傾いた流れの面は流れの向きへ流す
 * - 雨の波紋: セルごとの同心円 (2 層ずらし)
 * - 吸収 / 散乱: Jerlov の外洋タイプ IB 付近の係数 (1 ブロック = 1 m)
 * - コースティクス: 受け面側で水面の屈折光の面積比 (ヤコビアン) を有限差分で求める
 */
#ifndef SURFACE_WATER_GLSL
#define SURFACE_WATER_GLSL

// プレビュー用の旧版 (テクスチャ波) と見分けるための印
#define WATER_FFT_WAVES

uniform sampler3D waterWaveTex;
// カメラのバイオームが川 (shaders.properties の smooth)。海は distantOcean を使う
uniform float waterRiver;

const float WATER_IOR = 1.333;
const float WATER_GRAVITY = 9.81;
// 横向きの面 (滝・流れの側面) は波を弱める
// -> 海のスペクトルを弱めて貼るのをやめ、側面専用の落ちる水の乱れ (waterFallNormal) にした

// ---- 波テクスチャ (gen_water_waves.py と揃える) ----
const int WATER_LAYERS = 5;
const float WATER_LAYER_RATIO = 2.9;
// 最大の層のタイルの大きさ (ブロック)。帯の中心の波長はタイル / WATER_BAND_CENTER (既定で 22, 7.8, 2.7, 0.93, 0.32 ブロック)
const float WATER_LAYER0_TILE = 192.0;
const float WATER_BAND_CENTER = 8.5;
const float WATER_TEX_SIZE = 128.0;
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

// ---- スペクトル ----
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

// ---- 波頭・流れ ----
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
    // 散乱は外洋の粒子散乱の下限寄り (0.03-0.05 では浅瀬が底まで透けて浅いプールに見えた)
    // 緑と青の吸収 0.09 / 0.03 では手前の水が底の砂の照り返しで明るいターコイズに浮いた (iterationT の約 4 倍の明るさ)。
    // 緑を青より強く吸わせて紺に寄せる
    const vec3 WATER_ABSORPTION_COEFF = vec3(0.45, 0.20, 0.09);
    const vec3 WATER_SCATTERING_COEFF = vec3(0.090, 0.110, 0.130);
#endif
vec3 waterAbsorption() { return WATER_ABSORPTION_COEFF * WATER_FOG_DENSITY; }
vec3 waterScattering() { return WATER_SCATTERING_COEFF * WATER_FOG_DENSITY; }
vec3 waterExtinction() { return waterAbsorption() + waterScattering(); }

float waterLayerTile(int i) { return WATER_LAYER0_TILE * WATER_WAVE_LENGTH / pow(WATER_LAYER_RATIO, float(i)); }

// 層のテクスチャのループの周期 (秒)。gen_water_waves.py の時間の丸めと同じ式
float waterLayerPeriod(float tile) { return WATER_TIME_HARMONIC_LO * sqrt(TAU * tile / (WATER_TIME_N_LO * WATER_GRAVITY)); }

// 海の状態: 層ごとの傾きの RMS (ブロック/ブロック) と、層より細かい波の傾きの分散
struct WaterSea {
    float amp[WATER_LAYERS];
    float microVar;
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
        sea.amp[i] += v;
    }
    sea.amp[0] += WATER_SWELL_VAR0 * swell * weight;
    sea.amp[1] += WATER_SWELL_VAR1 * swell * weight;
    float smallest = waterLayerTile(WATER_LAYERS - 1) / (WATER_BAND_CENTER * WATER_LAYER_RATIO);
    sea.microVar += waterSlopeDensity(U) * log(max(smallest / WATER_CAPILLARY_WAVELENGTH, 1.0)) * WATER_RIPPLES * weight;
    sea.wind += U * weight;
}

// skyLm: スカイライト (0-1)。屋根の下や洞窟の水は風が当たらないので凪ぐ
WaterSea waterSeaState(float skyLm) {
    WaterSea sea;
    for (int i = 0; i < WATER_LAYERS; i++) sea.amp[i] = 0.0;
    sea.microVar = 0.0;
    sea.wind = 0.0;
    float ocean = saturate(distantOcean);
    float river = saturate(waterRiver) * (1.0 - ocean);
    float wind = WATER_WIND_SPEED * mix(WATER_SHELTER_WIND, 1.0, smoothstep(0.3, 0.9, skyLm));
    waterAddSpectrum(sea, ocean, wind, WATER_FETCH_OCEAN, 1.0);
    waterAddSpectrum(sea, 1.0 - ocean - river, wind * WATER_LAKE_WAVES, WATER_FETCH_LAKE, 0.0);
    waterAddSpectrum(sea, river, wind * WATER_RIVER_WAVES, WATER_FETCH_RIVER, 0.0);
    float h2 = 0.0;
    for (int i = 0; i < WATER_LAYERS; i++) {
        sea.amp[i] = sqrt(sea.amp[i]) * WATER_WAVE_HEIGHT;
        h2 += sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
    }
    sea.microVar *= sqr(WATER_WAVE_HEIGHT);
    sea.heightRms = sqrt(h2);
    return sea;
}

/*
 * 層 i を引く。戻り値 x = 高さ (ブロック), yz = 勾配 (ワールドの 2D), w = 水平変位の発散 (Jacobian の 1 次の項)
 * テクスチャの +x を風下に向け、タイルの長さで割った座標で引く。勾配はタイルの大きさによらず振幅 (傾きの RMS) 倍
 */
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
float waterLayerResolved(int i, float footprint) {
    return footprint > 0.0 ? 1.0 - smoothstep(1.5, 4.0, footprint * WATER_TEX_SIZE / waterLayerTile(i)) : 1.0;
}

// 層 first .. last-1 の和 (高さ, 勾配, 発散)。画素より細かい層は足さない (ちらつきの元になるため)
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
 * 流れのある面: 2 つの位相で流れの向きへずらした波を交互に混ぜる (flow map の定番)。flow は速度 (ブロック/秒)
 * 無相関な 2 つを重み w, 1 - w で混ぜると分散が w^2 + (1 - w)^2 倍に落ちるので戻す
 */
vec4 waterWaveSumFlow(WaterSea sea, vec2 p, int first, int last, float footprint, vec2 flow) {
    if (dot(flow, flow) < 1e-4) return waterWaveSum(sea, p, first, last, footprint);
    float phase = fract(frameTimeCounter / WATER_FLOW_CYCLE);
    vec4 a = waterWaveSum(sea, p - flow * (phase * WATER_FLOW_CYCLE), first, last, footprint);
    vec4 b = waterWaveSum(sea, p - flow * (fract(phase + 0.5) * WATER_FLOW_CYCLE) + 0.37, first, last, footprint);
    float wa = 1.0 - abs(1.0 - 2.0 * phase);
    return (a * wa + b * (1.0 - wa)) * inversesqrt(sqr(wa) + sqr(1.0 - wa));
}

/*
 * 波頭を寄せた面 (x' = x - lambda D) の Jacobian。勾配はこれで割ると 1 次元では厳密 (dh/dx' = (dh/dx) / J)
 * 山 (発散が正) で J < 1 になって斜面が立ち、谷は寝る。J が小さい所は波が崩れかけ (白波)
 */
float waterJacobian(vec4 w) { return max(1.0 - WATER_CHOPPINESS * w.w, WATER_JACOBIAN_MIN); }
vec3 waterChoppy(vec4 w) { return vec3(w.x, w.yz / waterJacobian(w)); }

// 視差・コースティクス用: 長い 4 層の高さと (尖らせた) 勾配。戻り値 x = 高さ, yz = 勾配
vec3 waterWaves(vec2 p) {
    return waterChoppy(waterWaveSum(waterSeaState(1.0), p, 0, WATER_LAYERS - 1, 0.0));
}

/*
 * 法線で表せなかった傾きの分散 (GGX の alpha^2 に足す)。画素の中で平均された波は面を粗くする (LEAN / Toksvig と同じ考え)
 * 遠くの水面で太陽の照り返しが縦に広がる帯になるのはこの分
 */
/*
 * 層より細かい表面張力波 (microVar) は粗さに一部だけ回す。全部回すと近景でも太陽の鏡面の alpha が 0.1 前後に広がり、
 * 波の斜面に柔らかい白い染みが乗ってプラスチックのようなマットな水面に見えた。近景の照り返しは表した波の鋭いきらめきに任せる
 * 遠景の照り返しの帯・空の持ち上げは、落とした層の分散 (下のループ) が受け持つ
 */
const float WATER_MICRO_ROUGHNESS = 0.2;

float waterUnresolvedSlopeVar(WaterSea sea, float footprint) {
    float v = sea.microVar * WATER_MICRO_ROUGHNESS;
    for (int i = 0; i < WATER_LAYERS; i++) {
        float r = waterLayerResolved(i, footprint);
        // 法線側に r 倍を残すので、分散の合計が保たれるよう 1 - r^2 を回す
        v += (1.0 - r * r) * sqr(sea.amp[i]);
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

/*
 * 太陽・月の照り返しのきらめき (sun glitter)
 * 画素より細かい波の面 (微小面) は数が限られ、太陽をちょうど目へ映す向きの面は 1 画素に 0 個か数個しかない。
 * 傾きを滑らかなローブ (GGX の alpha) に畳むと、それが平らな白い円盤になり、きらめきもブルーム・光条も出なかった
 * 傾きの分布 (Cox-Munk の正規分布, 分散 slopeVar) から太陽を映す面の密度を求め、ワールドに固定したセルごとに
 * Poisson 分布で個数を引いて輝点にする (Zirr & Kaplanyan 2016 / Jakob 2014 の離散微小面の考え方を簡略化)
 * 輝点の期待値はローブと同じなのでエネルギーは変えず、HDR の明るさのまま点に集まる
 */
const float GLINT_FACET = 0.02;                   // 太陽を映す微小面の大きさ (ブロック = m)。表面張力波から短い重力波の斜面
const float GLINT_DOT_PX = 0.7;                   // 輝点の半径の下限 (画素)。これより小さいと画素の中心に当たるかどうかで点が欠ける
const float GLINT_LIFETIME = 0.25;                // 1 つの輝点の寿命 (秒)。半周期ずらした 2 組を sin^2 / cos^2 で重ねて明滅をつなぐ
const vec2 GLINT_SMOOTH_LAMBDA = vec2(1.5, 6.0);  // 画素の中の輝点の期待個数がこの範囲で滑らかなローブへ移す (遠くの光の道)
const int GLINT_MAX_COUNT = 4;                    // 1 セル 1 組の輝点の最大数

// 1 セル 1 組の輝点の核の和 (面積あたりの密度)。p は水平面の位置, rho は輝点の半径
float waterGlintCell(ivec2 cell, uint seed, float lambda, vec2 p, float cellSize, float rho) {
    uvec2 c = uvec2(cell + 32768);
    float u = hash3(uvec3(c, seed)).x;
    // 個数は逆 CDF で引く。同じ u なら lambda が少し違う隣の画素でも同じ個数になり、輝点が画素の境で切れない
    float term = exp(-lambda);
    float cdf = term;
    float sum = 0.0;
    for (int i = 0; i < GLINT_MAX_COUNT; i++) {
        if (u <= cdf) break;
        term *= lambda / float(i + 1);
        cdf += term;
        vec2 center = (vec2(cell) + hash3(uvec3(c, seed * 8u + uint(i) + 7919u)).xy) * cellSize;
        float d2 = dot(p - center, p - center) / (rho * rho);
        if (d2 < 1.0) sum += sqr(1.0 - d2);
    }
    // (1 - d^2 / rho^2)^2 の面積分は pi rho^2 / 3
    return sum * 3.0 / (PI * rho * rho);
}

/*
 * worldXZ: 水面のワールド座標 (水平), N: 表した波の法線, L: 太陽 (月) の向き, slopeVar: 画素より細かい傾きの分散,
 * sunRadius: 円盤の視半径, pixelWorld: 水面上の画素の幅 (ブロック), NoVGeo: 平均水面と視線の cos
 * 戻り値 x = 照り返しのローブに掛ける倍率 (期待値 1, 滑らかな分を含む), y = そのうち輝点の分 (TAA を通さない)
 */
vec2 waterSunGlint(vec2 worldXZ, vec3 N, vec3 V, vec3 L, float slopeVar, float sunRadius, float pixelWorld, float NoVGeo) {
    vec3 H = normalize(L + V);
    float NoH = dot(N, H);
    if (NoH <= 0.0) return vec2(1.0, 0.0);
    slopeVar = max(slopeVar, 1e-5);
    float tan2 = (1.0 - NoH * NoH) / (NoH * NoH);
    // 太陽の円盤が半ベクトルの傾きの平面で占める面積 (半角の立体角 / cos^3)
    float sunArea = PI * sqr(0.5 * sunRadius) / (NoH * NoH * NoH);
    float p = min(exp(-tan2 / slopeVar) / (PI * slopeVar) * sunArea, 1.0);
    float density = p / sqr(GLINT_FACET);   // 太陽を映す面の数 (ブロック^2 あたり)
    float lambdaPx = density * sqr(pixelWorld) / max(NoVGeo, 0.02);
    float rho = max(GLINT_FACET, GLINT_DOT_PX * pixelWorld);
    // セルは輝点の直径以上 (2 の冪に丸める)。点は自分のセルの外へ半径ぶんしかはみ出さないので、近い 2x2 だけ見ればよい
    float cellSize = exp2(ceil(log2(2.0 * rho)));
    float lambdaCell = density * cellSize * cellSize;
    float smoothW = max(smoothstep(GLINT_SMOOTH_LAMBDA.x, GLINT_SMOOTH_LAMBDA.y, lambdaPx),
                        smoothstep(0.4, 0.8, lambdaCell / float(GLINT_MAX_COUNT)));
    // 正規分布の裾 (太陽から大きく外れた向き) は輝点がほぼ出ないので探さない
    if (smoothW >= 1.0 || lambdaCell < 1e-4) return vec2(smoothW, 0.0);

    vec2 q = worldXZ / cellSize;
    ivec2 base = ivec2(floor(q - 0.5));
    float t = frameTimeCounter / GLINT_LIFETIME;
    float sum = 0.0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            ivec2 cell = base + ivec2(i, j);
            // セルごとに位相をずらす (画面中の輝点が揃って入れ替わらないように)
            float phase = hash3(uvec3(uvec2(cell + 32768).yx, 101u)).z;
            for (int s = 0; s < 2; s++) {
                float ts = t + phase + 0.5 * float(s);
                uint slot = uint(floor(ts)) * 2u + uint(s);
                sum += sqr(sin(PI * fract(ts))) * waterGlintCell(cell, slot, lambdaCell, worldXZ, cellSize, rho);
            }
        }
    }
    float point = (1.0 - smoothW) * sum / density;
    return vec2(smoothW + point, point);
}

/*
 * 雨の波紋 (1 層)。セルの中に 1 つ、広がって消える輪を置く。戻り値は高さの勾配
 */
const float RIPPLE_CELL = 0.7;      // セルの大きさ (ブロック)
const float RIPPLE_RATE = 1.1;      // 1 秒あたりの発生回数
const float RIPPLE_FREQ = 55.0;     // 輪の細かさ
const float RIPPLE_STRENGTH = 0.012;

vec2 rippleLayer(vec2 p, float t, uint seed) {
    vec2 cell = floor(p);
    vec2 f = p - cell;
    vec3 h = hash3(uvec3(uvec2(ivec2(cell) + 32768), seed));
    vec2 c = 0.3 + 0.4 * h.xy;
    float phase = fract(t * RIPPLE_RATE + h.z);
    vec2 d = f - c;
    float r = length(d);
    // 輪の最大半径をセル端までに収めて隣のセルを見なくて済むようにする
    float x = (r - phase * 0.3) * RIPPLE_FREQ;
    float window = saturate(1.0 - abs(x) / TAU);
    float env = sqr(1.0 - phase) * window;
    return cos(x) * RIPPLE_FREQ * env * d / max(r, 1e-4);
}

// 雨の波紋の勾配 (ブロック座標)。strength は雨の強さ x 露天度
vec2 rainRipples(vec2 p, float strength) {
    if (strength <= 0.001) return vec2(0.0);
    float t = frameTimeCounter;
    vec2 g = rippleLayer(p / RIPPLE_CELL, t, 11u) + rippleLayer(p / RIPPLE_CELL + 0.5, t + 0.37, 23u);
    return g * RIPPLE_STRENGTH / RIPPLE_CELL * strength;
}

// 水面の 2D 座標系 (法線を z とする基底)。水平面はワールドの xz、側面は面内の 2 軸
mat3 waterBasis(vec3 geoNormal) {
    if (abs(geoNormal.y) > 0.5) {
        float s = sign(geoNormal.y);
        return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, s), geoNormal);
    }
    return tbnFromNormal(geoNormal);
}

/*
 * 流れの速度 (水面の 2D 座標, ブロック/秒)。faceNormal: 三角形の実際の向き (画面微分から)
 * バニラの流れる水の上面は角ごとに高さが違って傾き、法線は下流側へ倒れる。側面 (滝) は下へ流れる
 */
vec2 waterFlowVelocity(vec3 faceNormal, vec3 geoNormal) {
    if (abs(geoNormal.y) > 0.5) {
        vec2 tilt = faceNormal.xz * sign(geoNormal.y);
        float slope = length(tilt);
        if (slope < 0.02) return vec2(0.0);
        return tilt / slope * min(slope * WATER_FLOW_SPEED / max(abs(faceNormal.y), 0.2), WATER_FLOW_MAX);
    }
    mat3 basis = waterBasis(geoNormal);
    return vec2(-basis[0].y, -basis[1].y) * WATER_FALL_SPEED;
}

/*
 * 側面 (滝・流れの段差) の波。海の FFT の層をそのまま面に貼ると、海のバイオームでは 22 ブロックの長い波が
 * 1-2 ブロック幅の滝の上では一様な傾きになり、ゆっくり傾くだけの滑らかなガラス板に見えた
 * 落ちる水の乱れは流れの向きに引き伸ばされた細かい筋 (縦に長いさざ波) なので、同じ波テクスチャの短い帯だけを
 * 縦に引き伸ばして貼り、下へ流す。テクスチャの風下 (+x) を面の横に向けると波の峰が縦に並ぶ
 * 強さはバイオーム (風) によらない。滝の落ちる速さは WATER_FALL_SPEED
 */
const int WATER_FALL_LAYERS = 3;
// 層の横のタイルの大きさ (ブロック)。帯の中心の波長はタイル / WATER_BAND_CENTER (0.94, 0.33, 0.12 ブロック)
const float WATER_FALL_TILE[WATER_FALL_LAYERS] = float[](8.0, 2.8, 1.0);
// 層ごとの傾きの RMS (横方向。縦は WATER_FALL_STRETCH で割れる)
const float WATER_FALL_SLOPE[WATER_FALL_LAYERS] = float[](0.10, 0.08, 0.05);
// 層ごとの落ちる速さの倍率。同じ速さだと模様が 1 枚の絵のまま滑り落ちて見えるので、細かい乱れほど少し速くする
const float WATER_FALL_LAYER_SPEED[WATER_FALL_LAYERS] = float[](1.0, 1.25, 1.6);
const vec2 WATER_FALL_LAYER_OFFSET[WATER_FALL_LAYERS] = vec2[](vec2(0.21, 0.63), vec2(0.77, 0.18), vec2(0.45, 0.91));
const float WATER_FALL_STRETCH = 3.0;          // 縦の引き伸ばし
// 波テクスチャの時間の進み (層の周期に対する倍率)。テクスチャの波は風下 (= 面の横) へ進むので、速いと峰が横へ流れて見える
const float WATER_FALL_EVOLVE = 0.35;

// 側面の面内の座標 (x = 面の横, y = 高さ) と、その横の向き
vec3 waterFallTangent(vec3 geoNormal) { return normalize(vec3(-geoNormal.z, 0.0, geoNormal.x)); }

float waterFallLayerResolved(int i, float footprint) {
    return footprint > 0.0 ? 1.0 - smoothstep(1.5, 4.0, footprint * WATER_TEX_SIZE / WATER_FALL_TILE[i]) : 1.0;
}

// 側面の波の勾配 (面内の 2D: x = 横, y = 高さ)
vec2 waterFallGradient(vec3 worldPos, vec3 geoNormal, float footprint) {
    vec2 p = vec2(dot(worldPos, waterFallTangent(geoNormal)), worldPos.y);
    float t = frameTimeCounter;
    vec2 g = vec2(0.0);
    for (int i = 0; i < WATER_FALL_LAYERS; i++) {
        float r = waterFallLayerResolved(i, footprint);
        if (r <= 0.0) break;
        float tile = WATER_FALL_TILE[i];
        // 高さに落ちた距離を足すと、同じ模様が時間とともに下へ動く
        vec2 q = vec2(p.x / tile, (p.y + WATER_FALL_SPEED * WATER_FALL_LAYER_SPEED[i] * t) / (tile * WATER_FALL_STRETCH))
            + WATER_FALL_LAYER_OFFSET[i];
        vec4 s = texture(waterWaveTex, vec3(q, t * WATER_FALL_EVOLVE / waterLayerPeriod(tile))) * 2.0 - 1.0;
        // 縦に引き伸ばした分だけ縦の傾きは緩む
        g += vec2(s.x, s.y / WATER_FALL_STRETCH) * (WATER_TEX_SLOPE_RANGE * WATER_FALL_SLOPE[i] * r);
    }
    return g;
}

// 側面の画素より細かい乱れの傾きの分散 (太陽の鏡面の粗さへ回す)
float waterFallUnresolvedSlopeVar(float footprint) {
    float v = 0.0;
    for (int i = 0; i < WATER_FALL_LAYERS; i++) {
        float r = waterFallLayerResolved(i, footprint);
        v += (1.0 - r * r) * sqr(WATER_FALL_SLOPE[i]);
    }
    return v;
}

vec3 waterFallNormal(vec3 worldPos, vec3 geoNormal, float footprint) {
    vec2 g = waterFallGradient(worldPos, geoNormal, footprint);
    return normalize(mat3(waterFallTangent(geoNormal), vec3(0.0, 1.0, 0.0), geoNormal) * vec3(-g, 1.0));
}

/*
 * 水面の法線 (player 空間)。worldPos は cameraPosition を足したワールド座標, footprint は waterFootprint, flow は waterFlowVelocity
 */
vec3 getWaterNormal(WaterSea sea, vec3 worldPos, vec3 geoNormal, float footprint, vec2 flow) {
#ifdef WATER_WAVES
    if (abs(geoNormal.y) <= 0.5) return waterFallNormal(worldPos, geoNormal, footprint);
    mat3 basis = waterBasis(geoNormal);
    vec2 p = vec2(dot(worldPos, basis[0]), dot(worldPos, basis[1]));
    vec2 g = waterChoppy(waterWaveSumFlow(sea, p, 0, WATER_LAYERS, footprint, flow)).yz;
    #ifdef HAS_SKY
        if (geoNormal.y > 0.5 && biome_precipitation == 1) g += rainRipples(p, rainStrength);
    #endif
    return normalize(basis * vec3(-g, 1.0));
#else
    return geoNormal;
#endif
}

/*
 * 反射方向に使う水面の法線。かすめ角では波の傾きを弱める
 * 遠くの島の映り込みは手前 (数十ブロック) の水面に入り、そこでは波が全部表せていて反射方向が島の見かけの高さ (数度) より
 * 大きく振れるので、映り込みが空と交互の細かい斑になって消えていた。太陽の照り返しと屈折・フレネルは元の法線のまま
 */
// 0.3 では中景の反射が地平線のもやを一様に映す白っぽい面になった。画素より細かい波は層ごと落とすようになり
// (waterFootprint を伸びた辺で測る)、中景に残るのは長い波だけで斑にならないので、傾きを多めに残して雲を映させる
const float WATER_REFLECT_GRAZING_KEEP = 0.6; // 真横から見た時に残す傾きの割合
const float WATER_REFLECT_GRAZING_NOV = 0.4;  // 視線と水面の cos がこれ以上なら傾きをそのまま使う

vec3 waterReflectNormal(vec3 N, vec3 V) {
    if (abs(N.y) < 0.5) return N;
    float keep = mix(WATER_REFLECT_GRAZING_KEEP, 1.0, smoothstep(0.0, WATER_REFLECT_GRAZING_NOV, abs(V.y)));
    return normalize(vec3(N.x * keep, N.y, N.z * keep));
}

/*
 * 水面の視差: 平均水面上の点 worldPos から視線方向 viewDir (カメラ -> 水面, 正規化) に沿って
 * 波の高さ場との交点を探す。上向きの面だけ。波の高さの +-WATER_PARALLAX_RANGE x RMS の間を等間隔に探して、最後に割線で詰める
 * (固定点反復は斜面の傾きが視線の傾きより大きいかすめ角で発散する)
 * かすめ角では探す距離が WATER_PARALLAX_MAX に収まるよう高さを縮める。そのままだと手前の大きな波の斜面が画面の大半に
 * 引き伸ばされてぼやけ、探す範囲を切った所で視差が途切れて段差が出た
 */
const int WATER_PARALLAX_STEPS = 5;
const float WATER_PARALLAX_RANGE = 2.5;
const float WATER_PARALLAX_MAX = 1.5;          // 視線に沿って探す最大距離 (ブロック)
// 視差に使う長い層の数。3 番目 (波長 1-8 ブロック) の高さは 0.03 ブロック前後で、足すと全画面の水で 1 ms 近く重くなる (GTX 1070, 1080p)
const int WATER_PARALLAX_LAYERS = 2;

vec3 waterParallax(WaterSea sea, vec3 worldPos, vec3 viewDir, float footprint) {
#if defined WATER_WAVES && defined WATER_PARALLAX
    float h2 = 0.0;
    for (int i = 0; i < WATER_PARALLAX_LAYERS; i++) h2 += sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
    float range = WATER_PARALLAX_RANGE * sqrt(h2);
    float scale = min(1.0, WATER_PARALLAX_MAX * -viewDir.y / max(range, 1e-5));
    range *= scale;
    // 高さの差が画素に満たなければ探さない
    if (viewDir.y >= -0.01 || range < footprint * 0.5) return worldPos;
    float t0 = range / viewDir.y;
    float t1 = -t0;
    // 視線の高さ - 波の高さ。始点では視線が波の上 (正)
    float prevT = t0;
    float prevD = viewDir.y * t0 - scale * waterWaveSum(sea, worldPos.xz + viewDir.xz * t0, 0, WATER_PARALLAX_LAYERS, footprint).x;
    for (int i = 1; i <= WATER_PARALLAX_STEPS; i++) {
        float t = mix(t0, t1, float(i) / float(WATER_PARALLAX_STEPS));
        float d = viewDir.y * t - scale * waterWaveSum(sea, worldPos.xz + viewDir.xz * t, 0, WATER_PARALLAX_LAYERS, footprint).x;
        if (d <= 0.0) {
            float hit = mix(prevT, t, prevD / max(prevD - d, 1e-5));
            return worldPos + viewDir * hit;
        }
        prevT = t;
        prevD = d;
    }
    return worldPos;
#else
    return worldPos;
#endif
}

/*
 * 水底のコースティクス (集光率)。receiverWorld: 受け面のワールド座標, depth: 光の方向に測った水面までの距離, L: 光源方向
 * 水面上の 3 点で屈折した光が水底でどれだけ広がるか (面積比) を求める。平らな水面なら厳密に 1
 * 最大の層 (波長 8 ブロック以上) は浅い水底ではほとんど集光しないので、2 番目から最小の手前までの 3 層を使う
 */
const float CAUSTICS_EPS = 0.06;
const float CAUSTICS_MAX = 5.0;

float waterCaustics(vec3 receiverWorld, float depth, vec3 L) {
#if defined WATER_CAUSTICS && defined WATER_WAVES
    if (L.y <= 0.05 || depth <= 0.02) return 1.0;
    WaterSea sea = waterSeaState(1.0);
    vec2 p0 = receiverWorld.xz + L.xz / L.y * depth;
    vec2 hit[3];
    for (int i = 0; i < 3; i++) {
        vec2 p = p0 + (i == 1 ? vec2(CAUSTICS_EPS, 0.0) : (i == 2 ? vec2(0.0, CAUSTICS_EPS) : vec2(0.0)));
        vec2 g = waterChoppy(waterWaveSum(sea, p, 1, WATER_LAYERS - 1, 0.0)).yz;
        vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
        vec3 r = refract(-L, n, 1.0 / WATER_IOR);
        float vertical = depth * L.y;
        hit[i] = p + r.xz * (vertical / max(-r.y, 0.05));
    }
    vec2 a = hit[1] - hit[0];
    vec2 b = hit[2] - hit[0];
    float area = abs(a.x * b.y - a.y * b.x);
    // 平らな水面なら 3 点とも同じだけずれるので面積は eps^2 のまま (比は厳密に 1)
    float ratio = (CAUSTICS_EPS * CAUSTICS_EPS) / max(area, 1e-6);
    // 深いほど焦点がずれてぼやけるので浅い所だけ強く出す
    float fade = exp(-depth * 0.08);
    return mix(1.0, min(ratio, CAUSTICS_MAX), fade);
#else
    return 1.0;
#endif
}

#endif
