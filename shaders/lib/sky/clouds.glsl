/*
 * 雲の参照口と共通の幾何 (sky モジュール)
 * 雲の層はワールド高度で定義し、地球の曲率は放物面 (高度 = y + 水平距離^2 / 2R) で近似する
 * (半径 6360km に対して数十 km の範囲では誤差が数 cm で、球面交差の桁落ちが無い)
 *
 * 層の構成は実際の雲の階層 (WMO の十種雲形) に合わせる
 *   低層 (体積): 積雲 / 層積雲 / 雨の乱層雲 / 雷雨の積乱雲。CLOUD_BASE から CLOUD_DEPTH (CLOUDS=2 は薄い押し出しの層)
 *   中層 (体積, CLOUDS=3): 高積雲 / 高層雲。低層の上端より上の 4 km 前後
 *   上層 (平面, CLOUD_CIRRUS): 巻雲 / 巻積雲 / 巻層雲。9 km 前後
 * CLOUD_BASE / CLOUD_TOP は低層 (他のモジュールが参照する「雲の下面」, ワールド y)
 *
 * 高さテンプレート (CLOUD_HEIGHT_PRESET): 雲の形・光は「参照空間」(現実の雲の寸法, m) で一度だけ調整し、
 * ワールド -> 参照空間の写像だけをテンプレートで切り替える (docs/reference/techniques/real-clouds.md「Minecraft の高さへの縮尺テンプレート」)
 *   水平: 参照 = ワールド x CLOUD_KH (上層だけ CLOUD_KH_HIGH)
 *   鉛直: バニラ / 拡張は区分写像。海面から積雲の層の上端までは一次 (水平と同じ縮尺 K1)、その上は指数で強く縮める。
 *         カメラから雲底までと雲の厚みが同じ比率で縮むので、地上から見た積雲の大きさ・縦横比は現実比と同じ。
 *         (全体を指数で縮めると雲の厚みだけが 2 倍強く縮み、積雲が遠く小さく平たく見えた)
 *         中層・積乱雲の頂・巻雲は上へ行くほど詰めて、ワールドの高さに収める。上層は見かけの大きさ (仰角あたりの距離) が
 *         現実比と同じになるよう、別の水平の縮尺 CLOUD_KH_HIGH を持つ (天気図はどの層も CLOUD_KH の座標で引く)
 *         現実比は 1 ブロック = 1 m、カスタムは CLOUD_ALTITUDE / CLOUD_THICKNESS で決まる一次の写像
 *   マーチはワールドの直線の視線で行い、各サンプルの位置と歩幅だけを参照空間へ写す (光学的深さは参照空間で測るので、
 *   どのテンプレートでも雲の透け方・明暗が同じ)
 */
#ifndef SKY_CLOUDS_GLSL
#define SKY_CLOUDS_GLSL

/*------------------------------------------------------------------------------
  参照空間の層の高さ (m)。調整はここが基準
------------------------------------------------------------------------------*/
#if CLOUDS == 3
    const float CLOUD_R_BASE = 1500.0;
    // 積雲 (扁平雲 0.5 km -> 並雲 1-2 km -> 雄大雲 4 km) の層。最下層の雲に厚みを持たせて 2.2 km から広げた
    // (大きさ 3.0 の雲は幅 3-7 km なので、2.2 km の層では背より幅がずっと広い平たい雲ばかりだった)。
    // シュークリームのようにもっこりと背の高い雲にするため 3 -> 4.5 km (背丈が幅と同じくらいの雲を混ぜる)
    const float CLOUD_R_DEPTH = 4500.0;
#else
    // CLOUDS=2 (2D 押し出しの薄い層, Nostalgia 方式)
    const float CLOUD_R_BASE = 1500.0;
    const float CLOUD_R_DEPTH = 290.0;
