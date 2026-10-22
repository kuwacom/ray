/*
 * 太陽影マップの空間と歪み
 * shadow パス (書き込み) と参照側 (sky / surface モジュール) で必ず同じ関数を使うこと
 */
#ifndef COMMON_SHADOW_SPACE_GLSL
#define COMMON_SHADOW_SPACE_GLSL

// 中心付近ほど解像度を割く歪み。1 に近いほど中心に集中する
const float SHADOW_DISTORT_FACTOR = 0.85;
// 深度方向を圧縮して遠方のジオメトリが far で切れないようにする
const float SHADOW_DEPTH_SCALE = 0.2;

float shadowDistortScale(vec2 clipXY) {
    return length(clipXY) * SHADOW_DISTORT_FACTOR + (1.0 - SHADOW_DISTORT_FACTOR);
}

vec3 distortShadowClip(vec3 clipPos) {
    return vec3(clipPos.xy / shadowDistortScale(clipPos.xy), clipPos.z * SHADOW_DEPTH_SCALE);
}

vec3 playerToShadowView(vec3 playerPos) {
    return (shadowModelView * vec4(playerPos, 1.0)).xyz;
}

// 歪み前の影クリップ座標 (正射影なので w 除算不要)
vec3 playerToShadowClip(vec3 playerPos) {
    return (shadowProjection * vec4(playerToShadowView(playerPos), 1.0)).xyz;
}

// 影マップ参照用の [0,1] 座標 (歪み込み)
vec3 playerToShadowScreen(vec3 playerPos) {
    return distortShadowClip(playerToShadowClip(playerPos)) * 0.5 + 0.5;
}

// 影マップ 1 テクセルがワールドで何ブロックに相当するか (バイアス計算用)
float shadowTexelWorldSize(vec2 clipXY) {
    float s = shadowDistortScale(clipXY);
    // 歪み q = p / s(p) の径方向微分は (1-F)/s^2 なので、その逆数倍に引き伸ばされる
    return 2.0 * shadowDistance / float(shadowMapResolution) * s * s / (1.0 - SHADOW_DISTORT_FACTOR);
}

#endif
