// composite 系パス共通の全画面クアッド
#include "/lib/common/common.glsl"

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