#endif
const float CLOUD_R_TOP = CLOUD_R_BASE + CLOUD_R_DEPTH;
// prepare.csh (雲の高度での光源の高さ) が参照する CLOUDS=2 の層 (参照空間の m)
const float CLOUD2D_ALTITUDE = CLOUD_R_BASE;
const float CLOUD2D_THICKNESS = CLOUD_R_DEPTH;
// 高さテンプレートがカスタムの時は、中層・上層・積乱雲の頂をワールド y のスライダーで決める (0 は現実の比率のまま)。
// 低層と同じ一次の写像で参照空間へ戻し、層どうしが重ならないよう下の層の上端より上に保つ
#if CLOUD_HEIGHT_PRESET == 3
    const float CLOUD_CUSTOM_KV = CLOUD_R_DEPTH / CLOUD_THICKNESS;
    #define CLOUD_CUSTOM_ALT(y, auto) ((y) > 0.0 ? CLOUD_R_BASE + ((y) - CLOUD_ALTITUDE) * CLOUD_CUSTOM_KV : (auto))
    #define CLOUD_CUSTOM_LEN(b, auto) ((b) > 0.0 ? (b) * CLOUD_CUSTOM_KV : (auto))
#else
    #define CLOUD_CUSTOM_ALT(y, auto) (auto)
    #define CLOUD_CUSTOM_LEN(b, auto) (auto)
#endif
// 中層: 低層の雲頂から少し離す (実際の中層雲は 2-7 km)。厚みは高積雲の層の典型値
const float CLOUD_R_MID_BASE = max(CLOUD_CUSTOM_ALT(CLOUD_MID_ALTITUDE, 4200.0), CLOUD_R_TOP + 100.0);
const float CLOUD_R_MID_DEPTH = max(CLOUD_CUSTOM_LEN(CLOUD_MID_THICKNESS, 900.0), 100.0);
const float CLOUD_R_MID_TOP = CLOUD_R_MID_BASE + CLOUD_R_MID_DEPTH;
// 積乱雲の頂 (対流圏界面)。かなとこは巻雲の層の高さで横に広がる
const float CLOUD_R_CB_TOP = max(CLOUD_CUSTOM_ALT(CLOUD_CB_HEIGHT, 10200.0), CLOUD_R_MID_TOP + 500.0);
// 上層: 対流圏上部の巻雲の薄い体積。上の方に房 (発生源) があり、落下する氷晶の筋が下へ垂れる
const float CLOUD_R_HIGH_BASE = max(CLOUD_CUSTOM_ALT(CLOUD_HIGH_ALTITUDE, 8400.0), CLOUD_R_MID_TOP + 100.0);
const float CLOUD_R_HIGH_DEPTH = max(CLOUD_CUSTOM_LEN(CLOUD_HIGH_THICKNESS, 1400.0), 100.0);
const float CLOUD_R_HIGH_TOP = CLOUD_R_HIGH_BASE + CLOUD_R_HIGH_DEPTH;
const float CLOUD_PLANET_RADIUS = 6360e3; // m

/*------------------------------------------------------------------------------
  ワールド <-> 参照空間の写像 (高さテンプレート)
------------------------------------------------------------------------------*/
#if CLOUD_HEIGHT_PRESET == 0
    // バニラ (-64 -> 320): 雲底 y 170 (中小の雲の頂 y 230-330, 大きな雲は 290-466), 中層 y 498-546, 巻雲 y 591-623, 積乱雲の頂 y 630
    #define CLOUD_MAP_PIECEWISE
    const float CLOUD_MAP_SEA = 63.0;
    const float CLOUD_MAP_K1 = 14.0;
    const float CLOUD_MAP_S = 100.0;
    const float CLOUD_KH = 14.0;       // 積雲 1.5-3 km -> 100-200 ブロック
    const float CLOUD_KH_HIGH = 22.0;
