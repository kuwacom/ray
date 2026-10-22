/*
 * G バッファのレイアウト (不透明ジオメトリ)
 * colortex1 RGBA8 : rgb = アルベド (sRGB エンコード), a = マテリアル ID (lib/ids/material_ids.glsl)
 * colortex2 RGBA16: rg = テクスチャ法線 (oct, player 空間), b = 幾何法線 (oct 8+8), a = ライトマップ (block 8 + sky 8)
 * colortex3 RGBA16: r = smoothness 8 + f0 8, g = sss 8 + emission 8, b = ao 8 + wetness 8, a = 予備
 */
#ifndef COMMON_GBUFFER_GLSL
#define COMMON_GBUFFER_GLSL

struct GBufferData {
    vec3 albedo;      // 線形
    int materialId;
    vec3 normal;      // テクスチャ法線 (player 空間, 正規化)
    vec3 geoNormal;   // 幾何法線 (player 空間, 正規化)
    vec2 lightmap;    // x = ブロックライト, y = スカイライト ([0,1], バニラ値)
    float smoothness; // labPBR の値そのまま
    float f0;         // labPBR の g チャンネルそのまま (230/255 以上は金属)
    float sss;        // 表面下散乱の強さ
    float emission;   // [0,1]
    float ao;         // バニラ AO x マテリアル AO
    float wetness;    // 雨による濡れ (水たまり)
};

GBufferData gbufferDefault() {
    GBufferData g;
    g.albedo = vec3(1.0);
    g.materialId = 0;
    g.normal = vec3(0.0, 1.0, 0.0);
    g.geoNormal = vec3(0.0, 1.0, 0.0);
    g.lightmap = vec2(0.0);
    g.smoothness = 0.0;
    g.f0 = 0.04;
    g.sss = 0.0;
    g.emission = 0.0;
    g.ao = 1.0;
    g.wetness = 0.0;
    return g;
}

void encodeGBuffer(GBufferData g, out vec4 c1, out vec4 c2, out vec4 c3) {
    c1 = vec4(linearToSrgb(g.albedo), encodeId8(g.materialId));
    vec2 n = octEncode(g.normal);
    c2 = vec4(n, pack2x8(octEncode(g.geoNormal)), pack2x8(g.lightmap));
    c3 = vec4(pack2x8(vec2(g.smoothness, g.f0)), pack2x8(vec2(g.sss, g.emission)), pack2x8(vec2(g.ao, g.wetness)), 0.0);
}

GBufferData decodeGBuffer(vec4 c1, vec4 c2, vec4 c3) {
    GBufferData g;
    g.albedo = srgbToLinear(c1.rgb);
    g.materialId = decodeId8(c1.a);
    g.normal = octDecode(c2.rg);
    g.geoNormal = octDecode(unpack2x8(c2.b));
    g.lightmap = unpack2x8(c2.a);
    vec2 r = unpack2x8(c3.r);
    vec2 s = unpack2x8(c3.g);
    vec2 t = unpack2x8(c3.b);
    g.smoothness = r.x;
    g.f0 = r.y;
    g.sss = s.x;
    g.emission = s.y;
    g.ao = t.x;
    g.wetness = t.y;
    return g;
}

// gbuffers 以外 (deferred / composite) から読む
GBufferData readGBuffer(ivec2 texel) {
    return decodeGBuffer(
        texelFetch(colortex1, texel, 0),
        texelFetch(colortex2, texel, 0),
        texelFetch(colortex3, texel, 0)
    );
}

// 法線だけ欲しい時用 (GI・デノイズ等で多用するので個別に用意)
vec3 readGBufferNormal(ivec2 texel) { return octDecode(texelFetch(colortex2, texel, 0).rg); }
int readMaterialId(ivec2 texel) { return decodeId8(texelFetch(colortex1, texel, 0).a); }

/*
 * 半透明のデータ (colortex5 RGBA16)
 * rg = 法線 (oct), b = ライトマップ (8+8), a = マテリアル ID (8) + 予備 (8)
 * 色は colortex4 (RGBA16F, 乗算済みアルファ)
 */
vec4 encodeTranslucentData(vec3 normal, vec2 lightmap, int materialId) {
    return vec4(octEncode(normal), pack2x8(lightmap), pack2x8(vec2(float(materialId) / 255.0, 0.0)));
}

void decodeTranslucentData(vec4 d, out vec3 normal, out vec2 lightmap, out int materialId) {
    normal = octDecode(d.rg);
    lightmap = unpack2x8(d.b);
    materialId = int(round(unpack2x8(d.a).x * 255.0));
}

#endif
