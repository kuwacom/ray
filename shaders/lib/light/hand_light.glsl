/*
 * 手持ち光源 (light モジュール)
 * 両手を独立に扱う (shaders.properties の oldHandLight=false が前提)
 * 色は heldItemId -> 光源テーブル、強さは heldBlockLightValue (0-15)
 *
 * カメラと一緒に動くので時間蓄積のデノイズ (deferred2) には乗せず、ピクセルごとに直接計算する
 * 影: HAND_LIGHT_RAYS = ボクセル DDA (壁・ブロック・他のエンティティ。一人称では自分の体は無視、
 *     三人称では自分の体で遮る)
 *     HAND_LIGHT_SS_SHADOWS = 深度バッファの短いレイ (手の届く範囲の小物・モブ・三人称の自分の体)
 * 半影は終点を dither で揺らし TAA で均す
 */
#ifndef LIGHT_HAND_LIGHT_GLSL
#define LIGHT_HAND_LIGHT_GLSL

// 一人称のカメラから見た手の位置 (view 空間, ブロック)
// 目から離すほど段差の縁の影 (黒い楔) と、両手持ちで片方の影にだけ乗る色の帯が太く見えるので画面の手より内側に置く
const vec3 HAND_OFFSET_VIEW = vec3(0.2, -0.18, -0.3);
// 三人称の手の位置: 目からの下がり幅, 体の中心からの横幅, 前へのずれ (ブロック)
const float HAND_THIRD_PERSON_DROP = 0.75;
const float HAND_THIRD_PERSON_SIDE = 0.38;
const float HAND_THIRD_PERSON_FORWARD = 0.15;
// 画面空間の影のレイ長とステップ数
const float HAND_SS_LENGTH = 4.0;
const int HAND_SS_STEPS = 12;
// 一人称で手そのもの (カメラの直近) を受光面とみなす距離。ここでは影を計算しない
const float HAND_SELF_DIST = 0.9;
// 三人称で手の光源から自分の体の遮蔽を無視する距離 (ブロック)。腕は外し、胴 (手から 0.1-0.7) の奥側で遮る
// サブセル (0.5 ブロック) は実際の胴より太いので、短くすると影が実物より大きくなる
const float HAND_THIRD_PERSON_SELF_SKIP = 0.45;
// 三角形方式で手の光源から自分の三角形を無視する距離 (光源を持つ手と腕の先)。形どおりなのでボクセルより短くてよい
const float HAND_TRI_SELF_SKIP = 0.3;

// プレイヤーの目の位置 (player 空間)。relativeEyePosition = cameraPosition - eyePosition
vec3 getEyePlayerPos() { return -relativeEyePosition; }

// 体のモデル (shadow パス・三人称) で光源を持つ手の位置 (player 空間)
vec3 getBodyHandPosition(bool mainHand) {
    float side = (mainHand == isRightHanded) ? 1.0 : -1.0;
    // 体の向き (水平) から右手方向を作る。MC の座標系 (x 東, z 南) で右 = (-f.z, 0, f.x)
    vec3 body = vec3(playerBodyVector.x, 0.0, playerBodyVector.z);
    if (dot(body, body) < 1e-4) body = vec3(playerLookVector.x, 0.0, playerLookVector.z);
    body = dot(body, body) > 1e-4 ? normalize(body) : vec3(0.0, 0.0, 1.0);
    vec3 right = vec3(-body.z, 0.0, body.x);
    return getEyePlayerPos() + vec3(0.0, -HAND_THIRD_PERSON_DROP, 0.0)
        + right * (side * HAND_THIRD_PERSON_SIDE) + body * HAND_THIRD_PERSON_FORWARD;
}

