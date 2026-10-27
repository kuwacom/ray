/*
 * 二次光線のヒット点の照明と空のフォールバック (surface モジュール)
 * GI (deferred10)・反射 (composite)・半透明合成 (composite1) で共有する
 * 依存: lib/sky/sky.glsl (B), lib/light/light.glsl (A) を先に include すること
 */
#ifndef SURFACE_LIGHTING_GLSL
#define SURFACE_LIGHTING_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/surface_lights.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"

/*
 * ボクセルのヒット面の色が画面に無い時は、ブロックの平均の色の表 (lib/ids/block_albedo.glsl) を使う
 * 一定の灰色 (線形 0.3) では、色の付いた壁の照り返しや反射の色が画面の外で抜ける。表に無いブロックはこの灰色になる
 */

/*
 * 二次光線が当たった面の外向き放射輝度 (拡散のみ)
 * 太陽 (1 タップの色付き影 + 雲影) + floodfill + 空 (スカイライト)
 */
vec3 secondaryHitDirect(vec3 playerPos, vec3 normal) {
    // 省く項: 手持ち光源と直接光 (secondaryHitBlockLight が別に返す)、GI と AO と鏡面 (拡散の放射輝度だけ)
    SurfaceLights L = gatherSurfaceLights(surfacePoint(playerPos, normal), SL_SUN_VOLUME, SL_BLOCK_HIT_FLOOD, 0u);
    return L.sun.irradiance + L.block;
}

// ヒット点の空の拡散照度 (スカイライトの絞り込み)
vec3 secondaryHitSky(vec3 playerPos, vec3 normal, float skyLm) {
    SurfacePoint p = surfacePoint(playerPos, normal);
    p.lightmap.y = skyLm;
    return gatherSurfaceLights(p, SL_SUN_NONE, SL_BLOCK_NONE, SL_SKY).sky;
}

vec3 shadeSecondaryHit(vec3 playerPos, vec3 normal, vec3 albedo, float skyLm) {
    SurfacePoint p = surfacePoint(playerPos, normal);
    p.lightmap.y = skyLm;
    SurfaceLights L = gatherSurfaceLights(p, SL_SUN_VOLUME, SL_BLOCK_HIT_FLOOD, SL_SKY);
    return albedo * RCP_PI * (L.sun.irradiance + L.block + L.sky);
}

/*
 * 多重反射: GI のヒット点の間接光に前フレームの GI (colortex9 = deferred11 の履歴) を使う。
 * 1 フレームのレイは増やさず、フレームを重ねるごとに反射が 1 回ずつ増える (Lambert の多重反射の等比級数に収束する)
 * - 画面に映るヒット点だけ。映らない点は空の SH のまま (着色点の履歴で代用すると、地面を向く面のレイが当たる地面まで
 *   その面と同じ暗さになり、軒下が 0.6 倍まで暗くなる。面の向きが違うと代用にならない)
 * - 履歴は GI_STRENGTH 込み (GI_EFFECTIVE_STRENGTH) なので割ってから返す (返す量 x 反射率 < 1 で発散しない)
 * - GI_TRACES_SKY では履歴に空の光も入っているので、ヒット点の空の SH (方向の無い空の光) を履歴で置き換える。
 *   GI_SKY_OCCLUSION < 1 の時に deferred30 が空の環境光として足す分は履歴に入っていないので、その割合の SH を足す
 * 履歴の無い点 (画面外・前フレームの画面外) は prevIndirect.x < 0 で、空の SH のまま
 */
vec3 shadeSecondaryHitGi(vec3 playerPos, vec3 normal, vec3 albedo, float skyLm, vec3 prevIndirect) {
    vec3 sky = secondaryHitSky(playerPos, normal, skyLm);
    vec3 E = secondaryHitDirect(playerPos, normal);
    if (prevIndirect.x >= 0.0) {
#ifdef GI_TRACES_SKY
        E += mix(sky, prevIndirect + sky * (1.0 - LOOK_GI_SKY_OCCLUSION), GI_MULTI_BOUNCE);
#else
        E += sky + prevIndirect * GI_MULTI_BOUNCE;
#endif
    } else {
        E += sky;
    }
    return albedo * RCP_PI * E;
}

// GI の履歴 (照度, GI_STRENGTH を外した値)。前フレームの画面の外なら x = -1
const float GI_HISTORY_EDGE = 0.002;
vec3 giHistoryAtPlayer(vec3 playerPos) {
    vec2 uv = playerToPrevScreen(playerPos).xy;
    if (any(lessThan(uv, vec2(GI_HISTORY_EDGE))) || any(greaterThan(uv, vec2(1.0 - GI_HISTORY_EDGE)))) return vec3(-1.0);
    return textureLod(colortex9, uv, 0.0).rgb / max(GI_EFFECTIVE_STRENGTH * LK_GI_BOUNCE, 1e-3);
}

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
 * まとめて SECONDARY_BLOCKLIGHT_GAIN で補う (GI だけ。反射に映る面は直接光そのまま)
 */
