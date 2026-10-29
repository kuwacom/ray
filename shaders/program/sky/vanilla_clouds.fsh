//@include "/lib/common/common.glsl"
//@include "/lib/common/color.glsl"
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
#include "/lib/common/color.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
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

in vec4 glcolor;
in vec3 normalPlayer;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 outColor;

// 雲の反射率。バニラの雲は白だが、白 1.0 の面は日向で白飛びするので実際の雲に近い値にする
const float CLOUD_VANILLA_ALBEDO = 0.85;

void main() {
#if CLOUDS == 1
    // 雲は deferred の後に描かれるので、G バッファではなく半透明と同じ前方シェーディングで色を決める
    // 26.1 の雲は頂点色 (面の濃淡 x 雲の色 x 不透明度) だけで、テクスチャは無い。形はバニラのメッシュそのまま
    if (glcolor.a < alphaTestRef) discard;
    vec3 N = normalize(normalPlayer);
    LightSample celestial = getCelestialLight();
    vec3 irradiance = getSkyIrradiance(N) + celestial.irradiance * saturate(dot(N, celestial.direction));
    // colortex4 は既定のアルファブレンドで乗算済みになるので、ここでは掛けない
    outColor = vec4(CLOUD_VANILLA_ALBEDO * irradiance * RCP_PI, glcolor.a);
#else
    discard;
#endif
}
