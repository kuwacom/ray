/*
 * SSBO binding 3: ワールド空間のライトビン (light, deferred_a.csh が書く) とエンティティ光源の蓄積表
 * ビン = LIGHT_BIN_SIZE^3 ブロック。index = x + y*GRID.x + z*GRID.x*GRID.y
 * 確保: LIGHT_BIN_LIGHTS <= 64 で 10944512 バイト, それより上で 21430272 バイト (shaders.properties の bufferObject.3)
 * 既定は readonly。書くプログラム (setup・begin・deferred_a、蓄積表に足す shadow_entities / shadow_block) は
 * include の前に SSBO_LIGHT_BINS_WRITE を定義する。gbuffers_entities / gbuffers_entities_translucent はここで定義する
 * 設定で変わる大きさ (LIGHT_BIN_CAPACITY, LIGHT_BIN_GRID, LIGHT_BIN_KEYS_ALLOC) は lib/light/light_bins.glsl
 */
#ifndef BUFFERS_LIGHT_BINS_GLSL
#define BUFFERS_LIGHT_BINS_GLSL

// 同じプログラムの頂点とフラグメントで readonly が食い違うと AMD はリンクで落とす (NVIDIA は通す) ので、
// 頂点側が書くプログラムはフラグメント側も同じ宣言にする。段ごとに定義せずここで 1 か所にそろえる
#if (defined GBUF_ENTITIES || defined GBUF_ENTITIES_TRANSLUCENT) && !defined SSBO_LIGHT_BINS_WRITE
    #define SSBO_LIGHT_BINS_WRITE
#endif

#ifdef SSBO_LIGHT_BINS_WRITE
    #define SSBO_LIGHT_BINS_ACCESS
#else
    #define SSBO_LIGHT_BINS_ACCESS readonly
#endif

const int LIGHT_BIN_SIZE = 8;       // ライトビン 1 辺のブロック数
const int LIGHT_BINS_ALLOC = 40960;    // 最大体積 (384x128x384) のワールド格子のビン数 49x17x49 を 256 の倍数に。確保量はこれで固定

// エンティティ光源の蓄積表 (lib/light/entity_light.glsl)
const int ENTITY_ACC_SIZE = 4096;      // エントリ数 (2 のべき乗)
const int ENTITY_ACC_STRIDE = 8;       // 1 エントリの uint 数: key, count, sumX, sumY, sumZ, 予備 x3
const int ENTITY_ACC_UINTS = ENTITY_ACC_SIZE * ENTITY_ACC_STRIDE;

layout(std430, binding = 3) SSBO_LIGHT_BINS_ACCESS buffer LightBinsBuffer {
    uint binCount[LIGHT_BINS_ALLOC]; // 登録しようとした数 (容量超過を含む)
    // エンティティ光源の蓄積表。begin でクリア -> shadow / gbuffers で蓄積 -> deferred で読む
    uint entityAcc[ENTITY_ACC_UINTS];
    // ビンの中身 (キー, lib/light/light_select.glsl)。下位 13 bit が globalLights.lights のインデックス
    uint binLights[]; // 要素数: LIGHT_BIN_KEYS_ALLOC
} lightBins;

#endif
