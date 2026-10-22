/*
 * マテリアル (surface モジュール)
 * G バッファの labPBR 生値をシェーディング用の値に変換する
 * gbuffers 側の labPBR v1.3 デコードと、PBR テクスチャが無い時の自動推定もここに置く
 */
#ifndef SURFACE_MATERIAL_GLSL
#define SURFACE_MATERIAL_GLSL

struct Material {
    vec3 albedo;      // 拡散反射色 (金属は 0 に近づける)
    vec3 f0;          // 垂直入射の反射率 (プリセット金属はアルベドの色付け込み)
    float roughness;  // 知覚的ラフネスの二乗 (GGX の alpha)
    float metalness;  // [0,1]
    float sss;        // 表面下散乱 [0,1]
    float emission;   // 発光 [0,1]
    float ao;
    float perceptualRoughness; // 1 - smoothness (環境 BRDF の近似式はこちらで引く)
    int metalId;      // 0 = 誘電体, 1-8 = labPBR プリセット金属 (n/k で導体フレネル), 9 = アルベドを F0 に使う金属
    vec3 specTint;    // プリセット金属の反射に掛けるアルベド (labPBR 仕様: 230-254 はアルベドで反射を色付けする)
};

// GGX の alpha の下限。0 だと D 項が発散して TAA でも消えないホタルになる
const float MIN_ROUGHNESS = 0.002;
// 誘電体の F0 の下限 (水 0.02 より小さい実物質はほぼ無いので、0 指定のテクスチャもここに寄せる)
const float MIN_DIELECTRIC_F0 = 0.02;

const int METAL_NONE = 0;
const int METAL_ALBEDO = 9;

// labPBR v1.3 のプリセット金属 (green 230-237) の複素屈折率 n + ik (R, G, B)
const vec3 LABPBR_METAL_N[8] = vec3[8](
    vec3(2.9114, 2.9497, 2.5845),   // 鉄
    vec3(0.18299, 0.42108, 1.3734), // 金
    vec3(1.3456, 0.96521, 0.61722), // アルミニウム
    vec3(3.1071, 3.1812, 2.3230),   // クロム
    vec3(0.27105, 0.67693, 1.3164), // 銅
    vec3(1.9100, 1.8300, 1.4400),   // 鉛
    vec3(2.3757, 2.0847, 1.8453),   // 白金
    vec3(0.15943, 0.14512, 0.13547) // 銀
);
const vec3 LABPBR_METAL_K[8] = vec3[8](
    vec3(3.0893, 2.9318, 2.7670),
    vec3(3.4242, 2.3459, 1.7704),
    vec3(7.4746, 6.3995, 5.3031),
    vec3(3.3314, 3.3291, 3.1350),
    vec3(3.6092, 2.6248, 2.2921),
    vec3(3.5100, 3.4000, 3.1800),
    vec3(4.2655, 3.7153, 3.1365),
    vec3(3.9291, 3.1900, 2.3808)
);

// 導体の垂直入射反射率 ((n-1)^2 + k^2) / ((n+1)^2 + k^2)
vec3 conductorF0(vec3 n, vec3 k) {
    vec3 k2 = k * k;
    return (sqr(n - 1.0) + k2) / (sqr(n + 1.0) + k2);
}

// labPBR の green 値 (生値 [0,1]) -> 金属 ID
int labPbrMetalId(float f0Raw) {
    int v = int(round(f0Raw * 255.0));
    if (v < 230) return METAL_NONE;
    if (v <= 237) return v - 229;
    return METAL_ALBEDO;
}

Material decodeMaterial(GBufferData g) {
    Material m;
    m.perceptualRoughness = 1.0 - g.smoothness;
    m.roughness = max(m.perceptualRoughness * m.perceptualRoughness, MIN_ROUGHNESS);
    m.metalId = labPbrMetalId(g.f0);
    m.metalness = m.metalId != METAL_NONE ? 1.0 : 0.0;
    m.specTint = vec3(1.0);
    if (m.metalId == METAL_NONE) {
        m.f0 = vec3(max(g.f0, MIN_DIELECTRIC_F0));
    } else if (m.metalId == METAL_ALBEDO) {
        m.f0 = g.albedo;
    } else {
        int i = m.metalId - 1;
        m.specTint = g.albedo;
        m.f0 = conductorF0(LABPBR_METAL_N[i], LABPBR_METAL_K[i]) * g.albedo;
    }
    m.albedo = g.albedo * (1.0 - m.metalness);
    m.sss = g.sss;
    m.emission = g.emission;
    m.ao = g.ao;
    return m;
}

/*
 * colortex3.a (G バッファの予備, surface モジュールが使う): x = POM の自己影 (1 = 遮蔽なし), y = 水たまりの量
 * encodeGBuffer は a に 0 を書くので、gbuffers ではその後でこの値に置き換える
 */
float encodeSurfaceExtra(float parallaxShadow, float puddle) {
    // 0 はクリア値 (空) と区別が付かないので自己影は 1 - 値で持つ
    return pack2x8(vec2(1.0 - parallaxShadow, puddle));
}

