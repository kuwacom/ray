/*
 * 球面調和 (L2, 9 係数) の評価 (sky モジュール)
 * FrameData.skySH には「空の放射」の SH 係数が入る。照度にするには余弦ローブとの畳み込み定数を掛ける
 * (Ramamoorthi & Hanrahan 2001)
 */
#ifndef SKY_SH_GLSL
#define SKY_SH_GLSL

#include "/lib/buffers/frame_data.glsl"

// 球面調和関数 (2 次まで) の基底の係数と、クランプ余弦の畳み込みの係数 (バンドごと)
const float SH_Y0 = 0.282095;
const float SH_Y1 = 0.488603;
const float SH_Y2_XY = 1.092548;
const float SH_Y2_ZZ = 0.315392;
const float SH_Y2_XX_YY = 0.546274;
const float SH_COS_A0 = 3.141593;
const float SH_COS_A1 = 2.094395;
const float SH_COS_A2 = 0.785398;

void shBasis(vec3 n, out float b[9]) {
    b[0] = SH_Y0;
    b[1] = SH_Y1 * n.y;
    b[2] = SH_Y1 * n.z;
    b[3] = SH_Y1 * n.x;
    b[4] = SH_Y2_XY * n.x * n.y;
    b[5] = SH_Y2_XY * n.y * n.z;
    b[6] = SH_Y2_ZZ * (3.0 * n.z * n.z - 1.0);
    b[7] = SH_Y2_XY * n.x * n.z;
    b[8] = SH_Y2_XX_YY * (n.x * n.x - n.y * n.y);
}

// 法線 n の面が受ける照度 (半球積分済み)
vec3 shEvalIrradiance(vec3 n) {
    float b[9];
    shBasis(n, b);
    vec3 e = frameData.skySH[0].rgb * b[0] * SH_COS_A0;
    for (int i = 1; i < 4; i++) e += frameData.skySH[i].rgb * b[i] * SH_COS_A1;
    for (int i = 4; i < 9; i++) e += frameData.skySH[i].rgb * b[i] * SH_COS_A2;
    return max(e, 0.0);
}

#endif
