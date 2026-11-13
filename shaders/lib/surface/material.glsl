/*
 * マテリアル (surface モジュール)
 * G バッファの labPBR 生値をシェーディング用の値に変換する
 * gbuffers 側の labPBR v1.3 デコードと、PBR テクスチャが無い時の自動推定もここに置く
 */
#ifndef SURFACE_MATERIAL_GLSL
#define SURFACE_MATERIAL_GLSL

//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/encoding.glsl"
//@include "/lib/common/gbuffer.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/material_ids.glsl"

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

const float LABPBR_BYTE_SCALE = 255.0;
const int LABPBR_METAL_FIRST = 230;  // green の 230-237 が金属 8 種、238 以上は金属のアルベドを使う
const int LABPBR_METAL_LAST = 237;
const float LABPBR_POROSITY_MAX = 64.0;  // blue は 0-64 が porosity、65 以上が SSS
const float LABPBR_SSS_MIN = 65.0;
const float LABPBR_SSS_RANGE = 190.0;
const float LABPBR_EMISSION_MAX = 254.0;  // alpha の 255 は発光の指定なし

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
    int v = int(round(f0Raw * LABPBR_BYTE_SCALE));
    if (v < LABPBR_METAL_FIRST) return METAL_NONE;
    if (v <= LABPBR_METAL_LAST) return v - (LABPBR_METAL_FIRST - 1);
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

// gbuffers 用: labPBR v1.3 のデコードと自動推定

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
    float b = spec.b * LABPBR_BYTE_SCALE;
    p.porosity = b <= LABPBR_POROSITY_MAX + 0.5 ? saturate(b / LABPBR_POROSITY_MAX) : 0.0;
    p.sss = b > LABPBR_POROSITY_MAX + 0.5 ? saturate((b - LABPBR_SSS_MIN) / LABPBR_SSS_RANGE) : 0.0;
    float e = spec.a * LABPBR_BYTE_SCALE;
    p.emission = e < LABPBR_EMISSION_MAX + 0.5 ? e / LABPBR_EMISSION_MAX : 0.0;
    p.ao = normalTex.b;
    p.height = normalTex.a;
    return p;
}

// 推定した金属の滑らかさの範囲 (テクスチャの輝度の二乗で補間)
const float METAL_SMOOTHNESS_MIN = 0.35;
const float METAL_SMOOTHNESS_MAX = 0.72;

// 画素の判定で金属にした部分 (感圧板・トラップドア・道具など) の滑らかさの範囲
// 小さな面は輝度のばらつきがそのまま粗さのまだらときらめきになるので、ブロックより狭くする
const float METAL_PART_SMOOTHNESS_MIN = 0.55;
const float METAL_PART_SMOOTHNESS_MAX = 0.65;

// 金属の質感 (鉄・銅のブロックなど)。f0 = 1.0 は labPBR の「アルベドを F0 に使う金属」
SurfaceParams metalSurfaceParams(vec3 albedoSrgb, float smoothnessMin, float smoothnessMax) {
    SurfaceParams p = surfaceParamsDefault();
    // 緑青 (酸化した銅の緑の画素) は金属ではなく粗い鉱物。酸化途中の銅は金属の地と緑青がまだらになる
    if (albedoSrgb.g > albedoSrgb.r + 0.03) {
        p.smoothness = 0.25;
        p.f0 = 0.04;
        p.porosity = 0.3;
    } else {
        // 金属ブロックはテクスチャの明るい所ほど磨かれているように見せる。暗い筋 (傷・継ぎ目) は粗くする
        // 鏡に近いと周りの景色がそのまま映ってガラスの箱のように見えるので、最も明るい所でも少しぼかす
        float lum = luminance(albedoSrgb);
        p.smoothness = smoothnessMin + (smoothnessMax - smoothnessMin) * lum * lum;
        p.f0 = 1.0;
    }
    return p;
}

SurfaceParams metalSurfaceParams(vec3 albedoSrgb) {
    return metalSurfaceParams(albedoSrgb, METAL_SMOOTHNESS_MIN, METAL_SMOOTHNESS_MAX);
}

