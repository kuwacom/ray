/*
 * gbuffers_clouds: バニラの雲 (CLOUDS == 1 の時だけ G バッファに書く。それ以外は体積雲を使うので捨てる)
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"

out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    normalPlayer = viewToPlayerDir(normalize(gl_NormalMatrix * gl_Normal));
    gl_Position = ftransform();
    applyTaaJitter(gl_Position);
}
