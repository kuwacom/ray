/*
 * ライトビンの参照と光源 1 つの評価、低解像度トレースのサンプル配置 (light モジュール)
 * deferred1 (トレース), deferred2 (デノイズ), deferred30 (鏡面) で同じ式を使うためにまとめる
 *
 * 直接光は「比の推定」でデノイズする (Heitz et al. 2018, "Combining Analytic Direct Illumination and Stochastic Shadows")
 *   deferred1: 低解像度で S = Σ E_i V_i (影あり) と U = Σ E_i (影なし) を同じ光源選択で求める
 *   deferred2: S / U (可視率) だけを時空間フィルタし、フル解像度で厳密に求めた影なし照度に掛ける
 * 減衰・法線の細部はフル解像度のまま残り、ノイズのある可視率だけがぼける
 */
#ifndef LIGHT_LIGHT_SELECT_GLSL
#define LIGHT_LIGHT_SELECT_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/voxel_read.glsl"

// 半影用に終点を動かす半径の上限 (ブロック)。光源セルの外に出ると光源の隣の壁で遮られてしまう
const float LIGHT_JITTER_MAX_RADIUS = 0.45;
// LightDef.shape.w (光源の物理半径) に対する LIGHT_SOURCE_SIZE の倍率。既定 0.5 で物理半径そのもの
const float LIGHT_SOURCE_SIZE_SCALE = 2.0;

/*
 * ボクセルのセル座標に足すとワールドの 8 ブロック格子にそろう量 (LIGHT_CULL_MODE 1/2)
 * ボクセル体積はカメラのブロックに付いて動くので、そのままではビンの境界がカメラの 1 ブロックの移動ごとにずれ、
 * 溢れたビンで残る光源の組が歩くたびに入れ替わる
 */
ivec3 lightBinOffset() {
#if LIGHT_CULL_MODE == 0
    return ivec3(0);
#else
    return (getCameraBlock() - VOXEL_HALF) & (LIGHT_BIN_SIZE - 1);
#endif
}

ivec3 lightBinCoord(ivec3 cell) {
    return clamp((cell + lightBinOffset()) / LIGHT_BIN_SIZE, ivec3(0), LIGHT_BIN_GRID - 1);
}

int lightBinIndex(ivec3 cell) {
    ivec3 b = lightBinCoord(cell);
    return b.x + b.y * LIGHT_BIN_GRID.x + b.z * LIGHT_BIN_GRID.x * LIGHT_BIN_GRID.y;
}

/*
 * ビンの枠のキー: 上位 19 bit = 重要度 (正の float の bit 列の上位。大小関係が uint の大小と一致する),
 * 下位 13 bit = globalLights.lights のインデックス。0 は空き
 * 重要度の最下位 2 bit は光源のワールド位置のハッシュで置き換え、同じ重要度の光源 (並べたたいまつ等) の順位を
 * 毎フレーム変わるインデックス (登録の到着順) ではなく位置で決める
 */
const uint LIGHT_KEY_INDEX_BITS = 13u;
const uint LIGHT_KEY_INDEX_MASK = (1u << LIGHT_KEY_INDEX_BITS) - 1u;
const uint LIGHT_KEY_TIE_MASK = 3u;
// これより小さい重要度は丸める (キーが 0 = 空きにならないように)
const float LIGHT_KEY_MIN_IMPORTANCE = 1e-30;

uint packLightBinKey(float importance, uint index, uint tie) {
    uint q = floatBitsToUint(max(importance, LIGHT_KEY_MIN_IMPORTANCE)) >> 12u;
    q = (q & ~LIGHT_KEY_TIE_MASK) | (tie & LIGHT_KEY_TIE_MASK);
    return (q << LIGHT_KEY_INDEX_BITS) | index;
}
float lightBinKeyImportance(uint key) { return uintBitsToFloat((key >> LIGHT_KEY_INDEX_BITS) << 12u); }

uint lightBinBase(int bin) { return uint(bin * LIGHT_BIN_STRIDE); }
uint lightBinCount(int bin) { return min(lightBins.binCount[bin], uint(LIGHT_BIN_CAPACITY)); }
int lightBinEntry(int bin, uint k) { return int(lightBins.binLights[lightBinBase(bin) + k] & LIGHT_KEY_INDEX_MASK); }
uint globalLightCount() { return min(globalLights.count, uint(MAX_GLOBAL_LIGHTS)); }

/*
 * 溢れたビンの境界で光源を弱める幅 (重要度の比)。外れた光源のうち最も重要なもの (最後の枠) の重要度 x (1 + この値) 以上で 1
 * 光源が動く・増える時に、残る / 外れるの入れ替わりで明るさが飛ばないように、境界の近くの光源ほど弱めて連続にする
 * 大きくすると溢れたビン全体が暗くなる
 */
