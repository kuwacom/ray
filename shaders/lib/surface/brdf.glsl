/*
 * BRDF (surface モジュール)
 * 光源側 (A/B) が返す LightSample にこの関数で反射を掛ける
 *
 * 構成
 *   鏡面: GGX + Smith 高さ相関 (Heitz 2014) + フレネル (誘電体 Schlick / labPBR プリセット金属は導体の厳密式)
 *         マルチスキャッタのエネルギー補償 (Kulla-Conty の考え方を Karis の解析近似 DFG で LUT なしに)
 *   拡散: EON (Portsmouth, Kutz, Hill 2025, エネルギー保存の Oren-Nayar)。鏡面の方向アルベド分を差し引いて層を保存
 *   透過: 葉・草などの薄い散乱体 (St-Amour 2010 系の裏面透過 + 前方散乱の位相)
 */
#ifndef SURFACE_BRDF_GLSL
#define SURFACE_BRDF_GLSL

// EON の粗さ。labPBR の粗さをそのまま渡すとバニラの粗い面が平板に見えるので弱める
const float EON_ROUGHNESS_SCALE = 0.6;
const float EON_C1 = 0.5 - 2.0 / (3.0 * PI);
const float EON_C2 = 2.0 / 3.0 - 28.0 / (15.0 * PI);

float ggxD(float NoH, float a) {
    float a2 = a * a;
    float d = (NoH * a2 - NoH) * NoH + 1.0;
    return a2 / (PI * d * d);
}

// 高さ相関 Smith G2 を 4 NoL NoV で割った可視項
float smithVisibilityHC(float NoV, float NoL, float a) {
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-6);
}

vec3 fresnelSchlick(vec3 f0, float cosTheta) {
    return f0 + (1.0 - f0) * pow5(1.0 - saturate(cosTheta));
}

/*
 * 誘電体の厳密フレネル (非偏光)。eta = 透過側 / 入射側 の屈折率比。全反射なら 1
 */
float fresnelDielectric(float cosI, float eta) {
    cosI = saturate(cosI);
    float g2 = eta * eta - 1.0 + cosI * cosI;
    if (g2 < 0.0) return 1.0;
    float g = sqrt(g2);
    float a = (g - cosI) / (g + cosI);
    float b = (cosI * (g + cosI) - 1.0) / (cosI * (g - cosI) + 1.0);
    return 0.5 * a * a * (1.0 + b * b);
}

// 導体の厳密フレネル (非偏光, n + ik)
vec3 fresnelConductor(float cosTheta, vec3 n, vec3 k) {
    float c2 = sqr(saturate(cosTheta));
    float s2 = 1.0 - c2;
    vec3 n2 = n * n;
    vec3 k2 = k * k;
    vec3 t0 = n2 - k2 - s2;
    vec3 a2b2 = sqrt(t0 * t0 + 4.0 * n2 * k2);
    vec3 t1 = a2b2 + c2;
    vec3 a = sqrt(max(0.5 * (a2b2 + t0), 0.0));
    vec3 t2 = 2.0 * a * sqrt(c2);
    vec3 rs = (t1 - t2) / (t1 + t2);
    vec3 t3 = c2 * a2b2 + s2 * s2;
    vec3 t4 = t2 * s2;
    vec3 rp = rs * (t3 - t4) / (t3 + t4);
    return 0.5 * (rp + rs);
}

vec3 materialFresnel(Material m, float cosTheta) {
    if (m.metalId >= 1 && m.metalId <= 8) {
        int i = m.metalId - 1;
        return fresnelConductor(cosTheta, LABPBR_METAL_N[i], LABPBR_METAL_K[i]) * m.specTint;
    }
    return fresnelSchlick(m.f0, cosTheta);
}

/*
 * GGX の方向アルベドの解析近似 (Karis 2014 "Physically Based Shading on Mobile")
 * 戻り値 (A, B): 鏡面の方向アルベド = F0 * A + B。LUT を置く image の空きが無いのでこれで代用する
 */
vec2 envBrdfApprox(float NoV, float perceptualRoughness) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = perceptualRoughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return vec2(-1.04, 1.04) * a004 + r.zw;
}

