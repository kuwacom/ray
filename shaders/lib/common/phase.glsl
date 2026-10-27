#ifndef COMMON_PHASE_GLSL
#define COMMON_PHASE_GLSL

#include "/lib/common/constants.glsl"

// 位相関数 (立体角で正規化した公知の式)
float phaseRayleigh(float cosTheta) {
    return 3.0 / (16.0 * PI) * (1.0 + cosTheta * cosTheta);
}

float phaseHG(float cosTheta, float g) {
    float gg = g * g;
    float denom = 1.0 + gg - 2.0 * g * cosTheta;
    return (1.0 - gg) / (4.0 * PI * denom * sqrt(denom));
}

// HG より後方が膨らみ、ミー散乱の実測に近い
float phaseCS(float cosTheta, float g) {
    float gg = g * g;
    float denom = 1.0 + gg - 2.0 * g * cosTheta;
    return 3.0 / (8.0 * PI) * (1.0 - gg) * (1.0 + cosTheta * cosTheta) / ((2.0 + gg) * denom * sqrt(denom));
}

const float PHASE_ISOTROPIC = 1.0 / (4.0 * PI);

// HG に (1 + alpha cos^2) を掛けて正規化したもの
float phaseDraine(float cosTheta, float g, float alpha) {
    float g2 = g * g;
    float hg = (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1e-6), 1.5);
    return PHASE_ISOTROPIC * hg * (1.0 + alpha * cosTheta * cosTheta) / (1.0 + alpha * (1.0 + 2.0 * g2) / 3.0);
}

#endif
