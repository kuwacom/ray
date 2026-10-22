/*
 * アルベドに重ねるだけのオーバーレイ (エンチャントの光沢・クモの目・ブロックの破壊ひび)
 * colortex1 のみに書く。ブレンドは shaders.properties で a (マテリアル ID) を壊さない設定にしてある
 * surface モジュール (lib/surface)
 */
#include "/lib/common/common.glsl"

out vec2 texcoord;
out vec4 glcolor;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    gl_Position = ftransform();
    applyTaaJitter(gl_Position);
}
