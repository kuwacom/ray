/*
 * composite2: 半透明の合成 (屈折・水中の吸収・反射を適用して colortex4 を colortex0 に重ねる)
 * surface モジュール (lib/surface)
 *
 * 不透明面: 環境光の鏡面 (反射バッファ or 空) x 方向アルベド x 鏡面遮蔽 を足す
 * 水面: 屈折先の色と水の中の経路長、上向きの水面の太陽の可視率、鏡面の映り込みのフル解像度の SSR は composite1 (water_trace.fsh) が
 *       colortex18-21 に書いたもの
 *       屈折した経路長で Jerlov の吸収と内散乱 / 厳密フレネル (水中からは全反射とスネルの窓) / 反射 / 太陽の鏡面 / 岸の泡
 *       側面 (滝・水槽): 水の厚みと出る面での屈折は composite1 / 滝の気泡の白さと着水点の泡
 *       水中から見上げた水面より上は空気なので吸収しない (カメラと水面の間の水中フォグは sky の composite19)
 * ガラス等: 透過分 (1 - a) に透過色 (block_data の tints) と (1 - F) を掛け、前方で照らした拡散 (colortex4) と反射を足す
 *       平らな板ガラスは光線が平行にずれるだけなので屈折させない。厚い氷・スライムだけ少し歪める
 * それ以外 (パーティクル・手持ちの半透明・雨): 乗算済みアルファでそのまま重ねる
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/joint_bilateral.glsl"
//@include "/lib/surface/surface.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/surface/screen_trace.glsl"
//@include "/lib/surface/lighting.glsl"
//@include "/lib/surface/reflection.glsl"
//@include "/lib/surface/surface_lights.glsl"
//@include "/lib/surface/composite_specular.glsl"
//@include "/lib/surface/water_shading.glsl"
//@include "/lib/common/specular_sparkle.glsl"
//@include "/lib/common/jitter.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/common/joint_bilateral.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glitter.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/surface_lights.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/reflection.glsl"
#include "/lib/surface/composite_specular.glsl"
#include "/lib/common/exposure.glsl"
#include "/lib/surface/water_shading.glsl"
#include "/lib/common/specular_sparkle.glsl"
#include "/lib/common/jitter.glsl"
// END GENERATED includes

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

const float GLASS_IOR = 1.5;
const float GLASS_F0 = 0.04;
const float ICE_IOR = 1.31;
const float THICK_TRANSLUCENT_REFRACTION = 0.02; // 氷・スライムの屈折の UV オフセット
const float GLASS_TINT_STRENGTH = 0.65;        // 透過色の濃さ (1 で tints 表そのまま)

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec4 sceneIn = texelFetch(colortex0, texel, 0);
    vec3 scene = sceneIn.rgb;
    vec4 translucent = texelFetch(colortex4, texel, 0);
    float d0 = texelFetch(depthtex0, texel, 0).r;
    float d1 = texelFetch(depthtex1, texel, 0).r;
    vec4 data = texelFetch(colortex5, texel, 0);
    vec3 nT;
    vec2 lmT;
    int matT;
    decodeTranslucentData(data, nT, lmT, matT);
    int tintIndex = int(round(unpack2x8(data.a).y * UNORM8_MAX));
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    bool hasSurface = d0 < d1 && !isHandDepth(d0) && (matT == MAT_WATER || isReflectiveTranslucent(matT));
    if (!hasSurface) {
        vec3 color = scene;
        vec3 env = d1 < 1.0 ? opaqueEnvSpecular(texel, d1) : vec3(0.0);
        color += env;
        vec3 result = color * (1.0 - translucent.a) + translucent.rgb;
        // deferred30 が a = 1 + 割合で渡した直接光の鏡面の白飛び分と、ここで足す映り込みの白飛び分を、重なった半透明の分だけ直して渡す
        // (しきい値は別々に掛けるので、両方が白の手前の時は少なめに出る)
        float sparkle = saturate(sceneIn.a - 1.0) * luminance(scene) + luminance(sparkleExcess(env, getExposure()));
        outColor = vec4(result, 1.0 + saturate(sparkle * (1.0 - translucent.a) / max(luminance(result), 1e-6)));
        return;
    }

    vec3 surfView = screenToView(vec3(texcoord, d0));
    vec3 surfPlayer = viewToPlayer(surfView);
    float dist = length(surfPlayer);
    vec3 V = -surfPlayer / max(dist, 1e-4);
    // 水の波の法線はかすめ角で視線の裏を向くことがあり、そのまま表裏を決めると画素ごとに反射が水の上下へ入れ替わる。水の表裏は面の向きで決める
    vec3 faceRef = matT != MAT_WATER ? nT : abs(nT.y) >= 0.5 ? vec3(0.0, sign(nT.y), 0.0) : waterSideFaceNormal(nT);
    vec3 N = dot(faceRef, V) < 0.0 ? -nT : nT;
    float NoV = saturate(dot(N, V));
    vec3 floorPlayer = screenToPlayer(vec3(texcoord, d1));
    vec3 color;
    // 鏡面の白飛び分の輝度。TAA (composite20) は明るい点を近傍の箱で潰すので、割合を a = 1 + 割合で渡して TAA の後に足させる
    float sparkleLum = 0.0;

    if (matT == MAT_WATER) {
        bool below = isEyeInWater == 1;
        float eta = below ? 1.0 / WATER_IOR : WATER_IOR;
        WaterSea sea = waterSeaState(lmT.y);
        // 側面 (滝・流れの段差・水槽): 幾何の向きは面の軸。波は側面専用の落ちる水の乱れ (lib/common/water.glsl の waterFallNormal)
        bool side = abs(N.y) < 0.5;
        vec3 faceN = side ? waterSideFaceNormal(N) : vec3(0.0, 1.0, 0.0);
        float NoVGeo = abs(dot(V, faceN));
        float footprint = waterFootprint(dist, NoVGeo);
        // 側面で上向きの水面の NoV (|V.y|) を使うと、真横から見た側面で画素が無限に大きいとみなされ、海の波の分散が全部
        // 太陽の鏡面の粗さへ回って側面に白っぽい幅広のつやが乗っていた
        vec2 unresolved = side ? vec2(waterFallUnresolvedSlopeVar(footprint), 0.0) : waterUnresolvedSlopeCurvature(sea, footprint);
        float unresolvedVar = unresolved.x;
        // 上から見た上向きの水面だけ、画素より細かい波の粗さでフレネルと反射方向を均す (composite.csh と同じ)
        float roughVar = !below && N.y > 0.5 ? unresolvedVar : 0.0;
        float F = fresnelDielectric(waterRoughNoV(NoV, roughVar, dist), eta);
        vec3 refrDir = refract(-V, N, 1.0 / eta);
        if (dot(refrDir, refrDir) < 0.5) F = 1.0;
        /*
         * 側面の日向はスカイライトと雲影で近似する (影マップは滝の水柱自身の影に掛かり、PCSS のノイズが泡の白に出て砂嵐のようにざらついた)
         */
        vec3 sunSpecVis = vec3(0.0);
        vec3 sunVis = vec3(0.0);
        if (side && !below) {
            sunVis = vec3(smoothstep(0.6, 0.95, lmT.y)) * getCloudShadow(surfPlayer);
            sunSpecVis = sunVis * getCloudSunDiscVisibility();
        } else if (!below) {
            // 上向きの水面の影 (PCSS) は composite1 (water_trace.fsh) が求めた可視率
            sunVis = texelFetch(colortex21, texel, 0).rgb;
            sunSpecVis = texelFetch(colortex19, texel, 0).rgb;
        }

        // 太陽以外の光: 手持ち光源 (内散乱・泡・鏡面) とブロックライトの鏡面 (光源ごとにトレース)。水中から見た面の裏は掛けない
        // 省く項: 太陽 (上で別に取る)・GI・AO・接触影 (水面の下に不透明面の深度しか無い)
        SurfacePoint wp = surfacePoint(surfPlayer, faceN);
        wp.lightmap = lmT;
        wp.texel = texel;
        wp.dither = dither;
        SurfaceLights WL = gatherSurfaceLights(wp, SL_SUN_NONE, SL_BLOCK_NONE, 0u);
        if (!below) WL = gatherSurfaceLights(wp, SL_SUN_NONE, SL_BLOCK_FORWARD, SL_HAND | SL_BLOCK_SPECULAR_TRACED);

        // 屈折先の色と水の中の経路長は composite1 (water_trace.fsh) が求める。フレネルが 1 の画素は屈折先を使わない
        vec3 behind = vec3(0.0);
        float behindExcess = 0.0;
        float pathLen = WATER_SKY_PATH;
        if (F < 1.0) {
            vec4 refr = texelFetch(colortex18, texel, 0);
            behind = refr.rgb;
            pathLen = refr.a;
            behindExcess = texelFetch(colortex19, texel, 0).a;
        }

        // 吸収と内散乱 (水の上から見た時だけ。水中側は sky のフォグ)
        if (!below) {
            vec3 ext = waterExtinction();
            vec3 T = exp(-ext * pathLen);
            behindExcess *= luminance(T);
            float muView = dot(refrDir, refrDir) > 0.5 ? saturate(-refrDir.y) : saturate(V.y);
            behind = behind * T + waterInscatter(lmT.y, sunVis, WL.block + handIrradiance(WL, vec3(0.0, 1.0, 0.0)), muView, pathLen);
        }

        // 反射と太陽
        vec3 R = reflect(-V, below ? N : waterReflectNormal(N, V));
        /*
         * composite.csh と同じく、下向きの反射は平均水面でもう一度反射させる。上向きの水面だけ
         * (側面で折り返すと、少し上から見た滝が足元の地面ではなく空を映し、側面全体が白っぽく光っていた)
         */
        if (!below && !side) R.y = abs(R.y);
        // 空を引く方向だけ持ち上げる (物に当たった反射は composite.csh が持ち上げない方向で辿った結果)
        vec3 R0 = R;
        R = waterRoughReflectDir(R, roughVar);
        vec3 refl;