#elif CLOUD_HEIGHT_PRESET == 1
    // 高さ拡張ワールド (頂 2000 前後): 雲底 y 520, 雄大雲の頂 y 1770, 中層 y 1910-2110, 巻雲 y 2300-2430, 積乱雲の頂 y 2460
    #define CLOUD_MAP_PIECEWISE
    const float CLOUD_MAP_SEA = 63.0;
    const float CLOUD_MAP_K1 = 3.3;
    const float CLOUD_MAP_S = 405.0;
    const float CLOUD_KH = 3.3;
    const float CLOUD_KH_HIGH = 5.1;
#elif CLOUD_HEIGHT_PRESET == 2
    // 現実比 (1 ブロック = 1 m, 参照高度 = y)
    const float CLOUD_MAP_Y0 = CLOUD_R_BASE;
    const float CLOUD_MAP_KV = 1.0;
    const float CLOUD_KH = 1.0;
    const float CLOUD_KH_HIGH = 1.0;
#else
    // カスタム: 低層の雲底を CLOUD_ALTITUDE、積雲の層の厚みを CLOUD_THICKNESS にする一次の写像 (縦横同じ縮尺)
    const float CLOUD_MAP_Y0 = CLOUD_ALTITUDE;
    const float CLOUD_MAP_KV = CLOUD_R_DEPTH / CLOUD_THICKNESS;
    const float CLOUD_KH = CLOUD_MAP_KV;
    const float CLOUD_KH_HIGH = CLOUD_MAP_KV;
#endif

#ifdef CLOUD_MAP_PIECEWISE
    // 一次と指数の継ぎ目 (積雲の層の上端) のワールド y。傾きが連続になるよう指数の側の係数を K1 S にする
    const float CLOUD_MAP_YT = CLOUD_MAP_SEA + CLOUD_R_TOP / CLOUD_MAP_K1;
    // 指数はこの参照高度 (積乱雲の頂の少し上) までで、その上は同じ傾きの一次に戻す (高く飛んだ時に参照高度が爆発しない)
    const float CLOUD_MAP_R_CAP = CLOUD_R_CB_TOP + 1000.0;
    const float CLOUD_MAP_YC = CLOUD_MAP_YT + CLOUD_MAP_S * log(1.0 + (CLOUD_MAP_R_CAP - CLOUD_R_TOP) / (CLOUD_MAP_K1 * CLOUD_MAP_S));
    const float CLOUD_MAP_K_CAP = CLOUD_MAP_K1 + (CLOUD_MAP_R_CAP - CLOUD_R_TOP) / CLOUD_MAP_S;
#endif

// ワールド y -> 参照高度 (m)
float cloudRefAltitude(float y) {
#ifdef CLOUD_MAP_PIECEWISE
    if (y <= CLOUD_MAP_YT) return (y - CLOUD_MAP_SEA) * CLOUD_MAP_K1;
    if (y >= CLOUD_MAP_YC) return CLOUD_MAP_R_CAP + (y - CLOUD_MAP_YC) * CLOUD_MAP_K_CAP;
    return CLOUD_R_TOP + CLOUD_MAP_K1 * CLOUD_MAP_S * (exp((y - CLOUD_MAP_YT) / CLOUD_MAP_S) - 1.0);
#else
    return CLOUD_R_BASE + (y - CLOUD_MAP_Y0) * CLOUD_MAP_KV;
#endif
}

// 参照高度の y 微分 (鉛直の縮尺, 参照 m / ブロック)
float cloudRefSlope(float y) {
#ifdef CLOUD_MAP_PIECEWISE
    return CLOUD_MAP_K1 * exp(clamp(y - CLOUD_MAP_YT, 0.0, CLOUD_MAP_YC - CLOUD_MAP_YT) / CLOUD_MAP_S);
#else
    return CLOUD_MAP_KV;
#endif
}

