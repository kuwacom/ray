/*
 * shadow_entities / shadow_block の頂点: player 空間の位置をジオメトリシェーダーへ渡す
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"

out vec2 vTexcoord;
out vec4 vColor;
out vec3 vPlayerPos;
out vec3 vNormal;

void main() {
    vTexcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor = gl_Color;
    vNormal = mat3(shadowModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    vPlayerPos = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}
