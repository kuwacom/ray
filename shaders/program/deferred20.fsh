/*
 * deferred20: 体積雲のレイマーチ (CLOUD_RES 分の 1 解像度, CLOUD_TEMPORAL ならチェッカーボード)
 * 出力: colortex10 の左上領域。rgb = 散乱光, a = 透過率
 * 低解像度の 1 テクセル = フル解像度の CLOUD_RES 四方のブロック。今フレームはブロック内の 1 ピクセルだけを計算する
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/sky/cloud_volume.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 10 */
layout(location = 0) out vec4 outClouds;

void main() {
#if CLOUDS >= 2 && defined HAS_SKY
    ivec2 lowTexel = ivec2(gl_FragCoord.xy);
    ivec2 fullSize = ivec2(viewWidth, viewHeight);
    if (any(greaterThanEqual(lowTexel, cloudLowResSize()))) {
        outClouds = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    ivec2 blockOrigin = lowTexel * CLOUD_RES;
    ivec2 sampleTexel = min(blockOrigin + cloudSampleOffset(frameCounter), fullSize - 1);

    // ブロック内の最も遠い深度で計算する: 地形の縁で空ピクセルの雲が欠けないように (Kappa の depthMax と同じ考え方)
    float depth = 0.0;
    for (int y = 0; y < CLOUD_RES; y++) {
        for (int x = 0; x < CLOUD_RES; x++) {
            depth = max(depth, texelFetch(depthtex1, min(blockOrigin + ivec2(x, y), fullSize - 1), 0).r);
        }
    }

    vec2 uv = (vec2(sampleTexel) + 0.5) / viewSize();
    vec3 dir = normalize(viewToPlayerDir(screenToView(vec3(uv, 1.0))));
    float maxDist = depth >= 1.0 ? 1e9 : length(screenToPlayer(vec3(uv, fixHandDepth(depth))));

    // 雲の層にかからない視線 (雲の下から地形を見る等) はマーチしない
    if (maxDist < 1e8 && cameraPosition.y < CLOUD_BASE && maxDist < CLOUD_BASE - cameraPosition.y) {
        outClouds = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // r = 視線方向, g = 光方向のマーチの開始位置 (独立なチャンネルで相関の縞を避ける)
    vec2 dither = blueNoise(sampleTexel).rg;
    outClouds = renderClouds(dir, maxDist, dither);
#else
    outClouds = vec4(0.0, 0.0, 0.0, 1.0);
#endif
}