// 参照高度と鉛直の縮尺を同時に (指数を 1 回だけ評価する。マーチの 1 サンプルごとに使う)
float cloudRefAltitude(float y, out float slope) {
#ifdef CLOUD_MAP_PIECEWISE
    float e = exp(clamp(y - CLOUD_MAP_YT, 0.0, CLOUD_MAP_YC - CLOUD_MAP_YT) / CLOUD_MAP_S);
    slope = CLOUD_MAP_K1 * e;
    if (y <= CLOUD_MAP_YT) return (y - CLOUD_MAP_SEA) * CLOUD_MAP_K1;
    if (y >= CLOUD_MAP_YC) return CLOUD_MAP_R_CAP + (y - CLOUD_MAP_YC) * CLOUD_MAP_K_CAP;
    return CLOUD_R_TOP + CLOUD_MAP_K1 * CLOUD_MAP_S * (e - 1.0);
#else
    slope = CLOUD_MAP_KV;
    return cloudRefAltitude(y);
#endif
}

// ワールドの方向 dir を、水平の縮尺 kh・鉛直の縮尺 slope の点で参照空間に写した単位ベクトルと、歩幅 1 あたりの長さ
vec3 cloudRefDir(vec3 dir, float kh, float slope) { return normalize(vec3(dir.xz * kh, dir.y * slope).xzy); }
float cloudRefStretch(vec3 dir, float kh, float slope) { return length(vec2(length(dir.xz) * kh, dir.y * slope)); }

// 参照高度 -> ワールド y
#ifdef CLOUD_MAP_PIECEWISE
    #define CLOUD_WORLD_Y(a) ((a) <= CLOUD_R_TOP ? CLOUD_MAP_SEA + (a) / CLOUD_MAP_K1 : CLOUD_MAP_YT + CLOUD_MAP_S * log(1.0 + ((a) - CLOUD_R_TOP) / (CLOUD_MAP_K1 * CLOUD_MAP_S)))
#else
    #define CLOUD_WORLD_Y(a) (CLOUD_MAP_Y0 + ((a) - CLOUD_R_BASE) / CLOUD_MAP_KV)
#endif
float cloudWorldAltitude(float a) { return CLOUD_WORLD_Y(a); }

// ワールドの値 (他のモジュール・画面空間のパスが使う)
const float CLOUD_BASE = CLOUD_WORLD_Y(CLOUD_R_BASE);
const float CLOUD_TOP = CLOUD_WORLD_Y(CLOUD_R_TOP);
const float CLOUD_DEPTH = CLOUD_TOP - CLOUD_BASE;
const float CLOUD_CB_TOP = CLOUD_WORLD_Y(CLOUD_R_CB_TOP);
const float CLOUD_MID_BASE = CLOUD_WORLD_Y(CLOUD_R_MID_BASE);
const float CLOUD_MID_TOP = CLOUD_WORLD_Y(CLOUD_R_MID_TOP);
const float CLOUD_HIGH_BASE = CLOUD_WORLD_Y(CLOUD_R_HIGH_BASE);
const float CLOUD_HIGH_TOP = CLOUD_WORLD_Y(CLOUD_R_HIGH_TOP);

// その高さの層の水平の縮尺 (上層だけ別)
float cloudKH(float y) { return y >= 0.5 * (CLOUD_MID_TOP + CLOUD_HIGH_BASE) ? CLOUD_KH_HIGH : CLOUD_KH; }

// カメラの水平位置を水平の縮尺 kh で参照空間に写して周期 tile で畳んだもの (- shift)。
// 先にワールドで tile / kh に畳むので、遠い座標でも kh 倍で精度が落ちない
vec2 cloudFoldCamera(vec2 shift, float tile, float kh) {
    return mod(mod(cameraPosition.xz, tile / kh) * kh - shift, tile);
}
vec2 cloudFoldCamera(vec2 shift, float tile) { return cloudFoldCamera(shift, tile, CLOUD_KH); }

// ワールドの方向 dir を高度 y で参照空間に写した単位ベクトル
vec3 cloudRefDir(vec3 dir, float y) {
    return normalize(vec3(dir.xz * cloudKH(y), dir.y * cloudRefSlope(y)).xzy);
}

