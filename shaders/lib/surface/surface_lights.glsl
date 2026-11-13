/*
 * 表面の光の集め方 (surface モジュール)
 * 太陽の影・空・ブロックライト・手持ち光源・GI を、取り方 (モード) と足す項 (terms) を指定して 1 か所で集める
 * 返すのは照度と LightSample だけで、BRDF・AO・溶岩・水たまり・SSS の厚みの減衰は呼ぶ側で掛ける
 * モードと項はリテラルで渡すので、インライン展開の後に使わない分岐は消える
 * 呼ぶ側は使う組み合わせを const で書き、省いた項とその理由をコメントに残す
 */
#ifndef SURFACE_SURFACE_LIGHTS_GLSL
#define SURFACE_SURFACE_LIGHTS_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/look_presets.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/shadow_volume.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/light/blocklight.glsl"
//@include "/lib/light/floodfill.glsl"
//@include "/lib/light/hand_light.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/sky_color.glsl"
//@include "/lib/surface/gi.glsl"
//@include "/lib/surface/sun_shadow.glsl"

// 太陽の影の取り方 (どれか 1 つ)
// 影マップの外の扱い: SHADOW_MAP_FALLBACK だけスカイライトで日向を推定する。半透明の面と 2 次ヒットは軽さのため 1 (日向) にするので、
// 影の距離より遠い地下の水・ガラスは日向になり、太陽の鏡面と水の内散乱が出うる。遠くで画面に占める面積は小さいので近似しない
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

// 足す項 (組み合わせ)
const uint SL_SUN_CONTACT = 1u << 0;
const uint SL_POM = 1u << 2;
const uint SL_SKY = 1u << 3;
const uint SL_GI = 1u << 4;               // colortex8 を読み、GI が運ぶ空・地面の分を sky から引く
const uint SL_HAND = 1u << 5;             // 手持ち光源の LightSample (トレース付き)
const uint SL_HAND_FILL = 1u << 6;
const uint SL_BLOCK_SPECULAR = 1u << 7;
const uint SL_CELESTIAL = 1u << 8;      // 太陽の影を取らなくても、影を掛ける前の太陽 / 月を celestial に返す
const uint SL_BLOCK_SPECULAR_TRACED = 1u << 9; // 鏡面の光源を 1 つずつトレースして可視率を出す (colortex7 に無い半透明の面用)

// 影マップの外での日向の判定 (スカイライトがこれ以上なら日向とみなす)
const vec2 SHADOW_FALLBACK_SKYLIGHT = vec2(0.8, 0.97);
// GI が空の光を運ぶ時 (GI_TRACES_SKY): ボクセル体積の判定で面から浮かせる量
const float GI_VOLUME_TEST_OFFSET = 0.1;

// 影を落とす天体の影の濃さ (昼 = 太陽, 夜・エンド = 月)。可視率に mix(1, 可視率, 濃さ) で掛ける
float celestialShadowStrength() {
    return frameData.shadowLightIrradiance.a > 0.5 ? SUN_SHADOW_STRENGTH : MOON_SHADOW_STRENGTH;
}

// 洞窟の最低限の可視光と暗視の環境光 (照度)。AO は呼ぶ側で掛ける
float minAmbientIrradiance() { return MIN_AMBIENT + nightVision * NIGHT_VISION_AMBIENT; }

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
    float sunFade;    // 太陽の影を別の呼び出しで集めた時の sunShadow.fade (SL_GI の RSM が空を置き換える範囲)
    bool hand;        // 一人称の手
    // SL_SUN_VOLUME で水の下の点にコースティクスを掛けるか (照明の比だけに使う 2 次ヒットは false)。項の組 (terms) に
    // 入れると実行時の値になって全部の項がリンクされるので、点の値で渡す
    bool caustics;
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
    p.sunFade = 0.0;
    p.hand = false;
    p.caustics = true;
    return p;
}

