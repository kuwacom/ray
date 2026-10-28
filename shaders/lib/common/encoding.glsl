#ifndef COMMON_ENCODING_GLSL
#define COMMON_ENCODING_GLSL

#include "/lib/common/math.glsl"

// 八面体法線エンコード (Cigolle et al. 2014)。戻り値は [0,1]^2
vec2 octEncode(vec3 n) {
    n /= abs(n.x) + abs(n.y) + abs(n.z);
    vec2 e = n.z >= 0.0 ? n.xy : (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 octDecode(vec2 e) {
    e = e * 2.0 - 1.0;
    vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
    float t = max(-n.z, 0.0);
    n.x += n.x >= 0.0 ? -t : t;
    n.y += n.y >= 0.0 ? -t : t;
    return normalize(n);
}

const float UNORM8_MAX = 255.0;
const float UNORM16_MAX = 65535.0;

// 16bit unorm チャンネル 1 つに 8bit 値 2 つを詰める (a,b は [0,1])
float pack2x8(vec2 v) {
    uvec2 u = uvec2(round(saturate(v) * UNORM8_MAX));
    return float(u.x | (u.y << 8u)) / UNORM16_MAX;
}

vec2 unpack2x8(float p) {
    uint u = uint(round(p * UNORM16_MAX));
    return vec2(u & 255u, u >> 8u) / UNORM8_MAX;
}

// 8bit unorm チャンネルに 0-255 の整数 ID を格納
float encodeId8(int id) { return float(clamp(id, 0, 255)) / UNORM8_MAX; }
int decodeId8(float v) { return int(round(v * UNORM8_MAX)); }

#endif