/*
 * 光る物を持つ手 (体のモデル) の近くか。p は player 空間
 * 手持ちのランタンは影パスでエンティティ ID (entityId <= 0) も光るアイテムの ID も付かずに描かれる (たいまつ・グロウストーンでは起きない)。
 * ほかのエンティティの三角形として手持ち光の遮蔽物になり、一人称でランタン自身の影が床や壁に出ていた。
 * shadow_entities.gsh がこの範囲の ID の無い三角形を外す。ランタンのモデルはこの手の位置から 0.6 より離れた所まであるので 1.2 (実機で確認)
 */
const float HAND_HELD_ITEM_RADIUS = 1.2;

bool isNearLitHand(vec3 p) {
    if (heldBlockLightValue > 0 && distance(p, getBodyHandPosition(true)) < HAND_HELD_ITEM_RADIUS) return true;
    return heldBlockLightValue2 > 0 && distance(p, getBodyHandPosition(false)) < HAND_HELD_ITEM_RADIUS;
}

// 手の光源位置 (player 空間)。mainHand=false でオフハンド
vec3 getHandLightPosition(bool mainHand) {
    if (firstPersonCamera) {
        float side = (mainHand == isRightHanded) ? 1.0 : -1.0;
        return viewToPlayerDir(HAND_OFFSET_VIEW * vec3(side, 1.0, 1.0));
    }
    return getBodyHandPosition(mainHand);
}

/*
 * 壁に張り付いた時に光源位置が固体ブロックの中へ入ると、壁の向こう側へ光が漏れる
 * その場合は目 (必ず空気中) の位置へ引き戻す
 */
vec3 getHandLightPositionSafe(bool mainHand) {
    vec3 p = getHandLightPosition(mainHand);
    ivec3 cell = playerToVoxelCell(p);
    if (isInVoxelVolume(cell) && isVoxelOpaque(unpackVoxelBlockId(texelFetch(voxelBlockSampler, cell, 0).r))) {
        p = firstPersonCamera ? vec3(0.0) : getEyePlayerPos();
    }
    return p;
}


// 持っているアイテムの光源定義。テーブルにない発光アイテム (MOD 等) は中性の炎色
LightDef getHandLightDef(int itemId) {
    int index = getItemLightIndex(itemId);
    if (index != LIGHT_NONE) return getLightDef(index);
    return getLightDef(LIGHT_TORCH);
}

