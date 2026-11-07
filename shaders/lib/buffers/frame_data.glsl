/*
 * SSBO binding 0: フレーム共有データ (永続)
 * 確保: 4096 バイト (shaders.properties の bufferObject.0)
 * レイアウトは使う全プログラムで同一でなければならない (Iris の仕様)。書き込むモジュールをフィールドごとに明記。それ以外は読むだけ
 * 既定は readonly。書くプログラム (setup・begin・prepare・prepare2・deferred_a・composite25) は include の前に SSBO_FRAME_DATA_WRITE を定義する
 */
#ifndef BUFFERS_FRAME_DATA_GLSL
#define BUFFERS_FRAME_DATA_GLSL

#ifdef SSBO_FRAME_DATA_WRITE
    #define SSBO_FRAME_DATA_ACCESS
#else
    #define SSBO_FRAME_DATA_ACCESS readonly
#endif

const int FRAME_POST_PARAMS = 4;
layout(std430, binding = 0) SSBO_FRAME_DATA_ACCESS buffer FrameDataBuffer {
    // post (composite25 で書く)
    float exposure;           // 線形の露出倍率。シーン色に掛けて使う
    float exposureTarget;     // 順応前の目標露出
    float averageLuminance;   // 計測した平均輝度 (露出前)
    float focusDistance;      // オートフォーカス距離 (ブロック, 平滑化済み)

    // sky (prepare で書く)
    vec4 sunIrradiance;          // rgb = 地表での太陽直達照度 (大気透過込み), a = 太陽高度の sin
    vec4 moonIrradiance;         // rgb = 地表での月直達照度, a = 月高度の sin
    vec4 shadowLightIrradiance;  // rgb = 影を落とす側 (昼は太陽 / 夜は月) の直達照度, a = 1 なら太陽
    vec4 skySH[9];               // rgb = 空の放射の SH L2 係数 (照度は shEvalIrradiance で)
    vec4 skyParams[8];           // sky の自由領域 ([4] [5] [7] は prepare2 が書く、カメラの位置の雲の中の霧と、その板の上面・下面までの高さ。[6] は雨の空の置き換え)

    // light (begin / deferred_a で書く)
    uvec4 lightStats;            // x = 前フレームの光源数, y = 溢れ数, z = エンティティ光源の登録締め切りフラグ (light), w = 前フレームに距離で間引いた数

    // surface の自由領域 ([0..2] は prepare が書く開けた水面の海の状態。lib/common/water_waves.glsl。[3] は prepare が書くきらめきのフレームの長さ。lib/common/water_glitter.glsl。
    // [4..5] は prepare が書く海・湖・川を混ぜた水の吸収・散乱・波頭の尖り・映り込みの散らし。lib/common/water_waves.glsl)
    vec4 surfaceParams[6];

    // post
    uint histogram[256];         // 露出ヒストグラム (composite25 内で毎フレームクリア)
    vec4 postParams[];           // post の自由領域。要素数: FRAME_POST_PARAMS
} frameData;

#endif
