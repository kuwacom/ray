/*
 * ライトビンの参照と光源 1 つの評価、低解像度トレースのサンプル配置 (light モジュール)
 * deferred1 (トレース), deferred2 (デノイズ), deferred30 (鏡面) で同じ式を使うためにまとめる
 *
 * 直接光は「比の推定」でデノイズする (Heitz et al. 2018, "Combining Analytic Direct Illumination and Stochastic Shadows")
 *   deferred1: 低解像度で S = Σ E_i V_i (影あり) と U = Σ E_i (影なし) を同じ光源選択で求める
 *   deferred2: S / U (可視率) だけを時空間フィルタし、フル解像度で厳密に求めた影なし照度に掛ける
 * 減衰・法線の細部はフル解像度のまま残り、ノイズのある可視率だけがぼける
 */
#ifndef LIGHT_LIGHT_SELECT_GLSL
#define LIGHT_LIGHT_SELECT_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/light/trace.glsl"

// 半影用に終点を動かす半径の上限 (ブロック)。光源セルの外に出ると光源の隣の壁で遮られてしまう
const float LIGHT_JITTER_MAX_RADIUS = 0.45;
// LightDef.shape.w (光源の物理半径) に対する LIGHT_SOURCE_SIZE の倍率。既定 0.5 で物理半径そのもの
const float LIGHT_SOURCE_SIZE_SCALE = 2.0;

/*
 * ボクセルのセル座標に足すとワールドの 8 ブロック格子にそろう量 (LIGHT_CULL_MODE 1/2)
 * ボクセル体積はカメラのブロックに付いて動くので、そのままではビンの境界がカメラの 1 ブロックの移動ごとにずれ、
 * 溢れたビンで残る光源の組が歩くたびに入れ替わる
 */
ivec3 lightBinOffset() {
#if LIGHT_CULL_MODE == 0
    return ivec3(0);
#else
    return (getCameraBlock() - VOXEL_HALF) & (LIGHT_BIN_SIZE - 1);
#endif
}

ivec3 lightBinCoord(ivec3 cell) {
    return clamp((cell + lightBinOffset()) / LIGHT_BIN_SIZE, ivec3(0), LIGHT_BIN_GRID - 1);
}

int lightBinIndex(ivec3 cell) {
    ivec3 b = lightBinCoord(cell);
    return b.x + b.y * LIGHT_BIN_GRID.x + b.z * LIGHT_BIN_GRID.x * LIGHT_BIN_GRID.y;
}

/*
 * ビンの枠のキー: 上位 19 bit = 重要度 (正の float の bit 列の上位。大小関係が uint の大小と一致する),
 * 下位 13 bit = globalLights.lights のインデックス。0 は空き
 * 重要度の最下位 2 bit は光源のワールド位置のハッシュで置き換え、同じ重要度の光源 (並べたたいまつ等) の順位を
 * 毎フレーム変わるインデックス (登録の到着順) ではなく位置で決める
 */
const uint LIGHT_KEY_INDEX_BITS = 13u;
const uint LIGHT_KEY_INDEX_MASK = (1u << LIGHT_KEY_INDEX_BITS) - 1u;
const uint LIGHT_KEY_TIE_MASK = 3u;
// これより小さい重要度は丸める (キーが 0 = 空きにならないように)
const float LIGHT_KEY_MIN_IMPORTANCE = 1e-30;

uint packLightBinKey(float importance, uint index, uint tie) {
    uint q = floatBitsToUint(max(importance, LIGHT_KEY_MIN_IMPORTANCE)) >> 12u;
    q = (q & ~LIGHT_KEY_TIE_MASK) | (tie & LIGHT_KEY_TIE_MASK);
    return (q << LIGHT_KEY_INDEX_BITS) | index;
}
float lightBinKeyImportance(uint key) { return uintBitsToFloat((key >> LIGHT_KEY_INDEX_BITS) << 12u); }

uint lightBinBase(int bin) { return uint(bin * LIGHT_BIN_STRIDE); }
uint lightBinCount(int bin) { return min(lightBins.binCount[bin], uint(LIGHT_BIN_CAPACITY)); }
int lightBinEntry(int bin, uint k) { return int(lightBins.binLights[lightBinBase(bin) + k] & LIGHT_KEY_INDEX_MASK); }
uint globalLightCount() { return min(globalLights.count, uint(MAX_GLOBAL_LIGHTS)); }

/*
 * 溢れたビンの境界で光源を弱める幅 (重要度の比)。外れた光源のうち最も重要なもの (最後の枠) の重要度 x (1 + この値) 以上で 1
 * 光源が動く・増える時に、残る / 外れるの入れ替わりで明るさが飛ばないように、境界の近くの光源ほど弱めて連続にする
 * 大きくすると溢れたビン全体が暗くなる
 */
const float LIGHT_BIN_FADE = 0.15;

// ビンの k 番目の光源の重み (溢れていなければ 1)
float lightBinFade(int bin, uint k) {
#if LIGHT_CULL_MODE == 0
    return 1.0;
#else
    if (lightBins.binCount[bin] <= uint(LIGHT_BIN_CAPACITY)) return 1.0;
    uint base = lightBinBase(bin);
    float dropped = lightBinKeyImportance(lightBins.binLights[base + uint(LIGHT_BIN_CAPACITY)]);
    float own = lightBinKeyImportance(lightBins.binLights[base + k]);
    return saturate((own / max(dropped, LIGHT_KEY_MIN_IMPORTANCE) - 1.0) / LIGHT_BIN_FADE);
#endif
}

