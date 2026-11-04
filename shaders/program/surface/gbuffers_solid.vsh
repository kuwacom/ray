/*
 * 不透明ジオメトリ共通の頂点シェーダー (G バッファ経路)
 * 呼び出し元のラッパー (gbuffers_*.vsh) が GBUF_* を 1 つ define してから include する
 * surface モジュール (GBUF_ENTITIES の光源登録呼び出しは light モジュールの関数)
 */
#ifdef GBUF_ENTITIES
    // injectEntityLight が voxelEmitImg とエンティティ光源の蓄積表に書く (lib/buffers/images.glsl, light_bins.glsl)
    #define IMG_VOXEL_EMIT
    #define SSBO_LIGHT_BINS_WRITE
#endif
//@include "/lib/common/common.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/jitter.glsl"
//@include "/lib/surface/surface.glsl"
#ifdef GBUF_ENTITIES
    //@include "/lib/light/light.glsl"
#endif
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
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glitter.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
#ifdef GBUF_ENTITIES
    #include "/lib/buffers/light_bins.glsl"
    #include "/lib/light/light_bins.glsl"
    #include "/lib/buffers/block_data.glsl"
    #include "/lib/light/light_def.glsl"
    #include "/lib/light/light_table_data.glsl"
    #include "/lib/light/light_table.glsl"
    #include "/lib/light/block_data.glsl"
    #include "/lib/light/voxel.glsl"
    #include "/lib/light/floodfill.glsl"
    #include "/lib/buffers/entity_tris.glsl"
    #include "/lib/light/entity_tri.glsl"
    #include "/lib/light/trace.glsl"
    #include "/lib/buffers/global_lights.glsl"
    #include "/lib/light/light_select.glsl"
    #include "/lib/buffers/frame_data.glsl"
    #include "/lib/light/entity_light.glsl"
    #include "/lib/light/hand_light.glsl"
    #include "/lib/light/blocklight.glsl"
    #include "/lib/light/light.glsl"
#endif
// END GENERATED includes

#ifdef GBUF_TERRAIN
    in vec2 mc_Entity;
    in vec4 at_midBlock;
    in vec2 mc_midTexCoord;
#endif
in vec4 at_tangent;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 viewPos;
out vec3 normalPlayer;
out vec4 tangentPlayer;
// アトラス上のスプライトの中心と半径 (POM の折り返し・自動法線の近傍参照をスプライト内に留める)
out vec2 tileMid;
out vec2 tileHalf;
flat out int blockId;

const float MID_UV_FIXED_SCALE = 32768.0;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = saturate(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy - 1.0 / LIGHTMAP_TEXELS) * LIGHTMAP_TEXELS / LIGHTMAP_RANGE);
    glcolor = gl_Color;
    normalPlayer = viewToPlayerDir(normalize(gl_NormalMatrix * gl_Normal));
    tangentPlayer = vec4(viewToPlayerDir(normalize(gl_NormalMatrix * at_tangent.xyz)), at_tangent.w);

#ifdef GBUF_TERRAIN
    blockId = int(round(mc_Entity.x));
    /*
     * Iris 1.11 + Sodium 0.9 (26.1) では、頂点バッファの mid UV (u * 32768 の整数を float にした値) を Iris が
     * uvec2 として読み直すため、float のビット列を 1/32768 倍した巨大な値 (~3.6e4) が来る (実機で確認)。
     * そのまま使うとスプライトの範囲が画素ごとにでたらめになり、自動法線の近傍参照がテクセル単位で暴れていた
     * 範囲外の値はビット列として解釈し直す。正しい値 (0-1) が来る版ではそのまま使う
     */
    vec2 midUv = mc_midTexCoord;
    if (any(greaterThan(midUv, vec2(2.0)))) midUv = uintBitsToFloat(uvec2(midUv * MID_UV_FIXED_SCALE)) / MID_UV_FIXED_SCALE;
    tileMid = midUv;
    tileHalf = abs(texcoord - midUv);
#else
    blockId = 0;
    tileMid = vec2(0.5);
    tileHalf = vec2(0.5);
#endif

    viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;

#ifdef GBUF_TERRAIN
    vec3 playerPos = viewToPlayer(viewPos);
    playerPos = applyWaving(playerPos, blockId, at_midBlock.y < 0.0, lmcoord.y);
    viewPos = playerToView(playerPos);
#endif

#ifdef GBUF_ENTITIES
    // 画面内のエンティティ光源を登録 (4 頂点に 1 回で十分。重複は light モジュール側で排除される)
    if ((gl_VertexID & 3) == 0) injectEntityLight(viewToPlayer(viewPos), entityId, currentRenderedItemId, entityColor);
#endif

    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
    applyTaaJitter(gl_Position);
}