const float LIGHT_BIN_FADE = 0.15;

// ビンの k 番目の光源の重み (溢れていなければ 1)
float lightBinFade(int bin, uint k) {
#if LIGHT_CULL_MODE == 0
    return 1.0;
#else
    if (lightBins.binCount[bin] <= uint(LIGHT_BIN_CAPACITY)) return 1.0;
    uint base = lightBinBase(bin);
    float dropped = lightBinKeyImportance(lightBins.binLights[base + uint(LIGHT_BIN_CAPACITY)]);
    float own = lightBinKeyImportance(lightBins.binLights[base + k]);
    return saturate((own / max(dropped, LIGHT_KEY_MIN_IMPORTANCE) - 1.0) / LIGHT_BIN_FADE);
#endif
}

// ビンの k 番目の光源 (境界の重みを放射に掛け済み)。照度を求める所はこれを使う
LightInstance lightBinLight(int bin, uint k) {
    LightInstance L = globalLights.lights[lightBinEntry(bin, k)];
    L.colorSize.rgb *= lightBinFade(bin, k);
    return L;
}

// 幾何法線の NdotL がこれ以下ではテクスチャ法線の効きを弱める
const float LIGHT_NORMAL_GRAZING = 0.35;

/*
 * ブロック全体が光る光源 (グロウストーン・シーランタン・光る鉱物ブロックなど) の面からの近距離の放射
 * 中心の点からの近距離の放射では、ブロックの隣の床や壁が根元ほど明るくならない (根元は中心から 0.7 ブロック離れている)。
 * 着色点から見える面 (外向きの法線が着色点を向き、隣のセルが不透明でない面) ごとに、正方形の面光源の形態係数を
 * 多角形の解析式 (Lambert の式) で足す。面の中心の 1 点で近似すると、接地面の境目の真上では面の中心を見込む角が 0 になり、
 * 面の中央から丸く広がる点の光に見えた。面全体を積分するので、境目に近いほど明るく、境目に沿って一様に明るい
 * 面の向きで決まるので、並べた光るブロックの根元に隣のブロックの色は混ざらない。同じ平面に並ぶ面 (床に埋めた光源の隣の床) は光らない
 * 面の明るさは見た目の発光で決まり、光源の明るさとレベル (遠くへの届き方) とは別なので、呼ぶ側がそれで割った係数を掛ける
 */
const float LIGHT_BOX_RADIANCE = 4.5;   // 形態係数 1 の時の照度 / (色 x BLOCKLIGHT_ILLUMINANCE)
const float LIGHT_BOX_REACH = 4.0;      // 箱からこの距離で 0 へ落とす (ブロック)
const float LIGHT_BOX_COLOR_POWER = 1.5;

/*
 * 着色点 (原点、法線 n) から見た多角形 (頂点は着色点からの相対位置) の形態係数
 * F = 1 / (2 pi) |sum_i angle(v_i, v_i+1) * dot(n, normalize(cross(v_i, v_i+1)))|
 * 着色点の地平線より下の部分は先に切り取る (切り取らないと地平線の下の部分が負の寄与になる)
 */
float quadFormFactor(vec3 q[4], vec3 n) {
    vec3 p[5];
    int count = 0;
    for (int i = 0; i < 4; i++) {
        vec3 a = q[i];
        vec3 b = q[(i + 1) % 4];
        float da = dot(n, a);
        float db = dot(n, b);
        if (da >= 0.0) p[count++] = a;
        if ((da >= 0.0) != (db >= 0.0)) p[count++] = a + (b - a) * (da / (da - db));
    }
    if (count < 3) return 0.0;
    float sum = 0.0;
    for (int i = 0; i < count; i++) {
        vec3 a = normalize(p[i]);
        vec3 b = normalize(p[(i + 1) % count]);
        vec3 c = cross(a, b);
        float l = length(c);
        if (l > 1e-6) sum += acos(clamp(dot(a, b), -1.0, 1.0)) * dot(n, c / l);
    }
    return abs(sum) * (0.5 / PI);
}

