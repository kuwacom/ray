#include "/lib/common/common.glsl"

in vec2 texcoord;
in vec4 glcolor;
in vec3 normalPlayer;

/* RENDERTARGETS: 1,2,3,15 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outMaterial;
layout(location = 3) out vec4 outVelocity;

void main() {
#if CLOUDS == 1
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < alphaTestRef) discard;
    GBufferData g = gbufferDefault();
    g.albedo = srgbToLinear(c.rgb);
    g.materialId = MAT_CLOUD_VANILLA;
    g.normal = normalize(normalPlayer);
    g.geoNormal = g.normal;
    g.lightmap = vec2(0.0, 1.0);
    encodeGBuffer(g, outAlbedo, outNormal, outMaterial);
    outVelocity = vec4(0.0);
#else
    discard;
#endif
}
