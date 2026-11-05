/*
 * 画素より細かい波が太陽 (月) を映す点のきらめき (WATER_GLITTER)
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_GLITTER_GLSL
#define COMMON_WATER_GLITTER_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/water_waves.glsl"

/*
 * 曲がった水面の小さな面は、太陽の像を 1 つずつ映す (鏡面点)。単位面積あたりの点の数は「太陽を目へ返す傾きの確率密度 x ガウス曲率の
 * 絶対値の平均」で、1 つの点のエネルギーは曲率に反比例する (Longuet-Higgins 1960)。どちらも太陽の大きさによらない
 * 法線で表せない波を粗さ (ローブの広がり) にすると、本来は数個の画素に集まる光が広く薄く均され、照り返しがのっぺりした帯になる
 * ここでは粗さへ回した波の分を、ワールドに付いた点の集まりとして標本化する
 * - 点の数: 傾きの確率密度 (ガウス) x 曲率 (粗さへ回した層の曲率の 2 乗の和 x GLINT_CURVATURE)
 * - 1 つの明るさ: ローブ / 点の密度 に、曲率の小さい点ほど明るい 2 乗の裾の重みを掛ける。点の位置 (道の芯か端か) によらないので、
 *   道の端は点の数が減るだけで、1 つ 1 つは明るいまま光る
 * - 平均: 点がまばらな遠くは傾きの分布をガウスにしたローブ。GGX の裾にある薄い光 (道の外ののっぺりした滲み) は点にならない。
 *   点が詰まって滑らかな平均へ移る所と、粗さへ回した割合の小さい近景は GGX の裾を残す (道の縁を切り立たせない)
 * - 位置と寿命: セル (2 の冪、ワールドに固定) ごとに点を 1 つ置き、セルの格子をその大きさの波の位相の速さで風下へ流す。寿命は
 *   その波の周期の半分 (TAA が積分できる GLINT_MIN_FRAMES より短くしない)。半周期ずらした 2 組を sin^2 / cos^2 で重ねてつなぐ
 * - 波頭: 点の数を波頭の重み (waterGlintCrest) で寄せる。1 つの明るさは変えない
 * - 画素へは、標本の位置 (TAA のジッター込み) から半径 GLINT_RADIUS 画素の中の点を集める。TAA が画素の中の位置を積分する
 * 1 つのセルに置く点は 1 組 1 つまでなので、点の多い所は明るい点から順に置き、残りの暗い点の分は滑らかな平均として足す
 */
/*
 * ガウス曲率の絶対値の平均 / 曲率の 2 乗の和。一様な正規分布の面の理論の目安は 0.5 だが、それでは 2-10 m 先の道が白い点の
 * 砂目で埋まり、0.15 でも露出後 10 前後の暗い点が一面に散って灰色のざらつきになった。実際の表面張力波は風の息で場所ごとに
 * 途切れ、点が局所に偏る (波頭へ寄せる分は GLINT_CREST_SHORT)。実写の海の白く飛んだ点の数 (いちばん密な所で 100x100 画素に
 * 10-105 個、中央 34 個) に合わせた値
 */
const float GLINT_CURVATURE = 0.03;
const float GLINT_CREST = 0.5;              // 長い波の波頭へ寄せる強さ (表面張力波は長い波の波頭付近に集まる)
const float GLINT_CREST_MEAN = 0.18;        // 波頭の重み smoothstep(0, 2 sigma, h) の、正規分布の高さでの平均 (寄せても平均を変えない)
/*
 * 画面で波と分かる短い層 (0.93 / 0.32 ブロック) の波頭へ寄せる強さ。表面張力波は短い重力波の波頭の前の面に乗る (寄生さざ波) ので、
 * 2-5 m 先の点は細かい波の稜線に沿って並ぶ。重みは smoothstep(0, 2 sigma, h)^2 を平均で割ったもの (谷では 1 - 強さ まで減る)
 */
