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

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/frame_offset.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/buffers/light_bins.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/ids/light_ids.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/light_bins.glsl"
//@include "/lib/light/trace.glsl"
//@include "/lib/light/voxel.glsl"
//@include "/lib/light/voxel_read.glsl"

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
uint globalLightCount() { return min(globalLights.count, uint(GLOBAL_LIGHTS_MAX)); }

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
const int LIGHT_DECOR_COUNT = 6;                      // LIGHT_DECOR_FIRST から続く飾りの鉱物ブロックの光源の数
const float LIGHT_BOX_DECOR_LUM_MIN = 0.42;           // ブロック自身の明るさの、光源の表の明るさに対する割合の下限 (暗い青のラピスラズリが消えないように)
const vec2 LIGHT_BOX_DECOR_LUM_FADE = vec2(0.25, 1.5); // 光源の表の明るさへ戻る箱からの距離 (ブロック)

/*
 * 面の形態係数に掛ける、箱からの距離 s (ブロック) の係数。形態係数だけでは面から 1 ブロックを超えると急に暗くなり、
 * 面全体が光っている感じが根元で終わる。光を何度か跳ねた GI の広がりに合わせて、根元で弱く、離れるほど強くして補う
 * 係数は根元の分 (影を掛けない) と広がりの分 (光源の影を掛ける) に配分し、合計は距離に対してなめらかに保つ
 * 面に近い所は光源自身の影になるので影なしで足し、離れるほど影を掛ける側へ移す。影なしの分は近くだけなので、壁の裏へは漏れない
 */
const float LIGHT_BOX_GAIN_ROOT = 0.83;             // 根元の係数
const float LIGHT_BOX_GAIN_MID = 1.05;              // 離れた所の係数
const vec2 LIGHT_BOX_GAIN_RISE = vec2(0.0, 0.5);    // 根元の係数から離れた所の係数へ移る箱からの距離 (ブロック)
const vec2 LIGHT_BOX_GAIN_FALL = vec2(1.75, 3.5);   // 係数が 0 に戻る距離
const vec2 LIGHT_BOX_ROOT_SPLIT = vec2(0.25, 1.25); // 係数が影なしから影を掛ける側へ移る距離

float lightBoxGain(float s) {
    return mix(LIGHT_BOX_GAIN_ROOT, LIGHT_BOX_GAIN_MID, smoothstep(LIGHT_BOX_GAIN_RISE.x, LIGHT_BOX_GAIN_RISE.y, s))
        * (1.0 - smoothstep(LIGHT_BOX_GAIN_FALL.x, LIGHT_BOX_GAIN_FALL.y, s));
}

// 係数のうち、影を掛けずに足す根元の分の割合
float lightBoxRootShare(float s) {
    return 1.0 - smoothstep(LIGHT_BOX_ROOT_SPLIT.x, LIGHT_BOX_ROOT_SPLIT.y, s);
}

float lightBoxSpread(float s) {
    return lightBoxGain(s) * (1.0 - lightBoxRootShare(s));
}

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

/*
 * 向きのある光源 (LIGHT_FLAG_FACING。点灯したかまど・ジャック・オ・ランタン) は前面だけが光る
 * 炉の口やくり抜いた顔の奥にだけ光源が見え、ほかの面は光源が見えない。前面の向きはブロック ID の向き (blockLightFacing)
 */
const int LIGHT_FACE_FRONT = 3;

// 水平の面 (axis, side) の外向きの向き (0 北 = -z、1 東 = +x、2 南 = +z、3 西 = -x)。上下の面は -1
int lightFaceFacing(int axis, float side) {
    if (axis == 1) return -1;
    return axis == 2 ? (side > 0.0 ? 2 : 0) : (side > 0.0 ? 1 : 3);
}

/*
 * 光るブロックの面の光り方 (LIGHT_FLAG_EMISSION_MASK の付いた光源)。テクスチャの暗い縁を面光源に反映する
 * 面の光り方は光る範囲の四角 (rect) と、その中の割合 (ratio)。四角の中を一様に光らせ、面全体の光の量は変えない
 * ratio は光源の最も明るい面の光る部分を 1 とするので、明るい面の光る部分は面全体が光る時と同じ明るさのまま、暗い縁の分だけ減る
 * LIGHT_EMISSION_MASK_MODE 2 では四角を 4x4 に分けたマスの重みで、四角の中の模様も反映する
 * 向きのある光源の前面は、モード 0 でもこの四角で数える (面全体を光らせると、炉の口の周りの石まで光る)
 */
