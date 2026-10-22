/*
 * deferred11: GI / AO のアップサンプル + デノイズ (giRawImg + colortex9 -> colortex8, colortex9)
 * 出力 colortex8: rgb = 間接光の照度, a = AO
 * surface モジュール (lib/surface)
 *
 * 1. 空間: 低解像度テクセルの近傍 (GI_DENOISE=2 で 5x5、それ以外 3x3) を深度・法線の差で重み付けして集める (joint bilateral)
 *    各テクセルが表すフル解像度のピクセルは lowResOffset(frameCounter) で復元し、その深度・法線と比べる
 * 2. 時間 (GI_DENOISE>=1): 前フレームへ再投影した履歴を、近傍の平均 +- k 標準偏差に収めてから指数移動平均
 *    (分散クリップ。ディスオクルージョンで古い値が残るのも同じクリップで抑える)
 */
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/post/post.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 8,9 */
layout(location = 0) out vec4 outIndirect;
layout(location = 1) out vec4 outHistory;

#if GI_DENOISE == 2
    const int GI_FILTER_RADIUS = 2;
#else
    const int GI_FILTER_RADIUS = 1;
#endif
const float GI_DEPTH_SIGMA = 0.04;     // 相対深度差の許容
const float GI_NORMAL_POWER = 16.0;
const float GI_HISTORY_CLIP = 1.5;     // 履歴を収める標準偏差の幅
#if GI_RES == 1
    const float GI_TEMPORAL_ALPHA = 0.1;
#else
    const float GI_TEMPORAL_ALPHA = 0.16; // 1/4 のピクセルしか毎フレーム更新されないので少し速く追従させる
#endif

// エッジ停止は幾何法線で見る (GI / AO は幾何法線で計算している。テクスチャ法線だとテクセルごとに重みが切れてノイズが残る)
vec3 readGeoNormal(ivec2 texel) { return octDecode(unpack2x8(texelFetch(colortex2, texel, 0).b)); }

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex1, texel, 0).r;
    if (depth >= 1.0 || isHandDepth(depth)) {
        outIndirect = vec4(0.0, 0.0, 0.0, 1.0);
        outHistory = outIndirect;
        return;
    }
    float linZ = linearizeDepth(depth);
    vec3 normal = readGeoNormal(texel);
    ivec2 screen = ivec2(viewSize());

#if GI_RES == 1
    ivec2 offset = ivec2(0);
    ivec2 center = texel;
    ivec2 lowSize = screen;
    const int scale = 1;
#else
    ivec2 offset = lowResOffset(frameCounter);
    ivec2 center = (texel - offset) / 2;
    ivec2 lowSize = (screen + 1) / 2;
    const int scale = 2;
#endif

    vec4 sum = vec4(0.0);
    vec4 sum2 = vec4(0.0);
    float wsum = 0.0;
    for (int dy = -GI_FILTER_RADIUS; dy <= GI_FILTER_RADIUS; dy++) {
        for (int dx = -GI_FILTER_RADIUS; dx <= GI_FILTER_RADIUS; dx++) {
            ivec2 L = clamp(center + ivec2(dx, dy), ivec2(0), lowSize - 1);
            ivec2 P = min(L * scale + offset, screen - 1);
            float dP = texelFetch(depthtex1, P, 0).r;
            if (dP >= 1.0 || isHandDepth(dP)) continue;
            vec4 raw = texelFetch(giRawSampler, L, 0);
            float wDepth = exp(-abs(linearizeDepth(dP) - linZ) / (linZ * GI_DEPTH_SIGMA + 0.05));
            float wNormal = pow(saturate(dot(normal, readGeoNormal(P))), GI_NORMAL_POWER);
            float wSpatial = exp(-float(dx * dx + dy * dy) / float(GI_FILTER_RADIUS * GI_FILTER_RADIUS + 1));
            float w = wDepth * wNormal * wSpatial + 1e-5;
            sum += raw * w;
            sum2 += raw * raw * w;
            wsum += w;
        }
    }
    vec4 mean = wsum > 0.0 ? sum / wsum : texelFetch(giRawSampler, clamp(center, ivec2(0), lowSize - 1), 0);
    vec4 result = mean;

#if GI_DENOISE >= 1
    vec2 prevUv = getPreviousUv(texcoord, depth);
    if (all(greaterThan(prevUv, vec2(0.0))) && all(lessThan(prevUv, vec2(1.0)))) {
        vec4 sigma = sqrt(max(sum2 / max(wsum, 1e-5) - mean * mean, 0.0));
        vec4 history = texture(colortex9, prevUv);
        history = clamp(history, mean - sigma * GI_HISTORY_CLIP - 1e-3, mean + sigma * GI_HISTORY_CLIP + 1e-3);
        result = mix(history, mean, GI_TEMPORAL_ALPHA);
    }
#endif

    outIndirect = result;
    outHistory = result;
}
