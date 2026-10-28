/*
 * gbuffers_weather: 雨・雪 (deferred の後に描かれるので半透明バッファへ前方シェーディング)
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/common/transforms.glsl"

out vec2 texcoord;
out vec4 glcolor;
out vec2 lmcoord;
out vec3 playerPos;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = saturate(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy - 1.0 / LIGHTMAP_TEXELS) * LIGHTMAP_TEXELS / LIGHTMAP_RANGE);
    glcolor = gl_Color;
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPos = viewToPlayer(viewPos);
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
    applyTaaJitter(gl_Position);
}
