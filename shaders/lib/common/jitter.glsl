/*
 * TAA のサブピクセルジッター
 * gbuffers の頂点シェーダーで applyTaaJitter() を呼び、TAA (post モジュール) は同じ値で戻す
 */
#ifndef COMMON_JITTER_GLSL
#define COMMON_JITTER_GLSL

const int TAA_JITTER_PERIOD = 16;

float halton(int index, int base) {
    float f = 1.0, r = 0.0;
    int i = index;
    while (i > 0) {
        f /= float(base);
        r += f * float(i % base);
        i /= base;
    }
    return r;
}

// ピクセル単位のジッター ([-0.5, 0.5])
vec2 taaJitterPixels(int frame) {
    int i = (frame % TAA_JITTER_PERIOD) + 1;
    return vec2(halton(i, 2), halton(i, 3)) - 0.5;
}

vec2 taaJitterPixels() { return taaJitterPixels(frameCounter); }

// 画面 UV 単位のジッター (スクリーン座標の補正用)
vec2 taaJitterUv() { return taaJitterPixels() / vec2(viewWidth, viewHeight); }

void applyTaaJitter(inout vec4 clipPos) {
#ifdef TAA
    clipPos.xy += taaJitterPixels() * (2.0 / vec2(viewWidth, viewHeight)) * clipPos.w;
#endif
}

#endif