float lightBoxNearField(vec3 voxelPos, vec3 boxCenter, vec3 n) {
    vec3 rel = voxelPos - boxCenter;
    float s = length(max(abs(rel) - 0.5, 0.0));
    if (s >= LIGHT_BOX_REACH) return 0.0;
    ivec3 cell = ivec3(floor(boxCenter));
    float sum = 0.0;
    for (int axis = 0; axis < 3; axis++) {
        float side = rel[axis] >= 0.0 ? 1.0 : -1.0;
        // 着色点が面の平面の外側にある時だけ見える
        if (abs(rel[axis]) <= 0.5) continue;
        ivec3 nb = cell;
        nb[axis] += int(side);
        if (isVoxelOpaque(fetchVoxelBlockId(nb))) continue;
        int b = (axis + 1) % 3;
        int c = (axis + 2) % 3;
        vec3 q[4];
        for (int k = 0; k < 4; k++) {
            vec3 o = vec3(0.0);
            o[axis] = 0.5 * side;
            o[b] = (k == 1 || k == 2) ? 0.5 : -0.5;
            o[c] = k >= 2 ? 0.5 : -0.5;
            q[k] = o - rel;
        }
        sum += quadFormFactor(q, n);
    }
    float w = 1.0 - s / LIGHT_BOX_REACH;
    return LIGHT_BOX_RADIANCE * sum * (w * w);
}

// 光源がブロック全体が光る不透明ブロック (光源の表の LT_OCC) か。光源のセルのブロックから光源の定義を引く
bool isBlockBoxLight(LightInstance L, out LightDef d, out int voxelId) {
    voxelId = fetchVoxelBlockId(ivec3(floor(L.posRadius.xyz)));
    int light = getBlockLightIndex(voxelId);
    d = getLightDef(light);
    return light != LIGHT_NONE && (d.info.x & LIGHT_FLAG_OCCLUDES) != 0u;
}

/*
 * 光源 L が voxelPos の面 (法線 n) に作る影なしの照度 (NdotL 込み)
 * gateNormal: この法線で地平線の下なら 0 (テクスチャ法線で照らす時に、幾何的に裏側の光源を拾わないため)
 * nearField: 光源のすぐ周りの近距離の放射を足すか。GI の 2 次ヒットでは足さない (光源のそばの狭い面だけが急に明るく、
 *   少ない本数のレイがそこに当たるかどうかで GI がノイズになる)
 */
vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal, bool nearField) {
    vec3 toL = L.posRadius.xyz - voxelPos;
    float dist = length(toL);
    if (dist >= L.posRadius.w) return vec3(0.0);
    vec3 dir = toL / max(dist, EPS);
    float radius = L.colorSize.a;
    float gate = sphereLightNdotL(gateNormal, dir, dist, radius);
    if (gate <= 0.0) return vec3(0.0);
    // かすめ角ではテクスチャ法線の NdotL が幾何法線の何倍にも振れ、テクセルごとの明暗が強くなりすぎる
    // TAA のジッターでピクセルがテクセルの境界をまたぐたびに値が飛び、床が細かくちらついた。幾何法線の NdotL に寄せる
    float ndl = mix(gate, sphereLightNdotL(n, dir, dist, radius), smoothstep(0.0, LIGHT_NORMAL_GRAZING, gate));
    float falloff = lightFalloff(dist, L.posRadius.w);
    if (!nearField) return L.colorSize.rgb * falloff * ndl;
    // 点に近い光源 (たいまつ・ランタンなど) は中心の点から近距離の放射を足す。ブロック全体が光る光源の面からの分は
    // 影を掛けずに足すので lightBoxIrradiance で別に求める
    LightDef d;
    int voxelId;
    if (dist < LIGHT_BOX_REACH + 1.0 && isBlockBoxLight(L, d, voxelId)) return L.colorSize.rgb * falloff * ndl;
    return L.colorSize.rgb * (falloff + lightNearField(dist, radius)) * ndl;
}

/*
 * ブロック全体が光る光源の面からの近距離の照度 (影を掛けない)
 * 光源の影は中心の点へのトレース (と接触影) なので、根元の床から中心へ向かうと光るブロック自身の面に当たって影になり、
 * 接地面の境目ほど暗くなった。光る面は見える面だけを数えている (lightBoxNearField) ので、影は掛けない
 */
vec3 lightBoxIrradiance(LightInstance L, vec3 voxelPos, vec3 gateNormal) {
    if (distance(L.posRadius.xyz, voxelPos) >= LIGHT_BOX_REACH + 1.0) return vec3(0.0);
    LightDef d;
    int voxelId;
    if (!isBlockBoxLight(L, d, voxelId)) return vec3(0.0);
    // 面の明るさは光源の明るさとレベルによらない (光る鉱物ブロックは遠くへは弱く届くが、面は他の発光ブロックと同じに光る)
    float lightLum = luminance(d.color.rgb);
    float power = luminance(L.colorSize.rgb) / max(lightLum, EPS) * LIGHT_LEVEL_MAX / max(d.color.a * d.params.z, EPS);
    // 面の色はブロックのテクスチャの色 (光源の表の色より鮮やかで、ブロックごとの色が根元に出る)。明るさは表の色に合わせる
    // 発光は明るい画素ほど強い (gbuffers の発光の推定) ので、平均色を 1.5 乗して明るく鮮やかな画素の色に寄せる
    vec3 albedo = pow(getBlockAlbedo(voxelId), vec3(LIGHT_BOX_COLOR_POWER));
    vec3 faceColor = albedo * (lightLum / max(luminance(albedo), EPS));
    return faceColor * (power * lightBoxNearField(voxelPos, floor(L.posRadius.xyz) + 0.5, gateNormal));
}

