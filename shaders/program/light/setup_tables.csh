/*
 * setup (起動時・リサイズ時に 1 回): ブロックデータ表を SSBO に構築し、FrameData を初期化する
 * light モジュール (lib/light)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
#define SSBO_BLOCK_DATA_WRITE
#define SSBO_GLOBAL_LIGHTS_WRITE
#define SSBO_LIGHT_BINS_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/buffers/light_bins.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/ids/block_albedo.glsl"
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
#include "/lib/buffers/block_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/common/color.glsl"
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
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/ids/block_albedo.glsl"
// END GENERATED includes

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
    int i = int(gl_LocalInvocationIndex);
    blockData.lightDefs[i] = lightDefStatic(i);
    if (i < SHAPE_TABLE_SIZE) blockData.shapes[i] = shapeStatic(i);
    if (i < TINT_TABLE_SIZE) blockData.tints[i] = tintStatic(i);
    for (int j = i; j < ALBEDO_TABLE_SIZE; j += 256) {
        blockData.albedo[j] = blockAlbedoPacked(j);
        blockData.albedoUp[j] = blockAlbedoTopPacked(j);
    }
    /*
     * ライトビンを全部 0 にする。begin は前フレームに使った枠だけを戻すので、確保直後の中身が 0 でないと残り続ける
     * 1 回だけなので 1 ワークグループで足りる (約 5M uint)
     */
    for (int j = i; j < LIGHT_BINS_ALLOC; j += 256) lightBins.binCount[j] = 0u;
    for (int j = i; j < LIGHT_BIN_KEYS_ALLOC; j += 256) lightBins.binLights[j] = 0u;
    if (i < LIGHT_CULL_BUCKETS) globalLights.cullHist[i] = 0u;

    if (i == 0) {
        blockData.initialized = 1u;
        // 各モジュールの FrameData は初回フレームで未定義にならないよう既定値を入れておく
        frameData.exposure = 1.0;
        frameData.exposureTarget = 1.0;
        frameData.averageLuminance = 0.18;
        frameData.focusDistance = DOF_MANUAL_FOCUS;
        frameData.lightStats = uvec4(0u);
        globalLights.cullDistance = LIGHT_CULL_NONE;
        globalLights.culled = 0u;
    }
}
