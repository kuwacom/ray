/*
 * 半透明ジオメトリ共通の頂点シェーダー (水・色ガラス・手持ちの半透明・半透明パーティクル・半透明エンティティ)
 * 呼び出し元が GBUF_WATER / GBUF_HAND_WATER / GBUF_PARTICLES_TRANSLUCENT / GBUF_ENTITIES_TRANSLUCENT / GBUF_BLOCK_TRANSLUCENT を define する
 * surface モジュール (lib/surface)
 */
#ifdef GBUF_ENTITIES_TRANSLUCENT
    // 半透明で描かれる光源エンティティ (アレイ等) も画面内で登録する (lib/buffers/images.glsl)
    #define IMG_VOXEL_EMIT
#endif
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#ifdef GBUF_ENTITIES_TRANSLUCENT
    #include "/lib/light/light.glsl"
#endif

#ifdef GBUF_WATER
    in vec2 mc_Entity;
    in vec4 at_midBlock;
#endif
in vec4 at_tangent;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 viewPos;
out vec3 normalPlayer;
out vec4 tangentPlayer;
flat out int blockId;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = saturate(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy - 1.0 / 32.0) * 32.0 / 30.0);
    glcolor = gl_Color;
    normalPlayer = viewToPlayerDir(normalize(gl_NormalMatrix * gl_Normal));
    tangentPlayer = vec4(viewToPlayerDir(normalize(gl_NormalMatrix * at_tangent.xyz)), at_tangent.w);
#ifdef GBUF_WATER
    blockId = int(round(mc_Entity.x));
#else
    blockId = 0;
#endif
    viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
#ifdef GBUF_ENTITIES_TRANSLUCENT
    if ((gl_VertexID & 3) == 0) injectEntityLight(viewToPlayer(viewPos), entityId, currentRenderedItemId, entityColor);
#endif
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
    applyTaaJitter(gl_Position);
}
