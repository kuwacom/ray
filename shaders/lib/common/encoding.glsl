#ifndef COMMON_ENCODING_GLSL
#define COMMON_ENCODING_GLSL

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

// 16bit unorm チャンネル 1 つに 8bit 値 2 つを詰める (a,b は [0,1])
float pack2x8(vec2 v) {
    uvec2 u = uvec2(round(saturate(v) * 255.0));
    return float(u.x | (u.y << 8u)) / 65535.0;
}

vec2 unpack2x8(float p) {
    uint u = uint(round(p * 65535.0));
    return vec2(u & 255u, u >> 8u) / 255.0;
}

// 8bit unorm チャンネルに 0-255 の整数 ID を格納
float encodeId8(int id) { return float(clamp(id, 0, 255)) / 255.0; }
int decodeId8(float v) { return int(round(v * 255.0)); }

#endif
