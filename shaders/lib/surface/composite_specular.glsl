/*
 * 半透明の合成 (composite2) の鏡面: 反射の引き直し・不透明面の環境光の鏡面・太陽の可視率・誘電体の鏡面・手持ち光源の照度
 * surface モジュール
 */
#ifndef SURFACE_COMPOSITE_SPECULAR_GLSL
#define SURFACE_COMPOSITE_SPECULAR_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/gbuffer.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/surface/brdf.glsl"
//@include "/lib/surface/gi.glsl"
//@include "/lib/surface/lighting.glsl"
//@include "/lib/surface/material.glsl"
//@include "/lib/surface/reflection.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/sky_color.glsl"
//@include "/lib/surface/surface_lights.glsl"

// 全画面クアッド (program/common/fullscreen.vsh) の UV。composite1 / composite2 のような全画面の fragment パスだけが include する
in vec2 texcoord;

vec3 reflectionAt(ivec2 texel, float dist, vec3 R, float skyLm, float roughness, vec3 normal) {
    vec3 fallback = skyReflectionFallback(R, skyLm, roughness);
#if REFLECTIONS > 0
    vec4 r = sampleReflection(texel, dist, normal);
    return mix(fallback, r.rgb, saturate(r.a * 4.0));
#else
    return fallback;
#endif
}

/*
 * 鏡面 (水・水たまり・ガラス) の物の映り込みはフル解像度で辿り直す。氷は粗さが MIRROR_ROUGHNESS 以上なので対象外。composite.csh の半分の解像度の結果を
 * 2x2 で引き伸ばすと、映り込みの輪郭がぼけて角張り、鏡のはずの面がつやの無い面に見えた
 * 外れた画素 (空・画面外・ボクセルの当たり) は半分の解像度の結果 refl のまま
 */
vec3 mirrorReflection(vec3 refl, vec3 viewPos, vec3 playerPos, vec3 Ng, vec3 R, float dist, bool opaque, bool waterTop, float dither) {
#if REFLECTIONS > 0
    vec4 hit = traceReflectionHit(viewPos, playerPos, Ng, R, dist, mirrorTraceDistance(), opaque, waterTop, dither);
    if (hit.w > 0.5) refl = mix(refl, reflectionHitRadiance(hit.xy), hit.z);
#endif
    return refl;
}

// 不透明面の環境光の鏡面
vec3 opaqueEnvSpecular(ivec2 texel, float depth) {
    GBufferData g = readGBuffer(texel);
    Material m = decodeMaterial(g);
    bool hand = isHandDepth(depth);
    vec3 playerPos = screenToPlayer(vec3(texcoord, fixHandDepth(depth)));
    float dist = length(playerPos);
    vec3 V = -playerPos / max(dist, 1e-4);
    float NoV = max(dot(g.normal, V), 1e-3);
    vec3 R = reflect(-V, g.normal);
    vec3 refl = hand ? skyReflectionFallback(R, g.lightmap.y, m.perceptualRoughness)
        : reflectionAt(texel, dist, R, g.lightmap.y, m.perceptualRoughness, g.normal);
    if (!hand && m.perceptualRoughness < MIRROR_ROUGHNESS) {
        // composite.csh と同じ反射方向 (視線側へ倒した法線で反射し、幾何面より上へ折り返す)
        vec3 Ng = dot(g.geoNormal, V) < 0.0 ? -g.geoNormal : g.geoNormal;
        vec3 Rm = reflect(-V, frontFacingNormal(g.normal, V, REFLECT_MIN_NOV));
        float e = dot(Rm, Ng);
        Rm = normalize(Rm + Ng * (max(abs(e), REFLECT_MIN_ELEVATION) - e));
        refl = mirrorReflection(refl, playerToView(playerPos), playerPos, Ng, Rm, dist, true, false,
            interleavedGradientNoise(gl_FragCoord.xy, frameCounter));
    }
    // 照度を集めるのではなく、環境光の鏡面の遮蔽に AO だけ読む
    float ao = g.ao * getIndirectLight(texel).a;
    return refl * envSpecularWeight(m, NoV) * specularOcclusion(NoV, ao, m.roughness);
}

// 面での太陽の可視率 (影 + 雲影)。PCSS は重いので 1 ピクセル 1 回にして鏡面・内散乱・泡で使い回す
// 集める項は太陽の影だけ (空・ブロックライト・手持ち光源は泡・内散乱・鏡面が別に集める。GI・AO・接触影は水・ガラスに掛けない)
// specular: 太陽の照り返しに使う分 (葉を透過した拡散光を除く。葉越しの太陽が緑の光源として映らないように)
vec3 surfaceSunVisibility(vec3 playerPos, vec3 geoNormal, float dither, out vec3 specular) {
    SurfacePoint p = surfacePoint(playerPos, geoNormal);
    p.dither = dither;
    SurfaceLights L = gatherSurfaceLights(p, SL_SUN_SHADOW_MAP, SL_BLOCK_NONE, SL_SUN_LEAF);
    specular = L.sunVis * getCloudSunDiscVisibility();
    return L.sunVisAll;
}

