/*
 * 太陽・月の影 (surface モジュール)
 * 影マップの空間は lib/common/shadow_space.glsl (書き込み側と共通)
 *
 * バイアスは 3 層
 *   1. 法線オフセット: 受け点を幾何法線方向にずらす (量は歪み込みのテクセルサイズ x 傾き)
 *   2. 受け面の傾きに沿った深度 (receiver plane depth bias): PCF の各サンプル位置で受け面の深度を外挿して比較
 *   3. 歪み整合: 1, 2 の基準量を shadowTexelWorldSize (歪みで引き伸ばされた実テクセルサイズ) で決める
 * フィルタ
 *   SHADOW_FILTER 0 = 1 タップ (双線形比較), 1 = 固定半径 PCF, 2 = PCSS (ブロッカー探索と PCF を分離した 2 段)
 *   サンプル位置は歪み前のクリップ座標 (= ワールド単位) で円盤に並べ、1 つずつ歪ませる。歪みで半影の幅が場所により変わらない
 * 色付き影: shadowtex0 (半透明込み) と shadowtex1 (不透明のみ) の差分に shadowcolor0 の透過色を掛ける
 *   水 (shadowcolor1.a = 1) は透過色の代わりに水深による吸収 + コースティクス
 * 葉の透過 (SHADOW_LEAF_TINT): 不透明に遮られた分のうち葉の分を、葉の色 x 重なった枚数 (ボクセルで数える) で透過させる
 *   透過した分は SunShadow.leaf に分けて返し、拡散だけに使う (鏡面の太陽を緑に染めない)
 */
#ifndef SURFACE_SUN_SHADOW_GLSL
#define SURFACE_SUN_SHADOW_GLSL

const float SHADOW_NORMAL_OFFSET_MIN = 0.6;   // 法線オフセット (テクセル)。正面向きの面
const float SHADOW_NORMAL_OFFSET_SLOPE = 1.4; // 法線オフセット (テクセル)。傾いた面での追加分
const float SHADOW_CONSTANT_BIAS = 0.75;      // 深度の量子化分 (テクセル)
const float SHADOW_MAX_DEPTH_SLOPE = 6.0;     // 受け面深度の外挿の上限 (かすめ角で影が消えないように)
// 太陽の見かけの半径 (ラジアン)。実物 (0.0047) より少し大きくして遠くのブロッカーの半影を見やすくする
const float SHADOW_SUN_ANGULAR_RADIUS = 0.0065;
const float SHADOW_MAX_BLOCKER_DISTANCE = 24.0; // ブロッカー探索で想定する最大距離 (ブロック)
const float SHADOW_PCF_RADIUS_TEXELS = 1.5;    // SHADOW_FILTER=1 の半径
const float SHADOW_SSS_FILTER_RADIUS = 0.12;   // SSS が 1 の面で足すフィルタ半径 (ブロック)。影の中で光がにじむ
const float SHADOW_SSS_SEARCH_RADIUS = 0.35;   // SSS の厚みを測る探索半径 (ブロック)
const float SHADOW_EDGE_FADE = 0.1;            // 影の範囲の外周 10% でフォールバックへ溶かす

#if SHADOW_SAMPLES >= 16
    const int SHADOW_BLOCKER_SAMPLES = SHADOW_SAMPLES / 2;
#else
    const int SHADOW_BLOCKER_SAMPLES = 6;
#endif

struct SunShadow {
    vec3 visibility; // 直接光の色付き透過率 (葉を透過した光を含む)
    // visibility のうち葉を透過した分。葉の中で散乱して広がった光なので拡散だけに使い、鏡面の太陽 (水面・水たまり・金属の照り返し) には使わない
    vec3 leaf;
    float thickness; // 受け点から光源側の最寄りの不透明物までの距離 (ブロック, SSS 用。遮蔽なしなら 0)
    float fade;      // 1 = 影マップの範囲内。0 に近いほど呼び出し側のフォールバックを使う
};

