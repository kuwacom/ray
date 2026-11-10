/*
 * composite1: 水面の光線を辿る部分。屈折先の色と水の中の経路長 (colortex18 / colortex19)、上向きの水面の太陽の可視率
 * (colortex19 / colortex21)、鏡面の映り込みのフル解像度の SSR (colortex20) を書き、半透明の合成 (composite2) が読む
 * surface モジュール (lib/surface)
 *
 * 屈折 (WATER_REFRACTION 1 = 屈折方向に水深分進めて投影 + 深度検証, 2 = 屈折方向のレイマーチ)
 * 上から見た水面の屈折の方式 (WATER_REFRACTION_MODE): A = 波で曲がった分だけ / B = 屈折のまま画面の端で弱める /
 * D = 屈折のまま、画面に無い屈折先はボクセルで辿る (水底が浅く見える)
 * 側面 (滝・水槽): 水の厚みはボクセルで水を出る所まで / 出る面で空気へもう一度屈折
 *
 * 合成と別のパスにするのは、光線を辿る処理と影は深度の読みを待つ時間が長く、同時に動くワープの数で速さが決まるため。
 * 合成のシェーダーに入ると、レジスタの数が合成の重い経路 (影・きらめき・光源のトレース) で決まってワープが減り、
 * 水の画素の全部の処理が何倍も遅くなっていた
 * 水でない画素は書かない (合成は水の画素でだけ読む)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/surface/surface.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/common/water_normal.glsl"
//@include "/lib/surface/screen_trace.glsl"
//@include "/lib/surface/reflection.glsl"
//@include "/lib/surface/composite_specular.glsl"
//@include "/lib/surface/water_shading.glsl"
//@include "/lib/surface/water_self.glsl"
//@include "/lib/light/entity_tri.glsl"
//@include "/lib/light/hand_light.glsl"
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
#include "/lib/common/water_lod.glsl"
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
#include "/lib/common/celestial_shape.glsl"
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
#include "/lib/common/joint_bilateral.glsl"
#include "/lib/surface/surface_lights.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/reflection.glsl"
#include "/lib/surface/composite_specular.glsl"
#include "/lib/common/exposure.glsl"
#include "/lib/surface/water_shading.glsl"
#include "/lib/surface/water_self.glsl"
// END GENERATED includes

#if REFLECTIONS > 0
/* RENDERTARGETS: 18,19,21,20 */
#else
/* RENDERTARGETS: 18,19,21 */
#endif
layout(location = 0) out vec4 outRefraction;
layout(location = 1) out vec4 outSunExcess;
layout(location = 2) out vec4 outSunVis;
#if REFLECTIONS > 0
layout(location = 3) out vec4 outMirror;
#endif

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float d0 = texelFetch(depthtex0, texel, 0).r;
    float d1 = texelFetch(depthtex1, texel, 0).r;
    vec3 nT;
    vec2 lmT;
    int matT;
    decodeTranslucentData(texelFetch(colortex5, texel, 0), nT, lmT, matT);
    if (!(d0 < d1 && !isHandDepth(d0) && matT == MAT_WATER)) discard;
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec3 surfView = screenToView(vec3(texcoord, d0));
    vec3 surfPlayer = viewToPlayer(surfView);
    float dist = length(surfPlayer);
    vec3 V = -surfPlayer / max(dist, 1e-4);
    // 表裏は合成 (composite2) と同じく面の向きで決める
    vec3 faceRef = abs(nT.y) >= 0.5 ? vec3(0.0, sign(nT.y), 0.0) : waterSideFaceNormal(nT);
    vec3 N = dot(faceRef, V) < 0.0 ? -nT : nT;
    vec3 floorPlayer = screenToPlayer(vec3(texcoord, d1));
    bool below = isEyeInWater == 1;
    float eta = below ? 1.0 / WATER_IOR : WATER_IOR;
    bool side = abs(N.y) < 0.5;
    vec3 faceN = side ? waterSideFaceNormal(N) : vec3(0.0, 1.0, 0.0);
    vec3 refrDir = refract(-V, N, 1.0 / eta);
    bool refracts = dot(refrDir, refrDir) > 0.5;

    // 側面から入った光が水を出る所 (水の厚み)
    vec3 exitOutward = vec3(0.0);
    float exitDist = -1.0;
    // 面のすぐ内側 (水のセル)。深度の精度の分だけ遠いほど深く入れる
    vec3 insidePlayer = surfPlayer - faceN * (0.01 + dist * 0.002);
    if (!below && side && refracts) exitDist = waterExitDistance(insidePlayer, refrDir, exitOutward);

    vec2 refrUv = texcoord;
    float pathLen = d1 >= 1.0 ? WATER_SKY_PATH : distance(floorPlayer, surfPlayer);
    if (exitDist > 0.0) pathLen = min(pathLen, exitDist);
    vec3 behind = vec3(0.0);
    float behindExcess = 0.0;  // 屈折の先の白飛び分の輝度 (ボクセルで辿った水底は持たない)
    bool refrDone = false;  // 方式 D で屈折先の色と経路長が決まった
