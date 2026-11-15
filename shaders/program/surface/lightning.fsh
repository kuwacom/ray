//@include "/lib/common/common.glsl"
//@include "/lib/surface/lightning.glsl"
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
#include "/lib/common/exposure.glsl"
#include "/lib/surface/lightning.glsl"
// END GENERATED includes

in vec4 glcolor;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 outColor;

void main() {
    // colortex4 へは shaders.properties の加算ブレンドで足し、a (覆いの強さ) は変えない (明るさの決め方は lib/surface/lightning.glsl)
    outColor = vec4(lightningGlow(glcolor), 0.0);
}
