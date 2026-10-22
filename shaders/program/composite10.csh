/*
 * composite10 (compute): ボリューメトリックライト / 高さフォグのレイマーチ (VL_RES 分の 1 解像度)
 * 出力: 偶数フレームは colorimg12、奇数フレームは fogHistoryImg の左上領域 (もう一方が前フレームの履歴)
 *   空気中: rgb = 内散乱, a = 透過率 / 水中: rgb = 内散乱 (透過率は composite11 が距離から解析的に掛ける)
 * 時間蓄積: 前フレームを再投影し、ワークグループ内の 3x3 近傍 (共有メモリ) でクランプしてから混ぜる
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_COLORIMG12
#define IMG_FOG_HISTORY
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/light/light.glsl"
#include "/lib/sky/volumetrics.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
#if VL_RES == 1
    const vec2 workGroupsRender = vec2(1.0, 1.0);
#elif VL_RES == 2
    const vec2 workGroupsRender = vec2(0.5, 0.5);
#else
    const vec2 workGroupsRender = vec2(0.25, 0.25);
#endif

// 新しいフレームの混合率 (約 5 フレームの蓄積)
const float VL_HISTORY_BLEND = 0.2;
const float VL_CLAMP_EXPAND = 0.35;

shared vec4 sharedFog[8][8];

// 前フレームの低解像度バッファを、領域の外を読まないようにバイリニアで引く
vec4 sampleFogHistory(vec2 prevLowPos) {
    vec2 maxPos = vec2(vlLowResSize()) - 1.0;
    vec2 uv = (clamp(prevLowPos, vec2(0.0), maxPos) + 0.5) / viewSize();
    return vlWritesColortex12() ? texture(fogHistorySampler, uv) : texture(colortex12, uv);
}

void main() {
    ivec2 lowTexel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 local = ivec2(gl_LocalInvocationID.xy);
    bool inRange = all(lessThan(lowTexel, vlLowResSize()));

    ivec2 texel = vlSampleTexel(lowTexel);
    float depth = texelFetch(depthtex0, texel, 0).r;
    vec2 uv = (vec2(texel) + 0.5) / viewSize();
    bool isSky = depth >= 1.0;
    vec3 playerPos = screenToPlayer(vec3(uv, isSky ? 1.0 : fixHandDepth(depth)));
    vec3 dir = normalize(playerPos);
    // 空は描画距離までフォグを積む (描画距離端で地形が溶ける先と同じ量)
    float dist = isSky ? far : length(playerPos);
    float dither = blueNoise(texel).g;

    vec4 raw = vec4(0.0, 0.0, 0.0, 1.0);
    if (inRange) {
        if (isEyeInWater == 1) raw = vec4(marchWaterFog(dir, dist, dither), 1.0);
        else if (isEyeInWater == 0) raw = marchAirFog(dir, dist, dither);
    }

    sharedFog[local.y][local.x] = raw;
    barrier();
    if (!inRange) return;

    vec4 lo = raw, hi = raw;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 n = clamp(local + ivec2(x, y), ivec2(0), ivec2(7));
            vec4 s = sharedFog[n.y][n.x];
            lo = min(lo, s);
            hi = max(hi, s);
        }
    }

    vec2 prevUv;
    if (isHandDepth(depth)) {
        prevUv = uv;
    } else if (isSky) {
        vec3 prevView = mat3(gbufferPreviousModelView) * dir;
        prevUv = prevView.z < 0.0 ? projectAndDivide(gbufferPreviousProjection, prevView).xy * 0.5 + 0.5 : vec2(-1.0);
    } else {
        prevUv = playerToPrevScreen(playerPos).xy;
    }
    bool valid = all(greaterThanEqual(prevUv, vec2(0.0))) && all(lessThanEqual(prevUv, vec2(1.0))) && frameData.skyParams[1].y > 1.5;

    vec4 result = raw;
    if (valid) {
        vec2 prevLowPos = prevUv * viewSize() / float(VL_RES) - 0.5;
        vec4 history = sampleFogHistory(prevLowPos);
        vec4 pad = (hi - lo) * VL_CLAMP_EXPAND + vec4(vec3(1e-6), 0.005);
        history = clamp(history, lo - pad, hi + pad);
        result = mix(history, raw, VL_HISTORY_BLEND);
    }

    if (vlWritesColortex12()) imageStore(colorimg12, lowTexel, result);
    else imageStore(fogHistoryImg, lowTexel, result);
}
