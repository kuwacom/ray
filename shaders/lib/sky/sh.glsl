/*
 * 球面調和 (L2, 9 係数) の評価 (sky モジュール)
 * FrameData.skySH には「空の放射」の SH 係数が入る。照度にするには余弦ローブとの畳み込み定数を掛ける
 * (Ramamoorthi & Hanrahan 2001)
 */
#ifndef SKY_SH_GLSL
#define SKY_SH_GLSL

void shBasis(vec3 n, out float b[9]) {
    b[0] = 0.282095;
    b[1] = 0.488603 * n.y;
    b[2] = 0.488603 * n.z;
    b[3] = 0.488603 * n.x;
    b[4] = 1.092548 * n.x * n.y;
    b[5] = 1.092548 * n.y * n.z;
    b[6] = 0.315392 * (3.0 * n.z * n.z - 1.0);
    b[7] = 1.092548 * n.x * n.z;
    b[8] = 0.546274 * (n.x * n.x - n.y * n.y);
}

// 法線 n の面が受ける照度 (半球積分済み)
vec3 shEvalIrradiance(vec3 n) {
    float b[9];
    shBasis(n, b);
    const float A0 = 3.141593, A1 = 2.094395, A2 = 0.785398;
    vec3 e = frameData.skySH[0].rgb * b[0] * A0;
    for (int i = 1; i < 4; i++) e += frameData.skySH[i].rgb * b[i] * A1;
    for (int i = 4; i < 9; i++) e += frameData.skySH[i].rgb * b[i] * A2;
    return max(e, 0.0);
}

#endif
