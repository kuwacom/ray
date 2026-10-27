/*
 * SSBO binding 2: 今フレームの光源インスタンス (light)
 * begin.csh で count 等を 0 に戻し、deferred.csh が追加する (エンティティ光源は shadow / gbuffers_entities が蓄積表 lightBins.entityAcc に溜めたものを deferred が登録)
 * 確保: 295200 バイト (MAX_GLOBAL_LIGHTS_ALLOC 個分、shaders.properties の bufferObject.2)
 * 既定は readonly。書くプログラム (setup・begin・deferred・deferred_a) は include の前に SSBO_GLOBAL_LIGHTS_WRITE を定義する
 *
 * 設定で変わる大きさ (LIGHT_MAX_COUNT, LIGHT_BIN_LIGHTS, VOXEL_VOLUME, LIGHT_CULL_MODE) は lib/buffers に入れない
 * (lib/light/light_bins.glsl)。設定の値が前処理後の本文に残ると、その設定を変えるたびに
 * 宣言を読む全プログラムのドライバのキャッシュが外れて作り直しになる
 */
#ifndef BUFFERS_GLOBAL_LIGHTS_GLSL
#define BUFFERS_GLOBAL_LIGHTS_GLSL

#ifdef SSBO_GLOBAL_LIGHTS_WRITE
    #define SSBO_GLOBAL_LIGHTS_ACCESS
#else
    #define SSBO_GLOBAL_LIGHTS_ACCESS readonly
#endif

const int MAX_GLOBAL_LIGHTS_ALLOC = 8192;      // 確保数 (LIGHT_MAX_COUNT の最大)。ビンのキーの下位 13 bit に入る数

// 光源を間引く距離 (LIGHT_CULL_MODE 1/2) の分布の段数と 1 段の幅 (ブロック)
const int LIGHT_CULL_BUCKETS = 64;
const float LIGHT_CULL_BUCKET_WIDTH = 4.0;
const float LIGHT_CULL_NONE = 1e9;  // 間引かない時の cullDistance

struct LightInstance {
    vec4 posRadius;  // xyz = ボクセル空間の位置 (今フレーム), w = 到達半径 (ブロック)
    vec4 colorSize;  // rgb = 放射 (色 x 明るさ x レベル, BLOCKLIGHT_ILLUMINANCE 倍済み), a = 光源半径
};

layout(std430, binding = 2) SSBO_GLOBAL_LIGHTS_ACCESS buffer GlobalLightsBuffer {
    uint count;       // 登録数 (atomicAdd で確保。MAX_GLOBAL_LIGHTS を超えた分は捨てる)
    uint blockCount;  // うちブロック光源
    uint entityCount; // うちエンティティ光源 (ドロップ・投擲・燃焼・発光)
    uint overflow;    // 容量超過で捨てた数
    float cullDistance; // これより遠い光源は登録しない (LIGHT_CULL_MODE 1/2, 永続。deferred_a が前フレームの分布から更新)
    uint culled;        // cullDistance で間引いた数
    uint cullPad0;
    uint cullPad1;
    uint cullHist[LIGHT_CULL_BUCKETS]; // 登録しようとした光源の距離の分布 (deferred が足し、deferred_a が読んで 0 に戻す)
    LightInstance lights[MAX_GLOBAL_LIGHTS_ALLOC];
    float lightPower[]; // 揺らぎを掛ける前の放射の輝度 (ビンの重要度用。揺らぎで順位が入れ替わらないように)。要素数: MAX_GLOBAL_LIGHTS_ALLOC
} globalLights;

#endif
