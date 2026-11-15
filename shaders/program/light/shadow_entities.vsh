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
#if !defined PROGRAM_SHADOW_BLOCK && defined CHARGED_CREEPER_LIGHT
    flat out int vSwirlLayer;
    const float SWIRL_TEXTURE_MATRIX_EPS = 1e-6;
#endif

void main() {
    vTexcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
#if !defined PROGRAM_SHADOW_BLOCK && defined CHARGED_CREEPER_LIGHT
    // 電気の渦の層だけがテクスチャ行列で UV を流す (gbuffers_solid.vsh と同じ見分け方)
    mat4 texMatOffset = gl_TextureMatrix[0] - mat4(1.0);
    vec4 texMatDiff = abs(texMatOffset[0]) + abs(texMatOffset[1]) + abs(texMatOffset[2]) + abs(texMatOffset[3]);
    vSwirlLayer = dot(texMatDiff, vec4(1.0)) > SWIRL_TEXTURE_MATRIX_EPS ? 1 : 0;
#endif
    vColor = gl_Color;
    vNormal = mat3(shadowModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    vPlayerPos = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}
