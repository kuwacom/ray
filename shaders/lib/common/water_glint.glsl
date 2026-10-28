/*
 * 太陽・月の照り返しのきらめき (sun glitter)
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_GLINT_GLSL
#define COMMON_WATER_GLINT_GLSL

#include "/lib/common/constants.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/water_waves.glsl"

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

#endif