// 影を掛ける前の太陽 (方向・角半径・照度)。水の側面の近似と水中は可視率を呼ぶ側が決める
LightSample unshadowedSun() {
    return gatherSurfaceLights(surfacePoint(vec3(0.0), vec3(0.0, 1.0, 0.0)), SL_SUN_NONE, SL_BLOCK_NONE, SL_CELESTIAL).celestial;
}

// 光 L の鏡面だけ。f0 と alpha を与えた誘電体として。gaussian: 傾きの分布をガウス (Beckmann) にする (水)
vec3 dielectricSpecular(vec3 N, vec3 V, float f0, float roughness, LightSample L, float discScale, float gain, bool gaussian) {
    GBufferData g = gbufferDefault();
    g.f0 = f0;
    g.smoothness = 1.0 - sqrt(roughness);
    g.albedo = vec3(0.0);
    return evalDirectSpecular(decodeMaterial(g), N, V, L, discScale, gain, gaussian);
}

/*
 * gain: 画素より細かい波が光源を映す点の倍率 (WATER_GLITTER)。1 でローブのまま
 * 夜の月は空に描く円盤を暗くしてあり、滑らかな照り返しはその円盤の鏡像で頭打ちにする。点は実物の月の像なので、点に集めた分
 * (gain 倍) だけ上限を実物の円盤まで上げる (上げないと点のエネルギーが頭打ちで消え、月の道が点の無い時より暗くなる)
 * 強さを掛けた後も実物の円盤を超えないよう、上限を強さで割る (太陽。夜の月は強さに従って上限も上がる。celestialDiscScale を参照)
 * 円盤の上限を超える点は、像が画素より大きい (近い・曲率の小さい点) という意味なので、上限も gain 倍 (SPECULAR_POINT_SPREAD_MAX
 * まで) 上げてエネルギーを捨てない。広がりは白飛び分の点像の芯 (final) が受け持つ (明るい点ほど大きな光の塊になる)
 * 上限で切ると 2-5 m の点のエネルギーが 3 割消えていた
 */
const float SPECULAR_POINT_SPREAD_MAX = 16.0;
// シーンのバッファ (RGBA16F、最大 65504) に入る明るさの上限。超えると無限大になり、TAA が 0 に置き換えて点が消える
const float SPECULAR_HDR_MAX = 32768.0;

vec3 sunSpecular(vec3 N, vec3 V, float f0, float roughness, vec3 sunVis, float gain, bool gaussian) {
    LightSample sun = unshadowedSun();
    sun.irradiance *= sunVis;
    float strength = celestialSpecularStrength();
    float spread = clamp(gain, 1.0, SPECULAR_POINT_SPREAD_MAX);
    float discScale = min(celestialDiscScale() * max(gain, 1.0), spread / max(strength, 1.0));
    return min(dielectricSpecular(N, V, f0, roughness, sun, discScale, gain, gaussian) * strength, vec3(SPECULAR_HDR_MAX));
}

vec3 sunSpecular(vec3 N, vec3 V, float f0, float roughness, vec3 sunVis) {
    return sunSpecular(N, V, f0, roughness, sunVis, 1.0, false);
}

// 手持ち光源とブロックライトの鏡面 (太陽以外の光)。L は gatherSurfaceLights の SL_HAND | SL_BLOCK_SPECULAR_TRACED
vec3 localLightSpecular(SurfaceLights L, vec3 N, vec3 V, float f0, float roughness, bool gaussian) {
    vec3 s = dielectricSpecular(N, V, f0, roughness, L.handMain, 1.0, 1.0, gaussian) + dielectricSpecular(N, V, f0, roughness, L.handOff, 1.0, 1.0, gaussian);
    for (int j = 0; j < L.blockSpecCount; j++) s += dielectricSpecular(N, V, f0, roughness, L.blockSpec[j], 1.0, 1.0, gaussian);
    return s * SPECULAR_BLOCK_STRENGTH;
}

// 手持ち光源が向き n の面に与える照度
vec3 handIrradiance(SurfaceLights L, vec3 n) {
    return L.handMain.irradiance * saturate(dot(n, L.handMain.direction)) + L.handOff.irradiance * saturate(dot(n, L.handOff.direction));
}

/*
 * 屈折の先の画素の白飛び分の輝度 (deferred30 が a = 1 + 割合で書く)。半透明の画素は a を書き直すので、
 * 奥の金属・水たまりの照り返しを透過の分だけ引き継がないと、ガラス越し・水越しでは TAA で潰れる
 */
float behindSparkle(vec4 s) { return saturate(s.a - 1.0) * luminance(max(s.rgb, 0.0)); }

#endif
