/*
 * setup (起動時・リサイズ時に 1 回): ブロックデータ表を SSBO に構築し、FrameData を初期化する
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 256) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
    int i = int(gl_LocalInvocationIndex);
    blockData.lightDefs[i] = lightDefStatic(i);
    if (i < SHAPE_TABLE_SIZE) blockData.shapes[i] = shapeStatic(i);
    if (i < TINT_TABLE_SIZE) blockData.tints[i] = tintStatic(i);

    if (i == 0) {
        blockData.initialized = 1u;
        // 各モジュールの FrameData は初回フレームで未定義にならないよう既定値を入れておく
        frameData.exposure = 1.0;
        frameData.exposureTarget = 1.0;
        frameData.averageLuminance = 0.18;
        frameData.focusDistance = DOF_MANUAL_FOCUS;
        frameData.lightStats = uvec4(0u);
    }
}