#if WATER_REFRACTION >= 1
    /*
     * 全反射 (屈折の向きが無い) の画素は合成でフレネルが 1 になり屈折先を使わない。合成はフレネルが 1 の画素の屈折先を
     * 読まないので、ここでは屈折の向きがあれば求める
     */
    if (refracts) {
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
                vec4 sColor = wS > 0.0 ? texture(colortex0, sUv) : vec4(0.0);
                behind = mix(vColor, sColor.rgb, wS);
                behindExcess = behindSparkle(sColor) * wS;
                pathLen = mix(vPath, sPath, wS);
                refrDone = true;
            } else if (sValid) {
                // ボクセルの範囲外 (遠景): 画面の像は 1 対 1 の対応なので端でも引き伸ばされない
                vec4 sColor = texture(colortex0, sUv);
                behind = sColor.rgb;
                behindExcess = behindSparkle(sColor);
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
    if (!refrDone) {
        vec4 sColor = texture(colortex0, refrUv);
        behind = sColor.rgb;
        behindExcess = behindSparkle(sColor);
    }
#ifdef WATER_SELF_REFRACTION
    /*
     * 水に入った自分 (lib/surface/water_self.glsl): 屈折した視線を、影のパスで毎フレーム持っている自分の三角形に当てる
     * 自分の水の中の画素は gbuffers_entities_translucent が捨てるので、ここで水底の代わりに描く。色は三角形ごとの平均のアルベドを
     * 当たった点で照らしたもの (水の中の太陽の影・コースティクス・空)。体を描かない一人称では当てない
     * カメラが水の中の時は、水面の上へ屈折した視線を水面より上の体 (半透明の層が捨てた所) に当てる。全反射の画素は
     * 反射した視線を水の中の体に当て、鏡面の映り込み (colortex20) に重ねる (画面の像に体が無く、SSR では映らない)
     */
    #if REFLECTIONS > 0
    bool selfMirror = below && !refracts;
    #else
    const bool selfMirror = false;
    #endif
    vec3 selfColor = vec3(0.0);
    float selfT = -1.0;
    if ((refracts || selfMirror) && !firstPersonCamera) {
        vec3 selfDir = selfMirror ? reflect(-V, N) : refrDir;
        vec3 eye = getEyePlayerPos();
        vec3 boxT0 = (eye + WATER_SELF_BOX_LO - surfPlayer) / selfDir;
        vec3 boxT1 = (eye + WATER_SELF_BOX_HI - surfPlayer) / selfDir;
        float reach = selfMirror ? WATER_SELF_TRACE_MAX : min(pathLen, WATER_SELF_TRACE_MAX);
        if (max(maxOf(min(boxT0, boxT1)), 0.0) <= min(minOf(max(boxT0, boxT1)), reach)) {
            float tHit;
            uint tri = traceEntityTrianglesClosest(playerToVoxel(surfPlayer), selfDir, 0.0, reach, 0, tHit);
            vec3 hitPlayer = surfPlayer + selfDir * tHit;
            /*
             * 半透明の層が捨てた所だけ描く (同じ判定。捨てずに残した体と二重にならない)
             * 全反射は水面から下へ戻った視線なので、当たるのは水の中の体だけ (判定は要らない)
             */
            bool drawn = selfMirror || (below ? waterSelfHeight(hitPlayer) > 0.0 : waterSelfDepth(hitPlayer) > 0.0);
            if (tri != ENTITY_TRI_NONE && drawn) {
                vec3 n = entityTriNormal(tri);
                selfColor = shadeSecondaryHit(hitPlayer, dot(n, selfDir) > 0.0 ? -n : n, entityTriAlbedo(tri), lmT.y);
                selfT = tHit;
            }
        }
    }
    if (selfT >= 0.0 && !selfMirror) {
        behind = selfColor;
        behindExcess = 0.0;
        // 水の中から見上げた時の経路長は合成で使わない (水の中の霧は sky のフォグが水面まで掛ける)
        pathLen = selfT;
    }
#endif
    outRefraction = vec4(behind, pathLen);

    /*
     * 上から見た上向きの水面の太陽の可視率 (影の PCSS + 雲影)。PCSS も影マップの読みを待つ処理なので、合成ではなくここで求める
     * rgb = 内散乱・泡・波頭の透過光に使う可視率, 太陽の照り返しに使う分 (葉を透過した分を除く) は colortex19 の rgb
     * 側面と水中から見た面は合成が近似で決める
     */
    vec3 sunSpecVis = vec3(0.0);
    vec3 sunVis = vec3(0.0);
    if (!below && !side) sunVis = surfaceSunVisibility(surfPlayer, vec3(0.0, 1.0, 0.0), dither, sunSpecVis);
    outSunExcess = vec4(sunSpecVis, behindExcess);
    outSunVis = vec4(sunVis, 0.0);

#if REFLECTIONS > 0
    /*
     * 鏡面の物の映り込みのフル解像度の SSR (composite.csh の半分の解像度の結果を合成が引き伸ばすと、映り込みの輪郭が
     * ぼけて角張る)。反射方向は合成と同じ (下向きの反射は上向きの水面で平均水面にもう一度反射させる)
     * 当たりの色に画面端の重みを掛けた rgb と重み a を書き、合成が半分の解像度の反射に a で重ねる
     */
    // 画素より細かい波で映り込みを散らす水面は、半分の解像度の粗い反射 (reflection_trace.csh) だけを使う (鏡との境は重みで混ぜる)
    outMirror = vec4(0.0);
    float mirrorW = !below && !side && N.y > 0.5 ? waterLod(waterSeaState(lmT.y), dist, abs(V.y)).mirror : 1.0;
    if (mirrorW > 0.0) {
        vec3 R0 = reflect(-V, below ? N : waterReflectNormal(N, V));
        if (!below && !side) R0.y = abs(R0.y);
        vec4 hit = traceReflectionHit(surfView, surfPlayer, N, R0, dist, mirrorTraceDistance(), false, !below && !side, dither);
        if (hit.w > 0.5) outMirror = vec4(reflectionHitRadiance(hit.xy), 1.0) * (hit.z * mirrorW);
    #ifdef WATER_SELF_REFRACTION
        // 水面の裏に映る自分。SSR の当たりが体より手前ならそちら (体と水面の間の壁)
        if (selfT >= 0.0 && selfMirror) {
            bool nearer = hit.w < 0.5 || distance(screenToPlayer(vec3(hit.xy, texture(depthtex1, hit.xy).r)), surfPlayer) > selfT;
            if (nearer) outMirror = vec4(selfColor, 1.0);
        }
    #endif
    }
#endif
}
