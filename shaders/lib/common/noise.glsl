#ifndef COMMON_NOISE_GLSL
#define COMMON_NOISE_GLSL

// PCG ハッシュ (Jarzynski & Olano 2020, "Hash Functions for GPU Rendering")
uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

uvec3 pcg3d(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

float hash1(uint v) { return float(pcgHash(v)) / 4294967295.0; }
vec3 hash3(uvec3 v) { return vec3(pcg3d(v)) / 4294967295.0; }
vec3 hash3(ivec2 p, int frame) { return hash3(uvec3(uvec2(p), uint(frame))); }

// Interleaved Gradient Noise (Jimenez 2014)。frame で時間方向にずらす
float interleavedGradientNoise(vec2 pixel, int frame) {
    pixel += 5.588238 * float(frame & 63);
    return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

// R2 低食い違い列 (Roberts 2018)
vec2 r2Sequence(int n) {
    const vec2 alpha = vec2(0.754877666246693, 0.569840290998053);
    return fract(0.5 + alpha * float(n));
}

float r1Sequence(int n) {
    return fract(0.5 + 0.618033988749895 * float(n));
}

/*
 * ブルーノイズ。テクスチャは 128x128 の 4ch 独立ブルーノイズ
 * 時間方向は R2 列でテクスチャ座標をずらす (STBN の簡易代替)
 */
const int BLUE_NOISE_SIZE = 128;

vec4 blueNoise(ivec2 pixel, int frame) {
    ivec2 offset = ivec2(r2Sequence(frame & 255) * float(BLUE_NOISE_SIZE));
    return texelFetch(blueNoiseTex, (pixel + offset) & (BLUE_NOISE_SIZE - 1), 0);
}

vec4 blueNoise(ivec2 pixel) {
    return blueNoise(pixel, frameCounter);
}

// 値ノイズ (雲・水などの汎用。品質が要る用途は各モジュールで専用ノイズを持つ)
float valueNoise3d(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    uvec3 ui = uvec3(ivec3(i) + 32768);
    float n000 = hash3(ui).x;
    float n100 = hash3(ui + uvec3(1, 0, 0)).x;
    float n010 = hash3(ui + uvec3(0, 1, 0)).x;
    float n110 = hash3(ui + uvec3(1, 1, 0)).x;
    float n001 = hash3(ui + uvec3(0, 0, 1)).x;
    float n101 = hash3(ui + uvec3(1, 0, 1)).x;
    float n011 = hash3(ui + uvec3(0, 1, 1)).x;
    float n111 = hash3(ui + uvec3(1, 1, 1)).x;
    return mix(
        mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
        mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
        f.z
    );
}

#endif