float shadowDepthPerBlock() { return abs(shadowProjection[2][2]) * SHADOW_DEPTH_SCALE * 0.5; }
vec2 shadowClipPerBlock() { return vec2(shadowProjection[0][0], shadowProjection[1][1]); }

vec2 shadowClipToUv(vec2 clipXY) { return clipXY / shadowDistortScale(clipXY) * 0.5 + 0.5; }
float shadowClipToDepth(float clipZ) { return clipZ * SHADOW_DEPTH_SCALE * 0.5 + 0.5; }

// 4 テクセルを比較して双線形に補間する (ハードウェア比較フィルタの代わり)
float shadowCompareBilinear(sampler2D tex, vec2 uv, float z) {
    const float res = float(shadowMapResolution);
    vec2 px = uv * res - 0.5;
    vec2 f = fract(px);
    vec4 d = textureGather(tex, (floor(px) + 1.0) / res, 0);
    vec4 v = step(vec4(z), d);
    return mix(mix(v.w, v.z, f.x), mix(v.x, v.y, f.x), f.y);
}

/*
 * 影マップの 1 点の透過色。半透明の透過色 (ガラス) か水の吸収 + コースティクス
 * receiverPlayer: 受け点, z: 受け点の影深度
 */
vec3 shadowTranslucentTint(vec2 uv, float z, vec3 receiverPlayer) {
#ifdef SHADOW_COLORED
    vec4 kind = texture(shadowcolor1, uv);
    if (kind.a > 0.75) {
        float surfaceDepth = texture(shadowtex0, uv).r;
        float depthBelow = max(z - surfaceDepth, 0.0) / shadowDepthPerBlock();
        vec3 L = getShadowLightDir();
        vec3 t = exp(-waterExtinction() * depthBelow);
        return t * waterCaustics(receiverPlayer + cameraPosition, depthBelow, L);
    }
    vec4 c = texture(shadowcolor0, uv);
    return mix(vec3(1.0), srgbToLinear(c.rgb), c.a);
#else
    return vec3(1.0);
#endif
}

#ifdef SHADOW_LEAF_TINT
/*
 * 葉の透過 (SHADOW_LEAF_TINT)
 * 影マップの葉はテクスチャの穴だけを光が抜け、葉そのものは不透明として書かれる。実際の葉は緑の光を 1-2 割通すので、
 * 不透明の影のうち葉で遮られた分に、葉の色の透過率を通った葉の枚数だけ掛けて足す (木漏れ日と森の床・幹が緑がかる)
 * 枚数は影マップの最も光源側の葉から受け点へボクセルを辿り、葉のセルを通る長さで数える。重なるほど暗く、緑が濃くなる
 * 途中で葉以外の光を通さないブロック (幹・地形) に当たれば、その先へは届かないので 0
 */
const float LEAF_LAYER_PATH = 1.0;     // 葉 1 枚とみなす葉のセルの中を通る長さ (ブロック)。真上からの光が 1 ブロックを抜けると 1 枚
const int LEAF_MAX_CELLS = 24;         // 光源側の葉から辿る最大のセル数
const float LEAF_MAX_LAYERS = 5.0;     // これより重なれば届く光は無視できる (0.15^5 = 1e-4)
const float LEAF_TOP_MARGIN = 0.5;     // 光源側の葉の面から辿り始める位置の余裕 (ブロック)
const float LEAF_RECEIVER_MARGIN = 0.3; // 受け点の手前で辿るのをやめる距離 (受け点自身のブロックを数えない)
const float LEAF_FAR_LAYERS = 2.0;     // ボクセルの範囲外で仮定する葉の枚数
const float LEAF_VOXEL_EDGE = 8.0;     // ボクセルの範囲の端からこの幅で範囲外の仮定へ溶かす (ブロック)
const float LEAF_TINT_POWER = 1.25;    // 1 枚の透過色の彩度 (葉の色を最大成分で割った値の冪。葉の色素は反射より透過で濃く色付く)
// 葉の色が読めない時 (影マップの中心が葉の穴で下の地面が見えている) の色。オークの葉の平原の色 (tools/block_colors.json)
const vec3 LEAF_FALLBACK_SRGB = vec3(66.0, 98.0, 23.0) / 255.0;

