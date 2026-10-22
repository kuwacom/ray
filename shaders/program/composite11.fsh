/*
 * composite11: フォグ / VL の適用 (colortex12 をバイラテラルにアップサンプルして colortex0 に合成)
 * 順番 (遠い方から): 地形 -> 空中遠近 -> 描画距離端のフォグ -> 手前の雲 (雲より上にいる時) -> カメラ側の媒質 (高さフォグ / 水 / 溶岩 / 粉雪)
 * -> 手持ち光源が霧を照らす光 (点光源の内散乱を解析積分) -> 盲目・暗闇
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

// アップサンプルの深度の重み (相対深度差に対する鋭さ)
const float VL_UPSAMPLE_DEPTH_SHARPNESS = 20.0;
const float BLINDNESS_CLEAR_DIST = 2.0;
const float WATER_BORDER_FOG = 0.25; // 水面に掛ける描画距離端のフォグの割合
/*
 * 水中の内散乱の倍率。単散乱そのままだと水面近くの水が空の光で明るく光り、水面越しの空・地形との差が無い
 * 白っぽい一面の青になった。露出を下げるだけでは水面の明るさも一緒に沈むので、
 * 内散乱を弱めて深い所を暗く、水面 (スネルの窓) を相対的に明るく残す
 */
const float WATER_FOG_INSCATTER = 0.5;

vec4 fetchVolumetrics(ivec2 lowTexel) {
    lowTexel = clamp(lowTexel, ivec2(0), vlLowResSize() - 1);
    return vlWritesColortex12() ? texelFetch(colortex12, lowTexel, 0) : texelFetch(fogHistorySampler, lowTexel, 0);
}

// 深度を見たバイリニア (低解像度の 4 点のうち、深度の近い点だけを使う)
vec4 upsampleVolumetrics(ivec2 texel, float linearDepth) {
    vec2 lowPos = (vec2(texel) - float(VL_RES / 2)) / float(VL_RES);
    ivec2 base = ivec2(floor(lowPos));
    vec2 f = lowPos - vec2(base);
    vec4 sum = vec4(0.0);
    float weightSum = 0.0;
    vec4 nearest = vec4(0.0, 0.0, 0.0, 1.0);
    float nearestDiff = 1e9;
    for (int i = 0; i < 4; i++) {
        ivec2 o = ivec2(i & 1, i >> 1);
        ivec2 q = clamp(base + o, ivec2(0), vlLowResSize() - 1);
        float sampleDepth = linearizeDepth(fixHandDepth(texelFetch(depthtex0, vlSampleTexel(q), 0).r));
        float diff = abs(sampleDepth - linearDepth) / max(linearDepth, 0.1);
        vec2 bw = mix(1.0 - f, f, vec2(o));
        float w = bw.x * bw.y * exp(-diff * VL_UPSAMPLE_DEPTH_SHARPNESS);
        vec4 s = fetchVolumetrics(q);
        sum += s * w;
        weightSum += w;
        if (diff < nearestDiff) { nearestDiff = diff; nearest = s; }
    }
    return weightSum > 1e-4 ? sum / weightSum : nearest;
}

/*
 * 点光源 (手持ち) からの内散乱を視線に沿って解析積分 (逆二乗 1 / (d^2 + 1) の積分は atan で閉じる)
 * 影と減衰は無視する (手の周りの数ブロックの淡い光の暈なので見た目に差が出ない)
 */
