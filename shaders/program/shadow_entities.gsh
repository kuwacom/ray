/*
 * shadow_entities / shadow_block のジオメトリ: エンティティのボクセル化 (または三角形の保持)・光源登録・影マップ出力
 * PROGRAM_SHADOW_BLOCK が定義されていればブロックエンティティ (blockEntityId)
 * light モジュール (lib/light)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_ENTITY
#define IMG_VOXEL_EMIT
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"

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
    // 手持ちのランタンはエンティティ ID が付かずに描かれるので、光る物を持つ手の近くなら外す (lib/light/hand_light.glsl)
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
        float alpha = (vColor[0].a + vColor[1].a + vColor[2].a) / 3.0;
        bool stored = storeEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2],
                                          vTexcoord[0], vTexcoord[1], vTexcoord[2], alpha, isPlayer);
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