// ビンの k 番目の光源 (境界の重みを放射に掛け済み)。照度を求める所はこれを使う
LightInstance lightBinLight(int bin, uint k) {
    LightInstance L = globalLights.lights[lightBinEntry(bin, k)];
    L.colorSize.rgb *= lightBinFade(bin, k);
    return L;
}

// 幾何法線の NdotL がこれ以下ではテクスチャ法線の効きを弱める
const float LIGHT_NORMAL_GRAZING = 0.35;

/*
 * 光源 L が voxelPos の面 (法線 n) に作る影なしの照度 (NdotL 込み)
 * gateNormal: この法線で地平線の下なら 0 (テクスチャ法線で照らす時に、幾何的に裏側の光源を拾わないため)
 */
vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal) {
    vec3 toL = L.posRadius.xyz - voxelPos;
    float dist = length(toL);
    if (dist >= L.posRadius.w) return vec3(0.0);
    vec3 dir = toL / max(dist, EPS);
    float radius = L.colorSize.a;
    float gate = sphereLightNdotL(gateNormal, dir, dist, radius);
    if (gate <= 0.0) return vec3(0.0);
    // かすめ角ではテクスチャ法線の NdotL が幾何法線の何倍にも振れ、テクセルごとの明暗が強くなりすぎる
    // TAA のジッターでピクセルがテクセルの境界をまたぐたびに値が飛び、床が細かくちらついた。幾何法線の NdotL に寄せる
    float ndl = mix(gate, sphereLightNdotL(n, dir, dist, radius), smoothstep(0.0, LIGHT_NORMAL_GRAZING, gate));
    return L.colorSize.rgb * lightFalloff(dist, L.posRadius.w) * ndl;
}

// 着色点のビンの全光源の影なし照度の和 (deferred2 がフル解像度で使う)
vec3 sumBinLightsUnshadowed(vec3 voxelPos, vec3 normal, vec3 geoNormal) {
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    int bin = lightBinIndex(ivec3(voxelPos));
    uint n = lightBinCount(bin);
    vec3 sum = vec3(0.0);
    for (uint k = 0u; k < n; k++) {
        sum += evalLightIrradiance(lightBinLight(bin, k), voxelPos, normal, geoNormal);
    }
    return sum;
}

// 光源サイズ由来の半影を作るための終点の揺らぎ半径
float lightJitterRadius(LightInstance L) {
    return min(L.colorSize.a * LIGHT_SOURCE_SIZE * LIGHT_SOURCE_SIZE_SCALE, LIGHT_JITTER_MAX_RADIUS);
}

// 光源の体 (エンティティ光源) で自分を遮らないよう、光源側でエンティティ占有を無視する距離
// 三角形方式の基礎値。ボクセルの 0.75 のままだと光源の脇に立ったプレイヤーの頭等が影から抜け落ちる
const float LIGHT_ENTITY_SKIP_TRI_BASE = 0.15;

float lightEntitySkip(LightInstance L) {
#ifdef ENTITY_TRI_OCCLUSION
    // たいまつ (半径 0.08) で 0.31、発光・燃焼エンティティ (半径 0.4) で体の大半を覆う 0.95
    return L.colorSize.a * 2.0 + LIGHT_ENTITY_SKIP_TRI_BASE;
#else
    return max(TRACE_ENTITY_SKIP_END, L.colorSize.a * 2.0 + 0.25);
#endif
}

/*
 * 低解像度トレースのサンプル配置。低解像度テクセル l は毎フレーム違うフル解像度テクセル
 * l * RES + offset(frame) を受け持つ (時間方向にフル解像度を巡回し、デノイズで埋める)
 */
ivec2 traceFrameOffset(int frame) {
#if LIGHT_TRACE_RES == 1
    return ivec2(0);
#elif LIGHT_TRACE_RES == 2
    return bayerOffset2(frame & 3);
#else
    return bayerOffset4(frame);
#endif
}

ivec2 traceLowSize() { return (ivec2(viewSize()) + LIGHT_TRACE_RES - 1) / LIGHT_TRACE_RES; }

ivec2 traceSourceTexel(ivec2 low, int frame) {
    return min(low * LIGHT_TRACE_RES + traceFrameOffset(frame), ivec2(viewSize()) - 1);
}

// フル解像度テクセルに最も近い低解像度テクセル
ivec2 traceNearestLow(ivec2 texel, int frame) {
    vec2 lp = vec2(texel - traceFrameOffset(frame)) / float(LIGHT_TRACE_RES);
    return clamp(ivec2(floor(lp + 0.5)), ivec2(0), traceLowSize() - 1);
}

// 鏡面用の代表光源インデックスを fp16 に正確に入れる (fp16 は ±2048 までの整数が正確)
float encodeLightIndex(int i) { return float(i) - 2047.0; }
int decodeLightIndex(float v) { return int(round(v + 2047.0)); }

#endif
