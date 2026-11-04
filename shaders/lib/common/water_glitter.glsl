/*
 * 遠い水面の太陽 (月) の照り返しのきらめき (WATER_GLITTER)
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_GLITTER_GLSL
#define COMMON_WATER_GLITTER_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"

/*
 * 画素より細かい波 (法線で表せない表面張力波から短い重力波) は、太陽をちょうど目へ映す向きの面が 1 画素に 0 個か数個しか無い。
 * 滑らかなローブはその期待値で、遠い光の道が一様な帯になる。実際の水面は面の数のゆらぎで、道の端ほど点がまばらになり、
 * 1 つ 1 つは明るいまま光る
 * 画素の広さの格子 (ワールドに固定、2 の冪を 2 段補間) ごとに、太陽を映す面の数 n を平均 lambda の Poisson 分布で引き、
 * 照り返し x n / lambda にする。平均は滑らかなローブと同じでエネルギーは変わらず、点の形は持たない (面の数が画素の中の
 * 明るさのむらを作るだけ)。lambda が大きい所 (道の芯・近景) は n / lambda が 1 に寄るので点は出ない
 * 点の入れ替わりは 2 組の時刻を sin^2 / cos^2 で重ねてつなぐ。格子の位置はワールドで決めるので、カメラが動いても点は水面に付いて動く
 */
const float GLITTER_FACET = 0.02;                  // 太陽を映す微小面の大きさ (ブロック = m)。表面張力波から短い重力波の斜面
const float GLITTER_PERIOD = 0.2;                  // 1 組の寿命 (秒)
const vec2 GLITTER_SMOOTH_LAMBDA = vec2(3.0, 10.0); // 画素の中の期待個数がこの範囲で滑らかなローブへ移す
const int GLITTER_MAX_COUNT = 24;                  // Poisson の逆 CDF の探索の上限

// 平均 lambda の Poisson の個数を、一様乱数 u から逆 CDF で引く (lambda が少し違う隣の画素でも同じ u なら個数が近い)
float glitterCount(float u, float lambda) {
    float term = exp(-lambda);
    float cdf = term;
    float n = 0.0;
    for (int i = 0; i < GLITTER_MAX_COUNT; i++) {
        if (u <= cdf) break;
        n += 1.0;
        term *= lambda / n;
        cdf += term;
    }
    return n;
}

// 格子 1 段の n / lambda。セルごとに位相をずらし、画面中の点が揃って入れ替わらないようにする
float glitterLevel(vec2 worldXZ, float cell, float density, float t) {
    ivec2 c = ivec2(floor(worldXZ / cell));
    uvec2 uc = uvec2(c + 32768);
    float lambda = max(density * cell * cell, 1e-6);
    float phase = hash3(uvec3(uc.yx, 101u)).z;
    float sum = 0.0;
    for (int s = 0; s < 2; s++) {
        float ts = t + phase + 0.5 * float(s);
        uint slot = uint(floor(ts)) * 2u + uint(s);
        float u = hash3(uvec3(uc, slot)).x;
        sum += sqr(sin(PI * fract(ts))) * glitterCount(u, lambda);
    }
    return sum / lambda;
}

/*
 * worldXZ: 水面のワールド座標 (水平), N: 表した波の法線, L: 太陽 (月) の向き, slopeVar: 法線で表せない波の傾きの分散,
 * sunRadius: 光源の視半径, pixelWorld: 水面上の画素の幅 (ブロック), NoVGeo: 平均水面と視線の cos
 * 戻り値: 照り返しのローブに掛ける倍率 (期待値 1)
 */
float waterGlitter(vec2 worldXZ, vec3 N, vec3 V, vec3 L, float slopeVar, float sunRadius, float pixelWorld, float NoVGeo) {
    vec3 H = normalize(L + V);
    float NoH = dot(N, H);
    if (NoH <= 0.0) return 1.0;
    slopeVar = max(slopeVar, 1e-5);
    float tan2 = (1.0 - NoH * NoH) / (NoH * NoH);
    // 光源の円盤が半ベクトルの傾きの平面で占める面積 (半角の立体角 / cos^3)
    float discArea = PI * sqr(0.5 * sunRadius) / (NoH * NoH * NoH);
    float p = min(exp(-tan2 / slopeVar) / (PI * slopeVar) * discArea, 1.0);
    float density = p / sqr(GLITTER_FACET);   // 光源を映す面の数 (ブロック^2 あたり)
    float pixelArea = sqr(pixelWorld) / max(NoVGeo, 0.02);
    float smoothW = smoothstep(GLITTER_SMOOTH_LAMBDA.x, GLITTER_SMOOTH_LAMBDA.y, density * pixelArea);
    if (smoothW >= 1.0) return 1.0;
    // 正規分布の裾 (光源から大きく外れた向き) は面がほぼ無いので探さない
    if (density * pixelArea < 1e-4) return 1.0;
    float level = log2(sqrt(pixelArea));
    float cell = exp2(floor(level));
    float t = frameTimeCounter / GLITTER_PERIOD;
    float g = mix(glitterLevel(worldXZ, cell, density, t), glitterLevel(worldXZ, 2.0 * cell, density, t), fract(level));
    return mix(g, 1.0, smoothW);
}

#endif
