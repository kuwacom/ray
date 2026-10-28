/*
 * gbuffers_skybasic: バニラの空。空の色・星は deferred30 が renderSky で描くので、ここでは何も出さない
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"

out vec4 glcolor;

void main() {
    glcolor = gl_Color;
    gl_Position = ftransform();
}
