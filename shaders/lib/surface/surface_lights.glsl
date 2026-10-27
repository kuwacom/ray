/*
 * 表面の光の集め方 (surface モジュール)
 * 太陽の影・空・ブロックライト・手持ち光源・GI を、取り方 (モード) と足す項 (terms) を指定して 1 か所で集める
 * 返すのは照度と LightSample だけで、BRDF・AO・溶岩・水たまり・SSS の厚みの減衰は呼ぶ側で掛ける
 * モードと項はリテラルで渡すので、インライン展開の後に使わない分岐は消える
 * 呼ぶ側は使う組み合わせを const で書き、省いた項とその理由をコメントに残す
 */
#ifndef SURFACE_SURFACE_LIGHTS_GLSL
#define SURFACE_SURFACE_LIGHTS_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/surface/sun_shadow.glsl"

// 太陽の影の取り方 (どれか 1 つ)
const int SL_SUN_NONE = 0;
const int SL_SUN_SHADOW_MAP = 1;          // PCSS。影マップの外は 1
const int SL_SUN_SHADOW_MAP_FALLBACK = 2; // PCSS。影マップの外と一人称の手はスカイライトで近似
const int SL_SUN_VOLUME = 3;              // ボクセル体積の 1 タップ (2 次ヒット)。sun.irradiance は NoL 込み

// ブロックライトの集め方 (どれか 1 つ)
const int SL_BLOCK_NONE = 0;
const int SL_BLOCK_OPAQUE = 1;            // colortex6 の直接光 + floodfill x FLOODFILL_STRENGTH + 壁の照り返し
const int SL_BLOCK_FORWARD = 2;           // floodfill だけ
const int SL_BLOCK_FORWARD_ENTITY = 3;    // ビンの光源を直接トレース
const int SL_BLOCK_HIT_FLOOD = 4;         // 2 次ヒットの floodfill だけ
const int SL_BLOCK_HIT = 5;               // 2 次ヒットの floodfill (block) + 直接光と手持ち光源 (blockDirect)

// 足す項 (組み合わせ)
const uint SL_SUN_CONTACT = 1u << 0;
const uint SL_SUN_LEAF = 1u << 1;         // 葉を透過した分を sunLeafVis に分ける (無ければ sun に含める)
const uint SL_POM = 1u << 2;
const uint SL_SKY = 1u << 3;
const uint SL_GI = 1u << 4;               // colortex8 を読み、GI が運ぶ空・地面の分を sky から引く
const uint SL_HAND = 1u << 5;             // 手持ち光源の LightSample (トレース付き)
const uint SL_HAND_FILL = 1u << 6;
const uint SL_BLOCK_SPECULAR = 1u << 7;

// 影マップの外での日向の判定 (スカイライトがこれ以上なら日向とみなす)
const vec2 SHADOW_FALLBACK_SKYLIGHT = vec2(0.8, 0.97);
// GI が空の光を運ぶ時 (GI_TRACES_SKY): ボクセル体積の判定で面から浮かせる量
const float GI_VOLUME_TEST_OFFSET = 0.1;

/*
 * 二次ヒット点の設置光源・手持ち光の直接光の照度 (GI・反射の照り返し用)。光源シャドウ ON の時だけ
 * ヒット点の照明が floodfill だけだと、floodfill は光源から 2-3 ブロックで急に落ちるので、たいまつ 1 本の洞窟で
 * 照らされた壁からの照り返しがほとんど無く、光源の見えない側 (壁・天井・三人称の自分の背中) が真っ黒だった
 * - 画面に映っているヒット点 (screenTexel.x >= 0): deferred2 のデノイズ済みの直接光 (colortex6, 影込み) をそのまま使う
 * - 画面外: ビンで一番強い光源を 1 本だけボクセルでトレースし、その可視率をビンの全光源の影なし照度に掛ける
 *   (光源ごとに追うと GI のレイ数 x 光源数のトレースになる。壁越しの光源を影なしで足すと光が漏れる)
 * 手持ち光は影を追わず、幾何法線で光源の裏を向く面だけ除く (光源は自分の手元なので、遮られるのは大抵自分の体)
 * 1 回の照り返しだけでは洞窟の壁の反射率 (0.2 前後) で光の当たる面の数 % にしかならず、影の側はまだ真っ黒だった。
 * 閉じた洞窟・部屋の多重反射 (反射率 rho で 1 / (1 - rho) 倍) と、ヒット点の floodfill (近距離しか届かない) の不足を
 * まとめて SECONDARY_BLOCKLIGHT_GAIN (lib/surface/lighting.glsl) で補う
 *
 * handScale: 手持ち光の分に掛ける倍率。GI では handLightIndirectScale() (HAND_LIGHT_SHADOW_STRENGTH) を渡す
 * GI_MODE 2/3 では手持ち光の陰の中の明るさの半分ほどがこの GI の照り返しで、残りが getHandLightFill なので、両方に同じ倍率を掛ける
 * 反射に映る面は照り返しではなく直接見える面なので 1 を渡す
 */