const float GLINT_CREST_SHORT = 0.85;
const int GLINT_CREST_SHORT_FIRST = 3;      // 短い層の最初の番号
const float GLINT_CREST_SHORT_MEAN = 0.119; // smoothstep(0, 2 sigma, h)^2 の正規分布の高さでの平均 (波テクスチャの高さでも 0.119)
const float GLINT_CREST_MAX = 16.0;         // 2 つの波頭の重みの積の上限の目安
const float GLINT_WEIGHT_MIN = 1e-4;        // 曲率の裾の一様乱数の下限 (1 つの点は平均の 50 倍まで)
const float GLINT_RADIUS = 0.75;            // 点を画素へ配る半径 (画素)
const float GLINT_CELL = 1.5;               // セルの一辺の下限 (視線方向に伸びた画素)。2 x 2 のセルで半径の中の点を全部探せる大きさ
/*
 * 点の寿命の下限 (フレーム)。TAA が 1 つの点を積めるよう、物理の寿命 (数十 ms) が短くても数フレームは残す
 * フレームの長さは prepare が平滑化して半オクターブの段に丸めた値 (waterGlintFrameStep)。生の frameTime はフレームごとに揺れ、
 * 時刻 / 寿命 の床関数が毎フレーム跳んで全部の点が振り直されるため
 */
const float GLINT_MIN_FRAMES = 4.0;
const vec2 GLINT_SMOOTH_LAMBDA = vec2(8.0, 32.0);  // 画素の中の点の数がこの範囲で滑らかな平均へ移す (道の芯は白い帯)
const float GLINT_SKIP = 2e-4;              // 画素の中の点の数の期待値がこれより少ない所は平均のまま (道の外。5000 画素に 1 つ)
const vec2 GLINT_LEVEL_BLEND = vec2(0.3, 0.7);     // セルの大きさの 2 段を混ぜる帯 (log2 の端数)
const float GLINT_FRACTION_MIN = 0.01;      // ローブのうち粗さへ回した分がこれより少ない所 (近景) は変えない

// 重み 1 / sqrt(v) (v は [GLINT_WEIGHT_MIN, 1] の一様乱数) の平均
const float GLINT_WEIGHT_MEAN = 2.0 * (1.0 - sqrt(GLINT_WEIGHT_MIN)) / (1.0 - GLINT_WEIGHT_MIN);

/*
 * フレームの長さの段 (frameData.surfaceParams[3]: x = 平滑化した frameTime, y = 段の長さ (秒), z = 段の番号)
 * 段は 1/60 秒の半オクターブ刻みで、平滑化した値以上の最小の段。境目の近くで行き来しないよう、段を変えるのは 0.15 段を越えた時だけ
 */
const float GLINT_FRAME_SMOOTH = 0.05;      // 1 フレームあたりの平滑化の割合
const float GLINT_FRAME_LEVELS = 2.0;       // 1 オクターブの段の数
const float GLINT_FRAME_HYSTERESIS = 0.15;

#ifdef SSBO_FRAME_DATA_WRITE
void waterGlintFrameStore() {
    vec4 p = frameData.surfaceParams[3];
    float ft = clamp(frameTime, 1e-3, 0.5);
    bool valid = p.x > 0.0 && p.y > 0.0;
    float s = valid ? mix(p.x, ft, GLINT_FRAME_SMOOTH) : ft;
    float e = log2(s * 60.0) * GLINT_FRAME_LEVELS;
    float level = p.z;
    if (!valid || e > level + GLINT_FRAME_HYSTERESIS || e < level - 1.0 - GLINT_FRAME_HYSTERESIS) level = ceil(e);
    frameData.surfaceParams[3] = vec4(s, exp2(level / GLINT_FRAME_LEVELS) / 60.0, level, 0.0);
}
#endif

float waterGlintFrameStep() { return max(frameData.surfaceParams[3].y, 1.0 / 240.0); }

/*
 * 点を寄せる重み (場所の平均 1)。長い 3 層の波頭 crest (0-1) と、画面で表せている短い層の波頭
 * 短い層が表せていない遠くは長い波の重みだけ
 */
