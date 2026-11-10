//@include "/lib/common/common.glsl"
//@include "/lib/common/phase.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/light/light.glsl"
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
#include "/lib/common/phase.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/color.glsl"
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
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/light/voxel_read.glsl"
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
// END GENERATED includes

in vec2 texcoord;
in vec4 glcolor;
in vec2 lmcoord;
in vec3 playerPos;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 outColor;

// 雨粒は細く透明なので不透明度を下げ、空の光を映す明るさで描く。雪は白く拡散する
const float RAIN_OPACITY = 0.35;
const float SNOW_OPACITY = 0.85;
// 雨粒が逆光で光る前方散乱の強さ (水滴の屈折で光源側が明るく見える)
const float RAIN_FORWARD_SCATTER = 0.25;

void main() {
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < alphaTestRef) discard;

    bool snow = biome_precipitation == 2;
    vec3 V = normalize(playerPos);
    LightSample celestial = getCelestialLight();
    float skyLight = sqr(lmcoord.y);
    float sunVisibility = getCloudShadow(playerPos) * skyLight;

    vec3 ambient = getSkyIrradiance(vec3(0.0, 1.0, 0.0)) * skyLight + getBlockLightForward(playerPos, -V, lmcoord.x) + MIN_AMBIENT;
    vec3 color;
    float opacity;
    if (snow) {
        color = srgbToLinear(c.rgb) * (ambient + celestial.irradiance * 0.5 * sunVisibility) * RCP_PI;
        opacity = c.a * SNOW_OPACITY;
    } else {
        float phase = phaseHG(dot(V, celestial.direction), 0.7);
        color = srgbToLinear(c.rgb) * (ambient * RCP_PI + celestial.irradiance * phase * RAIN_FORWARD_SCATTER * sunVisibility);
        opacity = c.a * RAIN_OPACITY;
    }
    // 雨雲の層より上は雲の上で降っていないので、層の上端へ向けて薄くして消す
    opacity *= cloudRainBelowDeck();
    // colortex4 は既定のアルファブレンドで乗算済みになるので、ここでは掛けない
    outColor = vec4(color, opacity);
}