vec3 handLightGlow(vec3 dir, float dist, float scatterCoeff) {
    vec3 glow = vec3(0.0);
#ifdef HAND_LIGHT
    for (int hand = 0; hand < 2; hand++) {
        bool mainHand = hand == 0;
        int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
        if (level <= 0) continue;
        int index = getItemLightIndex(mainHand ? heldItemId : heldItemId2);
        LightDef d = getLightDef(index != LIGHT_NONE ? index : LIGHT_TORCH);
        vec3 intensity = lightEmission(d, float(level)) * HAND_LIGHT_BRIGHTNESS;
        vec3 lightPos = getHandLightPosition(mainHand);
        float t0 = dot(lightPos, dir);
        float a = sqrt(max(dot(lightPos, lightPos) - t0 * t0, 0.0) + 1.0);
        float integral = (atan((dist - t0) / a) - atan(-t0 / a)) / a;
        glow += intensity * integral;
    }
#endif
    return glow * scatterCoeff * SKY_PHASE_ISOTROPIC;
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec4 sceneIn = texelFetch(colortex0, texel, 0);
    vec3 color = sceneIn.rgb;
    /*
     * 水面の輝点 (composite1 が a = 1 + 輝度の割合で書く)。TAA (composite20) が近傍の箱で潰さず後から足すので、
     * フォグで減る分 (透過率) を掛けた輝度を追い、最後に割合へ戻して渡す
     */
    float glint = saturate(sceneIn.a - 1.0) * luminance(color);
    /*
     * 溶岩の発光も同じ仕組みで追い、a = -割合で渡す (composite23 がブルームの元でだけ明るくする)
     * 輝点の無い画素は a = 0 (TAA の glintShare はどちらも 0)
     */
    bool lavaGlow = glint <= 0.0 && readMaterialId(texel) == MAT_LAVA;
    if (lavaGlow) glint = luminance(color);
    float depth = texelFetch(depthtex0, texel, 0).r;
    bool isSky = depth >= 1.0;
    float fixedDepth = isSky ? 1.0 : fixHandDepth(depth);
    vec3 playerPos = screenToPlayer(vec3(texcoord, fixedDepth));
    vec3 dir = normalize(playerPos);
    float dist = isSky ? far : length(playerPos);

    // 遠景 (空気中のみ。水中・溶岩の中からは遠景が見えないので媒質のフォグだけで十分)
    if (!isSky && isEyeInWater == 0) {
        color = applyAerialPerspective(color, playerPos);
        // 空中遠近の透過率 (加わる空の色を除いた分)。輝点のある画素だけ求める
        if (glint > 0.0) glint *= luminance(applyAerialPerspective(vec3(1.0), playerPos) - applyAerialPerspective(vec3(0.0), playerPos));
        float borderFog = getBorderFog(playerPos);
        // 水面は描画距離の外へ続く平面で、端の色は地平線の空の映り込みとほぼ同じ。端のフォグで地平線の色へ溶かすと
        // 遠くの水面の雲や島の映り込みが消え、水平線の手前が白い帯になっていた
        vec3 nT; vec2 lmT; int matT;
        decodeTranslucentData(texelFetch(colortex5, texel, 0), nT, lmT, matT);
        if (matT == MAT_WATER && depth < texelFetch(depthtex1, texel, 0).r) borderFog *= WATER_BORDER_FOG;
        color = mix(color, getBorderFogColor(dir), borderFog);
        glint *= 1.0 - borderFog;
#if CLOUDS >= 2 && defined HAS_SKY
        // 雲の下面より上にいる時だけ、地形の手前の雲を重ねる (deferred20 は地形までの区間だけを積分している)
        if (cameraPosition.y > CLOUD_BASE) {
            vec4 clouds = getCloudLayer(texel);
            color = color * clouds.a + clouds.rgb;
            glint *= clouds.a;
        }
#endif
    }

    float scatterCoeff;
    if (isEyeInWater == 1) {
        vec3 extinction = waterExtinction();
        vec3 transmittance = exp(-extinction * dist);
#ifdef VL
        vec3 inscatter = upsampleVolumetrics(texel, linearizeDepth(fixedDepth)).rgb;
#else
        vec3 ambient = shEvalIrradiance(vec3(0.0, 1.0, 0.0)) * 0.5 * RCP_PI * (1.0 - getCaveFactor() * 0.8) + getCelestialLight().irradiance * 0.05;
        vec3 inscatter = ambient * waterScattering() / extinction * (1.0 - transmittance) * exp(-extinction * 3.0);
#endif
        color = color * transmittance + inscatter * WATER_FOG_INSCATTER;
        scatterCoeff = dot(waterScattering(), vec3(1.0 / 3.0));
    } else if (isEyeInWater == 2) {
        vec3 transmittance = exp(-FOG_LAVA_EXTINCTION * dist);
        color = color * transmittance + FOG_LAVA_RADIANCE * (1.0 - transmittance);
        scatterCoeff = 0.0;
    } else if (isEyeInWater == 3) {
        vec3 transmittance = exp(-FOG_POWDER_SNOW_EXTINCTION * dist);
        vec3 snowLight = (shEvalIrradiance(vec3(0.0, 1.0, 0.0)) + getCelestialLight().irradiance * 0.3) * RCP_PI * 0.8 + MIN_AMBIENT;
        color = color * transmittance + snowLight * (1.0 - transmittance);
        scatterCoeff = 0.0;
    } else {
#ifdef VL
        vec4 fog = upsampleVolumetrics(texel, linearizeDepth(fixedDepth));
#else
        float outdoor = 1.0 - getCaveFactor();
        vec4 fog = fogAnalyticSegment(dir, 0.0, dist, fogLightingSetup(dir), outdoor, max(outdoor, 0.05));
#endif
        color = color * fog.a + fog.rgb;
        glint *= fog.a;
#if defined HAS_SKY
        vec2 localDensity = fogDensityAt(vec3(0.0), fogHazeAmount(), fogMistAmount());
        scatterCoeff = (localDensity.x + localDensity.y) * FOG_ALBEDO;
#elif defined WORLD_END
        scatterCoeff = END_FOG_EXTINCTION * END_FOG_DENSITY;
#else
        scatterCoeff = netherFogExtinction();
#endif
    }

    if (scatterCoeff > 0.0) color += handLightGlow(dir, min(dist, 32.0), scatterCoeff);

    // 盲目・暗闇: 近く以外を黒へ (バニラと同じく視界を奪う効果)
    float blindFog = max(blindness, darknessFactor * (0.6 + 0.4 * darknessLightFactor));
    if (blindFog > 0.0) {
        float blindT = mix(1.0, exp(-BLINDNESS_FOG_EXTINCTION * max(dist - BLINDNESS_CLEAR_DIST, 0.0)), blindFog);
        color *= blindT;
        glint *= blindT;
    }

    float share = saturate(glint / max(luminance(color), 1e-6));
    outColor = vec4(color, lavaGlow ? -share : (share > 0.0 ? 1.0 + share : 0.0));
}
