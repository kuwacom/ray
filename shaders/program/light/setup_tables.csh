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
//@include "/lib/light/light_mask_data.glsl"
//@include "/lib/light/reflector_map_data.glsl"
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
#include "/lib/ids/material_ids.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/entity_ids.glsl"
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
#include "/lib/settings/capabilities.glsl"
#include "/lib/light/hand_pose.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/light/light_mask_data.glsl"
#include "/lib/light/reflector_map_data.glsl"
#include "/lib/ids/block_albedo.glsl"
// END GENERATED includes

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
    int i = int(gl_LocalInvocationIndex);
    blockData.lightDefs[i] = lightDefStatic(i);
#if DECORATIVE_BLOCK_LIGHTS == 2
    /*
     * 鉱物ブロックの光の色と強さ (DECOR_SATURATION / DECOR_BRIGHTNESS)。色は輝度を保って動かし、最大成分 1 に戻さない
     * (戻した分を明るさに入れると、届く距離 (lightRange) が色の濃さで伸び縮みする)
     */
    if (i >= LIGHT_DECOR_FIRST && i < LIGHT_DECOR_FIRST + LIGHT_DECOR_COUNT) {
        blockData.lightDefs[i].color.rgb = applyVividSaturation(blockData.lightDefs[i].color.rgb, decorSaturation(i - LIGHT_DECOR_FIRST));
        blockData.lightDefs[i].color.a *= DECOR_BRIGHTNESS;
    }
#endif
    if (i < SHAPE_TABLE_SIZE) {
        uvec4 s = shapeStatic(i);
        blockData.shapes[i] = s;
        blockData.shapeFaces[i] = shapeCoveredFaces(s);
    }
    if (i < TINT_TABLE_SIZE) blockData.tints[i] = tintStatic(i);
    for (int j = i; j < ALBEDO_TABLE_SIZE; j += 256) {
        uint albedo = blockAlbedoPacked(j);
        uint albedoUp = blockAlbedoTopPacked(j);
        // 色の付いた固体の反射率 (ALBEDO_*_STRENGTH)。G バッファと同じ色にして、画面外の GI の当たりと floodfill の壁の照り返しもそろえる
        if (COLOR_ALBEDO_ACTIVE && isColorAlbedoBlock(j)) {
            vec3 mean = srgbToLinear(unpackUnorm4x8(albedo).rgb);
            vec3 meanUp = srgbToLinear(unpackUnorm4x8(albedoUp).rgb);
            // a に掛ける前の平均の最大成分を残す (G バッファと RSM のテラコッタが同じ倍率を引く、colorBlockMeanMax)
            float meanMax = maxOf(mean);
            albedo = packUnorm4x8(vec4(linearToSrgb(applyColorBlockAlbedo(j, mean, meanMax)), linearToSrgb(vec3(meanMax)).x));
            albedoUp = packUnorm4x8(vec4(linearToSrgb(applyColorBlockAlbedo(j, meanUp, meanMax)), 0.0));
        }
        blockData.albedo[j] = albedo;
        blockData.albedoUp[j] = albedoUp;
    }
    if (i < LIGHT_MASK_LIGHTS) {
        uint litFaces = 0u;
        for (int c = 0; c < LIGHT_MASK_FACE_CLASSES; c++) {
            uvec4 m = lightMaskStatic(i, c);
            blockData.lightMasks[i * LIGHT_MASK_FACE_CLASSES + c] = m;
            litFaces |= m.y;
        }
        if (litFaces != 0u) blockData.lightDefs[i].info.x |= LIGHT_FLAG_EMISSION_MASK;
    }
    for (int j = i; j < REFLECTOR_MAP_BLOCKS * REFLECTOR_MAP_VEC4S; j += 256) blockData.lightMasks[REFLECTOR_MAP_BASE + j] = reflectorMapStatic(j);
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
        // 0 は未初期化の印。設定の値 (カスタム uniform) は setup に渡らないので、読む側が補う (cameraFocusDistance)
        frameData.focusDistance = 0.0;
        frameData.lightStats = uvec4(0u);
        globalLights.cullDistance = LIGHT_CULL_NONE;
        globalLights.culled = 0u;
    }
}