vec3 hitBlockDirect(vec3 playerPos, vec3 normal, ivec2 screenTexel, float handScale) {
#ifdef LIGHT_SHADOWS
    vec3 E = vec3(0.0);
    if (screenTexel.x >= 0) {
        E = texelFetch(colortex6, screenTexel, 0).rgb;
    } else {
        vec3 fromVoxel = playerToVoxel(playerPos + normal * TRACE_NORMAL_OFFSET);
        if (isInVoxelVolume(fromVoxel)) {
            int bin = lightBinIndex(ivec3(fromVoxel));
            uint n = lightBinCount(bin);
            int strongest = -1;
            float strongestW = 0.0;
            for (uint k = 0u; k < n; k++) {
                int ci = lightBinEntry(bin, k);
                vec3 e = evalLightIrradiance(globalLights.lights[ci], fromVoxel, normal, normal);
                E += e;
                float w = luminance(e);
                if (w > strongestW) { strongestW = w; strongest = ci; }
            }
            if (strongest >= 0) {
                uint flags = blockLightTraceFlags() & ~(TRACE_ENTITIES | TRACE_PLAYER);
                E *= luminance(traceVisibilityEx(fromVoxel, globalLights.lights[strongest].posRadius.xyz, flags, 0.5, 0.0, 0.0));
            }
        }
    }
    #ifdef HAND_LIGHT
    for (int i = 0; i < 2; i++) {
        bool mainHand = i == 0;
        int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
        if (level <= 0) continue;
        LightDef d = getHandLightDef(mainHand ? heldItemId : heldItemId2);
        vec3 toLight = getHandLightPositionSafe(mainHand) - playerPos;
        float dist = length(toLight);
        float range = lightRange(d, float(level));
        if (dist >= range) continue;
        float ndl = sphereLightNdotL(normal, toLight / max(dist, EPS), dist, d.shape.w);
        E += lightEmission(d, float(level)) * lightFalloff(dist, range) * (ndl * HAND_LIGHT_BRIGHTNESS * handScale);
    }
    #endif
    return E;
#else
    return vec3(0.0);
#endif
}

struct SurfacePoint {
    vec3 playerPos;
    vec3 viewPos;     // SL_SUN_CONTACT だけが使う
    vec3 normal;      // テクスチャ法線
    vec3 geoNormal;
    vec2 lightmap;
    ivec2 texel;      // 画面のテクセル。2 次ヒットでは画面に映ったヒット点のテクセル、映らなければ -1
    float dither;
    float pomShadow;  // SL_POM の時の太陽の可視率の倍率
    float sss;        // 太陽の影のブロッカー探索の SSS の強さ
    float handScale;  // SL_BLOCK_HIT の手持ち光源の倍率 (GI は handLightIndirectScale、反射は 1)
    bool hand;        // 一人称の手
};

// 使う項だけ呼ぶ側が上書きする。ほかは項を使わない時の値
SurfacePoint surfacePoint(vec3 playerPos, vec3 normal) {
    SurfacePoint p;
    p.playerPos = playerPos;
    p.viewPos = vec3(0.0);
    p.normal = normal;
    p.geoNormal = normal;
    p.lightmap = vec2(0.0);
    p.texel = ivec2(-1);
    p.dither = 0.0;
    p.pomShadow = 1.0;
    p.sss = 0.0;
    p.handScale = 1.0;
    p.hand = false;
    return p;
}

