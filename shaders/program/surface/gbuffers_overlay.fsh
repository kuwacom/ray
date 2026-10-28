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

in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 1 */
layout(location = 0) out vec4 outAlbedo;

void main() {
    vec4 c = texture(gtexture, texcoord) * glcolor;
#ifdef GBUF_DAMAGEDBLOCK
    if (c.a < 0.01) discard;
#endif
    outAlbedo = vec4(c.rgb, c.a);
}
