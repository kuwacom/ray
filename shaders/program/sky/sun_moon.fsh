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
// END GENERATED includes

in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

/*
 * バニラの太陽テクスチャの明るい部分は四角形の約 1/4 (視直径でおよそ 0.3 rad 四方) なので、
 * 円盤を積分した照度が直達照度と釣り合うようにこの倍率を掛ける
 */
const float VANILLA_SUN_RADIANCE_SCALE = 10.0;
const float VANILLA_MOON_RADIANCE_SCALE = 10.0;

void main() {
#if defined WORLD_END
    // エンドの空は renderSky が手続き生成で描く
    discard;
#else
    #if SUN_MOON_STYLE == 1
        // 物理的な円盤は renderSky が描くので、バニラの太陽と月は捨てる (リソースパックのカスタム空は残す)
        if (renderStage == MC_RENDER_STAGE_SUN || renderStage == MC_RENDER_STAGE_MOON) discard;
    #endif
    vec4 c = texture(gtexture, texcoord) * glcolor;
    vec3 radiance = srgbToLinear(c.rgb) * c.a;
    if (renderStage == MC_RENDER_STAGE_SUN) {
        radiance *= getSunIrradiance() * VANILLA_SUN_RADIANCE_SCALE;
    } else if (renderStage == MC_RENDER_STAGE_MOON) {
        radiance *= getMoonIlluminanceFull() * atmoTransmittanceToLight(atmoViewerRadius(), getMoonDir().y) * VANILLA_MOON_RADIANCE_SCALE;
    } else {
        radiance *= SKY_ILLUMINANCE * SKY_BRIGHTNESS;
    }
    outColor = vec4(radiance, 1.0);
#endif
}