// 鏡面の方向アルベド (単散乱)
vec3 specularAlbedo(Material m, float NoV) {
    vec2 ab = envBrdfApprox(NoV, m.perceptualRoughness);
    return m.f0 * ab.x + ab.y;
}

/*
 * マルチスキャッタのエネルギー補償倍率 (Fdez-Aguera 2019 / Filament と同形: 1 + F0 (1/E - 1))
 * 粗い金属が暗く沈むのを戻す
 */
vec3 specularEnergyCompensation(Material m, float NoV) {
    vec2 ab = envBrdfApprox(NoV, m.perceptualRoughness);
    return 1.0 + m.f0 * (1.0 / max(ab.x + ab.y, 1e-3) - 1.0);
}

/*
 * 環境光の鏡面に掛ける重み (方向アルベド x 補償)。反射バッファ・空のフォールバックに使う
 */
vec3 envSpecularWeight(Material m, float NoV) {
    return specularAlbedo(m, NoV) * specularEnergyCompensation(m, NoV);
}

// EON の方向アルベドの多項式近似 (論文付属の近似式)
float eonAlbedoApprox(float mu, float r) {
    float mc = 1.0 - mu;
    float gOverPi = mc * (0.0571085289 + mc * (0.491881867 + mc * (-0.332181442 + mc * 0.0714429953)));
    return (1.0 + r * gOverPi) / (1.0 + EON_C1 * r);
}

vec3 eonDiffuse(vec3 rho, float r, float NoL, float NoV, float LoV) {
    float s = LoV - NoL * NoV;
    float sOverT = s > 0.0 ? s / max(NoL, NoV) : s;
    float af = 1.0 / (1.0 + EON_C1 * r);
    vec3 fss = rho * RCP_PI * af * (1.0 + r * sOverT);
    float efo = eonAlbedoApprox(NoV, r);
    float efi = eonAlbedoApprox(NoL, r);
    float avgEf = af * (1.0 + EON_C2 * r);
    vec3 rhoMs = rho * rho * avgEf / (1.0 - rho * (1.0 - avgEf));
    vec3 fms = rhoMs * RCP_PI * max(1e-7, 1.0 - efo) * max(1e-7, 1.0 - efi) / max(1e-7, 1.0 - avgEf);
    return fss + fms;
}

float eonRoughness(Material m) { return saturate(m.roughness * EON_ROUGHNESS_SCALE); }

// 鏡面 BRDF x NoL (光源の見かけの大きさでラフネスを広げる)
vec3 evalSpecularLobe(Material m, vec3 N, vec3 V, vec3 L, float angularSize, float NoL, float NoV) {
    vec3 H = normalize(L + V);
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));
    // 球光源の正規化 (Karis 2013) の簡略形。光源の大きさ分だけローブを広げて点光源の発散を防ぐ
    float a = min(m.roughness + 0.5 * angularSize, 1.0);
    vec3 F = materialFresnel(m, VoH);
    return ggxD(NoH, a) * smithVisibilityHC(NoV, NoL, a) * F * specularEnergyCompensation(m, NoV);
}

/*
 * 直接光 1 つの出射放射輝度 (拡散 + 鏡面)。N, V は player 空間の正規化ベクトル (V は着色点 -> カメラ)
 * 裏から来る光は evalTranslucency が受け持つ
 */
vec3 evalDirectLight(Material m, vec3 N, vec3 V, LightSample L) {
    float NoL = dot(N, L.direction);
    if (NoL <= 0.0 || maxOf(L.irradiance) <= 0.0) return vec3(0.0);
    float NoV = max(dot(N, V), 1e-3);
    vec3 diffuse = eonDiffuse(m.albedo, eonRoughness(m), NoL, NoV, dot(L.direction, V)) * (1.0 - specularAlbedo(m, NoV));
    vec3 spec = evalSpecularLobe(m, N, V, L.direction, L.angularSize, NoL, NoV);
    return (diffuse + spec) * L.irradiance * NoL;
}

