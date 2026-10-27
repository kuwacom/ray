#ifndef COMMON_MATH_GLSL
#define COMMON_MATH_GLSL

#include "/lib/common/constants.glsl"

float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2 saturate(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 saturate(vec3 x) { return clamp(x, 0.0, 1.0); }
vec4 saturate(vec4 x) { return clamp(x, 0.0, 1.0); }

float sqr(float x) { return x * x; }
vec2 sqr(vec2 x) { return x * x; }
vec3 sqr(vec3 x) { return x * x; }

float pow4(float x) { x *= x; return x * x; }
float pow5(float x) { return pow4(x) * x; }

float maxOf(vec2 v) { return max(v.x, v.y); }
float maxOf(vec3 v) { return max(v.x, max(v.y, v.z)); }
float maxOf(vec4 v) { return max(max(v.x, v.y), max(v.z, v.w)); }
float minOf(vec2 v) { return min(v.x, v.y); }
float minOf(vec3 v) { return min(v.x, min(v.y, v.z)); }
float minOf(vec4 v) { return min(min(v.x, v.y), min(v.z, v.w)); }

float linearStep(float e0, float e1, float x) { return saturate((x - e0) / (e1 - e0)); }

float lengthSqr(vec3 v) { return dot(v, v); }

// 法線 n を z 軸とする正規直交基底 (Duff et al. 2017)
mat3 tbnFromNormal(vec3 n) {
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float b = n.x * n.y * a;
    vec3 t = vec3(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
    vec3 bt = vec3(b, s + n.y * n.y * a, -n.y);
    return mat3(t, bt, n);
}

// 一様な円板サンプル (Vogel spiral)。i 番目 / n 個
vec2 vogelDisk(int i, int n, float phi) {
    float r = sqrt((float(i) + 0.5) / float(n));
    float theta = float(i) * GOLDEN_ANGLE + phi;
    return r * vec2(cos(theta), sin(theta));
}

// 余弦重み半球サンプル (z が法線方向)
vec3 cosineHemisphere(vec2 xi) {
    float phi = TAU * xi.x;
    float r = sqrt(xi.y);
    return vec3(r * cos(phi), r * sin(phi), sqrt(max(1.0 - xi.y, 0.0)));
}

#endif