float waterGlintCrest(WaterSea sea, vec2 p, float footprint, float crest) {
    float w = 1.0 + GLINT_CREST * 2.0 * (crest - GLINT_CREST_MEAN);
    float t = frameTimeCounter;
    float h = 0.0;
    float var = 0.0;
    float varAll = 0.0;
    for (int i = GLINT_CREST_SHORT_FIRST; i < WATER_LAYERS; i++) {
        float r = waterLayerResolved(i, footprint);
        float s2 = sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
        varAll += s2;
        if (r <= 0.0 || sea.amp[i] <= 0.0) continue;
        var += s2 * r * r;
        h += waterLayer(p, i, sea.amp[i] * r, t).x;
    }
    if (var <= 0.0) return w;
    float c = smoothstep(0.0, 2.0 * sqrt(var), h);
    return w * (1.0 + GLINT_CREST_SHORT * sqrt(var / varAll) * (c * c / GLINT_CREST_SHORT_MEAN - 1.0));
}

/*
 * 格子 1 段 (セルの一辺 2^level) の倍率 (期待値 1)
 * pos: 標本の位置, rho: 点の密度 (1 / ブロック^2), axisAlong / axisAcross: ワールドの水平の差を画素の半径の単位へ直す 2 軸,
 * kernelArea: 1 つの点を配る重みの面積 (ブロック^2)
 */
float glintLevel(vec2 pos, float level, float rho, vec2 axisAlong, vec2 axisAcross, float kernelArea) {
    float cell = exp2(level);
    // 点はこの大きさの波が作るとみなし、その波の位相の速さで流れ、周期の半分で入れ替わる
    float wavelength = max(cell, WATER_CAPILLARY_WAVELENGTH);
    float speed = waterPhaseSpeed(wavelength);
    float life = max(0.5 * wavelength / speed, GLINT_MIN_FRAMES * waterGlintFrameStep());
    float t = frameTimeCounter;
    vec2 q = pos - vec2(cos(WATER_WIND_ANGLE), sin(WATER_WIND_ANGLE)) * (speed * t);

    // 1 組のセルに置ける点は 1 つなので、置き切れない分は暗い点 (重みの一様乱数の大きい側) を平均へ回す
    float count = rho * cell * cell;
    float present = min(count, 1.0);
    float vMax = GLINT_WEIGHT_MIN + (present / count) * (1.0 - GLINT_WEIGHT_MIN);
    float placed = (sqrt(vMax) - sqrt(GLINT_WEIGHT_MIN)) / (1.0 - sqrt(GLINT_WEIGHT_MIN));

    vec2 g = q / cell;
    ivec2 base = ivec2(floor(g - 0.5));
    uint levelTag = uint(int(level) + 128);
    float sum = 0.0;
    for (int k = 0; k < 4; k++) {
        ivec2 c = base + ivec2(k & 1, k >> 1);
        uvec2 uc = uvec2(c);
        // セルごとに時刻をずらし、点が揃って入れ替わらないようにする
        float phase = hash1(uc.x * 0x9E3779B1u ^ uc.y * 0x85EBCA77u ^ levelTag * 0xC2B2AE3Du);
        for (int s = 0; s < 2; s++) {
            float ts = t / life + phase + 0.5 * float(s);
            uint slot = uint(int(floor(ts))) * 512u + levelTag * 2u + uint(s);
            vec3 h = hash3(uvec3(uc, slot));
            if (h.x >= present) continue;
            vec2 d = (vec2(c) + h.yz) * cell - q;
            vec2 m = vec2(dot(d, axisAlong), dot(d, axisAcross));
            float r2 = dot(m, m);
            if (r2 >= 1.0) continue;
            float v = mix(GLINT_WEIGHT_MIN, vMax, h.x / present);
            sum += sqr(sin(PI * fract(ts))) * inversesqrt(v) * sqr(1.0 - r2);
        }
    }
    return sum / (GLINT_WEIGHT_MEAN * rho * kernelArea) + (1.0 - placed);
}

