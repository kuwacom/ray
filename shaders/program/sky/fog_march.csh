/*
 * composite1_a (compute): ボリューメトリックライト / 高さフォグのレイマーチ (VL_RES 分の 1 解像度)
 * 出力: 偶数フレームは colorimg12、奇数フレームは fogHistoryImg の左上領域 (もう一方が前フレームの履歴)
 *   空気中: rgb = 内散乱, a = 透過率 / 水中: rgb = 内散乱 (透過率はフォグの適用 (composite19) が距離から解析的に掛ける)
 * 時間蓄積: 前フレームを再投影し、ワークグループ内の 3x3 近傍 (共有メモリ) でクランプしてから混ぜる
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_COLORIMG12
#define IMG_FOG_HISTORY
//@include "/lib/common/common.glsl"
//@include "/lib/common/temporal.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/surface/surface.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/sky/volumetrics.glsl"
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
#include "/lib/common/temporal.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
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
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glint.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/sky/volumetrics.glsl"
// END GENERATED includes

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
const vec4 VL_CLAMP_PAD = vec4(vec3(1e-6), 0.005);

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
    float dist = isSky ? fogRenderDistance() : length(playerPos);
    float dither = blueNoise(texel).g;

    vec4 raw = vec4(0.0, 0.0, 0.0, 1.0);
    if (inRange) {
        if (isEyeInWater == 1) raw = vec4(marchWaterFog(dir, dist, dither), 1.0);
        else if (isEyeInWater == 0) {
#ifdef VL_FAR
    #ifdef HAS_SUN_SHADOWS
            float farStart = min(dist, min(shadowDistance, fogRenderDistance()));
    #else
            float farStart = min(dist, fogRenderDistance());
    #endif
            vec2 farVisibility = vlFarScreenVisibility(dir, farStart, dist, blueNoise(texel).b);
#else
            vec2 farVisibility = vec2(farSunHiddenShade(dir));
#endif
            raw = marchAirFog(dir, dist, dither, farVisibility);
        }
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
        prevUv = playerToPreviousScreen(playerPos).xy;
    }
    bool valid = reprojectionInside(prevUv) && frameData.skyParams[1].y > 1.5;

    vec4 result = raw;
    if (valid) {
        vec2 prevLowPos = prevUv * viewSize() / float(VL_RES) - 0.5;
        vec4 history = sampleFogHistory(prevLowPos);
        vec4 pad = neighborBoxMargin(lo, hi, VL_CLAMP_EXPAND, VL_CLAMP_PAD);
        history = clamp(history, lo - pad, hi + pad);
        result = mix(history, raw, VL_HISTORY_BLEND);
    }

    if (vlWritesColortex12()) imageStore(colorimg12, lowTexel, result);
    else imageStore(fogHistoryImg, lowTexel, result);
}