struct SurfaceLights {
    LightSample celestial;  // 影を掛ける前の太陽 / 月
    LightSample sun;        // 影・雲影・POM・接触影込み。SL_SUN_LEAF の時は葉を透過した分を除く (鏡面に使える)
    vec3 sunVis;            // sun に掛けた可視率 (雲影込み)
    vec3 sunVisAll;         // 葉を透過した分も含む可視率 (雲影込み)
    vec3 sunLeafVis;        // 葉を透過した分の可視率 (雲影の前。拡散だけに使う。SL_SUN_SHADOW_MAP_FALLBACK のみ)
    SunShadow sunShadow;    // SSS の厚みと fade (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    float sunFallback;      // 影マップの外の日向の推定 (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    float cloudShadow;      // 雲影 (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    LightSample handMain;
    LightSample handOff;
    vec3 sky;               // 空の SH x スカイライト。GI が運ぶ分を引いた後、AO の前
    vec3 block;             // ブロックライトの拡散照度 (AO の前)
    vec3 blockDirect;       // SL_BLOCK_HIT の直接光と手持ち光源
    vec3 handFill;          // 手持ち光源の照り返し (AO の前)
    vec4 indirect;          // colortex8 (rgb = GI, a = GTAO)
    bool giSky;             // GI が空の光を運んでいる
    int blockSpecCount;
    LightSample blockSpec[BLOCKLIGHT_SPECULAR_LIGHTS];
};

