/*
 * begin (shadow パスの前): 今フレームの光源リストとライトビンを空にする
 * binLights の先頭はエンティティ光源の蓄積表 (lib/light/entity_light.glsl) として使うのでここでクリアする
 * エンティティの三角形 (lib/light/entity_tri.glsl) のカウンタと AABB もここで空にする
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(144, 1, 1); // LIGHT_BIN_MAX / 256

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i < uint(LIGHT_BIN_MAX)) lightBins.binCount[i] = 0u;
    // 36864 スレッドで蓄積表 (32768 uint) を覆える
    if (i < uint(ENTITY_ACC_UINTS)) lightBins.binLights[i] = 0u;
    clearEntityTriangles(i);

    if (i == 0u) {
        frameData.lightStats.x = globalLights.count;
        frameData.lightStats.y = globalLights.overflow;
        // エンティティ光源の登録を受け付ける (deferred_a で締め切る)
        frameData.lightStats.z = 0u;
        globalLights.count = 0u;
        globalLights.blockCount = 0u;
        globalLights.entityCount = 0u;
        globalLights.overflow = 0u;
    }
}