// 葉 1 枚 (1 ブロック) の透過率。葉の色を最大成分で正規化して、輝度を SHADOW_LEAF_TRANSMISSION に合わせる
vec3 leafLayerTransmittance(vec3 leafColor) {
    vec3 c = pow(leafColor / max(maxOf(leafColor), 1e-4), vec3(LEAF_TINT_POWER));
    return min(c * (SHADOW_LEAF_TRANSMISSION / max(luminance(c), 1e-4)), vec3(0.95));
}

/*
 * 光源側の葉の手前 topPlayer から受け点の方向 -L へ len だけ辿り、通った葉の枚数を返す。葉以外の固体に当たれば -1
 * edge: 辿り始めがボクセルの範囲の内側にある度合い (0 = 範囲外で分からない)
 */
float leafLayersAlong(vec3 topPlayer, vec3 L, float len, out float edge) {
    vec3 o = playerToVoxel(topPlayer);
    edge = voxelEdgeFade(o, LEAF_VOXEL_EDGE);
    if (edge <= 0.0) return 0.0;
    vec3 dir = -L;
    ivec3 cell = ivec3(floor(o));
    ivec3 stepDir = ivec3(greaterThanEqual(dir, vec3(0.0))) * 2 - 1;
    vec3 tDelta = 1.0 / max(abs(dir), vec3(1e-7));
    vec3 fr = o - vec3(cell);
    vec3 tMax = mix(fr, 1.0 - fr, vec3(greaterThan(stepDir, ivec3(0)))) * tDelta;
    float t = 0.0;
    float path = 0.0;
    for (int i = 0; i < LEAF_MAX_CELLS && t < len; i++) {
        if (!isInVoxelVolume(cell)) break;
        float tNext = min(minOf(tMax), len);
        int id = int(texelFetch(voxelBlockSampler, cell, 0).r & 0xFFFu);
        if (id == BLOCK_LEAVES) {
            path += tNext - t;
            if (path > LEAF_MAX_LAYERS * LEAF_LAYER_PATH) break;
        } else if (isPlainSolidBlock(id) || (id >= 10 && id < 100)) {
            return -1.0;
        }
        t = tNext;
        if (tMax.x == minOf(tMax)) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y == minOf(tMax)) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
    }
    return path / LEAF_LAYER_PATH;
}

/*
 * 不透明の影のうち葉を通って届く光の透過率 (rgb)
 * receiver: 法線オフセット後の受け点, uv / z: その影マップの座標と深度, occluderDist: 受け点から最も光源側の遮る物までの距離 (ブロック)
 * centerOpen: 影マップの中心のテクセルが遮られていない (葉の穴)
 */
vec3 shadowLeafTransmittance(vec3 receiver, vec2 uv, float occluderDist, bool centerOpen) {
    if (occluderDist <= 0.0) return vec3(0.0);
    float kind = texture(shadowcolor1, uv).a;
    bool leafTop = abs(kind - SHADOW_KIND_LEAVES) < 0.05;
    // 中心が葉以外の物 (幹・地形・エンティティ) で遮られていれば葉の透過は無い
    if (!leafTop && !centerOpen) return vec3(0.0);
    vec3 leafColor = srgbToLinear(leafTop ? texture(shadowcolor0, uv).rgb : LEAF_FALLBACK_SRGB);
    vec3 layerT = leafLayerTransmittance(leafColor);

    vec3 L = getShadowLightDir();
    float edge;
    float start = occluderDist + LEAF_TOP_MARGIN;
    float layers = leafLayersAlong(receiver + L * start, L, start - LEAF_RECEIVER_MARGIN, edge);
    // 影マップは葉で遮られているのに葉が見つからない (エンティティ・ボクセルに入らない物) なら透過させない
    vec3 near = layers > 0.0 ? pow(layerT, vec3(max(layers, 1.0))) : vec3(0.0);
    vec3 far = leafTop ? pow(layerT, vec3(LEAF_FAR_LAYERS)) : vec3(0.0);
    return mix(far, near, edge);
}
#endif

