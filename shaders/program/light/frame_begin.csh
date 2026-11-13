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
//@include "/lib/common/common.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/buffers/light_bins.glsl"
//@include "/lib/light/light.glsl"
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
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/common/color.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_pose.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
// END GENERATED includes

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
