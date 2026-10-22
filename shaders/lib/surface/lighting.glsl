/*
 * 二次光線のヒット点の照明と空のフォールバック (surface モジュール)
 * GI (deferred10)・反射 (composite)・半透明合成 (composite1) で共有する
 * 依存: lib/sky/sky.glsl (B), lib/light/light.glsl (A) を先に include すること
 */
#ifndef SURFACE_LIGHTING_GLSL
#define SURFACE_LIGHTING_GLSL

// ボクセルのヒット面の色が画面に無い時の代わりのアルベド (Minecraft の地形の平均的な反射率)
const float VOXEL_HIT_ALBEDO = 0.3;

/*
 * 二次光線が当たった面の外向き放射輝度 (拡散のみ)
 * 太陽 (1 タップの色付き影 + 雲影) + floodfill + 空 (スカイライト)
 */
vec3 shadeSecondaryHit(vec3 playerPos, vec3 normal, vec3 albedo, float skyLm) {
    LightSample sun = getCelestialLight();
    float NoL = saturate(dot(normal, sun.direction));
    vec3 E = vec3(0.0);
    if (NoL > 0.0) {
        E += sun.irradiance * NoL * sampleShadowVolume(playerPos + normal * 0.08) * getCloudShadow(playerPos);
    }
    E += sampleFloodfill(playerPos, normal);
    E += getSkyIrradiance(normal) * skylightCurve(skyLm);
    return albedo * RCP_PI * E;
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
const float SECONDARY_BLOCKLIGHT_GAIN = 1.5;

vec3 secondaryHitBlockLight(vec3 playerPos, vec3 normal, ivec2 screenTexel) {
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
        E += lightEmission(d, float(level)) * lightFalloff(dist, range) * (ndl * HAND_LIGHT_BRIGHTNESS);
    }
    #endif
    return E;
#else
    return vec3(0.0);
#endif
}

/*
 * 反射が何にも当たらなかった時の空 (太陽円盤なし)
 * 下向きの反射は地面に遮られる (Kappa の horizon 減衰)、スカイライトの低い所は空を映さない
 * 粗い面ほど空の SH (余弦畳み込み) に寄せて反射をぼかす
 */
vec3 skyReflectionFallback(vec3 dir, float skyLm, float perceptualRoughness) {
#ifdef HAS_SKY
    float horizon = exp(-max(-dir.y, 0.0) * 1.77);
    vec3 sharp = getSkyRadiance(dir);
    vec3 blurry = getSkyIrradiance(dir) * RCP_PI;
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
    if (isInVoxelVolume(c) && isVoxelOpaque(unpackVoxelBlockId(texelFetch(voxelBlockSampler, c, 0).r))) {
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
    vec3 albedo = vec3(VOXEL_HIT_ALBEDO);
    ivec2 screenTexel = ivec2(-1);
    vec3 s = viewToScreen(playerToView(hitPlayer));
    if (all(greaterThan(s.xy, vec2(0.0))) && all(lessThan(s.xy, vec2(1.0))) && s.z > 0.0 && s.z < 1.0) {
        ivec2 t = ivec2(s.xy * viewSize());
        float d = texelFetch(depthtex1, t, 0).r;
        vec3 scenePlayer = screenToPlayer(vec3(s.xy, d));
        if (distance(scenePlayer, hitPlayer) < VOXEL_TRACE_SCREEN_MATCH) {
            if (useSceneColor) return vec4(texelFetch(colortex0, t, 0).rgb, 1.0);
            albedo = srgbToLinear(texelFetch(colortex1, t, 0).rgb);
            screenTexel = t;
        }
    }
    // useSceneColor = false は GI (多重反射の補い込み)、true は反射
    vec3 E = secondaryHitBlockLight(hitPlayer, hitNormal, screenTexel) * (useSceneColor ? 1.0 : SECONDARY_BLOCKLIGHT_GAIN);
    return vec4(shadeSecondaryHit(hitPlayer, hitNormal, albedo, skyLm) + albedo * RCP_PI * E, 1.0);
}

#endif