// ワールドの視線の歩幅 1 あたりの参照空間の長さ (高度 y で)
float cloudRefStretch(vec3 dir, float y) {
    return length(vec2(length(dir.xz) * cloudKH(y), dir.y * cloudRefSlope(y)));
}

// 雲影マップ (prepare2): 雲の下面の高さの水平面に貼った 512^2、カメラ周辺 CLOUD_SHADOW_EXTENT 四方 (ワールド)
// 参照空間で 6 km 四方。縮めたテンプレートでも影の届く範囲 (描画距離) を覆うよう下限を設ける
const float CLOUD_SHADOW_EXTENT = clamp(6144.0 / CLOUD_KH, 1024.0, 6144.0);
const float CLOUD_SHADOW_RAIN_OUTSIDE = 0.95; // 雨の日の雲影マップの外の影の濃さ (一面の雨雲)
const float CLOUD_SHADOW_RES = 512.0;
// 光源が低いと投影が伸びて精度が落ちるので、この高さ (sin) 以下では雲影を弱める
const float CLOUD_SHADOW_MIN_LIGHT_Y = 0.04;

// 放物面近似の曲率係数 k (高度 = y0 + t*dy + k*t^2)。A: その層のワールド高度。
// 参照空間の落ち込み (t CLOUD_KH)^2 / 2R をその高度の鉛直の縮尺でワールドの y に戻す (縮めたテンプレートでも地平線への沈み方が同じ)
float cloudCurvature(float dy, float A) { return (1.0 - dy * dy) * (0.5 * sqr(cloudKH(A)) / (CLOUD_PLANET_RADIUS * cloudRefSlope(A))); }

float cloudAltitudeAt(float y0, float dy, float t, float A) { return y0 + t * (dy + t * cloudCurvature(dy, A)); }

/*
 * 高さ A の殻との交差 (放物面)。戻り値は小さい順の 2 解。交差なしは (1, -1)
 * 2 次方程式は桁落ちしない形 (q = -(b + sign(b) sqrt(D)) / 2) で解く
 */
vec2 cloudShellIntersectK(float y0, float dy, float A, float k) {
    float c = y0 - A;
    float disc = dy * dy - 4.0 * k * c;
    if (disc < 0.0) return vec2(1.0, -1.0);
    float s = sqrt(disc);
    float q = -0.5 * (dy + (dy >= 0.0 ? s : -s));
    float t1 = abs(q) > 1e-12 ? c / q : 1e12;
    float t2 = k > 1e-14 ? q / k : (dy > 0.0 ? 1e12 : -1e12);
    return vec2(min(t1, t2), max(t1, t2));
}

vec2 cloudShellIntersect(float y0, float dy, float A) { return cloudShellIntersectK(y0, dy, A, cloudCurvature(dy, A)); }

/*
 * 視線が雲の層 [base, top] の中を通る最初の区間 (t の範囲)。無ければ x >= y
 * 層より下で下を向く視線は地面に遮られるとみなす
 * 曲率は層の真ん中の高さの値で上下の殻にそろえる (マーチの cloudAltitudeAt(.., 0.5 (base + top)) と一致させる)
 */
vec2 cloudLayerSegment(float y0, float dy, float base, float top) {
    if (y0 < base && dy <= 0.0) return vec2(1.0, 0.0);
    float k = cloudCurvature(dy, 0.5 * (base + top));
    vec2 tTop = cloudShellIntersectK(y0, dy, top, k);
    if (tTop.x > tTop.y) return vec2(1.0, 0.0);
    float start = max(tTop.x, 0.0);
    float end = tTop.y;
    vec2 tBase = cloudShellIntersectK(y0, dy, base, k);
    if (tBase.x <= tBase.y && tBase.y > start && tBase.x < end) {
        // 下面より下の区間 [tBase.x, tBase.y] を除いた最初の部分
        if (start < tBase.x) end = tBase.x;
        else start = max(start, tBase.y);
    }
    return vec2(start, end);
}