const int LIGHT_FACE_UP = 0;
const int LIGHT_FACE_DOWN = 1;
const int LIGHT_FACE_SIDE = 2;

struct LightFaceMask {
    vec4 rect;        // 光る範囲 (u0, v0, u1, v1)。テクスチャの座標で v は上が 0
    float ratio;
    float gridScale;  // マスの重みの最大
    uvec2 grid;       // 4x4 のマス (lib/buffers/block_data.glsl の lightMasks)
};

LightFaceMask readLightMask(int light, int faceClass) {
    uvec4 m = blockData.lightMasks[clamp(light, 0, LIGHT_MASK_LIGHTS - 1) * LIGHT_MASK_FACE_CLASSES + faceClass];
    LightFaceMask f;
    f.rect = unpackUnorm4x8(m.x);
    vec2 h = unpackHalf2x16(m.y);
    f.ratio = h.x;
    f.gridScale = h.y;
    f.grid = m.zw;
    return f;
}

// データの無い光源は面全体を一様に光らせる
LightFaceMask wholeLightFace() {
    LightFaceMask f;
    f.rect = vec4(0.0, 0.0, 1.0, 1.0);
    f.ratio = 1.0;
    f.gridScale = 0.0;
    f.grid = uvec2(0u);
    return f;
}

int lightFaceClass(int axis, float side) {
    return axis == 1 ? (side > 0.0 ? LIGHT_FACE_UP : LIGHT_FACE_DOWN) : LIGHT_FACE_SIDE;
}

/*
 * 面のテクスチャの座標 (u, v) を、面の平面の 2 軸 (b = (axis + 1) % 3, c = (axis + 2) % 3) の位置 [-0.5, 0.5] へ写す
 * Minecraft の既定の UV (外から見て正立、u は右、v は下) の向き。side は面の外向きの符号
 */
vec2 lightFaceUvToBox(int axis, float side, vec2 uv) {
    vec2 p = uv - 0.5;
    if (axis == 0) return vec2(-p.y, side > 0.0 ? -p.x : p.x);
    if (axis == 1) return vec2(side > 0.0 ? p.y : -p.y, p.x);
    return vec2(side * p.x, -p.y);
}

// 面の中の (u, v) の四角 a..b の、着色点 (箱の中心からの相対位置 rel) から見た形態係数
float lightMaskQuad(int axis, float side, vec2 a, vec2 b, vec3 rel, vec3 n) {
    vec3 q[4];
    for (int k = 0; k < 4; k++) {
        vec2 uv = vec2((k == 1 || k == 2) ? b.x : a.x, k >= 2 ? b.y : a.y);
        vec2 bc = lightFaceUvToBox(axis, side, uv);
        vec3 o = vec3(0.0);
        o[axis] = 0.5 * side;
        o[(axis + 1) % 3] = bc.x;
        o[(axis + 2) % 3] = bc.y;
        q[k] = o - rel;
    }
    return quadFormFactor(q, n);
}

// 面の種類の光の量 (面全体が光る時を 1 とした割合)
float lightMaskEnergy(LightFaceMask f) {
    return f.ratio * (f.rect.z - f.rect.x) * (f.rect.w - f.rect.y);
}

#if LIGHT_EMISSION_MASK_MODE != 0
/*
 * 点に近い光源 (ランタン) の近距離の放射に掛ける向きの重み。d は光源から着色点への単位ベクトル
 * 面の種類の光の量を、その向きから見た面の見かけの面積 (d の成分の絶対値) で混ぜ、最も光る面の種類を 1 とする
 * (近距離の放射の明るさは最も光る向きで調整してあるので、そこは変えない)。ふたが光らないランタンは真下で 0 になる
 */
