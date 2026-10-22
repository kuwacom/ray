/*
 * モジュール間で受け渡す光の型
 * 光源を計算する側 (A: ブロック/手持ち光, B: 太陽/空) はこの型で返し、BRDF を掛けるのは C
 */
#ifndef COMMON_SHADING_TYPES_GLSL
#define COMMON_SHADING_TYPES_GLSL

struct LightSample {
    vec3 direction;     // 着色点から光源への単位ベクトル (player 空間)
    vec3 irradiance;    // 光源方向に垂直な面での照度 (減衰・遮蔽込み)。NdotL と BRDF は受け取り側が掛ける
    float angularSize;  // 光源の見かけの半径 (ラジアン)。鏡面ハイライトを広げるのに使う
};

LightSample noLight() {
    LightSample s;
    s.direction = vec3(0.0, 1.0, 0.0);
    s.irradiance = vec3(0.0);
    s.angularSize = 0.0;
    return s;
}

#endif
