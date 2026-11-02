/*
 * prepare1 (毎フレーム): SkyView LUT (192x108) を skyViewImg に作る
 * 視点高度から上半球の空の放射を、太陽と月 (対蹠点) の 2 光源で積分する。単位は FrameData と同じ相対照度系
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_SKY_VIEW
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
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
// END GENERATED includes

layout(local_size_x = 8, local_size_y = 4) in;
const ivec3 workGroups = ivec3(24, 27, 1);

const int SKYVIEW_STEPS = 32;
// 太陽が地平線の近く (この sin より低い) の間は歩数を増やす。地平線の近くの視線は 1000 km 以上あり、地球の影の境目に段差が出るため
const int SKYVIEW_STEPS_TWILIGHT = 48;
const float SKYVIEW_TWILIGHT_MU = 0.17;

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(texel, SKYVIEW_LUT_SIZE))) return;

    float r = atmoViewerRadius();
    float viewMu, azimuth;
    atmoSkyViewParams((vec2(texel) + 0.5) / vec2(SKYVIEW_LUT_SIZE), r, viewMu, azimuth);
    // 最下段は地平線ちょうど。float の r^2 の精度では地面に当たるかの判定が揺れるので、わずかに上へ向ける
    viewMu = max(viewMu, 1e-3);

    // 太陽を方位角 0 に置いた局所座標で積分する
    float sunMu = atmoSkySunMu(getSunDir().y);
    int steps = abs(sunMu) < SKYVIEW_TWILIGHT_MU ? SKYVIEW_STEPS_TWILIGHT : SKYVIEW_STEPS;
    vec3 sunDir = vec3(sqrt(max(1.0 - sunMu * sunMu, 0.0)), sunMu, 0.0);
    float sinView = sqrt(max(1.0 - viewMu * viewMu, 0.0));
    vec3 dir = vec3(sinView * cos(azimuth), viewMu, sinView * sin(azimuth));

    vec3 transmittance;
    vec3 radiance = atmoIntegrateScattering(vec3(0.0, r, 0.0), dir, sunDir, getSunIlluminanceTOA(), -sunDir, getMoonIlluminanceTOA(), steps, transmittance);
    imageStore(skyViewImg, texel, vec4(radiance, 1.0));
}
