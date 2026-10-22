/*
 * ボリューメトリックライト / 高さフォグのレイマーチ (sky モジュール, composite10 専用)
 * light の sampleBlockLightVolume と surface の sampleShadowVolume を使うので light.glsl / surface.glsl の後に include する
 *
 * - 指数分布のステップ (Chocapic13 / Solas): 近くを細かく、遠くを粗く。ステップ内の位置をディザで揺らす
 * - 各サンプルで影マップ (光芒)、雲影 (FOG_CLOUD_SHADOWS)、floodfill (FOG_BLOCKLIGHT: 松明が霧を照らす)
 * - 区間ごとの解析積分 (Hillaire 2015): (1 - exp(-sigma dt)) で段差の無いエネルギー保存の和
 * - 影マップの範囲より遠い区間は解析積分で続ける (空と地形のフォグ量を一致させる)
 */
#ifndef SKY_VOLUMETRICS_GLSL
#define SKY_VOLUMETRICS_GLSL

// 指数分布の強さ (大きいほど手前に集中)
const float VL_DISTRIBUTION = 3.0;
// 水中のマーチ範囲 (ブロック)。これより先は透過率がほぼ 0
const float VL_WATER_MAX_DIST = 48.0;
// 洞窟内でも霧が完全な黒にならない最低限の明るさ
const float VL_MIN_AMBIENT_SCALE = 0.25;
// ネザーは溶岩がどこにでもあり、一様な霧がその光で一面に光って地形を覆う。霧が照らされる量だけ弱める
#ifdef WORLD_NETHER
    const float VL_BLOCKLIGHT_SCALE = 0.35;
#else
    const float VL_BLOCKLIGHT_SCALE = 1.0;
#endif

/*
 * VL 用の太陽影 (rgb = 色付き透過率)。inside = 影マップの範囲内か
 * VL_COLORED_SHADOWS が無ければ不透明の 1 フェッチだけ
 */
vec3 vlShadow(vec3 playerPos, out bool inside) {
#ifdef HAS_SUN_SHADOWS
    vec3 s = playerToShadowScreen(playerPos);
    inside = all(greaterThan(s, vec3(0.0))) && all(lessThan(s, vec3(1.0)));
    if (!inside) return vec3(1.0);
    #ifdef VL_COLORED_SHADOWS
        return sampleShadowVolume(playerPos);
    #else
        return vec3(step(s.z, texture(shadowtex1, s.xy).r));
    #endif
#else
    inside = false;
    return vec3(1.0);
#endif
}

/*
 * 点から光源方向に水面までの水の厚さ (ブロック)。shadowtex0 (半透明込み) は水面の深度を持つので、
 * 点の影空間の深度との差を view 空間の距離へ戻す (水中の光芒の減衰に使う)
 */
float vlWaterColumn(vec3 playerPos) {
#ifdef HAS_SUN_SHADOWS
    vec3 s = playerToShadowScreen(playerPos);
    if (any(lessThan(s, vec3(0.0))) || any(greaterThan(s, vec3(1.0)))) return 4.0;
    float surface = texture(shadowtex0, s.xy).r;
    float dScreen = max(s.z - surface, 0.0);
    return dScreen * 2.0 / (SHADOW_DEPTH_SCALE * abs(shadowProjection[2][2]));
#else
    return 4.0;
#endif
}

// 指数分布の区間境界 (x = 0..1 -> 0..maxDist)
float vlStepDistance(float x, float maxDist) {
    return maxDist * (exp2(VL_DISTRIBUTION * x) - 1.0) / (exp2(VL_DISTRIBUTION) - 1.0);
}

/*
 * 空気中のフォグ (全ディメンション)。endDist: 地形 (空なら描画距離) までの距離
 * 戻り値: rgb = 内散乱, a = 透過率 (灰色)
 */