// 多重反射 (GI_MULTI_BOUNCE) を入れた分は本物の多重反射が受け持つので、補いを 1 へ戻す
const float SECONDARY_BLOCKLIGHT_GAIN = 1.5 - 0.5 * GI_MULTI_BOUNCE;

/*
 * handScale: 手持ち光の分に掛ける倍率。GI では handLightIndirectScale() (HAND_LIGHT_SHADOW_STRENGTH) を渡す
 * GI_MODE 2/3 では手持ち光の陰の中の明るさの半分ほどがこの GI の照り返しで、残りが getHandLightFill なので、両方に同じ倍率を掛ける
 * 反射に映る面は照り返しではなく直接見える面なので 1 を渡す
 */
vec3 secondaryHitBlockLight(vec3 playerPos, vec3 normal, ivec2 screenTexel, float handScale) {
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

/*
 * 2 次ヒット点の発光 (albedo に掛ける放射輝度)。GI のレイが光源として拾う
 * 登録した光源 (たいまつ・グロウストーンなど) の光は着色点の直接光 (colortex6) と floodfill が数えているので除く
 * 溶岩は直接光を水平に間引いて登録している (deferred.csh) ので表面の発光を残す
 * 登録していない発光 (labPBR の発光、鉱物ブロック DECORATIVE_BLOCK_LIGHTS = 1、溶岩) は GI の方式によらず足す
 */
bool isRegisteredLightHit(int voxelId, int materialId) {
    if (materialId == MAT_EMISSIVE_ENTITY || materialId == MAT_HAND_EMISSIVE || materialId == MAT_LIGHTNING) return true;
    int light = getBlockLightIndex(voxelId);
    return light != LIGHT_NONE && (getLightDef(light).info.x & LIGHT_FLAG_FLUID) == 0u;
}

float secondaryHitEmission(float emission, int voxelId, int materialId) {
    if (emission <= 0.0 || isRegisteredLightHit(voxelId, materialId)) return 0.0;
    return emission * EMISSION_LUMINANCE * EMISSION_STRENGTH;
}

// 画面に映ったヒット点 (G バッファ h) の発光。ヒット点が属するボクセルは面から少し内側のセル
const float VOXEL_HIT_INSET = 0.05;
float screenHitEmission(GBufferData h, vec3 hitPlayer) {
    if (h.emission <= 0.0) return 0.0;
    int voxelId = unpackVoxelBlockId(readVoxelBlock(ivec3(floor(playerToVoxel(hitPlayer - h.geoNormal * VOXEL_HIT_INSET)))));
    return secondaryHitEmission(h.emission, voxelId, h.materialId);
}

// 画面に映らないボクセルのヒットで分かる登録外の発光は溶岩だけ (G バッファの推定値 0.12-0.3 の中ほど)
const float LAVA_HIT_EMISSION = 0.2;

/*
 * 反射が何にも当たらなかった時の空 (太陽円盤なし)
 * 下向きの反射は地面に遮られる (Kappa の horizon 減衰)、スカイライトの低い所は空を映さない
 * 粗い面ほど空の SH (余弦畳み込み) に寄せて反射をぼかす
 */
vec3 skyReflectionFallback(vec3 dir, float skyLm, float perceptualRoughness) {
#ifdef HAS_SKY
    float horizon = exp(-max(-dir.y, 0.0) * 1.77);
    vec3 sharp = getSkyRadiance(dir);
    // 反射の空は照度ではなく放射輝度なので gatherSurfaceLights では集めない
    vec3 blurry = getSkyIrradiance(dir) * (RCP_PI * SH_LOOK_UNDO);
    vec3 sky = mix(sharp, blurry, saturate(perceptualRoughness * 1.5));
    return sky * horizon * skylightCurve(skyLm);
#else
    return getSkyRadiance(dir) * 0.5;
#endif
}

/*
 * ボクセル空間で反射・GI のレイを飛ばしたヒット点の色 (REFLECTIONS=3, GI_MODE=3)
 * ヒット点が画面に映っていればその色 (照明済みのシーン色) を使い、無ければ代わりのアルベドで照らす
 * 戻り値 a = 1 ならヒット
 */
const float VOXEL_TRACE_SCREEN_MATCH = 0.6; // 画面の深度とヒット点の距離がこれ以下なら同じ面とみなす (ブロック)
const float VOXEL_RAY_OFFSET = 0.05;        // 面から法線方向に浮かせる量 (ブロック)
const float VOXEL_RAY_OFFSET_DIST = 0.01;   // 距離 1 ブロックあたりの追加量 (深度から復元した位置とジッターの誤差が距離に比例するため)
const float VOXEL_RAY_FACE_EPS = 0.01;      // 固体セルから押し出した時の面からの距離 (ブロック)

/*
 * ボクセルのレイの始点 (player 空間)。面から少し浮かせ、それでも固体セルの中なら法線の主軸方向に隣のセルへ押し出す
 * 深度から復元した位置は遠いほど面からずれる。traceVoxelRay は開始セルを判定しないので、浮かせ方が足りないと
 * ブロックの境目でだけ隣の床に当たり、床に格子状の明るい線が出る (EXTREME の GI_MODE=3 で観察)
 */
vec3 voxelRayOrigin(vec3 playerPos, vec3 geoNormal) {
    vec3 v = playerToVoxel(playerPos + geoNormal * (VOXEL_RAY_OFFSET + VOXEL_RAY_OFFSET_DIST * length(playerPos)));
    ivec3 c = ivec3(floor(v));
    if (isInVoxelVolume(c) && isVoxelOpaque(fetchVoxelBlockId(c))) {
        vec3 a = abs(geoNormal);
        int axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2);
        v[axis] = geoNormal[axis] > 0.0 ? float(c[axis]) + 1.0 + VOXEL_RAY_FACE_EPS : float(c[axis]) - VOXEL_RAY_FACE_EPS;
    }
    return voxelToPlayer(v);
}