// 宝石 (ダイヤモンドの道具・防具)。F0 0.17 は屈折率 2.42
const float GEM_SMOOTHNESS = 0.85;
const float GEM_F0 = 0.17;

SurfaceParams gemSurfaceParams() {
    SurfaceParams p = surfaceParamsDefault();
    p.smoothness = GEM_SMOOTHNESS;
    p.f0 = GEM_F0;
    return p;
}

/*
 * 一部だけ金属のブロック・アイテムで、金属の画素をテクスチャの色から選ぶ (METAL_GATE_*)
 * 木の枕木・持ち手・炎・中身の液体を金属にしないための判定で、種類ごとに金属の色が違う
 * 暗い画素の彩度は誤差で大きく振れるので、灰色は最大成分に対する彩度で見る
 */
const float METAL_GRAY_SATURATION = 0.2;
const float METAL_GRAY_COOL_SATURATION = 0.3; // 鉄の暗い面 (ミニカートの車体・メイスの頭) は彩度 0.2-0.3 の青みの暗い灰色。水や溶岩 (彩度 0.7 以上) は入らない
const float METAL_GRAY_COOL_LUMINANCE = 0.4;
const float METAL_GOLD_SATURATION = 0.4;    // 金の持ち手 (木) との境。持ち手は同じ色相で暗いので明るさでも分ける
const float METAL_GOLD_LUMINANCE = 0.45;
const float METAL_GOLD_DARK_SATURATION = 0.8; // 暗い金の面 (インゴットの影) は彩度が高い。持ち手の木は 0.72 以下
const float METAL_GOLD_DARK_LUMINANCE = 0.15;
const float METAL_COOL_LUMINANCE = 0.4;     // ランタンの枠 (青みの暗い灰色)。炎は明るいか暖色
const float METAL_COPPER_GREEN_RATIO = 0.68; // 銅の色相 (赤に対する緑の比) の上限。木の持ち手は 0.75 以上
const float METAL_COPPER_SATURATION = 0.35;

bool metalGatePixel(int gate, vec3 c) {
    float mx = maxOf(c);
    float sat = (mx - minOf(c)) / max(mx, EPS);
    float lum = luminance(c);
    bool gray = sat < METAL_GRAY_SATURATION;
    bool gold = c.r >= 0.9 * c.g && c.g > c.b && sat > METAL_GOLD_SATURATION && lum > METAL_GOLD_LUMINANCE && c.g > 0.6 * c.r;
    if (gate == METAL_GATE_GRAY) return gray || (c.b >= c.r && sat < METAL_GRAY_COOL_SATURATION && lum < METAL_GRAY_COOL_LUMINANCE);
    if (gate == METAL_GATE_COOL) return c.b >= c.r - 0.01 && lum < METAL_COOL_LUMINANCE;
    // 線路は灰色の鉄。動力レールの金の線路は金色で明るく彩度が高い。枕木の木はもっと暗いか彩度が低い
    if (gate == METAL_GATE_RAIL) return gray || (gold && sat > 0.6 && lum > 0.5);
    if (gate == METAL_GATE_GOLD) {
        return gold || (c.r >= 0.9 * c.g && c.g > c.b && c.g > 0.3 * c.r && sat > METAL_GOLD_DARK_SATURATION && lum > METAL_GOLD_DARK_LUMINANCE);
    }
    if (gate == METAL_GATE_COPPER) return c.g < METAL_COPPER_GREEN_RATIO * c.r && c.b <= c.g && sat > METAL_COPPER_SATURATION;
    if (gate == METAL_GATE_NETHERITE) return gray || c.b > c.g;
    if (gate == METAL_GATE_GEM) return c.g > c.r + 0.02 && c.b > c.r + 0.02;
    return true;
}

/*
 * 線路の金属は走行で磨かれた面。反射率は高いが、細かな削れと線路の湾曲で映り込みと太陽・月の照り返しはぼやける (完全な鏡にはしない)
 * 輝度で変えると画素ごとの粗さのまだらがきらめきになるので一定
 */
