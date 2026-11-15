/*
 * shadow パスのエンティティ・ブロックエンティティの三角形: 遮蔽物のボクセル化 (または三角形の保持)・光源登録 (light モジュール)
 * 呼び出し元: shadow_entities.gsh / shadow_block.gsh と、それらが読まれない Iris で全ジオメトリを受ける shadow.gsh
 * 呼ぶプログラムは IMG_VOXEL_ENTITY / IMG_VOXEL_EMIT と SSBO_LIGHT_BINS_WRITE / SSBO_ENTITY_TRIS_WRITE を定義する
 * 戻り値は、影マップにも描くか
 */
#ifndef LIGHT_SHADOW_ENTITY_GLSL
#define LIGHT_SHADOW_ENTITY_GLSL

//@include "/lib/common/uniforms.glsl"
//@include "/lib/ids/entity_ids.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/light/voxel.glsl"
//@include "/lib/light/entity_tri.glsl"
//@include "/lib/light/entity_light.glsl"
//@include "/lib/light/hand_pose.glsl"

bool shadowBlockEntityTriangle(vec3 p0, vec3 p1, vec3 p2) {
    // 光るブロックエンティティ (エンダーチェスト・コンジット等) を三角形の重心で登録する
    injectBlockEntityLight((p0 + p1 + p2) / 3.0, blockEntityId);
#ifdef LIGHT_ENTITY_OCCLUSION
    voxelizeEntityTriangle(p0, p1, p2, false);
#endif
#ifdef BLOCK_ENTITY_SHADOWS
    return true;
#else
    return false;
#endif
}

// c0〜c2: 頂点色 (三角形方式では平均を保持する)
bool shadowEntityTriangle(vec3 p0, vec3 p1, vec3 p2, vec2 uv0, vec2 uv1, vec2 uv2, vec4 c0, vec4 c1, vec4 c2) {
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
    if (!isPlayer && entityId <= 0 && voxelize && isNearLitHand((p0 + p1 + p2) / 3.0)) voxelize = false;
#ifdef ENTITY_SHADOWS
    bool castShadow = !ignored;
#else
    bool castShadow = isPlayer;
#endif

    // 画面外のエンティティ光源もここで登録する (gbuffers_entities と同じセルなら重複しない)
    injectEntityLight((p0 + p1 + p2) / 3.0, entityId, currentRenderedItemId, entityColor);
    /*
     * Iris 1.11 は影のパスのブロックエンティティを描き方 (RenderPipeline) で振り分け、shadow_block に回すのは
     * エンドポータル・エンドゲートウェイだけ。エンダーチェスト・コンジットなどはこちらに来るので、ここでも登録する
     * エンティティを描く間の blockEntityId は光源でない値 (0 / 1) なので、エンティティでは何もしない
     */
    injectBlockEntityLight((p0 + p1 + p2) / 3.0, blockEntityId);

#ifdef ENTITY_TRI_OCCLUSION
    /*
     * 三角形方式: 形どおりの三角形を保持し、保持できなかった他のエンティティだけ占有ボクセルへ退避する
     * 自分の退避はしない (一人称の手持ち光源が体のボクセルの中に入り、粗いサブセルで手の光が遮られるため)
     * 光る手持ちアイテム (たいまつ等) はその光源自身なので遮蔽物にしない
     */
    if (voxelize && getItemLightIndex(currentRenderedItemId) == LIGHT_NONE) {
        vec4 tint = (c0 + c1 + c2) / 3.0;
        bool stored = storeEntityTriangle(p0, p1, p2, uv0, uv1, uv2, tint, isPlayer);
        if (!stored && !isPlayer) voxelizeEntityTriangle(p0, p1, p2, false);
    }
#else
    if (voxelize) voxelizeEntityTriangle(p0, p1, p2, isPlayer);
#endif
    return castShadow;
}

#endif
