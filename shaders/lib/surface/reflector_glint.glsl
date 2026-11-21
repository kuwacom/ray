/*
 * 金属・鉱物ブロックのキラキラ (REFLECTOR_GLINT、surface モジュール。opaque_shading.fsh が太陽・灯りの鏡面に使う)
 * 1/16 ブロック (テクスチャの 1 テクセル) のセルごとに、微小な面の法線を乱数で傾け、残りを狭いローブにする。
 * 照り返しの平均 (ローブの幅の 2 乗の和) は変えないまま、太陽・灯りの像が当たるセルだけが明るく、他は暗くなる。
 * 面の法線は視点で変わらないが、ハーフベクトルが視点で動くので、歩くと光るセルが入れ替わる
 * 法線マップの分布を数える方式 (P-NDF) の離散版で、水面の WATER_GLITTER と同じ考え (ローブの確率を点に変える) だが、
 * 波の層を使わないのでブロックの面に固定したセルだけで済む。セルの乱数はワールドの座標から決めるので動かない
 */
#ifndef SURFACE_REFLECTOR_GLINT_GLSL
#define SURFACE_REFLECTOR_GLINT_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/surface/material.glsl"

#ifdef REFLECTOR_GLINT

const float GLINT_CELLS_PER_BLOCK = 16.0;
// 強さ 1 での、微小面の法線の傾きの標準偏差 / 面のローブの alpha。1 に近いほどローブの中の点が少なく明るい
const float GLINT_TILT_RATIO = 0.9;
// 2 つの一様乱数の和 - 1 (三角分布、標準偏差 0.408) を標準偏差 1 にする倍率
const float GLINT_TRIANGLE_SCALE = 2.449;
// 微小面のローブの alpha の下限 (傾きが alpha に近すぎて 0 にならないように)
const float GLINT_RESIDUAL_MIN = 0.3;
// セルが画面で何画素あるか (この範囲で 0 -> 1)。画素より細かいセルの点は TAA のジッターでちらつくので消す
const vec2 GLINT_CELL_PX = vec2(0.5, 1.5);
// 磨いた石・宝石 (MAT_GLOSSY) の効き。金属は 1
const float GLINT_GLOSSY_WEIGHT = 0.7;

struct GlintSurface {
    Material m;   // ローブを狭めた材質 (鏡面だけに使う)
    vec3 N;       // セルの微小面の法線
    bool on;
};

/*
 * 面の法線 geoN の面の上の点 playerPos (ジッターを除いた player 空間) のセルの微小面。
 * weight: 0-1 (材質の効きと、セルが画素より細かい遠くで弱める分)
 */
GlintSurface reflectorGlintSurface(Material m, vec3 N, vec3 geoN, vec3 playerPos, float weight) {
    GlintSurface g;
    g.m = m;
    g.N = N;
    g.on = false;
    float k = GLINT_TILT_RATIO * REFLECTOR_GLINT_STRENGTH * weight;
    if (k <= 0.0) return g;
    vec3 a3 = abs(geoN);
    int a = a3.x >= a3.y && a3.x >= a3.z ? 0 : (a3.y >= a3.z ? 1 : 2);
    int u = (a + 1) % 3;
    int v = (a + 2) % 3;
    // 整数のブロックの座標は int で持つ (float のワールド座標では 1/16 の精度が足りない遠くがある)
    vec3 p = playerPos + getCameraFract();
    ivec3 base = getCameraBlock() * int(GLINT_CELLS_PER_BLOCK);
    ivec3 cell = base + ivec3(floor(p * GLINT_CELLS_PER_BLOCK));
    int plane = base[a] + int(floor(p[a] * GLINT_CELLS_PER_BLOCK + 0.5));
    uvec3 key = uvec3(uint(cell[u]), uint(cell[v]), uint(plane * 3 + a));
    vec3 h = hash3(key);
    vec3 h2 = hash3(key ^ uvec3(0x68E31DA4u, 0xB5297A4Du, 0x1B56C4E9u));
    vec2 tilt = vec2(h.x + h.y - 1.0, h.z + h2.x - 1.0) * GLINT_TRIANGLE_SCALE;
    mat3 tbn = tbnFromNormal(N);
    float alpha = m.roughness;
    g.N = normalize(N + (tbn[0] * tilt.x + tbn[1] * tilt.y) * (k * alpha));
    g.m.roughness = alpha * sqrt(max(1.0 - k * k, GLINT_RESIDUAL_MIN * GLINT_RESIDUAL_MIN));
    g.m.perceptualRoughness = sqrt(g.m.roughness);
    g.on = true;
    return g;
}

#endif

#endif
