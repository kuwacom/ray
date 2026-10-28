/*
 * gbuffers_skybasic: バニラの空。空の色・星は deferred30 が renderSky で描くので、ここでは何も出さない
 * sky モジュール (lib/sky)
 */
//@include "/lib/common/common.glsl"
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
// END GENERATED includes

out vec4 glcolor;

void main() {
    glcolor = gl_Color;
    gl_Position = ftransform();
}
