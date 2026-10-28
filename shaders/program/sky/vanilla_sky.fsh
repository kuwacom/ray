#include "/lib/common/common.glsl"

in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // 空の色・夕焼け・星はすべて deferred30 の renderSky が描く (星は天球に固定した手続き生成)
    discard;
}