float lightMaskDirection(int light, vec3 d) {
    float side = lightMaskEnergy(readLightMask(light, LIGHT_FACE_SIDE));
    float up = lightMaskEnergy(readLightMask(light, LIGHT_FACE_UP));
    float down = lightMaskEnergy(readLightMask(light, LIGHT_FACE_DOWN));
    float peak = max(side, max(up, down));
    vec3 a = abs(d);
    float vert = d.y > 0.0 ? up : down;
    return (side * (a.x + a.z) + vert * a.y) / max(peak * (a.x + a.y + a.z), EPS);
}
#endif

#if LIGHT_EMISSION_MASK_MODE == 2
const int LIGHT_MASK_GRID = 4;
const float LIGHT_MASK_GRID_LEVELS = 15.0;
// 箱からこの距離までは 4x4 のマスで求め、次の幅で四角へ混ぜる (ブロック)。マスは 16 回の形態係数で重いので近くだけにする
// 1 ブロック先ではマスと四角の差が 2% 以内。1.0 / 0.5 では部屋で 0.9 ms、壁際の拡大で 2 ms 増えたので半分にした
const float LIGHT_MASK_GRID_REACH = 0.5;
const float LIGHT_MASK_GRID_FADE = 0.25;

// 光る範囲の四角を 4x4 に分けたマスごとの形態係数の、重み付きの和
float lightMaskGridFormFactor(LightFaceMask f, int axis, float side, vec3 rel, vec3 n) {
    float sum = 0.0;
    for (int k = 0; k < LIGHT_MASK_GRID * LIGHT_MASK_GRID; k++) {
        uint q = ((k < 8 ? f.grid.x : f.grid.y) >> (4u * uint(k & 7))) & 15u;
        if (q == 0u) continue;
        vec2 cell = vec2(k & 3, k >> 2) / float(LIGHT_MASK_GRID);
        vec2 a = mix(f.rect.xy, f.rect.zw, cell);
        vec2 b = mix(f.rect.xy, f.rect.zw, cell + 1.0 / float(LIGHT_MASK_GRID));
        sum += float(q) * lightMaskQuad(axis, side, a, b, rel, n);
    }
    return sum * (f.gridScale / LIGHT_MASK_GRID_LEVELS);
}
#endif

/*
 * light: 光源インデックス、masked: 面の光り方のデータがあるか、grid: 近くで 4x4 のマスを使うか (LIGHT_EMISSION_MASK_MODE 2)
 * 0 では面全体を光らせるので、この 3 つは使わない (向きのある光源の前面を除く)
 * facing: 向きのある光源の前面の向き (blockLightFacing)。-1 は向きなしで、向きがあれば前面の面だけを数える (どのモードでも)
 * 戻り値は見える面の形態係数の和 (光る範囲の割合込み)。s は着色点から箱までの距離 (ブロック)
 */
float lightBoxFormFactors(vec3 voxelPos, vec3 boxCenter, vec3 n, int light, bool masked, bool grid, int facing, out float s) {
    bool useMask = LIGHT_EMISSION_MASK_MODE != 0 || (facing >= 0 && masked);
    // 呼ぶ所は面から TRACE_NORMAL_OFFSET だけ浮かせた点を渡す。浮いたままだと、テクスチャの縁 (1 画素 = 0.0625) の下半分が
    // 着色点の水平線の下になり、接地面の境目の暗い縁が効かない。光る範囲を使う時は面の上の点から見る
    vec3 rel = voxelPos - (useMask ? n * TRACE_NORMAL_OFFSET : vec3(0.0)) - boxCenter;
    s = length(max(abs(rel) - 0.5, 0.0));
    if (s >= LIGHT_BOX_REACH) return 0.0;
    ivec3 cell = ivec3(floor(boxCenter));
    float sum = 0.0;
    for (int axis = 0; axis < 3; axis++) {
        float side = rel[axis] >= 0.0 ? 1.0 : -1.0;
        // 着色点が面の平面の外側にある時だけ見える
        if (abs(rel[axis]) <= 0.5) continue;
        if (facing >= 0 && lightFaceFacing(axis, side) != facing) continue;
        ivec3 nb = cell;
        nb[axis] += int(side);
        if (isVoxelOpaque(fetchVoxelBlockId(nb))) continue;
        if (!useMask) {
            sum += lightMaskQuad(axis, side, vec2(0.0), vec2(1.0), rel, n);
            continue;
        }
        LightFaceMask f = masked ? readLightMask(light, facing >= 0 ? LIGHT_FACE_FRONT : lightFaceClass(axis, side)) : wholeLightFace();
        if (f.ratio <= 0.0) continue;
        float ff = f.ratio * lightMaskQuad(axis, side, f.rect.xy, f.rect.zw, rel, n);
#if LIGHT_EMISSION_MASK_MODE == 2
        float gridMix = saturate((s - LIGHT_MASK_GRID_REACH) / LIGHT_MASK_GRID_FADE);
        // 向きのある光源の前面は、火が炉の口の奥にあって枠に遮られる。マスで火の下の行を近くから見ると、接地面の境目に鋭い筋が出る
        if (grid && masked && facing < 0 && gridMix < 1.0) ff = mix(lightMaskGridFormFactor(f, axis, side, rel, n), ff, gridMix);
#endif
        sum += ff;
    }
    return sum;
}

