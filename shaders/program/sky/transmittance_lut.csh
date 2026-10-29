/*
 * setup1 (起動時 1 回): 大気の透過率 LUT (Hillaire 2020, 256x64) を skyTransmittanceImg に作る
 * 各テクセル = (高度 r, 天頂角余弦 mu) から大気上端までの透過率
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_SKY_TRANSMITTANCE
//@include "/lib/common/common.glsl"
//@include "/lib/sky/sky.glsl"
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
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
// END GENERATED includes

layout(local_size_x = 8, local_size_y = 8) in;
const ivec3 workGroups = ivec3(32, 8, 1);

const int TRANSMITTANCE_STEPS = 64;

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(texel, TRANSMITTANCE_LUT_SIZE))) return;

    float r, mu;
    atmoTransmittanceParams((vec2(texel) + 0.5) / vec2(TRANSMITTANCE_LUT_SIZE), r, mu);

    float tMax = atmoDistanceToTop(r, mu);
    float dt = tMax / float(TRANSMITTANCE_STEPS);
    vec3 opticalDepth = vec3(0.0);
    for (int i = 0; i < TRANSMITTANCE_STEPS; i++) {
        float t = (float(i) + 0.5) * dt;
        float h = sqrt(r * r + t * t + 2.0 * r * mu * t) - ATMO_GROUND_RADIUS;
        vec3 rayleighScatter, extinction;
        float mieScatter;
        atmoMedium(h, rayleighScatter, mieScatter, extinction);
        opticalDepth += extinction * dt;
    }
    imageStore(skyTransmittanceImg, texel, vec4(exp(-opticalDepth), 1.0));
}
