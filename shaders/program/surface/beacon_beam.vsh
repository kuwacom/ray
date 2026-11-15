/*
 * gbuffers_beaconbeam: ビーコンの光線のジオメトリは描かず、光線の区間 (柱・高さ・色) を FrameData に登録する
 * 光線は composite19 が大気の散乱として視線ごとに積分して足す (lib/sky/beacon_beam.glsl)。
 * G バッファの不透明な柱として描くと深度で雲の合成から外れ、雲の奥の光線が雲の上に描かれていた
 * surface モジュール (lib/surface)
 */
#define SSBO_FRAME_DATA_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
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
#include "/lib/common/color.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/buffers/frame_data.glsl"
// END GENERATED includes

void main() {
    vec3 worldPos = viewToPlayer((gl_ModelViewMatrix * gl_Vertex).xyz) + cameraPosition;
    // 内側の光線 (半径 0.2) も外側の光 (0.25) も回転してもブロックの中に収まるので、柱はブロックで決まる
    ivec2 cell = ivec2(floor(worldPos.xz));
    uint color = packUnorm4x8(vec4(srgbToLinear(saturate(gl_Color.rgb)), 1.0));
    uint key = max(pcgHash(uint(cell.x) ^ pcgHash(uint(cell.y) ^ pcgHash(color))), 1u);
    int y = int(round(worldPos.y));
    // 前から順に空きを取る (同じ区間の頂点は同じ枠に集まる)。読む側は最初の空きで止まれる
    for (int i = 0; i < BEACON_BEAM_MAX; i++) {
        uint prev = atomicCompSwap(frameData.beaconBeamKey[i], 0u, key);
        if (prev == 0u || prev == key) {
            frameData.beaconBeamCell[i] = cell;
            frameData.beaconBeamColor[i] = color;
            atomicMin(frameData.beaconBeamYMin[i], y);
            atomicMax(frameData.beaconBeamYMax[i], y);
            break;
        }
    }
    // クリップ空間の外へ置いてラスタライズさせない
    gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
}
