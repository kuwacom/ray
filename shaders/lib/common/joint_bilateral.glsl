/*
 * 深度・法線で縁を止める空間フィルタ (joint bilateral) の重み
 * 空間の重み (距離のガウスなど) と、許容の決め方・係数・下限は呼ぶ側のパスごとに違うので持たない
 */
#ifndef COMMON_JOINT_BILATERAL_GLSL
#define COMMON_JOINT_BILATERAL_GLSL

//@include "/lib/common/math.glsl"

// tolerance: 基準の深度に応じた許容 (大きいほど深度差を許す)
float bilateralDepthWeight(float depth, float refDepth, float tolerance) {
    return exp(-abs(depth - refDepth) / tolerance);
}

// power が大きいほど法線のずれに厳しい
float bilateralNormalWeight(vec3 normal, vec3 refNormal, float power) {
    return pow(saturate(dot(normal, refNormal)), power);
}

#endif