vec4 traceVoxelRadiance(vec3 originPlayer, vec3 dir, float maxDist, float skyLm, bool useSceneColor) {
    vec3 hitVoxel, hitNormal;
    int hitBlock;
    if (!traceVoxelRay(playerToVoxel(originPlayer), dir, maxDist, hitVoxel, hitNormal, hitBlock)) return vec4(0.0);
    vec3 hitPlayer = voxelToPlayer(hitVoxel);
    vec3 albedo = getBlockAlbedo(hitBlock, hitNormal);
    ivec2 screenTexel = ivec2(-1);
    float emission = getBlockLightIndex(hitBlock) == LIGHT_LAVA ? LAVA_HIT_EMISSION : 0.0;
    int hitMaterial = MAT_TERRAIN;
    vec3 s = viewToScreen(playerToView(hitPlayer));
    if (all(greaterThan(s.xy, vec2(0.0))) && all(lessThan(s.xy, vec2(1.0))) && s.z > 0.0 && s.z < 1.0) {
        ivec2 t = ivec2(s.xy * viewSize());
        float d = texelFetch(depthtex1, t, 0).r;
        vec3 scenePlayer = screenToPlayer(vec3(s.xy, d));
        if (distance(scenePlayer, hitPlayer) < VOXEL_TRACE_SCREEN_MATCH) {
            if (useSceneColor) return vec4(texelFetch(colortex0, t, 0).rgb, 1.0);
            albedo = srgbToLinear(texelFetch(colortex1, t, 0).rgb);
            // 空の光は当たった面のスカイライトで絞る (着色点のスカイライトだと、明るい屋外から洞窟の奥の壁に当たったレイが空に照らされる)。
            // 画面外の当たりは分からないので着色点の値のまま
            skyLm = unpack2x8(texelFetch(colortex2, t, 0).a).y;
            screenTexel = t;
            emission = unpack2x8(texelFetch(colortex3, t, 0).g).y;
            hitMaterial = readMaterialId(t);
        }
    }
    // useSceneColor = false は GI (多重反射込み)、true は反射
    if (useSceneColor) {
        vec3 E = secondaryHitBlockLight(hitPlayer, hitNormal, screenTexel, 1.0);
        return vec4(shadeSecondaryHit(hitPlayer, hitNormal, albedo, skyLm) + albedo * RCP_PI * E
            + albedo * secondaryHitEmission(emission, hitBlock, hitMaterial), 1.0);
    }
    vec3 E = secondaryHitBlockLight(hitPlayer, hitNormal, screenTexel, handLightIndirectScale()) * SECONDARY_BLOCKLIGHT_GAIN;
    vec3 prev = GI_MULTI_BOUNCE > 0.0 && screenTexel.x >= 0 ? giHistoryAtPlayer(hitPlayer) : vec3(-1.0);
    return vec4(shadeSecondaryHitGi(hitPlayer, hitNormal, albedo, skyLm, prev) + albedo * RCP_PI * E
        + albedo * secondaryHitEmission(emission, hitBlock, hitMaterial), 1.0);
}

#endif