struct SurfaceLights {
    LightSample celestial;  // 影を掛ける前の太陽 / 月
    LightSample sun;        // 影・雲影・POM・接触影込み
    vec3 sunVis;            // sun に掛けた可視率 (雲影込み)
    SunShadow sunShadow;    // SSS の厚みと fade (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    float sunFallback;      // 影マップの外の日向の推定 (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    float cloudShadow;      // 雲影 (SL_SUN_SHADOW_MAP_FALLBACK のみ)
    LightSample handMain;
    LightSample handOff;
    vec3 sky;               // 空の SH x スカイライト。GI が運ぶ分を引いた後、AO の前
    vec3 block;             // ブロックライトの拡散照度 (AO の前)
    vec3 handFill;          // 手持ち光源の照り返し (AO の前)
    vec4 indirect;          // colortex8 (rgb = GI, a = GTAO)
    float giSky;            // GI が空の光を運んでいる度合い (ボクセル RT の範囲の端で 0 へ落ちる)
    int blockSpecCount;
    LightSample blockSpec[BLOCKLIGHT_SPECULAR_LIGHTS];
};

SurfaceLights gatherSurfaceLights(SurfacePoint p, int sunMode, int blockMode, uint terms) {
    SurfaceLights L;
    L.celestial = (terms & SL_CELESTIAL) != 0u ? getCelestialLight() : noLight();
    L.sun = noLight();
    L.sunVis = vec3(0.0);
    L.sunShadow.visibility = vec3(1.0);
    L.sunShadow.thickness = 0.0;
    L.sunShadow.fade = 0.0;
    L.sunFallback = 0.0;
    L.cloudShadow = 1.0;
    L.sky = vec3(0.0);
    L.block = vec3(0.0);
    L.handFill = vec3(0.0);
    L.indirect = vec4(0.0, 0.0, 0.0, 1.0);
    L.giSky = 0.0;
    L.blockSpecCount = 0;

    if ((terms & SL_GI) != 0u) L.indirect = getIndirectLight(p.texel);

    // 影の濃さ (SUN_SHADOW_STRENGTH / MOON_SHADOW_STRENGTH) は影マップ・接触影・POM の可視率だけに掛け、雲影は対象外
    float shadowStrength = celestialShadowStrength();
    if (sunMode == SL_SUN_SHADOW_MAP) {
        L.celestial = getCelestialLight();
        L.sunVis = mix(vec3(1.0), getSunShadow(p.playerPos, p.geoNormal, p.dither), shadowStrength) * getCloudShadow(p.playerPos);
        L.sun = L.celestial;
        L.sun.irradiance *= L.sunVis;
    } else if (sunMode == SL_SUN_SHADOW_MAP_FALLBACK) {
        L.celestial = getCelestialLight();
        SunShadow ss = evalSunShadow(p.playerPos, p.geoNormal, p.sss, p.dither);
        L.sunShadow = ss;
        float fallback = smoothstep(SHADOW_FALLBACK_SKYLIGHT.x, SHADOW_FALLBACK_SKYLIGHT.y, p.lightmap.y);
        L.sunFallback = fallback;
        vec3 vis = mix(vec3(fallback), ss.visibility, ss.fade);
        if ((terms & SL_POM) != 0u) vis *= p.pomShadow;
        // 一人称の手は影マップ上で自分の体の影の中にあるので、スカイライトから日向を推定する
        if (p.hand) vis = vec3(fallback);
#ifdef SCREEN_SPACE_SHADOWS
        if ((terms & SL_SUN_CONTACT) != 0u && !p.hand && maxOf(vis) > 0.0) {
            vis *= sunContactShadow(p.viewPos, playerToViewDir(p.geoNormal), playerToViewDir(L.celestial.direction), p.dither);
        }
#endif
        L.cloudShadow = getCloudShadow(p.playerPos);
        L.sunVis = mix(vec3(1.0), vis, shadowStrength) * L.cloudShadow;
        L.sun = L.celestial;
        L.sun.irradiance *= L.sunVis;
    } else if (sunMode == SL_SUN_VOLUME) {
        L.celestial = getCelestialLight();
        float NoL = saturate(dot(p.normal, L.celestial.direction));
        L.sun = L.celestial;
        L.sun.irradiance = vec3(0.0);
        if (NoL > 0.0) {
            L.sun.irradiance += L.celestial.irradiance * NoL * mix(vec3(1.0), sampleShadowVolume(p.playerPos + p.normal * 0.08, p.caustics), shadowStrength) * getCloudShadow(p.playerPos);
        }
    }

    if ((terms & SL_HAND) != 0u) {
        getHandLights(p.playerPos, p.geoNormal, p.dither, L.handMain, L.handOff);
    } else {
        L.handMain = noLight();
        L.handOff = noLight();
    }
    if ((terms & SL_BLOCK_SPECULAR) != 0u) L.blockSpecCount = getBlockLightSpecular(p.texel, p.playerPos, p.geoNormal, false, L.blockSpec);
    else if ((terms & SL_BLOCK_SPECULAR_TRACED) != 0u) L.blockSpecCount = getBlockLightSpecular(p.texel, p.playerPos, p.geoNormal, true, L.blockSpec);

    if (blockMode == SL_BLOCK_OPAQUE) {
        L.block = getBlockLightOpaque(p.texel, p.playerPos, p.geoNormal, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_FORWARD) {
        L.block = getBlockLightForward(p.playerPos, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_FORWARD_ENTITY) {
        L.block = getBlockLightForwardEntity(p.playerPos, p.geoNormal, p.normal, p.lightmap.x);
    } else if (blockMode == SL_BLOCK_HIT_FLOOD) {
        L.block = sampleFloodfill(p.playerPos, p.normal);
    }

    if ((terms & SL_SKY) != 0u) {
        vec3 skyE = getSkyIrradiance(p.normal);
        // GI が運ぶ空・地面の分を引く (二重に数えない)。一人称の手には GI が無いので引かない
        if ((terms & SL_GI) != 0u) {
#if GI_MODE == 2 || GI_MODE == 3
    #ifdef GI_TRACES_SKY
            // GI のレイが空の光を向きと遮蔽込みで運ぶので、空の環境光は置き換えない分 (GI_SKY_OCCLUSION, GI_GROUND_REPLACE) だけ残す
            // (lib/surface/gi.glsl)。ボクセル体積の外は GI が 0 なので空の環境光をそのまま使い、端 (GI_VOXEL_FADE) では GI と同じ重みで移る
        #if GI_MODE == 3
            L.giSky = p.hand ? 0.0 : giVoxelWeight(p.playerPos + p.geoNormal * GI_VOLUME_TEST_OFFSET);
        #else
            L.giSky = p.hand ? 0.0 : 1.0;
        #endif
            if (L.giSky > 0.0) {
                vec3 groundE = getSkyGroundIrradiance(p.normal);
                vec3 replaced = max(skyE - groundE, 0.0) * (1.0 - LOOK_GI_SKY_OCCLUSION) + groundE * (1.0 - GI_GROUND_REPLACE);
                skyE = mix(skyE, replaced, L.giSky);
            }
    #else
            if (!p.hand) skyE = max(skyE - getSkyGroundIrradiance(p.normal) * GI_GROUND_REPLACE, 0.0);
    #endif
#elif GI_MODE == 1 && defined HAS_SUN_SHADOWS
            // RSM が置き換えるのは影マップの中だけ (deferred10 と同じスカイライトの絞り)
            float sunFade = sunMode == SL_SUN_SHADOW_MAP_FALLBACK ? L.sunShadow.fade : p.sunFade;
            if (!p.hand) skyE = max(skyE - getSkyGroundIrradiance(p.normal) * (GI_GROUND_REPLACE * sunFade * smoothstep(RSM_SKYLIGHT_MIN, RSM_SKYLIGHT_MAX, p.lightmap.y)), 0.0);
#endif
        }
        L.sky = skyE * skylightCurve(p.lightmap.y);
    }

    if ((terms & SL_HAND_FILL) != 0u) L.handFill = getHandLightFill(p.playerPos);
    return L;
}

#endif