SurfaceLights gatherSurfaceLights(SurfacePoint p, int sunMode, int blockMode, uint terms) {
    SurfaceLights L;
    L.celestial = getCelestialLight();
    L.sun = noLight();
    L.sunVis = vec3(0.0);
    L.sunVisAll = vec3(0.0);
    L.sunLeafVis = vec3(0.0);
    L.sunShadow.visibility = vec3(1.0);
    L.sunShadow.leaf = vec3(0.0);
    L.sunShadow.thickness = 0.0;
    L.sunShadow.fade = 0.0;
    L.sunFallback = 0.0;
    L.cloudShadow = 1.0;
    L.sky = vec3(0.0);
    L.block = vec3(0.0);
    L.blockDirect = vec3(0.0);
    L.handFill = vec3(0.0);
    L.indirect = vec4(0.0, 0.0, 0.0, 1.0);
    L.giSky = false;
    L.blockSpecCount = 0;

    if ((terms & SL_GI) != 0u) L.indirect = getIndirectLight(p.texel);

    if (sunMode == SL_SUN_SHADOW_MAP) {
        if ((terms & SL_SUN_LEAF) != 0u) {
            float cloud = getCloudShadow(p.playerPos);
            vec3 specular;
            L.sunVisAll = getSunShadow(p.playerPos, p.geoNormal, p.dither, specular) * cloud;
            L.sunVis = specular * cloud;
        } else {
            L.sunVis = getSunShadow(p.playerPos, p.geoNormal, p.dither) * getCloudShadow(p.playerPos);
            L.sunVisAll = L.sunVis;
        }
        L.sun = L.celestial;
        L.sun.irradiance *= L.sunVis;
    } else if (sunMode == SL_SUN_SHADOW_MAP_FALLBACK) {
        SunShadow ss = evalSunShadow(p.playerPos, p.geoNormal, p.sss, p.dither);
        L.sunShadow = ss;
        float fallback = smoothstep(SHADOW_FALLBACK_SKYLIGHT.x, SHADOW_FALLBACK_SKYLIGHT.y, p.lightmap.y);
        L.sunFallback = fallback;
        vec3 vis = mix(vec3(fallback), ss.visibility, ss.fade);
        vec3 leaf = ss.leaf * ss.fade;
        if ((terms & SL_POM) != 0u) {
            vis *= p.pomShadow;
            leaf = ss.leaf * (ss.fade * p.pomShadow);
        }
        // 一人称の手は影マップ上で自分の体の影の中にあるので、スカイライトから日向を推定する
        if (p.hand) {
            vis = vec3(fallback);
            leaf = vec3(0.0);
        }
#ifdef SCREEN_SPACE_SHADOWS
        if ((terms & SL_SUN_CONTACT) != 0u && !p.hand && maxOf(vis) > 0.0) {
            float contact = sunContactShadow(p.viewPos, playerToViewDir(p.geoNormal), playerToViewDir(L.celestial.direction), p.dither);
            vis *= contact;
            leaf *= contact;
        }
#endif
        L.cloudShadow = getCloudShadow(p.playerPos);
        L.sunVisAll = vis * L.cloudShadow;
        if ((terms & SL_SUN_LEAF) != 0u) {
            L.sunVis = max(vis - leaf, 0.0) * L.cloudShadow;
            L.sunLeafVis = leaf;
        } else {
            L.sunVis = L.sunVisAll;
        }
        L.sun = L.celestial;
        L.sun.irradiance *= L.sunVis;
    } else if (sunMode == SL_SUN_VOLUME) {
        float NoL = saturate(dot(p.normal, L.celestial.direction));
        vec3 E = vec3(0.0);
        if (NoL > 0.0) {
            E += L.celestial.irradiance * NoL * sampleShadowVolume(p.playerPos + p.normal * 0.08) * getCloudShadow(p.playerPos);
        }
        L.sun = L.celestial;
        L.sun.irradiance = E;
    }

    if ((terms & SL_HAND) != 0u) {
        getHandLights(p.playerPos, p.geoNormal, p.dither, L.handMain, L.handOff);
    } else {
        L.handMain = noLight();
        L.handOff = noLight();
    }
    if ((terms & SL_BLOCK_SPECULAR) != 0u) L.blockSpecCount = getBlockLightSpecular(p.texel, p.playerPos, p.geoNormal, L.blockSpec);

    if (blockMode == SL_BLOCK_OPAQUE) {
        L.block = getBlockLightOpaque(p.texel, p.playerPos, p.geoNormal, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_FORWARD) {
        L.block = getBlockLightForward(p.playerPos, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_FORWARD_ENTITY) {
        L.block = getBlockLightForwardEntity(p.playerPos, p.geoNormal, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_HIT_FLOOD || blockMode == SL_BLOCK_HIT) {
        L.block = sampleFloodfill(p.playerPos, p.normal);
        if (blockMode == SL_BLOCK_HIT) L.blockDirect = hitBlockDirect(p.playerPos, p.normal, p.texel, p.handScale);
    }

    if ((terms & SL_SKY) != 0u) {
        vec3 skyE = getSkyIrradiance(p.normal);
        // GI が運ぶ空・地面の分を引く (二重に数えない)。一人称の手には GI が無いので引かない
        if ((terms & SL_GI) != 0u) {
#if GI_MODE == 2 || GI_MODE == 3
    #ifdef GI_TRACES_SKY
            // GI のレイが空の光を向きと遮蔽込みで運ぶので、空の環境光は置き換えない分 (GI_SKY_OCCLUSION, GI_GROUND_REPLACE) だけ残す
            // (lib/surface/gi.glsl)。ボクセル体積の外は GI が 0 なので空の環境光をそのまま使う
        #if GI_MODE == 3
            L.giSky = !p.hand && isInVoxelVolume(playerToVoxel(p.playerPos + p.geoNormal * GI_VOLUME_TEST_OFFSET));
        #else
            L.giSky = !p.hand;
        #endif
            if (L.giSky) {
                vec3 groundE = getSkyGroundIrradiance(p.normal);
                skyE = max(skyE - groundE, 0.0) * (1.0 - LOOK_GI_SKY_OCCLUSION) + groundE * (1.0 - GI_GROUND_REPLACE);
            }
    #else
            if (!p.hand) skyE = max(skyE - getSkyGroundIrradiance(p.normal) * GI_GROUND_REPLACE, 0.0);
    #endif
#elif GI_MODE == 1 && defined HAS_SUN_SHADOWS
            // RSM が置き換えるのは影マップの中だけ (deferred10 と同じスカイライトの絞り)
            if (!p.hand) skyE = max(skyE - getSkyGroundIrradiance(p.normal) * (GI_GROUND_REPLACE * L.sunShadow.fade * smoothstep(RSM_SKYLIGHT_MIN, RSM_SKYLIGHT_MAX, p.lightmap.y)), 0.0);
#endif
        }
        L.sky = skyE * skylightCurve(p.lightmap.y);
    }

    if ((terms & SL_HAND_FILL) != 0u) L.handFill = getHandLightFill(p.playerPos);
    return L;
}

#endif