/*
 * 面の太陽影 (詳細版)。sss: 表面下散乱の強さ (厚みの探索とフィルタ半径に使う)
 */
SunShadow evalSunShadow(vec3 playerPos, vec3 geoNormal, float sss, float dither) {
    SunShadow r;
    r.visibility = vec3(1.0);
    r.leaf = vec3(0.0);
    r.thickness = 0.0;
    r.fade = 0.0;
#ifdef HAS_SUN_SHADOWS
    vec3 L = getShadowLightDir();
    float NoL = dot(geoNormal, L);
    // 裏を向いた面は SSS が無ければ光らないので探索しない
    if (NoL <= 0.0 && sss <= 0.0) {
        r.visibility = vec3(0.0);
        r.fade = 1.0;
        return r;
    }

    float dist = length(playerPos.xz);
    r.fade = saturate((1.0 - dist / shadowDistance) / SHADOW_EDGE_FADE);
    if (r.fade <= 0.0) return r;

    vec3 clip0 = playerToShadowClip(playerPos);
    float texelWorld = shadowTexelWorldSize(clip0.xy);
    float absNoL = max(abs(NoL), 0.02);
    float sinT = sqrt(saturate(1.0 - absNoL * absNoL));

    // 1. 法線オフセット (裏向きの面は光源側へ押すと自分の厚みを測れないので外向きのまま)
    vec3 biased = playerPos + geoNormal * texelWorld * (SHADOW_NORMAL_OFFSET_MIN + SHADOW_NORMAL_OFFSET_SLOPE * sinT);
    vec3 clip = playerToShadowClip(biased);
    vec2 clipPerBlock = shadowClipPerBlock();
    float depthPerBlock = shadowDepthPerBlock();

    // 2. 受け面の深度勾配 (影ビュー空間で面内の移動 1 ブロックあたりの深度変化)
    vec3 nS = mat3(shadowModelView) * geoNormal;
    vec2 dzdxy = -nS.xy / max(abs(nS.z), 1e-3) * sign(nS.z);
    dzdxy = clamp(dzdxy, -SHADOW_MAX_DEPTH_SLOPE, SHADOW_MAX_DEPTH_SLOPE);
    // 深度は影ビューの -z 方向に増えるので符号を反転して深度単位へ
    vec2 depthGrad = -dzdxy * depthPerBlock;
    float z0 = shadowClipToDepth(clip.z) - SHADOW_CONSTANT_BIAS * texelWorld * depthPerBlock * min(sinT / absNoL, SHADOW_MAX_DEPTH_SLOPE);

    vec2 uv0 = shadowClipToUv(clip.xy);
    if (any(lessThan(uv0, vec2(0.0))) || any(greaterThan(uv0, vec2(1.0)))) {
        r.fade = 0.0;
        return r;
    }

    float phi = dither * TAU;

#if SHADOW_FILTER == 0
    float vo = shadowCompareBilinear(shadowtex1, uv0, z0);
    float va = vo;
    #ifdef SHADOW_COLORED
        va = shadowCompareBilinear(shadowtex0, uv0, z0);
    #endif
    if (sss > 0.0) {
        float d = texture(shadowtex1, uv0).r;
        r.thickness = max(z0 - d, 0.0) / depthPerBlock;
    }
#else
    // 段 1: ブロッカー探索 (PCSS の半影幅と SSS の厚み)
    float searchRadius = SHADOW_MAX_BLOCKER_DISTANCE * SHADOW_SUN_ANGULAR_RADIUS * SHADOW_SOFTNESS + 2.0 * texelWorld;
    searchRadius = max(searchRadius, sss * SHADOW_SSS_SEARCH_RADIUS);
    float blockerSum = 0.0;
    float blockerCount = 0.0;
    #if SHADOW_FILTER == 2
        bool needSearch = true;
    #else
        bool needSearch = sss > 0.0;
    #endif
    if (needSearch) {
        for (int i = 0; i < SHADOW_BLOCKER_SAMPLES; i++) {
            vec2 off = vogelDisk(i, SHADOW_BLOCKER_SAMPLES, phi + 1.7) * searchRadius;
            vec2 uv = shadowClipToUv(clip.xy + off * clipPerBlock);
            float zr = z0 + dot(depthGrad, off);
            float d = texture(shadowtex1, uv).r;
            if (d < zr) {
                blockerSum += zr - d;
                blockerCount += 1.0;
            }
        }
    }
    float blockerDistance = blockerCount > 0.0 ? blockerSum / blockerCount / depthPerBlock : 0.0;
    r.thickness = blockerDistance;

    #if SHADOW_FILTER == 2
        // ブロッカーが 1 つも無ければ不透明の影は無い。半透明の色だけ 1 タップで見る
        if (blockerCount <= 0.0 && sss <= 0.0) {
            #ifdef SHADOW_COLORED
                float va0 = shadowCompareBilinear(shadowtex0, uv0, z0);
                if (va0 < 0.999) r.visibility = mix(shadowTranslucentTint(uv0, z0, playerPos), vec3(1.0), va0);
            #endif
            r.visibility *= step(0.0, NoL);
            return r;
        }
        float radius = blockerDistance * SHADOW_SUN_ANGULAR_RADIUS * SHADOW_SOFTNESS + texelWorld;
    #else
        float radius = SHADOW_PCF_RADIUS_TEXELS * texelWorld;
    #endif
    radius += sss * SHADOW_SSS_FILTER_RADIUS;

    // 段 2: 可変半径 PCF
    float vo = 0.0;
    float va = 0.0;
    for (int i = 0; i < SHADOW_SAMPLES; i++) {
        vec2 off = vogelDisk(i, SHADOW_SAMPLES, phi) * radius;
        vec2 uv = shadowClipToUv(clip.xy + off * clipPerBlock);
        float zr = z0 + dot(depthGrad, off);
        float o = shadowCompareBilinear(shadowtex1, uv, zr);
        vo += o;
        #ifdef SHADOW_COLORED
            va += o > 0.0 ? shadowCompareBilinear(shadowtex0, uv, zr) : 0.0;
        #else
            va += o;
        #endif
    }
    vo /= float(SHADOW_SAMPLES);
    va /= float(SHADOW_SAMPLES);
#endif

    // 不透明で遮られず半透明で遮られた割合に透過色を掛ける (透過色は中心 1 点で代表させる)
    vec3 tint = vec3(1.0);
    if (vo - va > 0.001) tint = shadowTranslucentTint(uv0, z0, playerPos);
    r.visibility = vec3(va) + max(vo - va, 0.0) * tint;
    #ifdef SHADOW_LEAF_TINT
        // 不透明に遮られた割合のうち葉の分は、葉の色で透過させる (遮る物の距離は中心のテクセル、葉の穴ならブロッカー探索の平均)
        if (vo < 0.999 && NoL > 0.0) {
            float dc = texture(shadowtex1, uv0).r;
            bool centerOpen = dc >= z0;
            float occluderDist = centerOpen ? r.thickness : (z0 - dc) / depthPerBlock;
            r.leaf = (1.0 - vo) * shadowLeafTransmittance(biased, uv0, occluderDist, centerOpen);
            r.visibility += r.leaf;
        }
    #endif
    if (NoL <= 0.0) {
        r.visibility = vec3(0.0);
        r.leaf = vec3(0.0);
    }
#endif
    return r;
}

