/*
 * shadow_entities / shadow_block の頂点: player 空間の位置をジオメトリシェーダーへ渡す
 * light モジュール (lib/light)
 */
//@include "/lib/common/common.glsl"
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
// END GENERATED includes

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
