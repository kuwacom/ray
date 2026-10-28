/*
 * gbuffers_clouds: バニラの雲 (CLOUDS == 1 の時だけ G バッファに書く。それ以外は体積雲を使うので捨てる)
 * sky モジュール (lib/sky)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/jitter.glsl"
//@include "/lib/common/transforms.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/common/transforms.glsl"
// END GENERATED includes

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
