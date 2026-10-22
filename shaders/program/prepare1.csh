/*
 * prepare1 (毎フレーム): SkyView LUT (192x108) を skyViewImg に作る
 * 視点高度から上半球の空の放射を、太陽と月 (対蹠点) の 2 光源で積分する。単位は FrameData と同じ相対照度系
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_SKY_VIEW
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"

layout(local_size_x = 8, local_size_y = 4) in;
const ivec3 workGroups = ivec3(24, 27, 1);

const int SKYVIEW_STEPS = 32;

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(texel, SKYVIEW_LUT_SIZE))) return;

    float r = atmoViewerRadius();
    float viewMu, azimuth;
    atmoSkyViewParams((vec2(texel) + 0.5) / vec2(SKYVIEW_LUT_SIZE), r, viewMu, azimuth);
    // 最下段は地平線ちょうど。float の r^2 の精度では地面に当たるかの判定が揺れるので、わずかに上へ向ける
    viewMu = max(viewMu, 1e-3);

    // 太陽を方位角 0 に置いた局所座標で積分する
    float sunMu = getSunDir().y;
    vec3 sunDir = vec3(sqrt(max(1.0 - sunMu * sunMu, 0.0)), sunMu, 0.0);
    float sinView = sqrt(max(1.0 - viewMu * viewMu, 0.0));
    vec3 dir = vec3(sinView * cos(azimuth), viewMu, sinView * sin(azimuth));

    vec3 transmittance;
    vec3 radiance = atmoIntegrateScattering(vec3(0.0, r, 0.0), dir, sunDir, getSunIlluminanceTOA(), -sunDir, getMoonIlluminanceTOA(), SKYVIEW_STEPS, transmittance);
    imageStore(skyViewImg, texel, vec4(radiance, 1.0));
}
