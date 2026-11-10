/*
 * deferred20: 体積雲のレイマーチ (CLOUD_RES 分の 1 解像度, CLOUD_TEMPORAL ならチェッカーボード)
 * 出力: colortex10 の左上領域。rgb = 散乱光, a = 透過率
 * 低解像度の 1 テクセル = フル解像度の CLOUD_RES 四方のブロック。今フレームはブロック内の 1 ピクセルだけを計算する
 * sky モジュール (lib/sky)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/sky/cloud_volume.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/sky/cloud_constants.glsl"
#include "/lib/sky/cloud_weather.glsl"
#include "/lib/sky/cloud_vanilla.glsl"
#include "/lib/sky/cloud_density.glsl"
#include "/lib/sky/cloud_lighting.glsl"
#include "/lib/sky/cloud_march.glsl"
#include "/lib/sky/cloud_volume.glsl"
// END GENERATED includes

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
    if (maxDist < 1e8 && cameraPosition.y < cloudLowestBase() && maxDist < cloudLowestBase() - cameraPosition.y) {
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