#if REFLECTIONS > 0
        float skyWeight;
        vec4 rs = sampleWaterReflection(texel, dist, skyWeight);
        vec3 fallback = below ? vec3(0.0) : skyReflectionFallback(R, lmT.y, 0.0);
        if (rs.a > 0.0) {
            vec3 sky = skyWeight > 0.0 && R.y > 0.0 ? waterSkyReflection(R0, roughVar, lmT.y, dist) : fallback;
            refl = mix(fallback, (rs.rgb + sky * skyWeight) / rs.a, saturate(rs.a * 4.0));
        } else {
            refl = fallback;
        }
        // 物の映り込みのフル解像度の SSR は composite1 (water_trace.fsh) が辿った当たり (rgb = 色 x 重み, a = 重み)
        vec4 mirror = texelFetch(colortex20, texel, 0);
        refl = refl * (1.0 - mirror.a) + mirror.rgb;
#else
        refl = below ? vec3(0.0) : skyReflectionFallback(R, lmT.y, 0.0);
#endif
        color = behind * (1.0 - F) + refl * F;
        sparkleLum = behindExcess * (1.0 - F);
        if (!below) {
            // 太陽・灯りの照り返しの粗さ: 表した波の斜面は法線が受け持つので、光学的に滑らかな水に、画素より細かい波と画素の中・露光の間の法線の揺れを足す
            // 側面 (滝) は落ちる水の乱れに任せ、幅のある淡いつやを残す
            float sunAlpha = side ? sqrt(sqr(WATER_ROUGHNESS) + unresolvedVar)
                : sqrt(sqr(WATER_SUN_ROUGHNESS) + unresolvedVar + waterPixelSlopeVar(sea, footprint));
            // 上向きの面だけ: 長い 3 層の高さと Jacobian (波頭の透過光・泡・きらめきを寄せる波頭)。視差の位置ずれは長い波では画素未満
            bool top = N.y > 0.5;
            vec3 surfWorld = surfPlayer + cameraPosition;
            vec4 waves = vec4(0.0);
            if (top) waves = waterWaveSum(sea, surfWorld.xz, 0, 3, footprint);
            float crest = smoothstep(0.0, 2.0 * sea.heightRms, waves.x);
            // 粗さへ回した細かい波の分は、太陽 (月) を映す点の集まりとして描く (WATER_GLITTER)
            float glitter = 1.0;
#ifdef WATER_GLITTER
            // 日陰・雲の影では光源が映らないので探さない
            if (top && maxOf(sunSpecVis) > 0.0) {
                vec2 glintPos = screenToPlayer(vec3(removeTaaJitter(texcoord), d0)).xz + cameraPosition.xz;
                glitter = waterGlitter(glintPos, N, V, unshadowedSun().direction, sqr(sunAlpha), unresolved,
                    dist * 2.0 / (gbufferProjection[1][1] * viewSize().y), NoVGeo,
                    waterGlintCrest(vec3(sea.amp[0], sea.amp[1], sea.amp[2]), vec2(sea.amp[GLINT_CREST_SHORT_FIRST], sea.amp[GLINT_CREST_SHORT_FIRST + 1]),
                        surfWorld.xz, footprint, waves.x));
                /*
                 * 念のための保護: 倍率が有限でない画素は滑らかなローブに戻す (鏡面の上限の min が NaN を円盤の明るさに置き換えるため)
                 * isnan / isinf は最適化で消えることがあるので、指数のビットで調べる
                 */
                if (!waterGlintFinite(glitter)) glitter = 1.0;
            }
#endif
            vec3 spec = refl * F + sunSpecular(N, V, WATER_F0, sunAlpha, sunSpecVis, glitter) + localLightSpecular(WL, N, V, WATER_F0, sunAlpha);
            color = behind * (1.0 - F) + spec;
            sparkleLum += luminance(sparkleExcess(spec, getExposure()));

            if (top) {
                LightSample sun = unshadowedSun();

                // 波頭の透過光: 太陽の側を向いて見た時だけ。真上の太陽では横から波頭へ入る光が無い
                vec2 toSun = sun.direction.xz;
                float back = dot(toSun, toSun) > 1e-4 ? saturate(dot(normalize(-V.xz), normalize(toSun))) : 0.0;
                float sss = WATER_CREST_SSS * crest * sqr(sqr(back)) * (1.0 - sqr(sun.direction.y)) * (1.0 - F);
                color += sun.irradiance * sunVis * waterScattering() / waterExtinction() * sss;

                // 泡: 崩れかけた波頭の白波 (沖だけ。視線に沿った水の厚みが薄い水際には出さない)
                float t = frameTimeCounter;
                float pattern = valueNoise3d(vec3(surfWorld.xz * 3.0, t * 0.4)) * 0.6
                    + valueNoise3d(vec3(surfWorld.xz * 9.0, t * 0.9)) * 0.4;
                float offshore = d1 < 1.0 ? smoothstep(0.0, FOAM_SHORE_WIDTH, distance(floorPlayer, surfPlayer)) : 1.0;
                float J = waterJacobian(waves);
                float cap = smoothstep(WHITECAP_J0, WHITECAP_J1, J) * smoothstep(WHITECAP_WIND0, WHITECAP_WIND1, sea.wind)
                    * smoothstep(0.3, 0.6, pattern) * offshore;
                float foam = saturate(cap * WATER_FOAM) * FOAM_OPACITY;
                if (foam > 0.0) color = mix(color, foamRadiance(surfPlayer, vec3(0.0, 1.0, 0.0), lmT, sunVis, WL), foam);
                sparkleLum *= 1.0 - foam;
            }
        }
    } else {
        // ガラス・氷・スライム等
        float ior = matT == MAT_ICE ? ICE_IOR : GLASS_IOR;
        float F = fresnelDielectric(NoV, ior);
        vec2 refrUv = texcoord;
#if WATER_REFRACTION >= 1
        if (matT == MAT_ICE || matT == MAT_SLIME_HONEY) {
            vec2 tuv = texcoord + playerToViewDir(N).xy * THICK_TRANSLUCENT_REFRACTION;
            if (validRefraction(tuv, d0)) refrUv = tuv;
        }
#endif
        vec4 behindRaw = texture(colortex0, refrUv);
        vec3 behind = behindRaw.rgb;
        float behindExcess = behindSparkle(behindRaw);
        if (d1 < 1.0) {
            vec3 env = opaqueEnvSpecular(texel, d1);
            behind += env;
            behindExcess += luminance(sparkleExcess(env, getExposure()));
        }
#ifdef CLOUD_INTERIOR
        // 雲の中の霧: ガラスの向こうの背景には、ガラスから奥の面 (空は無限遠) までの分を先に掛ける。ガラスまでの分は fog_apply が全体に掛ける
        if (isEyeInWater == 0) {
            vec4 backFog = cloudInteriorFog(-V, dist, d1 >= 1.0 ? CLOUD_RAY_FAR : length(floorPlayer));
            behind = behind * backFog.a + backFog.rgb;
            behindExcess *= backFog.a;
        }
#endif
        vec3 transmit = vec3(1.0 - translucent.a);
        if (tintIndex > 0) {
            vec4 tint = getTint(tintIndex - 1);
            transmit *= mix(vec3(1.0), tint.rgb, tint.a * GLASS_TINT_STRENGTH);
        }
        float roughness = translucentRoughness(matT);
        vec3 R = reflect(-V, N);
        vec3 refl = reflectionAt(texel, dist, R, lmT.y, roughness, vec3(0.0));
        if (roughness < MIRROR_ROUGHNESS) refl = mirrorReflection(refl, surfView, surfPlayer, N, R, dist, false, false, dither);
        vec3 glassSunVis;
        surfaceSunVisibility(surfPlayer, N, dither, glassSunVis);
        // 太陽以外の光の鏡面。省く項は水と同じ
        SurfacePoint gp = surfacePoint(surfPlayer, N);
        gp.lightmap = lmT;
        gp.texel = texel;
        gp.dither = dither;
        SurfaceLights GL = gatherSurfaceLights(gp, SL_SUN_NONE, SL_BLOCK_NONE, SL_HAND | SL_BLOCK_SPECULAR_TRACED);
        float glassAlpha = max(roughness * roughness, MIN_ROUGHNESS);
        // 前方で照らした拡散 (translucent.rgb) は鏡面で反射する F の分を除く (太陽の鏡面を足すので、その分だけ明るくならないように)
        vec3 spec = refl * F + sunSpecular(N, V, GLASS_F0, glassAlpha, glassSunVis) + localLightSpecular(GL, N, V, GLASS_F0, glassAlpha);
        color = behind * transmit * (1.0 - F) + translucent.rgb * (1.0 - F) + spec;
        float glassSparkle = luminance(sparkleExcess(spec, getExposure())) + behindExcess * luminance(transmit) * (1.0 - F);
        outColor = vec4(color, 1.0 + saturate(glassSparkle / max(luminance(color), 1e-6)));
        return;
    }

    // 水の上に重なった物 (WATER_TEXTURE の水テクスチャ・パーティクル・雨) を重ねる
    vec3 result = color * (1.0 - translucent.a) + translucent.rgb;
    float sparkleShare = saturate(sparkleLum * (1.0 - translucent.a) / max(luminance(result), 1e-6));
    outColor = vec4(result, 1.0 + sparkleShare);
}