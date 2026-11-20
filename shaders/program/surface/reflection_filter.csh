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

#define REFLECTION_FILTER_GROUP 8
layout(local_size_x = REFLECTION_FILTER_GROUP, local_size_y = REFLECTION_FILTER_GROUP) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

const int REFLECTION_FILTER_RADIUS = 3;       // 半分の解像度のテクセルで (7x7)
const float REFLECTION_FILTER_SIGMA = 2.5;    // 最も粗い面のガウスの幅 (テクセル)
const float REFLECTION_FILTER_SIGMA_MIN = 0.6;
const float REFLECTION_FILTER_PLANE = 0.02;   // 同じ平面とみなす距離 (ブロック + 視線距離に対する比)
const float REFLECTION_FILTER_PLANE_REL = 0.01;

/*
 * 近傍は 1 グループで共有メモリに 1 回だけ読み、近傍だけで決まる分 (法線の復元、反射を求めた面との一致、明るさの重み) もそこで済ませる
 * radiance: rgb = 放射 x 明るさの重み 1 / (1 + L)、a = その重み (使えない近傍は 0)。pos: player 空間の位置。normal: テクスチャ法線
 */
const int REFLECTION_FILTER_TILE = REFLECTION_FILTER_GROUP + 2 * REFLECTION_FILTER_RADIUS;
shared vec4 tileRadiance[REFLECTION_FILTER_TILE * REFLECTION_FILTER_TILE];
shared vec3 tilePos[REFLECTION_FILTER_TILE * REFLECTION_FILTER_TILE];
shared vec3 tileNormal[REFLECTION_FILTER_TILE * REFLECTION_FILTER_TILE];

void main() {
    ivec2 lowSize = reflectionLowResSize();
    ivec2 region = reflectionRegion(frameCounter);
    ivec2 offset = lowResOffset(frameCounter);
    ivec2 screen = ivec2(viewSize());
    float exposure = getExposure();
    ivec2 tileBase = ivec2(gl_WorkGroupID.xy) * REFLECTION_FILTER_GROUP - REFLECTION_FILTER_RADIUS;
    for (int k = int(gl_LocalInvocationIndex); k < REFLECTION_FILTER_TILE * REFLECTION_FILTER_TILE; k += REFLECTION_FILTER_GROUP * REFLECTION_FILTER_GROUP) {
        ivec2 L = tileBase + ivec2(k % REFLECTION_FILTER_TILE, k / REFLECTION_FILTER_TILE);
        vec4 r = vec4(0.0);
        vec3 q = vec3(0.0);
        vec3 n = vec3(0.0);
        if (all(greaterThanEqual(L, ivec2(0))) && all(lessThan(L, lowSize))) {
            vec4 h = imageLoad(reflectionImg, L + region);
            if (h.a > 0.0) {
                ivec2 nt = min(L * 2 + offset, screen - 1);
                float d1 = texelFetch(depthtex1, nt, 0).r;
                q = viewToPlayer(screenToView(vec3((vec2(nt) + 0.5) / viewSize(), d1)));
                float lq = length(q);
                // 反射を求めた面 (距離 h.a) が不透明の面と違う (半透明の面の反射) 近傍は混ぜない
                if (abs(lq - h.a) < REFLECTION_FILTER_PLANE + lq * REFLECTION_FILTER_PLANE_REL) {
                    // たまたま明るい物を引いたテクセルが近傍を支配して点に残らないよう、明るさで重みを下げる (c / (1 + L) の平均)
                    float k1 = 1.0 / (1.0 + luminance(h.rgb) * exposure);
                    r = vec4(h.rgb * k1, k1);
                    n = octDecode(texelFetch(colortex2, nt, 0).rg);
                }
            }
        }
        tileRadiance[k] = r;
        tilePos[k] = q;
        tileNormal[k] = n;
    }
    memoryBarrierShared();
    barrier();

    ivec2 low = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(low, lowSize))) return;
    ivec2 outLow = low + reflectionFilteredRegion();
    vec4 center = imageLoad(reflectionImg, low + region);
    if (center.a <= 0.0) {
        imageStore(reflectionImg, outLow, center);
        return;
    }
    ReflectSurface s = getReflectSurface(low * 2 + offset);
    ivec2 local = ivec2(gl_LocalInvocationID.xy) + REFLECTION_FILTER_RADIUS;
    if (!s.valid || s.translucent || s.perceptualRoughness < MIRROR_ROUGHNESS || tileRadiance[local.y * REFLECTION_FILTER_TILE + local.x].a <= 0.0) {
        imageStore(reflectionImg, outLow, center);
        return;
    }

    vec3 P = viewToPlayer(s.viewPos);
    float planeTol = REFLECTION_FILTER_PLANE + length(P) * REFLECTION_FILTER_PLANE_REL;
    float t = saturate((s.perceptualRoughness - MIRROR_ROUGHNESS) / 0.4);
    float sigma = mix(REFLECTION_FILTER_SIGMA_MIN, REFLECTION_FILTER_SIGMA, t);
    float gaussK = -0.5 / (sigma * sigma * log(2.0));
    /*
     * 法線はローブの半角より傾いた近傍を混ぜない (ReBLUR の法線の重み。半角は 90 m / (1 + m) 度、m = 粗さの二乗)
     * 半角で 0 になる直線の重みにする (pow より安い)
     */
    float m = s.perceptualRoughness * s.perceptualRoughness;
    float cosLobe = cos(radians(90.0 * m / (1.0 + m)));
    float invLobe = 1.0 / max(1.0 - cosLobe, 1e-4);

    vec4 sum = vec4(0.0);
    for (int j = -REFLECTION_FILTER_RADIUS; j <= REFLECTION_FILTER_RADIUS; j++) {
        for (int i = -REFLECTION_FILTER_RADIUS; i <= REFLECTION_FILTER_RADIUS; i++) {
            int k = (local.y + j) * REFLECTION_FILTER_TILE + local.x + i;
            vec4 r = tileRadiance[k];
            float w = exp2(float(i * i + j * j) * gaussK)
                * saturate((dot(tileNormal[k], s.normal) - cosLobe) * invLobe + float(i == 0 && j == 0))
                * step(abs(dot(tilePos[k] - P, s.geoNormal)), planeTol);
            sum += r * w;
        }
    }
    // 中心は必ず入るので sum.a > 0。明るさの重みで割った分を戻す
    imageStore(reflectionImg, outLow, vec4(sum.rgb / max(sum.a, 1e-8), center.a));
}