/*
 * 太陽 (月) の照り返しのローブに掛ける倍率。ローブのうち粗さへ回した分の割合だけ効かせる (近景は表した波の法線のまま)
 * pos: 標本の位置 (ワールドの水平, TAA のジッター込み), N: 表した波の法線, L: 太陽 (月) の向き, alpha2: 照り返しのローブの alpha^2,
 * unresolved: 粗さへ回した (傾きの分散, 曲率の 2 乗の和), pixelWorld: 水面上の画素の幅 (視線と直交する向き, ブロック),
 * NoVGeo: 平均水面と視線の cos, crestWeight: 波頭へ寄せる重み (waterGlintCrest, 場所の平均 1)
 */
float waterGlitter(vec2 pos, vec3 N, vec3 V, vec3 L, float alpha2, vec2 unresolved, float pixelWorld, float NoVGeo, float crestWeight) {
    float fraction = saturate(unresolved.x / alpha2);
    if (fraction < GLINT_FRACTION_MIN) return 1.0;
    float NoH = dot(N, normalize(L + V));
    if (NoH <= 0.0) return 1.0;
    // 傾きの分布をローブと同じ alpha^2 のガウスにする。期待値はガウス / GGX の比で、GGX の長い裾の分は点にならない
    float x = (1.0 / (NoH * NoH) - 1.0) / alpha2;
    float gauss = exp(-x);
    float expected = gauss * sqr(1.0 + x);
    float rho = gauss / (PI * alpha2) * GLINT_CURVATURE * unresolved.y;

    float NoV = max(NoVGeo, 0.02);
    float footprint = pixelWorld / NoV;
    float pixelArea = pixelWorld * footprint;
    rho *= crestWeight;
    float lambdaPx = rho * pixelArea;
    float smoothW = smoothstep(GLINT_SMOOTH_LAMBDA.x, GLINT_SMOOTH_LAMBDA.y, lambdaPx);
    float level = log2(GLINT_CELL * footprint);
    float levelLo = floor(level) + 1.0;
    float g = 1.0;
    if (smoothW < 1.0 && lambdaPx >= GLINT_SKIP) {
        // 画素の単位: 視線の向き (水平) には 1 / NoV 倍に伸びた画素
        vec2 along = V.xz;
        along = dot(along, along) > 1e-8 ? normalize(along) : vec2(1.0, 0.0);
        vec2 axisAlong = along * NoV / (pixelWorld * GLINT_RADIUS);
        vec2 axisAcross = vec2(-along.y, along.x) / (pixelWorld * GLINT_RADIUS);
        // (1 - r^2)^2 の重みの面積
        float kernelArea = PI * sqr(GLINT_RADIUS) / 3.0 * pixelArea;
        // どちらの段も期待値は同じなので、混ぜるのは切り替わりの帯だけにし、帯の外は片方の段だけを探す
        float wHi = smoothstep(GLINT_LEVEL_BLEND.x, GLINT_LEVEL_BLEND.y, fract(level));
        float gLo = wHi < 1.0 ? glintLevel(pos, levelLo, rho, axisAlong, axisAcross, kernelArea) : 0.0;
        float gHi = wHi > 0.0 ? glintLevel(pos, levelLo + 1.0, rho, axisAlong, axisAcross, kernelArea) : 0.0;
        g = mix(mix(gLo, gHi, wHi), 1.0, smoothW);
    }
    /*
     * 点がまばらで粗さへ回した割合の大きい所 (gaussian 1) はガウスのローブを点で、点が詰まった所と近景 (0) は GGX のまま。
     * 間は GGX のうちガウスと重なる分を点にし、GGX の裾 (ガウスを超える分) を滑らかに残す (近景の道の縁を切り立たせない)。
     * どの値でも GGX と同じエネルギー (ガウスと GGX の重なりは 0.796、残りが裾)
     */
    float sparse = 1.0 - smoothW;
    float gaussian = sparse * fraction;
    float points = min(expected, 1.0) + gaussian * max(expected - 1.0, 0.0);
    float tail = (1.0 - gaussian) * max(1.0 - expected, 0.0);
    return mix(1.0, g * points * mix(1.0, crestWeight, sparse) + tail, fraction);
}

#endif