LightSample evalHandLight(bool mainHand, vec3 playerPos, vec3 geoNormal, float dither) {
    int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
    if (level <= 0) return noLight();
    LightDef d = getHandLightDef(mainHand ? heldItemId : heldItemId2);
    vec3 lightPos = getHandLightPositionSafe(mainHand);
    vec3 toLight = lightPos - playerPos;
    float dist = length(toLight);
    float range = lightRange(d, float(level));
    if (dist >= range) return noLight();

    LightSample s;
    s.direction = toLight / max(dist, EPS);
    s.angularSize = atan(d.shape.w, max(dist, EPS));
    float flicker = lightFlicker(d.params.y, uvec3(mainHand ? 1u : 2u, 0x51u, 0x7Au));
    s.irradiance = lightEmission(d, float(level)) * lightFalloff(dist, range) * HAND_LIGHT_BRIGHTNESS * flicker;

    // 一人称の手そのものはカメラの直近なので影を計算しない (自分の腕で遮ってしまう)
    bool isSelf = firstPersonCamera && length(playerPos) < HAND_SELF_DIST;
    if (isSelf || dot(geoNormal, s.direction) <= -0.2) return s;

#ifdef HAND_LIGHT_RAYS
    vec3 fromVoxel = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);
    if (isInVoxelVolume(fromVoxel)) {
        // 光源半径の円板上で終点を揺らして半影を作る
        float radius = min(d.shape.w * LIGHT_SOURCE_SIZE * LIGHT_SOURCE_SIZE_SCALE, LIGHT_JITTER_MAX_RADIUS);
        mat3 tbn = tbnFromNormal(s.direction);
        float a = (dither + (mainHand ? 0.0 : 0.5)) * TAU;
        vec2 disk = sqrt(fract(dither * 7.31 + 0.27)) * vec2(cos(a), sin(a)) * radius;
        uint flags = blockLightTraceFlags();
        float skipEnd = TRACE_ENTITY_SKIP_END;
        vec3 jitter = tbn[0] * disk.x + tbn[1] * disk.y;
    #ifdef ENTITY_TRI_OCCLUSION
        /*
         * 三角形方式: 三人称は自分の体の三角形で遮り、光源を持つ手・腕の先だけを無視する
         * 一人称では自分の体で手の光を遮らない。以前は体のモデルの手から別に判定して体の影を落としていたが、
         * 見えない体の影が足元や視界に出るのは不自然なため。設置光源・太陽による自分の影は一人称でも残る
         */
        vec3 target = playerToVoxel(lightPos) + jitter;
        skipEnd = HAND_TRI_SELF_SKIP;
        if (firstPersonCamera) flags &= ~TRACE_PLAYER;
    #else
        vec3 target = playerToVoxel(lightPos) + jitter;
        if (firstPersonCamera) {
            // 一人称: 光源が体のボクセルの中にあり、粗いサブセルが手の光を不自然に遮るので自分は外す
            flags &= ~TRACE_PLAYER;
        } else {
            /*
             * 三人称: Iris 26.1 は自分 (半透明エンティティ) を deferred の後に描くので画面空間の影に体が写らない
             * 手の周り (腕) だけを外して体のボクセルで遮り、反対側の壁に自分の影を落とす
             */
            skipEnd = HAND_THIRD_PERSON_SELF_SKIP;
        }
    #endif
        s.irradiance *= traceVisibilityEx(fromVoxel, target, flags, dither, TRACE_ENTITY_SKIP_START, skipEnd);
    }
#endif
#ifdef HAND_LIGHT_SS_SHADOWS
    if (maxOf(s.irradiance) > 0.0) {
        // 光源の直前 (手・たいまつ自身の形) までで止める
        float len = min(dist - 0.4, HAND_SS_LENGTH);
        s.irradiance *= screenSpaceShadow(playerPos, geoNormal, s.direction, len, HAND_SS_STEPS, dither);
    }
#endif
    return s;
}

/*
 * 手持ち光の壁・床からの照り返し (影なし・向きなしの環境光として足す照度)
 * 手持ち光は floodfill にも GI のヒット点の照明にも入らないので、影の側が真っ黒になり、
 * 一人称では手の位置と目のずれで段差の縁が黒い楔の線に見えた。洞窟の壁の反射率 0.2-0.4 程度の多重反射を一定割合で近似する
 */
const float HAND_LIGHT_FILL = 0.18;

vec3 getHandLightFill(vec3 playerPos) {
#ifdef HAND_LIGHT
    vec3 sum = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        bool mainHand = i == 0;
        int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
        if (level <= 0) continue;
        LightDef d = getHandLightDef(mainHand ? heldItemId : heldItemId2);
        float dist = distance(getHandLightPosition(mainHand), playerPos);
        sum += lightEmission(d, float(level)) * lightFalloff(dist, lightRange(d, float(level)));
    }
    return sum * (HAND_LIGHT_FILL * HAND_LIGHT_BRIGHTNESS);
#else
    return vec3(0.0);
#endif
}

/*
 * 着色点 playerPos での両手の光。光らない手は irradiance = 0
 * 呼び出し元: deferred30 (不透明), gbuffers_water 等 (半透明)
 */
void getHandLights(vec3 playerPos, vec3 geoNormal, float dither, out LightSample mainHand, out LightSample offHand) {
#ifdef HAND_LIGHT
    mainHand = evalHandLight(true, playerPos, geoNormal, dither);
    offHand = evalHandLight(false, playerPos, geoNormal, dither);
#else
    mainHand = noLight();
    offHand = noLight();
#endif
}

#endif