// 光源がブロック全体が光る不透明ブロック (光源の表の LT_OCC) か。光源のセルのブロックから光源の定義を引く
bool isBlockBoxLight(LightInstance L, out LightDef d, out int voxelId, out int light) {
    voxelId = fetchVoxelBlockId(ivec3(floor(L.posRadius.xyz)));
    light = getBlockLightIndex(voxelId);
    d = getLightDef(light);
    return light != LIGHT_NONE && (d.info.x & LIGHT_FLAG_OCCLUDES) != 0u;
}

/*
 * ブロック全体が光る光源の面からの近距離の照度。戻り値は根元の分 (影を掛けない)、spread は離れた所の広がりの分
 * 光源の影は中心の点へのトレース (と接触影) なので、根元の床から中心へ向かうと光るブロック自身の面に当たって影になり、
 * 接地面の境目ほど暗くなった。光る面は見える面だけを数えている (lightBoxFormFactors) ので、根元は影を掛けない
 * 広がりは光源の影を掛ける側 (evalLightIrradiance、deferred2 の full) に入れるので、壁の裏へ漏れない
 * grid: 近くで 4x4 のマスを使うか (LIGHT_EMISSION_MASK_MODE 2)。マスは重いので、画面の大半を占める deferred2 だけが true を渡す
 */
vec3 lightBoxTerms(LightInstance L, vec3 voxelPos, vec3 gateNormal, bool grid, out vec3 spread) {
    spread = vec3(0.0);
    if (distance(L.posRadius.xyz, voxelPos) >= LIGHT_BOX_REACH + 1.0) return vec3(0.0);
    LightDef d;
    int voxelId;
    int light;
    if (!isBlockBoxLight(L, d, voxelId, light)) return vec3(0.0);
    vec3 boxCenter = floor(L.posRadius.xyz) + 0.5;
    bool masked = (d.info.x & LIGHT_FLAG_EMISSION_MASK) != 0u;
    int facing = (d.info.x & LIGHT_FLAG_FACING) != 0u ? blockLightFacing(voxelId) : -1;
    float s;
    float sum = lightBoxFormFactors(voxelPos, boxCenter, gateNormal, light, masked, grid, facing, s);
    if (sum <= 0.0) return vec3(0.0);
    // 面の明るさは光源の明るさとレベルによらない (光る鉱物ブロックは遠くへは弱く届くが、面は他の発光ブロックと同じに光る)
    float lightLum = luminance(d.color.rgb);
    float power = luminance(L.colorSize.rgb) / max(lightLum, EPS) * LIGHT_LEVEL_MAX / max(d.color.a * d.params.z, EPS);
    // 面の色はブロックのテクスチャの色 (光源の表の色より鮮やかで、ブロックごとの色が根元に出る)。明るさは表の色に合わせる
    // 発光は明るい画素ほど強い (gbuffers の発光の推定) ので、平均色を 1.5 乗して明るく鮮やかな画素の色に寄せる
    vec3 albedo = pow(getBlockAlbedo(voxelId), vec3(LIGHT_BOX_COLOR_POWER));
    vec3 faceColor = albedo * (lightLum / max(luminance(albedo), EPS));
    // 向きのある光源は光るのが火の部分だけで、ブロックの平均の色 (かまどの灰色の石) ではなく光源の色で光る
    if (facing >= 0) faceColor = d.color.rgb;
    // 飾りの鉱物ブロックは光源の表の明るさがブロックの色と合わず (暗い赤のレッドストーンも他と同じ明るさになる)、
    // 根元ではブロック自身の色の明るさで光らせ、離れるほど光源の表の明るさへ戻す
    if (light >= LIGHT_DECOR_FIRST && light < LIGHT_DECOR_FIRST + LIGHT_DECOR_COUNT) {
        float own = max(luminance(getBlockAlbedo(voxelId)) / max(lightLum, EPS), LIGHT_BOX_DECOR_LUM_MIN);
        faceColor *= mix(own, 1.0, smoothstep(LIGHT_BOX_DECOR_LUM_FADE.x, LIGHT_BOX_DECOR_LUM_FADE.y, s));
    }
    vec3 irradiance = faceColor * (power * LIGHT_BOX_RADIANCE * sum);
    spread = irradiance * lightBoxSpread(s);
    return irradiance * (lightBoxGain(s) * lightBoxRootShare(s));
}