// 着色点のビンの全光源の、ブロック全体が光る面からの近距離の照度の和 (影なし)
vec3 sumBinBoxIrradiance(vec3 voxelPos, vec3 geoNormal) {
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    int bin = lightBinIndex(ivec3(voxelPos));
    uint n = lightBinCount(bin);
    vec3 sum = vec3(0.0);
    for (uint k = 0u; k < n; k++) {
        sum += lightBoxIrradiance(lightBinLight(bin, k), voxelPos, geoNormal);
    }
    return sum;
}

vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal) {
    return evalLightIrradiance(L, voxelPos, n, gateNormal, true);
}

// 着色点のビンの全光源の影なし照度の和 (deferred2 がフル解像度で使う)
vec3 sumBinLightsUnshadowed(vec3 voxelPos, vec3 normal, vec3 geoNormal, bool nearField) {
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    int bin = lightBinIndex(ivec3(voxelPos));
    uint n = lightBinCount(bin);
    vec3 sum = vec3(0.0);
    for (uint k = 0u; k < n; k++) {
        sum += evalLightIrradiance(lightBinLight(bin, k), voxelPos, normal, geoNormal, nearField);
    }
    return sum;
}

vec3 sumBinLightsUnshadowed(vec3 voxelPos, vec3 normal, vec3 geoNormal) {
    return sumBinLightsUnshadowed(voxelPos, normal, geoNormal, true);
}

// 光源サイズ由来の半影を作るための終点の揺らぎ半径
float lightJitterRadius(LightInstance L) {
    return min(L.colorSize.a * LIGHT_SOURCE_SIZE * LIGHT_SOURCE_SIZE_SCALE, LIGHT_JITTER_MAX_RADIUS);
}

// 光源の体 (エンティティ光源) で自分を遮らないよう、光源側でエンティティ占有を無視する距離
// 三角形方式の基礎値。ボクセルの 0.75 のままだと光源の脇に立ったプレイヤーの頭等が影から抜け落ちる
const float LIGHT_ENTITY_SKIP_TRI_BASE = 0.15;
const float LIGHT_ENTITY_SKIP_BASE = 0.25; // ボクセル方式の基礎値

float lightEntitySkip(LightInstance L) {
#ifdef ENTITY_TRI_OCCLUSION
    // たいまつ (半径 0.08) で 0.31、発光・燃焼エンティティ (半径 0.4) で体の大半を覆う 0.95
    return L.colorSize.a * 2.0 + LIGHT_ENTITY_SKIP_TRI_BASE;
#else
    return max(TRACE_ENTITY_SKIP_END, L.colorSize.a * 2.0 + LIGHT_ENTITY_SKIP_BASE);
#endif
}

/*
 * 低解像度トレースのサンプル配置。低解像度テクセル l は毎フレーム違うフル解像度テクセル
 * l * RES + offset(frame) を受け持つ (時間方向にフル解像度を巡回し、デノイズで埋める)
 */
ivec2 lightTraceFrameOffset(int frame) {
#if LIGHT_TRACE_RES == 1
    return ivec2(0);
#elif LIGHT_TRACE_RES == 2
    return bayerOffset2(frame & 3);
#else
    return bayerOffset4(frame);
#endif
}

ivec2 lightTraceLowResSize() { return (ivec2(viewSize()) + LIGHT_TRACE_RES - 1) / LIGHT_TRACE_RES; }

ivec2 lightTraceSourceTexel(ivec2 low, int frame) {
    return min(low * LIGHT_TRACE_RES + lightTraceFrameOffset(frame), ivec2(viewSize()) - 1);
}

// フル解像度テクセルに最も近い低解像度テクセル
ivec2 lightTraceNearestLow(ivec2 texel, int frame) {
    vec2 lp = vec2(texel - lightTraceFrameOffset(frame)) / float(LIGHT_TRACE_RES);
    return clamp(ivec2(floor(lp + 0.5)), ivec2(0), lightTraceLowResSize() - 1);
}

// 鏡面用の代表光源インデックスを fp16 に正確に入れる (fp16 は ±2048 までの整数が正確)
const float LIGHT_INDEX_BIAS = 2047.0;
float encodeLightIndex(int i) { return float(i) - LIGHT_INDEX_BIAS; }
int decodeLightIndex(float v) { return int(round(v + LIGHT_INDEX_BIAS)); }

#endif
