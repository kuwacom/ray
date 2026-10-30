/*
 * SSBO binding 1: ブロックデータ表 (setup.csh が起動時に 1 回だけ書く。以降は読み取り専用)
 * 確保: 65536 バイト (使用 61456、shaders.properties の bufferObject.1)
 * 既定は readonly。書くプログラム (setup) は include の前に SSBO_BLOCK_DATA_WRITE を定義する
 */
#ifndef BUFFERS_BLOCK_DATA_GLSL
#define BUFFERS_BLOCK_DATA_GLSL

#ifdef SSBO_BLOCK_DATA_WRITE
    #define SSBO_BLOCK_DATA_ACCESS
#else
    #define SSBO_BLOCK_DATA_ACCESS readonly
#endif

const int LIGHT_TABLE_SIZE = 256;   // 光源定義の数 (光源インデックス 0-255, 0 は「光らない」)
const int SHAPE_TABLE_SIZE = 128;   // 遮蔽形状の数 (ブロック ID 300-399 -> 形状 0-99)
const int TINT_TABLE_SIZE = 128;    // 透過色の数 (ブロック ID 200-299 -> 色 0-99)
const int ALBEDO_TABLE_SIZE = 4096; // ブロックの平均の色の数 (ボクセルの 12bit ID をそのまま引く)
const int LIGHT_MASK_LIGHTS = 128;  // 面の光り方を持てる光源の数 (ブロック光源の帯 0-127)
const int LIGHT_MASK_FACE_CLASSES = 4; // 面の種類: 0 = 上、1 = 下、2 = 側面 (4 面の平均)、3 = 前面 (向きのある光源だけ)
const int LIGHT_MASK_TABLE_SIZE = LIGHT_MASK_LIGHTS * LIGHT_MASK_FACE_CLASSES;

struct LightDef {
    vec4 color;   // rgb = 線形色 (最大成分 1), a = 明るさ倍率
    vec4 shape;   // xyz = ブロック内の発光中心 [0,1], w = 光源半径 (ブロック, 半影用)
    vec4 params;  // x = 光源レベル 15 時の到達半径 (ブロック), y = フリッカー量 [0,1], z = 既定の光源レベル (0-15), w = 予備
    uvec4 info;   // x = フラグ (LIGHT_FLAG_*), y = 遮蔽形状 ID (SHAPE_*), zw = 予備
};

layout(std430, binding = 1) SSBO_BLOCK_DATA_ACCESS buffer BlockDataBuffer {
    LightDef lightDefs[LIGHT_TABLE_SIZE];
    uvec4 shapes[SHAPE_TABLE_SIZE]; // AABB 2 個: x/y = box0 min/max, z/w = box1 min/max (packUnorm4x8, min>max で無効)
    vec4 tints[TINT_TABLE_SIZE];    // rgb = 透過色 (線形), a = 不透明度
    uint initialized;
    /*
     * ボクセル ID ごとの平均の色 (sRGB 8bit を R | G << 8 | B << 16, lib/ids/block_albedo.glsl)
     * 生成した定数配列を floodfill の全セルから直接引くと EXTREME で 37 -> 22 FPS に落ちた (この SSBO に移して 41 FPS)。
     * 動的な添字の定数配列がスレッドごとのローカルメモリに展開されたとみられる
     */
    uint albedo[ALBEDO_TABLE_SIZE];
    // 上向きの面の色 (同じ詰め方)。上面の色が違うブロック (草ブロック・原木など) 以外は albedo と同じ
    uint albedoUp[ALBEDO_TABLE_SIZE];
    /*
     * 光るブロックの面の光り方 (添字 = 光源インデックス x 4 + 面の種類。lib/light/light_mask_data.glsl)
     * x = 光る範囲の四角 packUnorm4x8(vec4(u0, v0, u1, v1)) (テクスチャの座標、v は上が 0)
     * y = packHalf2x16(vec2(割合, マスの最大の重み))。割合 = 面の光の量 / (四角の面積 x 光源の最も明るい面の中の平均)
     * z, w = 光る範囲の四角を 4x4 に分けたマス (4 bit ずつ、重み = 値 / 15 x マスの最大の重み)。z が行 0-1、w が行 2-3 で、
     *   行 r 列 c は bit 4 x (c + 4 x (r & 1))。r は v の向き、c は u の向き
     * 光らない面は全部 0。データの無い光源は LIGHT_FLAG_EMISSION_MASK が立たない
     * albedoUp の後ろに置くのは、手前のメンバーのオフセットを変えないため
     */
    uvec4 lightMasks[]; // 要素数: LIGHT_MASK_TABLE_SIZE
} blockData;

#endif
