/*
 * composite1: 半透明の合成 (屈折・水中の吸収・反射を適用して colortex4 を colortex0 に重ねる)
 * surface モジュール (lib/surface)
 *
 * 不透明面: 環境光の鏡面 (反射バッファ or 空) x 方向アルベド x 鏡面遮蔽 を足す
 * 水面: 屈折 (WATER_REFRACTION 1 = 屈折方向に水深分進めて投影 + 深度検証, 2 = 屈折方向のレイマーチ)
 *       上から見た水面の屈折の方式 (WATER_REFRACTION_MODE): A = 波で曲がった分だけ / B = 屈折のまま画面の端で弱める /
 *       D = 屈折のまま、画面に無い屈折先はボクセルで辿る (水底が浅く見える)
 *       屈折した経路長で Jerlov の吸収と内散乱 / 厳密フレネル (水中からは全反射とスネルの窓) / 反射 / 太陽の鏡面 / 岸の泡
 *       側面 (滝・水槽): 水の厚みはボクセルで水を出る所まで / 出る面で空気へもう一度屈折 / 滝の気泡の白さと着水点の泡
 *       水中から見上げた水面より上は空気なので吸収しない (カメラと水面の間の水中フォグは sky の composite11)
 * ガラス等: 透過分 (1 - a) に透過色 (block_data の tints) と (1 - F) を掛け、前方で照らした拡散 (colortex4) と反射を足す
 *       平らな板ガラスは光線が平行にずれるだけなので屈折させない。厚い氷・スライムだけ少し歪める
 * それ以外 (パーティクル・手持ちの半透明・雨): 乗算済みアルファでそのまま重ねる
 */
#include "/lib/common/common.glsl"
#include "/lib/common/joint_bilateral.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/reflection.glsl"
#include "/lib/surface/surface_lights.glsl"
#include "/lib/surface/composite_specular.glsl"
#include "/lib/surface/water_shading.glsl"

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

const float GLASS_IOR = 1.5;
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
    int tintIndex = int(round(unpack2x8(data.a).y * 255.0));
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    bool hasSurface = d0 < d1 && !isHandDepth(d0) && (matT == MAT_WATER || isReflectiveTranslucent(matT));
    if (!hasSurface) {
        vec3 color = scene;
        if (d1 < 1.0) color += opaqueEnvSpecular(texel, d1);
        vec3 result = color * (1.0 - translucent.a) + translucent.rgb;
        // 水たまりの輝点 (deferred30 が a = 1 + 割合で渡す) の割合を、足した鏡面と重なった半透明の分だけ直して渡す
        float sceneGlint = saturate(sceneIn.a - 1.0) * luminance(scene);
        outColor = vec4(result, 1.0 + saturate(sceneGlint * (1.0 - translucent.a) / max(luminance(result), 1e-6)));
        return;
    }

    vec3 surfView = screenToView(vec3(texcoord, d0));
    vec3 surfPlayer = viewToPlayer(surfView);
    float dist = length(surfPlayer);
    vec3 V = -surfPlayer / max(dist, 1e-4);
    vec3 N = dot(nT, V) < 0.0 ? -nT : nT;
    float NoV = saturate(dot(N, V));
    vec3 floorPlayer = screenToPlayer(vec3(texcoord, d1));
    vec3 color;
    // 水面の輝点の輝度。TAA (composite20) は輝点を近傍の箱で潰すので、割合を a = 1 + 割合で渡して TAA の後に足させる
    float glintLum = 0.0;

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
        float unresolvedVar = side ? waterFallUnresolvedSlopeVar(footprint) : waterUnresolvedSlopeVar(sea, footprint);
        // 上から見た上向きの水面だけ、画素より細かい波の粗さでフレネルと反射方向を均す (composite.csh と同じ)
        float roughVar = !below && N.y > 0.5 ? unresolvedVar : 0.0;
        float F = fresnelDielectric(waterRoughNoV(NoV, roughVar, dist), eta);
        vec3 refrDir = refract(-V, N, 1.0 / eta);
        if (dot(refrDir, refrDir) < 0.5) F = 1.0;
        /*
         * 側面の日向はスカイライトと雲影で近似する (影マップは滝の水柱自身の影に掛かり、PCSS のノイズが泡の白に出て砂嵐のようにざらついた)
         */
        vec3 sunSpecVis = vec3(0.0);
        vec3 sunVis = below ? vec3(0.0)
            : side ? vec3(smoothstep(0.6, 0.95, lmT.y)) * getCloudShadow(surfPlayer)
            : surfaceSunVisibility(surfPlayer, vec3(0.0, 1.0, 0.0), dither, sunSpecVis);
        if (side) sunSpecVis = sunVis;

        // 太陽以外の光: 手持ち光源 (内散乱・泡・鏡面) とブロックライトの鏡面 (光源ごとにトレース)。水中から見た面の裏は掛けない
        // 省く項: 太陽 (上で別に取る)・GI・AO・接触影 (水面の下に不透明面の深度しか無い)
        SurfacePoint wp = surfacePoint(surfPlayer, faceN);
        wp.lightmap = lmT;
        wp.texel = texel;
        wp.dither = dither;
        SurfaceLights WL = gatherSurfaceLights(wp, SL_SUN_NONE, SL_BLOCK_NONE, 0u);
        if (!below) WL = gatherSurfaceLights(wp, SL_SUN_NONE, SL_BLOCK_FORWARD, SL_HAND | SL_BLOCK_SPECULAR_TRACED);

        // 側面から入った光が水を出る所 (水の厚み)
        vec3 exitOutward = vec3(0.0);
        float exitDist = -1.0;
        // 面のすぐ内側 (水のセル)。深度の精度の分だけ遠いほど深く入れる
        vec3 insidePlayer = surfPlayer - faceN * (0.01 + dist * 0.002);
        if (!below && side && dot(refrDir, refrDir) > 0.5) exitDist = waterExitDistance(insidePlayer, refrDir, exitOutward);

        // 屈折
        vec2 refrUv = texcoord;
        float pathLen = d1 >= 1.0 ? WATER_SKY_PATH : distance(floorPlayer, surfPlayer);
        if (exitDist > 0.0) pathLen = min(pathLen, exitDist);
        vec3 behind = vec3(0.0);
        bool refrDone = false;  // 方式 D で屈折先の色と経路長が決まった
