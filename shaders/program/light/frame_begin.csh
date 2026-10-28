/*
 * begin (shadow パスの前): 今フレームの光源リストとライトビンを空にする
 * エンティティ光源の蓄積表 (lib/light/entity_light.glsl) もここでクリアする
 * エンティティの三角形 (lib/light/entity_tri.glsl) のカウンタと AABB もここで空にする
 * light モジュール (lib/light)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
#define SSBO_GLOBAL_LIGHTS_WRITE
#define SSBO_LIGHT_BINS_WRITE
#define SSBO_ENTITY_TRIS_WRITE
#include "/lib/common/common.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(160, 1, 1); // LIGHT_BINS_ALLOC / 256

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i < uint(LIGHT_BINS_ALLOC)) {
#if LIGHT_CULL_MODE != 0
        // 重要度順の挿入 (deferred_a) は空きの枠が 0 である必要がある。前フレームに書いた枠だけを戻す
        uint used = min(lightBins.binCount[i], uint(LIGHT_BIN_STRIDE));
        uint base = lightBinBase(int(i));
        for (uint k = 0u; k < used; k++) lightBins.binLights[base + k] = 0u;
#endif
        lightBins.binCount[i] = 0u;
    }
    // 40960 スレッドで蓄積表 (32768 uint) を覆える
    if (i < uint(ENTITY_ACC_UINTS)) lightBins.entityAcc[i] = 0u;
    clearEntityTriangles(i);

    if (i == 0u) {
        frameData.lightStats.x = globalLights.count;
        frameData.lightStats.y = globalLights.overflow;
        // エンティティ光源の登録を受け付ける (deferred_a で締め切る)
        frameData.lightStats.z = 0u;
        // w = 前フレームに距離で間引いた数
        frameData.lightStats.w = globalLights.culled;
        globalLights.count = 0u;
        globalLights.blockCount = 0u;
        globalLights.entityCount = 0u;
        globalLights.overflow = 0u;
        globalLights.culled = 0u;
    }
}