vec3 lightBoxIrradiance(LightInstance L, vec3 voxelPos, vec3 gateNormal, bool grid) {
    vec3 spread;
    return lightBoxTerms(L, voxelPos, gateNormal, grid, spread);
}

vec3 lightBoxIrradiance(LightInstance L, vec3 voxelPos, vec3 gateNormal) {
    return lightBoxIrradiance(L, voxelPos, gateNormal, false);
}

/*
 * 広がりの分の簡易版 (deferred1 の光源の重みと可視率の比、前方のエンティティ、反射の 2 次ヒット用)
 * 面の形態係数を、箱からの距離だけで決まる関数で置き換える (壁が広い時の値。光源ごとの形の違いは重みの差になるだけ)
 * 光源ごとに 4 角形の形態係数を求めるとトレースのパスが重くなり、フレームが 2 ms ほど延びた
 */
const float LIGHT_BOX_SPREAD_FF = 0.5;
const float LIGHT_BOX_SPREAD_FF_SCALE = 0.55;
const float LIGHT_BOX_SPREAD_FF_POWER = 1.6;

vec3 lightBoxSpreadApprox(LightInstance L, LightDef d, vec3 voxelPos) {
    float s = length(max(abs(voxelPos - (floor(L.posRadius.xyz) + 0.5)) - 0.5, 0.0));
    if (s >= LIGHT_BOX_REACH) return vec3(0.0);
    float ff = LIGHT_BOX_SPREAD_FF / (1.0 + pow(s / LIGHT_BOX_SPREAD_FF_SCALE, LIGHT_BOX_SPREAD_FF_POWER));
    // 光源の色を、明るさとレベルによらない面の明るさへ戻す (lightBoxTerms の power と同じ)
    vec3 unit = L.colorSize.rgb * (LIGHT_LEVEL_MAX / max(d.color.a * d.params.z, EPS));
    return unit * (LIGHT_BOX_RADIANCE * ff * lightBoxSpread(s));
}

/*
 * 光源 L が voxelPos の面 (法線 n) に作る影なしの照度 (NdotL 込み)
 * gateNormal: この法線で地平線の下なら 0 (テクスチャ法線で照らす時に、幾何的に裏側の光源を拾わないため)
 * nearField: 光源のすぐ周りの近距離の放射を足すか。GI の 2 次ヒットでは足さない (光源のそばの狭い面だけが急に明るく、
 *   少ない本数のレイがそこに当たるかどうかで GI がノイズになる)
 * boxSpread: ブロック全体が光る光源の広がりの分 (簡易版) を足すか。deferred2 は面の分と一緒に正確に求めるので false
 */
vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal, bool nearField, bool boxSpread) {
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
    // 点に近い光源 (たいまつ・ランタンなど) は中心の点から近距離の放射を足す。ブロック全体が光る光源は、根元の分を
    // 影を掛けずに lightBoxIrradiance で別に足し、離れた所の広がりの分だけここで足す
    LightDef d;
    int voxelId;
    int light;
#if LIGHT_EMISSION_MASK_MODE == 0
    if (dist < LIGHT_BOX_REACH + 1.0 && isBlockBoxLight(L, d, voxelId, light)) {
        return L.colorSize.rgb * falloff * ndl + (boxSpread ? lightBoxSpreadApprox(L, d, voxelPos) : vec3(0.0));
    }
    return L.colorSize.rgb * (falloff + lightNearField(dist, radius)) * ndl;
#else
    // ふたが光らないランタンなどは、近距離の放射を着色点の向きで弱める (光源のセルのブロックから面の光り方を引く)
    float near = 0.0;
    if (dist < LIGHT_NEAR_REACH) {
        bool box = isBlockBoxLight(L, d, voxelId, light);
        if (dist < LIGHT_BOX_REACH + 1.0 && box) {
            return L.colorSize.rgb * falloff * ndl + (boxSpread ? lightBoxSpreadApprox(L, d, voxelPos) : vec3(0.0));
        }
        near = lightNearField(dist, radius);
        if ((d.info.x & LIGHT_FLAG_EMISSION_MASK) != 0u) near *= lightMaskDirection(light, -dir);
    }
    return L.colorSize.rgb * (falloff + near) * ndl;
#endif
}

vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal, bool nearField) {
    return evalLightIrradiance(L, voxelPos, n, gateNormal, nearField, true);
}

// 広がりの分を足してよい光源か。evalLightIrradiance と同じ条件 (光の届く範囲と、中心の地平線)
bool lightBoxSpreadReaches(LightInstance L, vec3 voxelPos, vec3 gateNormal) {
    vec3 toL = L.posRadius.xyz - voxelPos;
    float dist = length(toL);
    return dist < L.posRadius.w && sphereLightNdotL(gateNormal, toL / max(dist, EPS), dist, L.colorSize.a) > 0.0;
}

/*
 * 着色点のビンの全光源の、ブロック全体が光る面からの近距離の照度の和。戻り値は影なしの根元の分
 * spread は広がりの分で、evalLightIrradiance と同じ条件 (光の届く範囲と中心の地平線) で数える。光源の影を掛ける側 (deferred2 の full) に足す
 */
vec3 sumBinBoxIrradiance(vec3 voxelPos, vec3 geoNormal, bool grid, out vec3 spread) {
    spread = vec3(0.0);
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    int bin = lightBinIndex(ivec3(voxelPos));
    uint n = lightBinCount(bin);
    vec3 sum = vec3(0.0);
    for (uint k = 0u; k < n; k++) {
        LightInstance L = lightBinLight(bin, k);
        vec3 s;
        sum += lightBoxTerms(L, voxelPos, geoNormal, grid, s);
        if (maxOf(s) > 0.0 && lightBoxSpreadReaches(L, voxelPos, geoNormal)) spread += s;
    }
    return sum;
}

vec3 sumBinBoxIrradiance(vec3 voxelPos, vec3 geoNormal, bool grid) {
    vec3 spread;
    return sumBinBoxIrradiance(voxelPos, geoNormal, grid, spread);
}

vec3 sumBinBoxIrradiance(vec3 voxelPos, vec3 geoNormal) {
    return sumBinBoxIrradiance(voxelPos, geoNormal, false);
}

vec3 evalLightIrradiance(LightInstance L, vec3 voxelPos, vec3 n, vec3 gateNormal) {
    return evalLightIrradiance(L, voxelPos, n, gateNormal, true);
}

// 着色点のビンの全光源の影なし照度の和 (deferred2 がフル解像度で使う)
vec3 sumBinLightsUnshadowed(vec3 voxelPos, vec3 normal, vec3 geoNormal, bool nearField, bool boxSpread) {
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    int bin = lightBinIndex(ivec3(voxelPos));
    uint n = lightBinCount(bin);
    vec3 sum = vec3(0.0);
    for (uint k = 0u; k < n; k++) {
        sum += evalLightIrradiance(lightBinLight(bin, k), voxelPos, normal, geoNormal, nearField, boxSpread);
    }
    return sum;
}

vec3 sumBinLightsUnshadowed(vec3 voxelPos, vec3 normal, vec3 geoNormal, bool nearField) {
    return sumBinLightsUnshadowed(voxelPos, normal, geoNormal, nearField, true);
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