void readSurfaceExtra(ivec2 texel, out float parallaxShadow, out float puddle) {
    vec2 v = unpack2x8(texelFetch(colortex3, texel, 0).a);
    parallaxShadow = 1.0 - v.x;
    puddle = v.y;
}

/*------------------------------------------------------------------------------
  gbuffers 用: labPBR v1.3 のデコードと自動推定
------------------------------------------------------------------------------*/

struct SurfaceParams {
    float smoothness; // labPBR R
    float f0;         // labPBR G の生値 (230 以上は金属)
    float sss;        // [0,1]
    float porosity;   // [0,1]
    float emission;   // [0,1]
    float ao;         // マテリアル AO
    float height;     // 高さ [0,1] (1 = 表面)
};

SurfaceParams surfaceParamsDefault() {
    SurfaceParams p;
    p.smoothness = 0.0;
    p.f0 = 0.04;
    p.sss = 0.0;
    p.porosity = 0.0;
    p.emission = 0.0;
    p.ao = 1.0;
    p.height = 1.0;
    return p;
}

/*
 * labPBR v1.3 の _s (specular) と _n (normal) のアルファ以外を読む
 * _s.b は 0-64 が porosity, 65-255 が SSS。_s.a は 0-254 が発光 (255 は「指定なし」)
 */
SurfaceParams decodeLabPbr(vec4 spec, vec4 normalTex) {
    SurfaceParams p;
    p.smoothness = spec.r;
    p.f0 = spec.g;
    float b = spec.b * 255.0;
    p.porosity = b <= 64.5 ? saturate(b / 64.0) : 0.0;
    p.sss = b > 64.5 ? saturate((b - 65.0) / 190.0) : 0.0;
    float e = spec.a * 255.0;
    p.emission = e < 254.5 ? e / 254.0 : 0.0;
    p.ao = normalTex.b;
    p.height = normalTex.a;
    return p;
}

// 推定した金属の滑らかさの範囲 (テクスチャの輝度の二乗で補間)
const float METAL_SMOOTHNESS_MIN = 0.35;
const float METAL_SMOOTHNESS_MAX = 0.72;

/*
 * PBR テクスチャが無い時 (PBR_FORMAT=0) の推定 (マテリアル ID + 色の統計)
 * ブロックごとの巨大な表は持たず、ID の大分類と輝度から決める (保守性のため)
 */
SurfaceParams estimateSurfaceParams(int materialId, vec3 albedoSrgb) {
    SurfaceParams p = surfaceParamsDefault();
    float lum = luminance(albedoSrgb);
    float chroma = maxOf(albedoSrgb) - minOf(albedoSrgb);
    if (materialId == MAT_METAL) {
        // 緑青 (酸化した銅の緑の画素) は金属ではなく粗い鉱物。酸化途中の銅は金属の地と緑青がまだらになる
        if (albedoSrgb.g > albedoSrgb.r + 0.03) {
            p.smoothness = 0.25;
            p.f0 = 0.04;
            p.porosity = 0.3;
        } else {
            // 金属ブロックはテクスチャの明るい所ほど磨かれているように見せる。暗い筋 (傷・継ぎ目) は粗くする
            // 鏡に近いと周りの景色がそのまま映ってガラスの箱のように見えるので、最も明るい所でも少しぼかす
            p.smoothness = METAL_SMOOTHNESS_MIN + (METAL_SMOOTHNESS_MAX - METAL_SMOOTHNESS_MIN) * lum * lum;
            p.f0 = 1.0;
        }
    } else if (materialId == MAT_GLOSSY) {
        p.smoothness = 0.72 + 0.15 * lum;
        p.f0 = 0.045;
    } else if (materialId == MAT_SNOW) {
        p.smoothness = 0.35;
        p.f0 = 0.02;
        p.sss = 0.55;
    } else if (materialId == MAT_LEAVES) {
        p.smoothness = 0.38;
        p.f0 = 0.03;
        p.sss = 0.8;
        p.porosity = 0.2;
    } else if (materialId == MAT_PLANT || materialId == MAT_UNDERWATER_PLANT) {
        p.smoothness = 0.28;
        p.f0 = 0.03;
        p.sss = 0.65;
        p.porosity = 0.2;
    } else if (materialId == MAT_LAVA) {
        p.smoothness = 0.35;
    } else if (materialId == MAT_PLAYER) {
        p.smoothness = 0.3;
        p.f0 = 0.028;
        p.sss = 0.3;
    } else if (isEntityMaterial(materialId) || isHandMaterial(materialId)) {
        p.smoothness = 0.3;
    } else if (materialId == MAT_TERRAIN || materialId == MAT_EMISSIVE_BLOCK) {
        // 彩度が低く明るい面 (石・石英・コンクリート) ほどやや滑らか。土や砂のような暗い高彩度面は粗い
        p.smoothness = mix(0.08, 0.32, saturate(lum * lum * 1.6 - chroma));
        p.porosity = mix(0.6, 0.15, lum);
    }
    return p;
}

#endif
