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

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/buffers/images.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/ids/light_ids.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/hand_pose.glsl"
//@include "/lib/light/light_select.glsl"
//@include "/lib/light/trace.glsl"
//@include "/lib/light/voxel.glsl"

// 一人称のカメラから見た手の位置 (view 空間, ブロック)
// 目から離すほど段差の縁の影 (黒い楔) と、両手持ちで片方の影にだけ乗る色の帯が太く見えるので画面の手より内側に置く
const vec3 HAND_OFFSET_VIEW = vec3(0.2, -0.18, -0.3);
// 画面空間の影のレイ長とステップ数
const float HAND_SS_LENGTH = 4.0;
const int HAND_SS_STEPS = 12;
// 一人称で手そのもの (カメラの直近) を受光面とみなす距離。ここでは影を計算しない
const float HAND_SELF_DIST = 0.9;
const float HAND_BACKFACE_COS = -0.2;  // 光源に背を向けた面の影を計算しない cos の下限
const float HAND_SS_END_MARGIN = 0.4;  // 画面空間の影を光源の手前で止める距離 (ブロック)
const float HAND_DISK_PHASE_SCALE = 7.31;
const float HAND_DISK_PHASE_OFFSET = 0.27;
// 三人称で手の光源から自分の体の遮蔽を無視する距離 (ブロック)。腕は外し、胴 (手から 0.1-0.7) の奥側で遮る
// サブセル (0.5 ブロック) は実際の胴より太いので、短くすると影が実物より大きくなる
const float HAND_THIRD_PERSON_SELF_SKIP = 0.45;
// 三角形方式で手の光源から自分の三角形を無視する距離 (光源を持つ手と腕の先)。形どおりなのでボクセルより短くてよい
const float HAND_TRI_SELF_SKIP = 0.3;
// 直接光の影が真っ暗になる HAND_LIGHT_SHADOW_STRENGTH。これ未満では影が薄くなり、これ以上では陰の照り返しだけが減る
const float HAND_SHADOW_FULL_STRENGTH = 0.6;
const float HAND_DIRECT_SHADOW_STRENGTH = min(HAND_LIGHT_SHADOW_STRENGTH / HAND_SHADOW_FULL_STRENGTH, 1.0);

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
    if (isInVoxelVolume(cell) && isVoxelOpaque(fetchVoxelBlockId(cell))) {
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

/*
 * 手持ち光源の画素によらない値 (frameData.handLights。手ごとに 3 つの vec4)
 * 光源の定義・位置 (壁の中なら戻す)・揺らぎは画素ごとに求めると呼ぶ所ごとに数百行になるので、deferred_a が毎フレーム 1 回だけ求める
 * 光らない手 (heldBlockLightValue が 0) の値は使わない。読む側は今までどおり uniform のレベルで判定する
 */
const int HAND_LIGHT_SLOTS = 3;

struct HandLight {
    vec3 pos;       // 光源の位置 (player 空間)。固体ブロックの中なら目へ戻した getHandLightPositionSafe
    float range;    // 届く距離 lightRange
    vec3 emission;  // lightEmission (HAND_LIGHT_BRIGHTNESS と揺らぎの前)
    float flicker;  // 揺らぎの倍率 lightFlicker
    vec3 handPos;   // 戻す前の手の位置 getHandLightPosition (照り返しとフォグの光の暈)
    float radius;   // 光源の半径 LightDef.shape.w
};

HandLight handLightAt(bool mainHand) {
    int base = mainHand ? 0 : HAND_LIGHT_SLOTS;
    vec4 a = frameData.handLights[base];
    vec4 b = frameData.handLights[base + 1];
    vec4 c = frameData.handLights[base + 2];
    HandLight h;
    h.pos = a.xyz;
    h.range = a.w;
    h.emission = b.rgb;
    h.flicker = b.a;
    h.handPos = c.xyz;
    h.radius = c.w;
    return h;
}

#ifdef SSBO_FRAME_DATA_WRITE
// deferred_a (light_bins.csh) が書く。位置の判定に今フレームのボクセルを読むので shadow の後で、読む側 (deferred10 以降) の前
void handLightsStore() {
    for (int i = 0; i < 2; i++) {
        bool mainHand = i == 0;
        int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
        LightDef d = getHandLightDef(mainHand ? heldItemId : heldItemId2);
        float flicker = lightFlicker(d.params.y, uvec3(mainHand ? 1u : 2u, 0x51u, 0x7Au));
        int base = mainHand ? 0 : HAND_LIGHT_SLOTS;
        frameData.handLights[base] = vec4(getHandLightPositionSafe(mainHand), lightRange(d, float(level)));
        frameData.handLights[base + 1] = vec4(lightEmission(d, float(level)), flicker);
        frameData.handLights[base + 2] = vec4(getHandLightPosition(mainHand), d.shape.w);
    }
}
#endif

// 手持ち光源の影に使う値。光源の位置 (player 空間) と半径、光源までの距離 (画面空間の影の長さ)
struct HandShadowRay {
    vec3 lightPos;
    float lightRadius;
    float dist;
};

/*
 * 影を掛ける前の手持ち光源 s と、影のレイ r。影を計算する点なら true を返す
 * ボクセルのトレースは呼ぶ側 (lib/surface/surface_lights.glsl の gatherTracedLights) が設置光源のトレースと同じ 1 か所で呼び、
 * applyHandLightTrace と applyHandLightContactShadow で影を掛ける (NVIDIA は関数を全部展開するので、呼ぶ所ごとにトレースの本体が増える)
 */
bool handLightUnshadowed(bool mainHand, vec3 playerPos, vec3 geoNormal, out LightSample s, out HandShadowRay r) {
    // r は true を返す時だけ使う
    s = noLight();
    int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
    if (level <= 0) return false;
    HandLight h = handLightAt(mainHand);
    vec3 toLight = h.pos - playerPos;
    float dist = length(toLight);
    if (dist >= h.range) return false;

    s.direction = toLight / max(dist, EPS);
    s.angularSize = atan(h.radius, max(dist, EPS));
    s.irradiance = h.emission * lightFalloff(dist, h.range) * HAND_LIGHT_BRIGHTNESS * h.flicker;
    r.dist = dist;

    // 一人称の手そのものはカメラの直近なので影を計算しない (自分の腕で遮ってしまう)
    bool isSelf = firstPersonCamera && length(playerPos) < HAND_SELF_DIST;
    if (isSelf || dot(geoNormal, s.direction) <= HAND_BACKFACE_COS) return false;

    r.lightPos = h.pos;
    r.lightRadius = h.radius;
    return true;
}

/*
 * トレースの終点・フラグ・光源側の無視区間 (トレースする時だけ求める)
 * 光源半径の円板上で終点を揺らして半影を作る
 */
vec3 handShadowTarget(HandShadowRay r, LightSample s, bool mainHand, float dither, out uint flags, out float skipEnd) {
    float radius = min(r.lightRadius * LIGHT_SOURCE_SIZE * LIGHT_SOURCE_SIZE_SCALE, LIGHT_JITTER_MAX_RADIUS);
    mat3 tbn = tbnFromNormal(s.direction);
    float a = (dither + (mainHand ? 0.0 : 0.5)) * TAU;
    vec2 disk = sqrt(fract(dither * HAND_DISK_PHASE_SCALE + HAND_DISK_PHASE_OFFSET)) * vec2(cos(a), sin(a)) * radius;
    flags = blockLightTraceFlags();
    skipEnd = TRACE_ENTITY_SKIP_END;
    vec3 jitter = tbn[0] * disk.x + tbn[1] * disk.y;
#ifdef ENTITY_TRI_OCCLUSION
    /*
     * 三角形方式: 三人称は自分の体の三角形で遮り、光源を持つ手・腕の先だけを無視する
     * 一人称では自分の体で手の光を遮らない (見えない体の影が足元や視界に出るのは不自然なため)。設置光源・太陽による自分の影は一人称でも残る
     */
    vec3 target = playerToVoxel(r.lightPos) + jitter;
    skipEnd = HAND_TRI_SELF_SKIP;
    if (firstPersonCamera) flags &= ~TRACE_PLAYER;
#else
    vec3 target = playerToVoxel(r.lightPos) + jitter;
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
    return target;
}

// ボクセルのトレースの可視率 vis (traceVisibility(始点, handShadowTarget(..), flags, dither, TRACE_ENTITY_SKIP_START, skipEnd)) を掛ける
void applyHandLightTrace(inout LightSample s, vec3 vis) {
    s.irradiance *= mix(vec3(1.0), vis, HAND_DIRECT_SHADOW_STRENGTH);
}

void applyHandLightContactShadow(inout LightSample s, HandShadowRay r, vec3 playerPos, vec3 geoNormal, float dither) {
#ifdef HAND_LIGHT_SS_SHADOWS
    if (maxOf(s.irradiance) > 0.0) {
        // 光源の直前 (手・たいまつ自身の形) までで止める
        float len = min(r.dist - HAND_SS_END_MARGIN, HAND_SS_LENGTH);
        s.irradiance *= mix(1.0, lightContactShadow(playerPos, geoNormal, s.direction, len, HAND_SS_STEPS, dither), HAND_DIRECT_SHADOW_STRENGTH);
    }
#endif
}

/*
 * 手持ち光の壁・床からの照り返し (影なし・向きなしの環境光として足す照度)
 * 手持ち光は floodfill にも GI のヒット点の照明にも入らないので、影の側が真っ黒になり、
 * 一人称では手の位置と目のずれで段差の縁が黒い楔の線に見えた。洞窟の壁の反射率 0.2-0.4 程度の多重反射を一定割合で近似する
 */
const float HAND_LIGHT_FILL = 0.18;

/*
 * 手持ち光の照り返し (陰の中に回り込む分) の倍率。HAND_LIGHT_SHADOW_STRENGTH = 0.5 で 1 倍、1 で照り返しなし
 * 直接光の影の濃さ (HAND_DIRECT_SHADOW_STRENGTH) は 0.6 以上で最大なので、0.6 から上は影の濃さそのままで照り返しだけが減る
 * 陰の中の明るさは、GI_MODE 0/1 ではほぼこの getHandLightFill だけ、GI_MODE 2/3 では GI のヒット点の手持ち光
 * (lib/surface/lighting.glsl の secondaryHitBlockLight) と半分ずつ (ゲーム内で計測)。両方に同じ倍率を掛ける
 */
float handLightIndirectScale() { return 2.0 * (1.0 - HAND_LIGHT_SHADOW_STRENGTH); }

vec3 getHandLightFill(vec3 playerPos) {
#ifdef HAND_LIGHT
    vec3 sum = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        bool mainHand = i == 0;
        int level = mainHand ? heldBlockLightValue : heldBlockLightValue2;
        if (level <= 0) continue;
        HandLight h = handLightAt(mainHand);
        float dist = distance(h.handPos, playerPos);
        sum += h.emission * lightFalloff(dist, h.range);
    }
    return sum * (HAND_LIGHT_FILL * HAND_LIGHT_BRIGHTNESS * handLightIndirectScale());
#else
    return vec3(0.0);
#endif
}