#if WATER_REFRACTION >= 1
        if (F < 1.0) {
            bool checkHeight = !below && N.y > 0.5;
            vec3 flatRefr = refract(-V, vec3(0.0, 1.0, 0.0), 1.0 / eta);
    #if WATER_REFRACTION_MODE == 2
            /*
             * 方式 D: 上から見た水面は屈折した向きそのもので水底を探す。平らな水面でも視線は水へ入ると下へ折れるので、
             * 水底は手前 (画面の下側) にずれて浅く見える。画面の像で見つかればその色、画面の外・手前の物の陰・岸の水面より上を
             * 指した時はボクセルで辿った水底 (waterRefractVoxel)。画面の端に近い屈折先はボクセルの色へ溶かす
             * 経路長は屈折した光線に沿った水底までの実際の長さ
             */
            if (checkHeight) {
                vec3 refrViewD = playerToViewDir(refrDir);
                vec2 sUv = texcoord;
                bool sValid = false;
        #if WATER_REFRACTION == 2
                vec4 hitD = traceScreenRay(surfView, refrViewD, WATER_REFRACT_D_DISTANCE, WATER_REFRACT_STEPS, dither);
                sValid = hitD.w > 0.5;
                sUv = hitD.xy;
        #else
                // 水底が平らだとして、まっすぐ見た水底の高さまで屈折した向きに進めて投影する (外れは下の光線との距離で落とす)
                float depthBelow = d1 >= 1.0 ? WATER_REFRACT_D_DISTANCE : max(surfPlayer.y - floorPlayer.y, 0.0);
                sUv = viewToScreen(surfView + refrViewD * min(depthBelow / max(-refrDir.y, 0.05), WATER_REFRACT_D_DISTANCE)).xy;
                sValid = true;
        #endif
                float sPath = WATER_SKY_PATH;
                if (sValid) sValid = refractionInWater(sUv, d0, surfPlayer.y, true);
                if (sValid) {
                    float ds = texture(depthtex1, sUv).r;
                    if (ds < 1.0) {
                        // 画面の点が屈折した光線の上にあるか (投影の平らな水底の仮定が外れた所・手前の物を拾わない)
                        vec3 rel = screenToPlayer(vec3(sUv, ds)) - surfPlayer;
                        float along = dot(rel, refrDir);
                        sValid = along > 0.0 && length(rel - refrDir * along) < WATER_REFRACT_D_MATCH * (1.0 + dist * 0.01);
                        sPath = length(rel);
                    }
                }
                float wS = sValid ? waterRefractScreenWeight(texcoord, sUv) : 0.0;
                vec3 vColor = vec3(0.0);
                float vPath = WATER_SKY_PATH;
                if (wS < 1.0 && waterRefractVoxel(surfPlayer, refrDir, floorPlayer, d1, lmT.y, vColor, vPath)) {
                    vec3 sColor = wS > 0.0 ? texture(colortex0, sUv).rgb : vec3(0.0);
                    behind = mix(vColor, sColor, wS);
                    pathLen = mix(vPath, sPath, wS);
                    refrDone = true;
                } else if (sValid) {
                    // ボクセルの範囲外 (遠景): 画面の像は 1 対 1 の対応なので端でも引き伸ばされない
                    behind = texture(colortex0, sUv).rgb;
                    pathLen = sPath;
                    refrDone = true;
                }
                // どちらも無ければ方式 A で写す
            }
    #endif
            if (!refrDone) {
                /*
                 * 方式 A: 上から見た水面は、波で曲がった分だけを画面へ写す。平らな水面でも視線は水へ入ると下へ折れ、水底は
                 * 画面の下側 (手前) へ大きくずれる。画面の下端ではそのずれが画面の外を指し、映っていない所を描けずに
                 * 端の画素を寄せ直した帯が引き伸ばされて縞に並ぶ。平らな水面の分 (見かけの浅さ) は落として水底を
                 * 見えている位置のまま波で歪ませ、吸収の経路長だけ屈折した向きの物理的な長さ (水深 / cos) で測る
                 * 方式 B: 屈折した向きそのままで写し、画面の端へ近いほどずれを弱める (softClampRefractUv)
                 * 水中から見上げた時 (スネルの窓) と側面の水は、どの方式でも屈折した向きそのもの
                 */
    #if WATER_REFRACTION_MODE == 1
                vec3 bendDir = refrDir;
    #else
                vec3 bendDir = checkHeight ? normalize(-V + (refrDir - flatRefr)) : refrDir;
    #endif
                vec3 refrView = playerToViewDir(bendDir);
                bool found = false;
    #if WATER_REFRACTION == 2
                // 水を出る所が分かった側面は下の板の近似で写す (屈折した向きのまま奥まで辿ると、薄い滝の向こうが厚い水のように大きくずれる)
                if (exitDist <= 0.0) {
                    vec4 hit = traceScreenRay(surfView, refrView, WATER_REFRACT_MAX_DISTANCE * 4.0, WATER_REFRACT_STEPS, dither);
                    if (hit.w > 0.5 && refractionInWater(hit.xy, d0, surfPlayer.y, checkHeight)) {
                        refrUv = hit.xy;
                        found = true;
                    }
                }
    #endif
                if (!found) {
                    // 曲げた向きは視線とほぼ同じなので、まっすぐ見た水底までの距離で投影する
                    float reach = checkHeight ? (d1 >= 1.0 ? WATER_SKY_PATH : distance(floorPlayer, surfPlayer)) : pathLen;
                    vec3 target = surfView + refrView * min(reach, WATER_REFRACT_MAX_DISTANCE);
                    if (exitDist > 0.0) {
                        /*
                         * 側面の水を出た光は出る面で空気へもう一度屈折する (板・柱の水)。平らな面同士なら視線と平行に戻り、
                         * 波で傾いた分だけ向きがずれる (薄いプリズム)。奥の物は出た所からその向きに、まっすぐ見た距離の残りだけ進めて写す
                         */
                        vec3 exitPos = surfPlayer + refrDir * exitDist;
                        vec3 exitDir = refract(refrDir, -exitOutward, WATER_IOR);
                        if (dot(exitDir, exitDir) < 0.5) exitDir = refrDir;
                        float rest = d1 >= 1.0 ? WATER_SKY_PATH : max(distance(floorPlayer, surfPlayer) - exitDist, 0.0);
                        target = playerToView(exitPos + exitDir * min(rest, WATER_REFRACT_MAX_DISTANCE));
                    }
                    // 画面の外は描けないので、ずれを画面の内側に収まるまで縮める (端の画素を引き伸ばさない)
    #if WATER_REFRACTION_MODE == 1
                    vec2 tuv = softClampRefractUv(texcoord, viewToScreen(target).xy);
    #else
                    vec2 tuv = clampRefractUv(texcoord, viewToScreen(target).xy);
    #endif
                    // 水の外を指したら元の画素の側へ寄せ直す (水際でも少しは歪み、岸の水面より上は拾わない)
                    for (int k = 0; k < WATER_REFRACT_RETRY; k++) {
                        if (refractionInWater(tuv, d0, surfPlayer.y, checkHeight)) {
                            refrUv = tuv;
                            break;
                        }
                        tuv = mix(texcoord, tuv, 0.5);
                    }
                }
                float dr = texture(depthtex1, refrUv).r;
                if (dr >= 1.0) {
                    pathLen = WATER_SKY_PATH;
                } else {
                    vec3 refrPlayer = screenToPlayer(vec3(refrUv, dr));
                    // 上から見た水面は、水底から水面まで屈折した向きに進む長さ (水深 / cos(屈折角))
                    pathLen = checkHeight ? max(surfPlayer.y - refrPlayer.y, 0.0) / max(-flatRefr.y, 0.05)
                        : distance(refrPlayer, surfPlayer);
                }
                if (exitDist > 0.0) pathLen = min(pathLen, exitDist);
            }
        }
