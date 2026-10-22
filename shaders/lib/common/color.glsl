#ifndef COMMON_COLOR_GLSL
#define COMMON_COLOR_GLSL

// シーンの作業色空間は線形 Rec.709 (sRGB 原色)

vec3 srgbToLinear(vec3 c) {
    vec3 lo = c / 12.92;
    vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(hi, lo, lessThanEqual(c, vec3(0.04045)));
}

vec3 linearToSrgb(vec3 c) {
    c = max(c, 0.0);
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, lessThanEqual(c, vec3(0.0031308)));
}

float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 rgbToYCoCg(vec3 c) {
    return vec3(
        0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
        0.5 * c.r - 0.5 * c.b,
        -0.25 * c.r + 0.5 * c.g - 0.25 * c.b
    );
}

vec3 yCoCgToRgb(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// 黒体放射の近似色 (線形 RGB, 最大成分 1 に正規化)。1000K-40000K
// Tanner Helland の近似式を線形化したもの (公知の近似)
vec3 blackbody(float kelvin) {
    float t = clamp(kelvin, 1000.0, 40000.0) / 100.0;
    vec3 c;
    c.r = t <= 66.0 ? 1.0 : saturate(1.29293618606 * pow(t - 60.0, -0.1332047592));
    c.g = t <= 66.0 ? saturate(0.390081578769 * log(t) - 0.631841443788) : saturate(1.12989086089 * pow(t - 60.0, -0.0755148492));
    c.b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : saturate(0.543206789110 * log(t - 10.0) - 1.19625408914));
    c = srgbToLinear(c);
    return c / max(maxOf(c), EPS);
}

#endif
