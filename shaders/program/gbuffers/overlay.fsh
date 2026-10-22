#include "/lib/common/common.glsl"

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
