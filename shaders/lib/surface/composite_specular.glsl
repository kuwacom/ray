/*
 * 半透明の合成 (composite1) の鏡面: 反射の引き直し・不透明面の環境光の鏡面・太陽の可視率・誘電体の鏡面・手持ち光源の照度
 * surface モジュール
 */
#ifndef SURFACE_COMPOSITE_SPECULAR_GLSL
#define SURFACE_COMPOSITE_SPECULAR_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/reflection.glsl"
#include "/lib/surface/surface_lights.glsl"

// 全画面クアッド (program/common/fullscreen.vsh) の UV。composite1 のような全画面の fragment パスだけが include する
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
    specular = L.sunVis;
    return L.sunVisAll;
}

// 影を掛ける前の太陽 (方向・角半径・照度)。水の側面の近似と水中は可視率を呼ぶ側が決める
LightSample unshadowedSun() {
    return gatherSurfaceLights(surfacePoint(vec3(0.0), vec3(0.0, 1.0, 0.0)), SL_SUN_NONE, SL_BLOCK_NONE, SL_CELESTIAL).celestial;
}

// 光 L の鏡面だけ。f0 と alpha を与えた誘電体として
vec3 dielectricSpecular(vec3 N, vec3 V, float f0, float roughness, LightSample L) {
    GBufferData g = gbufferDefault();
    g.f0 = f0;
    g.smoothness = 1.0 - sqrt(roughness);
    g.albedo = vec3(0.0);
    return evalDirectSpecular(decodeMaterial(g), N, V, L);
}

vec3 sunSpecular(vec3 N, vec3 V, float f0, float roughness, vec3 sunVis) {
    LightSample sun = unshadowedSun();
    sun.irradiance *= sunVis;
    return dielectricSpecular(N, V, f0, roughness, sun);
}

// 手持ち光源とブロックライトの鏡面 (太陽以外の光)。L は gatherSurfaceLights の SL_HAND | SL_BLOCK_SPECULAR_TRACED
vec3 localLightSpecular(SurfaceLights L, vec3 N, vec3 V, float f0, float roughness) {
    vec3 s = dielectricSpecular(N, V, f0, roughness, L.handMain) + dielectricSpecular(N, V, f0, roughness, L.handOff);
    for (int j = 0; j < L.blockSpecCount; j++) s += dielectricSpecular(N, V, f0, roughness, L.blockSpec[j]);
    return s;
}

// 手持ち光源が向き n の面に与える照度
vec3 handIrradiance(SurfaceLights L, vec3 n) {
    return L.handMain.irradiance * saturate(dot(n, L.handMain.direction)) + L.handOff.irradiance * saturate(dot(n, L.handOff.direction));
}

#endif
