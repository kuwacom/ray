/*
 * shadow_entities / shadow_block のフラグメント (エンティティは常に不透明扱い)
 * light モジュール (lib/light)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/encoding.glsl"
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
#include "/lib/common/encoding.glsl"
// END GENERATED includes

in vec2 texcoord;
in vec4 glcolor;
in vec3 normalPlayer;

/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outNormal;

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < 0.1) discard;
    outColor = vec4(albedo.rgb, 1.0);
    outNormal = vec4(octEncode(normalize(normalPlayer)), 1.0, 0.0);
}
