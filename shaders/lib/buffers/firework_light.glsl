/*
 * SSBO binding 5: 花火の一時的な光 (light, lib/light/firework_light.glsl)
 * 光るパーティクル (gbuffers_particles_translucent の頂点) が位置と色を acc に足し、次のフレームの begin が
 * 平均の位置と色から点光源 1 つにまとめて posRadius / intensity に置き、acc を空にする。deferred30・composite2・composite19 が読む
 * 確保: 64 バイト (shaders.properties の bufferObject.5)
 * 既定は readonly。書くプログラム (begin・gbuffers_particles_translucent) は include の前に SSBO_FIREWORK_LIGHT_WRITE を定義する
 */
#ifndef BUFFERS_FIREWORK_LIGHT_GLSL
#define BUFFERS_FIREWORK_LIGHT_GLSL

#ifdef SSBO_FIREWORK_LIGHT_WRITE
    #define SSBO_FIREWORK_LIGHT_ACCESS
#else
    #define SSBO_FIREWORK_LIGHT_ACCESS readonly
#endif

// 蓄積の固定小数点の和: 粒の数, 重みの和, 位置 x 重み (xyz), 線形の色 x 重み (rgb)
const int FIREWORK_ACC_COUNT = 8;

layout(std430, binding = 5) SSBO_FIREWORK_LIGHT_ACCESS buffer FireworkLightBuffer {
    vec4 posRadius;  // xyz = player 空間の位置 (今フレーム), w = 光の広がりの半径 (0 = 光っていない)
    vec4 intensity;  // rgb = 放射強度 (照度 = rgb x NdotL / (距離^2 + 半径^2)), a = 予備
    int acc[];       // 要素数: FIREWORK_ACC_COUNT
} fireworkLight;

#endif