/*
 * 雲の低解像度レンダリングで、CLOUD_RES 四方のブロックのどのピクセルを今フレーム計算するか
 * CLOUD_TEMPORAL ではフレームごとに Bayer 順で巡回し (チェッカーボード)、deferred21 が CLOUD_RES^2 フレームでフル解像度に戻す
 */
ivec2 cloudSampleOffset(int frame) {
#if defined CLOUD_TEMPORAL && CLOUD_RES > 1
    const ivec2 BAYER2[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));
    int i = frame % (CLOUD_RES * CLOUD_RES);
    #if CLOUD_RES == 2
        return BAYER2[i];
    #else
        return BAYER2[i & 3] * 2 + BAYER2[(i >> 2) & 3];
    #endif
#else
    return ivec2(CLOUD_RES / 2);
#endif
}

ivec2 cloudLowResSize() { return (ivec2(viewWidth, viewHeight) + CLOUD_RES - 1) / CLOUD_RES; }

/*
 * 画面座標 texel の雲 (deferred21 の時間アップスケール済み結果 colortex11)
 * 戻り値: rgb = 雲の散乱光, a = 雲の透過率 (背景色に掛ける)
 */
vec4 getCloudLayer(ivec2 texel) {
#if CLOUDS >= 2 && defined HAS_SKY
    return texelFetch(colortex11, texel, 0);
#else
    return vec4(0.0, 0.0, 0.0, 1.0);
#endif
}

// 雲影マップの中心 (ワールド xz)。テクセル単位に丸めて、カメラが動いても影がちらつかないようにする
vec2 cloudShadowMapOrigin(vec3 lightDir) {
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    vec2 center = cameraPosition.xz + lightDir.xz * ((CLOUD_BASE - cameraPosition.y) / ly);
    float texel = CLOUD_SHADOW_EXTENT / CLOUD_SHADOW_RES;
    return (floor(center / texel) + 0.5) * texel;
}

// player 空間の点を光の方向に雲の下面まで延ばした位置の雲影マップ UV
vec2 cloudShadowUv(vec3 playerPos, vec3 lightDir) {
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    float worldY = playerPos.y + cameraPosition.y;
    vec2 rel = playerPos.xz + lightDir.xz * ((CLOUD_BASE - worldY) / ly) + (cameraPosition.xz - cloudShadowMapOrigin(lightDir));
    return rel / CLOUD_SHADOW_EXTENT + 0.5;
}

/*
 * 地表の点 playerPos が受ける雲影の透過率 [0,1] (prepare2 の雲影マップから)
 * 雲の下面より上の点、光源が低い時、マップの端ではなめらかに 1 へ戻す
 */
float getCloudShadow(vec3 playerPos) {
#if CLOUDS >= 2 && defined CLOUD_SHADOWS && defined HAS_SKY
    vec3 lightDir = getShadowLightDir();
    float strength = smoothstep(CLOUD_SHADOW_MIN_LIGHT_Y, CLOUD_SHADOW_MIN_LIGHT_Y * 3.0, lightDir.y);
    if (strength <= 0.0) return 1.0;
    vec2 uv = cloudShadowUv(playerPos, lightDir);
    vec2 edge = saturate((0.5 - abs(uv - 0.5)) * 10.0);
    float worldY = playerPos.y + cameraPosition.y;
    float below = 1.0 - smoothstep(CLOUD_BASE, CLOUD_BASE + 0.5 * CLOUD_DEPTH, worldY);
    // マップの外は天気からの平均の透過率にする。雨の日に 1 (日なた) へ戻すと、遠くの霧の光の筋がマップの四角い範囲の外だけ
    // 明るくなり、雷雨の空に直線の縁の白い面が出た
    float outside = 1.0 - CLOUD_SHADOW_RAIN_OUTSIDE * max(rainStrength, wetness);
    float transmittance = mix(outside, texture(cloudShadowSampler, uv).r, edge.x * edge.y);
    return mix(1.0, transmittance, strength * below);
#else
    return 1.0;
#endif
}

#endif
