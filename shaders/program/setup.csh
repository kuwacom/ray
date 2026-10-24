/*
 * setup (起動時・リサイズ時に 1 回): ブロックデータ表を SSBO に構築し、FrameData を初期化する
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"
#include "/lib/ids/block_albedo.glsl"

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
    for (int j = i; j < LIGHT_BIN_MAX; j += 256) lightBins.binCount[j] = 0u;
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
