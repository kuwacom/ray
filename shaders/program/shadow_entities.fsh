/*
 * shadow_entities / shadow_block のフラグメント (エンティティは常に不透明扱い)
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"

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
