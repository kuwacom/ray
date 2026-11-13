/*
 * shadow_entities / shadow_block のジオメトリ: エンティティのボクセル化 (または三角形の保持)・光源登録・影マップ出力
 * PROGRAM_SHADOW_BLOCK が定義されていればブロックエンティティ (blockEntityId)
 * light モジュール (lib/light)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_LIGHT_BINS_WRITE
#define SSBO_ENTITY_TRIS_WRITE
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_ENTITY
#define IMG_VOXEL_EMIT
//@include "/lib/common/common.glsl"
//@include "/lib/common/shadow_space.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/light/voxel.glsl"
//@include "/lib/light/entity_tri.glsl"
//@include "/lib/light/entity_light.glsl"
//@include "/lib/light/hand_pose.glsl"
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
#include "/lib/common/shadow_space.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_pose.glsl"
// END GENERATED includes

layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

in vec2 vTexcoord[];
in vec4 vColor[];
in vec3 vPlayerPos[];
in vec3 vNormal[];

out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;

void main() {
#ifdef PROGRAM_SHADOW_BLOCK
    bool isPlayer = false;
    #ifdef LIGHT_ENTITY_OCCLUSION
        bool voxelize = true;
    #else
        bool voxelize = false;
    #endif
    #ifdef BLOCK_ENTITY_SHADOWS
        bool castShadow = true;
    #else
        bool castShadow = false;
    #endif
    // 光るブロックエンティティ (エンダーチェスト・コンジット等) を三角形の重心で登録する
    injectBlockEntityLight((vPlayerPos[0] + vPlayerPos[1] + vPlayerPos[2]) / 3.0, blockEntityId);
#else
    bool isPlayer = entityId == ENTITY_CURRENT_PLAYER;
    int entLight = getEntityLightIndex(entityId);
    // 名札・丸影・ビーム・炎・雷は形を持たないので遮蔽物にも影にもしない
    bool ignored = entityId == ENTITY_NAME_TAG || entityId == ENTITY_SHADOW || entityId == ENTITY_BEAM
        || entLight == LIGHT_ENTITY_FLAME || entLight == LIGHT_ENTITY_LIGHTNING;
    bool voxelize = false;
    #ifdef LIGHT_PLAYER_OCCLUSION
        if (isPlayer) voxelize = true;
    #endif
    #ifdef LIGHT_ENTITY_OCCLUSION
        if (!isPlayer && entityId != ENTITY_ITEM && entityId != ENTITY_ITEM_FRAME) voxelize = true;
    #endif
    voxelize = voxelize && !ignored;
    // 手持ちのランタンはエンティティ ID が付かずに描かれるので、光る物を持つ手の近くなら外す (lib/light/hand_pose.glsl)
    if (!isPlayer && entityId <= 0 && voxelize && isNearLitHand((vPlayerPos[0] + vPlayerPos[1] + vPlayerPos[2]) / 3.0)) voxelize = false;
    #ifdef ENTITY_SHADOWS
        bool castShadow = !ignored;
    #else
        bool castShadow = isPlayer;
    #endif

    // 画面外のエンティティ光源もここで登録する (gbuffers_entities と同じセルなら重複しない)
    injectEntityLight((vPlayerPos[0] + vPlayerPos[1] + vPlayerPos[2]) / 3.0, entityId, currentRenderedItemId, entityColor);
#endif

#if defined ENTITY_TRI_OCCLUSION && !defined PROGRAM_SHADOW_BLOCK
    /*
     * 三角形方式: 形どおりの三角形を保持し、保持できなかった他のエンティティだけ占有ボクセルへ退避する
     * 自分の退避はしない (一人称の手持ち光源が体のボクセルの中に入り、粗いサブセルで手の光が遮られるため)
     * 光る手持ちアイテム (たいまつ等) はその光源自身なので遮蔽物にしない
     */
    if (voxelize && getItemLightIndex(currentRenderedItemId) == LIGHT_NONE) {
        vec4 tint = (vColor[0] + vColor[1] + vColor[2]) / 3.0;
        bool stored = storeEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2],
                                          vTexcoord[0], vTexcoord[1], vTexcoord[2], tint, isPlayer);
        if (!stored && !isPlayer) voxelizeEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2], false);
    }
#else
    if (voxelize) voxelizeEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2], isPlayer);
#endif

    if (!castShadow) return;
    for (int i = 0; i < 3; i++) {
        texcoord = vTexcoord[i];
        glcolor = vColor[i];
        normalPlayer = vNormal[i];
        vec3 clip = (shadowProjection * vec4(playerToShadowView(vPlayerPos[i]), 1.0)).xyz;
        gl_Position = vec4(distortShadowClip(clip), 1.0);
        EmitVertex();
    }
    EndPrimitive();
}
