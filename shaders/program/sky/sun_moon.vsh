/*
 * gbuffers_skytextured: 太陽・月のテクスチャ (colortex0 に描き、deferred30 が空に足す)
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"

out vec2 texcoord;
out vec4 glcolor;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    gl_Position = ftransform();
}
