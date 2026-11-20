/*
 * composite_a (compute): 時間蓄積した粗い反射を半分の解像度のまま空間でぼかし、reflectionImg の下の半分に書く
 * surface モジュール (lib/surface)
 *
 * 粗い反射は 1 画素 1 本の VNDF のサンプルを 3〜16 フレーム溜めるだけなので、暗い所の金属で粒が動いて見え、
 * 明るい物をたまたま引いたテクセルが点になって残っていた。ローブの広さの分だけ同じ平面の近傍を混ぜる
 * 時間蓄積の後でぼかすので、履歴 (上の半分) はぼかさない。合成 (composite2) は下の半分を読む
 * 鏡面・半透明・空へ抜けた所はそのまま写す
 */
#define IMG_REFLECTION
//@include "/lib/common/common.glsl"
//@include "/lib/surface/reflection.glsl"
//@include "/lib/common/exposure.glsl"
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
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/common/joint_bilateral.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/slots.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/settings/capabilities.glsl"
#include "/lib/light/hand_pose.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glitter.glsl"
#include "/lib/common/water_lod.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/surface/surface_lights.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/reflection.glsl"
#include "/lib/common/exposure.glsl"
// END GENERATED includes

layout(local_size_x = 8, local_size_y = 8) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

const int REFLECTION_FILTER_RADIUS = 3;       // 半分の解像度のテクセルで (7x7)
const float REFLECTION_FILTER_SIGMA = 2.5;    // 最も粗い面のガウスの幅 (テクセル)
const float REFLECTION_FILTER_SIGMA_MIN = 0.6;
const float REFLECTION_FILTER_PLANE = 0.02;   // 同じ平面とみなす距離 (ブロック + 視線距離に対する比)
const float REFLECTION_FILTER_PLANE_REL = 0.01;

// ローブの半角 (度) で重みが半分になる法線の指数。半角は 90 m / (1 + m)、m = 粗さの二乗 (ReBLUR の法線の重み)
float lobeNormalPower(float roughness) {
    float m = roughness * roughness;
    float halfAngle = radians(90.0 * m / (1.0 + m));
    return log(0.5) / log(max(cos(halfAngle), 1e-3));
}

void main() {
    ivec2 low = ivec2(gl_GlobalInvocationID.xy);
    ivec2 lowSize = reflectionLowResSize();
    if (any(greaterThanEqual(low, lowSize))) return;
    ivec2 region = reflectionRegion(frameCounter);
    ivec2 outLow = low + reflectionFilteredRegion();
    vec4 center = imageLoad(reflectionImg, low + region);
    if (center.a <= 0.0) {
        imageStore(reflectionImg, outLow, center);
        return;
    }
    ivec2 offset = lowResOffset(frameCounter);
    ReflectSurface s = getReflectSurface(low * 2 + offset);
    if (!s.valid || s.translucent || s.perceptualRoughness < MIRROR_ROUGHNESS) {
        imageStore(reflectionImg, outLow, center);
        return;
    }

    vec3 P = viewToPlayer(s.viewPos);
    float dist = length(P);
    float t = saturate((s.perceptualRoughness - MIRROR_ROUGHNESS) / 0.4);
    float sigma = mix(REFLECTION_FILTER_SIGMA_MIN, REFLECTION_FILTER_SIGMA, t);
    float invTwoSigma2 = 0.5 / (sigma * sigma);
    float normalPower = lobeNormalPower(s.perceptualRoughness);
    float planeTol = REFLECTION_FILTER_PLANE + dist * REFLECTION_FILTER_PLANE_REL;
    float exposure = getExposure();
    ivec2 screen = ivec2(viewSize());

    // 明るさで重みを下げて混ぜる (c / (1 + L) の平均)。たまたま明るい物を引いたテクセルが近傍を支配して点に残らない
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int j = -REFLECTION_FILTER_RADIUS; j <= REFLECTION_FILTER_RADIUS; j++) {
        for (int i = -REFLECTION_FILTER_RADIUS; i <= REFLECTION_FILTER_RADIUS; i++) {
            ivec2 L = low + ivec2(i, j);
            if (any(lessThan(L, ivec2(0))) || any(greaterThanEqual(L, lowSize))) continue;
            vec4 r = (i == 0 && j == 0) ? center : imageLoad(reflectionImg, L + region);
            if (r.a <= 0.0) continue;
            ivec2 nt = min(L * 2 + offset, screen - 1);
            float w = exp(-float(i * i + j * j) * invTwoSigma2);
            if (i != 0 || j != 0) {
                float d1 = texelFetch(depthtex1, nt, 0).r;
                vec3 Q = viewToPlayer(screenToView(vec3((vec2(nt) + 0.5) / viewSize(), d1)));
                // 同じ平面で、反射を求めた面が同じ (半透明の面の反射を混ぜない) 近傍だけ
                if (abs(dot(Q - P, s.geoNormal)) > planeTol || abs(length(Q) - r.a) > planeTol) continue;
                w *= pow(saturate(dot(readGBufferNormal(nt), s.normal)), normalPower);
            }
            w /= 1.0 + luminance(r.rgb) * exposure;
            sum += r.rgb * w;
            wsum += w;
        }
    }
    // 中心は必ず入るので wsum > 0。明るさの重みで割った分を戻す
    imageStore(reflectionImg, outLow, vec4(sum / wsum, center.a));
}