/*
 * VL 等の体積マーチ用の 1 タップ影 (sky モジュールが使う)。rgb = 色付き透過率
 */
vec3 sampleShadowVolume(vec3 playerPos) {
#ifdef HAS_SUN_SHADOWS
    vec3 s = playerToShadowScreen(playerPos);
    if (any(lessThan(s, vec3(0.0))) || any(greaterThan(s, vec3(1.0)))) return vec3(1.0);
    float opaqueVis = step(s.z, texture(shadowtex1, s.xy).r);
    #ifdef SHADOW_COLORED
        float allVis = step(s.z, texture(shadowtex0, s.xy).r);
        if (opaqueVis > 0.0 && allVis < 1.0) return shadowTranslucentTint(s.xy, s.z, playerPos);
    #endif
    return vec3(opaqueVis);
#else
    return vec3(1.0);
#endif
}

/*
 * 面の太陽影 (色付き透過率)。範囲外は 1 (呼び出し側が雲影等を掛ける)
 */
vec3 getSunShadow(vec3 playerPos, vec3 geoNormal, float dither) {
    SunShadow s = evalSunShadow(playerPos, geoNormal, 0.0, dither);
    return mix(vec3(1.0), s.visibility, s.fade);
}

/*
 * 面の太陽影と、鏡面の太陽に使う透過率 specular (葉を透過した拡散光を除く)
 * 葉の隙間を抜けた光は白いまま照り返すが、葉を透過した光は散乱して向きを失っているので太陽の鏡像を作らない
 */