/*
 * 光らせる手の数 (トレースのループの回数)。両手を 1 つのループで回す。2 回並べて呼ぶと光源シャドウのトレースが 2 つ展開され、
 * NVIDIA のリンクが数秒延びる。回数を uniform で決めてループを展開させない
 * (左手が光らなければ handLightUnshadowed(false) は noLight なので、1 回で止めても結果は同じ)
 */
int handLightCount() {
#ifdef HAND_LIGHT
    return heldBlockLightValue2 > 0 ? 2 : 1;
#else
    return 0;
#endif
}

/*
 * 着色点 playerPos での両手の光。光らない手は irradiance = 0
 * 手持ち光源だけをトレースするプログラム用 (deferred30, gbuffers_water 等)。設置光源もトレースする所は
 * lib/surface/surface_lights.glsl の gatherTracedLights が同じ部品で 1 本のループにする (この形のほうが命令と一時変数が少し少ない)
 */
void getHandLights(vec3 playerPos, vec3 geoNormal, float dither, out LightSample mainHand, out LightSample offHand) {
    mainHand = noLight();
    offHand = noLight();
    for (int i = 0; i < handLightCount(); i++) {
        LightSample s;
        HandShadowRay r;
        if (handLightUnshadowed(i == 0, playerPos, geoNormal, s, r)) {
#ifdef HAND_LIGHT_RAYS
            vec3 fromVoxel = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);
            if (isInVoxelVolume(fromVoxel)) {
                uint flags;
                float skipEnd;
                vec3 target = handShadowTarget(r, s, i == 0, dither, flags, skipEnd);
                applyHandLightTrace(s, traceVisibility(fromVoxel, target, flags, dither, TRACE_ENTITY_SKIP_START, skipEnd));
            }
#endif
            applyHandLightContactShadow(s, r, playerPos, geoNormal, dither);
        }
        if (i == 0) mainHand = s;
        else offHand = s;
    }
}

#endif