const float RAIL_SMOOTHNESS = 0.7;
// 線路のテクスチャの鉄は暗い灰色 (線形 0.33 前後) で、そのまま F0 にすると暗い鏡になる。磨いた金属の高い反射率まで上げる。明暗の模様は残る
const float RAIL_F0_GAIN = 1.8;

// 判定に合う画素を金属 (宝石は光沢のある誘電体) に置き換える。AO と高さはそのまま。PBR テクスチャが無い (推定の) 時だけ使う
SurfaceParams applyMetalGate(SurfaceParams base, int gate, vec3 albedoSrgb) {
    if (gate == 0 || !metalGatePixel(gate, albedoSrgb)) return base;
    SurfaceParams p = gate == METAL_GATE_GEM ? gemSurfaceParams()
        : gate == METAL_GATE_RAIL ? metalSurfaceParams(albedoSrgb, RAIL_SMOOTHNESS, RAIL_SMOOTHNESS)
        : metalSurfaceParams(albedoSrgb, METAL_PART_SMOOTHNESS_MIN, METAL_PART_SMOOTHNESS_MAX);
    p.ao = base.ao;
    p.height = base.height;
    return p;
}

/*
 * 金属のアルベド (線形) を F0 に使うときの持ち上げ。暗い金属 (鉄の鎖・金床・ネザライト) をそのまま F0 にすると黒い鏡になる
 * 灰色を足すので色味の差はそのまま残り (掛けると暗い紫のネザライトがピンクになる)、明るい金属ほど足す量が小さい
 * 暗い金属 (鎖・金床・鉄の道具。線形 0.03-0.1) だけ F0 を 0.5 前後まで上げ、明るい鉄・金と銅の色味はほぼ変えない (暗さの 6 乗で効かせる。銅ブロックの輝度 0.25 で 0.12)
 */
const float METAL_DARK_LIFT = 0.7;
// 金のように青の反射率がほぼ 0 の金属は、青い空を映すと緑がかったオリーブ色になる。赤緑が強く青が弱い色だけ輝度の灰色へ寄せる
const float METAL_YELLOW_DESATURATE = 0.25;
// ネザライトは暗い赤紫の金属 (緑だけが最小)。鉄と同じに持ち上げると銀色になるので、紫がかった画素は持ち上げを弱める。鉄・銅・金は緑が最小にならない
const float METAL_PURPLE_DARK_KEEP = 0.8;

vec3 metalReflectance(vec3 albedoLinear) {
    float l = luminance(albedoLinear);
    float yellow = smoothstep(0.45, 0.6, albedoLinear.g / max(albedoLinear.r, 1e-4)) * (1.0 - smoothstep(0.2, 0.4, albedoLinear.b / max(albedoLinear.g, 1e-4)));
    vec3 f0 = mix(albedoLinear, vec3(l), METAL_YELLOW_DESATURATE * yellow);
    float dark = sqr(1.0 - l);
    float rbMax = max(max(albedoLinear.r, albedoLinear.b), 1e-4);
    float purple = smoothstep(0.0, 0.06, (min(albedoLinear.r, albedoLinear.b) - albedoLinear.g) / rbMax);
    // 赤茶の画素 (緑と青が同じ) もネザライトの一部。銅も暖色だが、持ち上げは残したいので弱めに混ぜる
    float brown = smoothstep(0.1, 0.3, (albedoLinear.r - max(albedoLinear.g, albedoLinear.b)) / rbMax);
    float keep = METAL_PURPLE_DARK_KEEP * max(purple, 0.7 * brown);
    return min(f0 + METAL_DARK_LIFT * (1.0 - keep) * dark * dark * dark, vec3(1.0));
}

/*
 * PBR テクスチャが無い時 (PBR_FORMAT=0) の推定 (マテリアル ID + 色の統計)
 * ブロックごとの巨大な表は持たず、ID の大分類と輝度から決める (保守性のため)
 */
SurfaceParams estimateSurfaceParams(int materialId, vec3 albedoSrgb) {
    SurfaceParams p = surfaceParamsDefault();
    float lum = luminance(albedoSrgb);
    float chroma = maxOf(albedoSrgb) - minOf(albedoSrgb);
    if (materialId == MAT_METAL) {
        p = metalSurfaceParams(albedoSrgb);
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