vec3 getSunShadow(vec3 playerPos, vec3 geoNormal, float dither, out vec3 specular) {
    SunShadow s = evalSunShadow(playerPos, geoNormal, 0.0, dither);
    specular = mix(vec3(1.0), s.visibility - s.leaf, s.fade);
    return mix(vec3(1.0), s.visibility, s.fade);
}

/*
 * スクリーンスペースの接触影 (Bend Studio / Days Gone 方式の短距離マーチ)
 * 影マップのテクセルより細かい接地影 (草の根元・柵・エンティティの足元) を深度バッファで補う
 * viewPos: 着色点 (view 空間), geoNormalView: 幾何法線 (view 空間), lightView: 光源方向 (view 空間)
 */
const int CONTACT_SHADOW_STEPS = 12;
const float CONTACT_SHADOW_LENGTH = 0.35;      // 近距離のマーチ長 (ブロック)
const float CONTACT_SHADOW_LENGTH_SCALE = 0.012; // 距離に比例して伸ばす (遠景の小物の影を拾う)
const float CONTACT_SHADOW_THICKNESS = 0.15;   // 遮蔽物として扱う厚み (ブロック)
const float CONTACT_SHADOW_MIN_NOV = 0.1;      // 押し出しの 1/NoV の上限 (真横から見た面で押し出しすぎない)

float screenSpaceShadow(vec3 viewPos, vec3 geoNormalView, vec3 lightView, float dither) {
    float dist = -viewPos.z;
    float len = CONTACT_SHADOW_LENGTH + dist * CONTACT_SHADOW_LENGTH_SCALE;
    vec3 stepVec = lightView * (len / float(CONTACT_SHADOW_STEPS));
    /*
     * 始点を幾何法線の方向へ 1 画素の奥行きぶん浮かせる。かすめ角の面では 1 画素の中で深度が大きく変わり、
     * 面から少し上がっただけのレイが隣の画素の自分の面より奥と判定されて、遠くの雪・氷の床の日向が
     * 一面に影になっていた (段差の縁だけ判定を逃れて明るく残り、ブロックごとのマス目に見えた)
     */
    float pixelSize = dist * 2.0 / (gbufferProjection[1][1] * viewSize().y);
    float NoV = max(dot(geoNormalView, -viewPos / max(dist, 1e-4)), CONTACT_SHADOW_MIN_NOV);
    vec3 p = viewPos + geoNormalView * (0.01 + pixelSize / NoV) + stepVec * dither;
    float thickness = CONTACT_SHADOW_THICKNESS + dist * 0.01;
    for (int i = 0; i < CONTACT_SHADOW_STEPS; i++) {
        p += stepVec;
        if (p.z > -near) break;
        vec3 s = viewToScreen(p);
        if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0)))) break;
        float d = texture(depthtex1, s.xy).r;
        if (isHandDepth(d)) continue;
        float delta = -p.z - linearizeDepth(d);
        // 自分の面に当たらないよう、深度の精度分の余裕を取る
        if (delta > 0.002 * dist + 0.01 && delta < thickness) {
            vec2 edge = min(s.xy, 1.0 - s.xy);
            return 1.0 - saturate(minOf(edge) * 20.0);
        }
    }
    return 1.0;
}

#endif