vec4 marchAirFog(vec3 dir, float endDist, float dither) {
    FogLighting fl = fogLightingSetup(dir);
    float outdoor = 1.0 - getCaveFactor();
#ifdef CAVE_LEAK_PREVENTION
    // 影マップの外では遮蔽が分からないので、目の位置の空の見え方で光芒を抑える
    float farSunVisibility = outdoor;
#else
    float farSunVisibility = 1.0;
#endif

#if defined HAS_SKY
    float haze = fogHazeAmount();
    float mist = fogMistAmount();
#elif defined WORLD_END
    float haze = END_FOG_EXTINCTION * END_FOG_DENSITY;
    float mist = 0.0;
#else
    float haze = netherFogExtinction();
    float mist = 0.0;
#endif

#ifdef HAS_SUN_SHADOWS
    float marchEnd = min(endDist, min(shadowDistance, far));
#else
    float marchEnd = min(endDist, far);
#endif

    vec3 scattering = vec3(0.0);
    float transmittance = 1.0;
    float tPrev = 0.0;
    for (int i = 0; i < VL_SAMPLES; i++) {
        float tNext = vlStepDistance(float(i + 1) / float(VL_SAMPLES), marchEnd);
        float dt = tNext - tPrev;
        float t = tPrev + dt * dither;
        tPrev = tNext;
        vec3 p = dir * t;

#if defined HAS_SKY
        vec2 density = fogDensityAt(p, haze, mist);
#else
        // ネザー・エンドは一様な霞に、ゆっくり漂う濃淡だけを付ける
        vec3 wp = p + cameraPosition + vec3(frameTimeCounter * 0.4, frameTimeCounter * 0.15, 0.0);
        vec2 density = vec2(haze * (0.6 + 0.8 * valueNoise3d(wp * 0.03)), 0.0);
    #ifdef WORLD_NETHER
        density.x *= netherFogNearFade(t);
    #endif
#endif
        float extinction = density.x + density.y;
        if (extinction < 1e-7) continue;

        bool inside;
        vec3 shadow = vlShadow(p, inside);
#if defined FOG_CLOUD_SHADOWS && defined HAS_SKY
        shadow *= getCloudShadow(p);
#endif
        float sunVisibility = inside ? 1.0 : farSunVisibility;
        float skyVisibility = inside ? max(outdoor, luminance(shadow)) : outdoor;

        float phase = (density.x * fl.phaseHaze + density.y * fl.phaseMist) / extinction;
        vec3 light = fl.light * shadow * (phase * sunVisibility * VL_STRENGTH);
        light += fl.ambient * max(skyVisibility, VL_MIN_AMBIENT_SCALE * MIN_AMBIENT / max(luminance(fl.ambient), 1e-6));
#ifdef FOG_BLOCKLIGHT
        light += sampleBlockLightVolume(p) * (FOG_BLOCKLIGHT_STRENGTH * VL_BLOCKLIGHT_SCALE * RCP_PI);
#endif

        float stepT = exp(-extinction * dt);
        scattering += transmittance * light * (1.0 - stepT);
        transmittance *= stepT;
        if (transmittance < 0.005) break;
    }
#if defined HAS_SKY
    scattering *= FOG_HAZE_TINT * FOG_ALBEDO;
#endif

    if (endDist > marchEnd && transmittance > 0.005) {
        vec4 rest = fogAnalyticSegment(dir, marchEnd, endDist, fl, farSunVisibility, outdoor);
        scattering += transmittance * rest.rgb;
        transmittance *= rest.a;
    }
    return vec4(scattering, transmittance);
}

/*
 * 水中 (カメラが水の中): 水面からの光の減衰込みの光芒。透過率は composite11 が距離から解析的に掛けるので内散乱だけ返す
 */
vec3 marchWaterFog(vec3 dir, float endDist, float dither) {
    LightSample celestial = getCelestialLight();
    float phase = mix(skyPhaseHG(dot(dir, celestial.direction), 0.75), SKY_PHASE_ISOTROPIC, 0.3);
    vec3 skyUp = shEvalIrradiance(vec3(0.0, 1.0, 0.0));
    vec3 extinction = waterExtinction();
    vec3 scatter = waterScattering();
    float lightY = max(celestial.direction.y, 0.1);

    float marchEnd = min(endDist, VL_WATER_MAX_DIST);
    float dt = marchEnd / float(VL_SAMPLES);
    vec3 result = vec3(0.0);
    vec3 transmittance = vec3(1.0);
    for (int i = 0; i < VL_SAMPLES; i++) {
        float t = (float(i) + dither) * dt;
        vec3 p = dir * t;
        bool inside;
        vec3 shadow = vlShadow(p, inside);
        float column = vlWaterColumn(p);
        vec3 lightT = exp(-extinction * column);
        // 空の光は水面からの深さ (光源方向の水の厚さ x 光源の高さ) だけ減衰する
        vec3 ambientT = exp(-extinction * column * lightY);
        vec3 light = celestial.irradiance * shadow * lightT * phase * VL_STRENGTH + skyUp * ambientT * (0.5 * RCP_PI);
#ifdef FOG_BLOCKLIGHT
        light += sampleBlockLightVolume(p) * (FOG_BLOCKLIGHT_STRENGTH * RCP_PI);
#endif
        vec3 stepT = exp(-extinction * dt);
        result += transmittance * light * scatter * (1.0 - stepT) / extinction;
        transmittance *= stepT;
    }
    return result;
}

#endif
