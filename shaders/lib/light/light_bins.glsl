/*
 * 光源リストとライトビンの、設定で変わる大きさ (light モジュール)
 * SSBO の宣言 (lib/buffers/ssbo.glsl) は全プログラムに入るので、設定の値はそこに置かず、光源を扱うプログラムだけが読むここに置く
 * 確保量は設定の最大で固定 (shaders.properties の bufferObject.2 / 3)
 */
#ifndef LIGHT_LIGHT_BINS_GLSL
#define LIGHT_LIGHT_BINS_GLSL

#include "/lib/settings.glsl"
#include "/lib/buffers/ssbo.glsl"

const int MAX_GLOBAL_LIGHTS = LIGHT_MAX_COUNT; // 1 フレームに登録できる光源インスタンス数

const int LIGHT_BIN_CAPACITY = LIGHT_BIN_LIGHTS; // ビン 1 つに入る光源数
/*
 * ビン 1 つの枠の数。LIGHT_CULL_MODE 1/2 は重要度の降順に LIGHT_BIN_CAPACITY 個を持ち、
 * 最後の 1 枠に外れた光源のうち最も重要なもののキーを持つ (境界で弱めるため, lib/light/light_select.glsl)
 */
const int LIGHT_BIN_STRIDE = LIGHT_BIN_CAPACITY + 1;
#if LIGHT_BIN_LIGHTS > 64
    const int LIGHT_BIN_STRIDE_ALLOC = 129;
#else
    const int LIGHT_BIN_STRIDE_ALLOC = 65;
#endif
const int LIGHT_BIN_KEYS_ALLOC = LIGHT_BIN_MAX * LIGHT_BIN_STRIDE_ALLOC; // binLights の確保数
#if LIGHT_CULL_MODE == 0
    const ivec3 LIGHT_BIN_GRID = ivec3(VOXEL_SIZE_X, VOXEL_SIZE_Y, VOXEL_SIZE_Z) / LIGHT_BIN_SIZE;
#else
    // ビンをワールドの 8 ブロック格子にそろえる (カメラの 1 ブロックの移動でビンの境界が動かないように)。端の分 1 つ多い
    const ivec3 LIGHT_BIN_GRID = ivec3(VOXEL_SIZE_X, VOXEL_SIZE_Y, VOXEL_SIZE_Z) / LIGHT_BIN_SIZE + 1;
#endif

#endif