// 拡散だけ (前方シェーディングの半透明: 鏡面は composite1 でまとめて掛けるため)
vec3 evalDirectDiffuse(Material m, vec3 N, vec3 V, LightSample L) {
    float NoL = dot(N, L.direction);
    if (NoL <= 0.0) return vec3(0.0);
    float NoV = max(dot(N, V), 1e-3);
    return eonDiffuse(m.albedo, eonRoughness(m), NoL, NoV, dot(L.direction, V)) * L.irradiance * NoL;
}

// 鏡面だけ (水面の太陽ハイライト等)
vec3 evalDirectSpecular(Material m, vec3 N, vec3 V, LightSample L) {
    float NoL = dot(N, L.direction);
    if (NoL <= 0.0) return vec3(0.0);
    float NoV = max(dot(N, V), 1e-3);
    return evalSpecularLobe(m, N, V, L.direction, L.angularSize, NoL, NoV) * L.irradiance * NoL;
}

// 拡散照度 (方向を持たない光: 空・GI・floodfill) の出射放射輝度
vec3 evalDiffuseIrradiance(Material m, vec3 irradiance) {
    return m.albedo * RCP_PI * irradiance;
}

// Henyey-Greenstein 位相関数 (立体角で正規化)
float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1e-4), 1.5));
}

// 透過光の前方散乱の強さ (g を大きくすると逆光で葉が強く光る)
const float TRANSLUCENCY_PHASE_G = 0.4;

/*
 * 葉・草・雪などの透過光。L.irradiance は「裏側まで届いた光」(太陽なら厚みで減衰済み) を渡す
 * 表から強く当たる光は拡散が受け持つので、裏から来る成分だけを足す
 */
vec3 evalTranslucency(Material m, vec3 N, vec3 V, LightSample L) {
    if (m.sss <= 0.0) return vec3(0.0);
    float NoL = dot(N, L.direction);
    float back = saturate((0.3 - NoL) / 1.3);
    float phase = mix(1.0, henyeyGreenstein(dot(V, -L.direction), TRANSLUCENCY_PHASE_G) * 4.0 * PI, 0.5);
    return m.albedo * m.sss * RCP_PI * L.irradiance * back * phase;
}

/*
 * GGX の可視法線サンプリング (Heitz 2018 を Dupuy & Benyoub 2023 の球冠法で)
 * Ve: 接空間 (z = 法線) の視線, a: alpha, u: [0,1)^2。戻り値は接空間のマイクロ法線
 */
vec3 sampleGgxVndf(vec3 Ve, float a, vec2 u) {
    vec3 vh = normalize(vec3(a * Ve.x, a * Ve.y, Ve.z));
    float phi = TAU * u.x;
    float z = (1.0 - u.y) * (1.0 + vh.z) - vh.z;
    float sinTheta = sqrt(saturate(1.0 - z * z));
    vec3 nh = vec3(sinTheta * cos(phi), sinTheta * sin(phi), z) + vh;
    return normalize(vec3(a * nh.x, a * nh.y, max(nh.z, 0.0)));
}

/*
 * 鏡面の遮蔽 (Lagarde & de Rousiers 2014)。AO と視線角とラフネスから
 * 凹みや影の中で環境反射が光る漏れを抑える
 */
float specularOcclusion(float NoV, float ao, float roughness) {
    return saturate(pow(NoV + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao);
}

/*
 * テクスチャ法線を視線側へ倒して NoV >= minNoV (正規化前) を保つ
 * 自動生成法線はかすめ角でテクセルごとに視線の裏を向き、NoV が 0 に張り付いてフレネルと鏡面がテクセル単位で跳ねる。
 * 反射側で裏向きの法線を反転すると反射が面の中へ向かい、自分の面を映す
 */
vec3 frontFacingNormal(vec3 n, vec3 v, float minNoV) {
    float nv = dot(n, v);
    if (nv >= minNoV) return n;
    return normalize(n + v * (minNoV - nv));
}

/*
 * AO の多重バウンス近似 (Jimenez et al. 2016)。明るい面ほど AO が浅くなる
 */
vec3 aoMultiBounce(float v, vec3 albedo) {
    vec3 a = 2.0404 * albedo - 0.3324;
    vec3 b = -4.7951 * albedo + 0.6417;
    vec3 c = 2.7552 * albedo + 0.6903;
    return max(vec3(v), ((v * a + b) * v + c) * v);
}

#endif