#endif
        if (!refrDone) behind = texture(colortex0, refrUv).rgb;

        // 吸収と内散乱 (水の上から見た時だけ。水中側は sky のフォグ)
        if (!below) {
            vec3 ext = waterExtinction();
            vec3 T = exp(-ext * pathLen);
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
        refl = mirrorReflection(refl, surfView, surfPlayer, N, R0, dist, false, !below && !side, dither);
#else
        refl = below ? vec3(0.0) : skyReflectionFallback(R, lmT.y, 0.0);
#endif
        color = behind * (1.0 - F) + refl * F;
        if (!below) {
            float sunAlpha = sqrt(sqr(WATER_ROUGHNESS) + unresolvedVar);
            // 上向きの水面は照り返しの一部を輝点にする。輝点の傾きの分布は画素より細かい波の全部 (表面張力波を含む)
            float g = N.y > 0.5 ? WATER_GLINT * WATER_GLINT_POINT_SHARE : 0.0;
            color += sunSpecular(N, V, 0.02, sunAlpha, sunSpecVis) * (1.0 - g);
            color += localLightSpecular(WL, N, V, 0.02, sunAlpha);
            if (g > 0.0) {
                float glintVar = unresolvedVar + sea.microVar * (1.0 - WATER_MICRO_ROUGHNESS);
                vec4 glint = sunGlint(surfPlayer, N, V, glintVar, sunSpecVis, dist, NoVGeo);
                color += glint.rgb * g;
                glintLum = glint.a * g;
            }

            // 上向きの面だけ: 長い 3 層の高さと Jacobian (波頭の透過光と泡)。視差の位置ずれは長い波では画素未満
            if (N.y > 0.5) {
                vec3 surfWorld = surfPlayer + cameraPosition;
                vec4 waves = waterWaveSum(sea, surfWorld.xz, 0, 3, footprint);
                float crest = smoothstep(0.0, 2.0 * sea.heightRms, waves.x);
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
        vec3 behind = texture(colortex0, refrUv).rgb;
        if (d1 < 1.0) behind += opaqueEnvSpecular(texel, d1);
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
        float glassAlpha = max(roughness * roughness, WATER_ROUGHNESS);
        // 前方で照らした拡散 (translucent.rgb) は鏡面で反射する F の分を除く (太陽の鏡面を足すので、その分だけ明るくならないように)
        color = behind * transmit * (1.0 - F) + translucent.rgb * (1.0 - F) + refl * F
            + sunSpecular(N, V, 0.04, glassAlpha, glassSunVis) + localLightSpecular(GL, N, V, 0.04, glassAlpha);
        outColor = vec4(color, 1.0);
        return;
    }

    // 水の上に重なった物 (WATER_TEXTURE の水テクスチャ・パーティクル・雨) を重ねる
    vec3 result = color * (1.0 - translucent.a) + translucent.rgb;
    float glintShare = saturate(glintLum * (1.0 - translucent.a) / max(luminance(result), 1e-6));
    outColor = vec4(result, 1.0 + glintShare);
}