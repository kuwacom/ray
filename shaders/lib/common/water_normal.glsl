/*
 * 水面の法線: 水たまり・雨の波紋・流れ・側面の落ちる水・視差・コースティクス
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_NORMAL_GLSL
#define COMMON_WATER_NORMAL_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/dimension.glsl"
//@include "/lib/common/encoding.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/water_waves.glsl"

/*
 * 水たまりの鏡面を広げる傾きの分散 (deferred30)
 * 水たまりは滑らかさ 0.99 の鏡なので、太陽・灯りの鏡面は光源の円盤の鏡像になる。風の揺れは下の小さな波 (法線) が受け持ち、
 * 粗さへ回すのは雨粒の跳ねと画素より細かい波紋だけ。止んだ後の水たまりは光源の円盤の大きさの鋭い鏡像になる
 */
const float PUDDLE_RAIN_SLOPE_VAR = 0.002;   // 本降りの雨粒の跳ねと画素より細かい波紋の傾きの分散 (PUDDLE_RIPPLES = 1)

float puddleSlopeVar() {
    return PUDDLE_RAIN_SLOPE_VAR * rainStrength * PUDDLE_RIPPLES;
}

/*
 * 水たまりのごく小さな波。吹送距離が水たまりの大きさしか無いので、水の波のテクスチャの短い 2 層だけを小さな傾きで足す
 * 傾きは反射の向きを 1 度ほど揺らすだけで、映り込みの輪郭がわずかに揺れる程度 (水面のような波模様は出さない)
 * 海の状態 (waterSeaState) は地形の全画素で呼ぶには重いので使わない
 */
const float PUDDLE_WAVE_SLOPE = 0.004;     // 層ごとの傾きの RMS
const float PUDDLE_WAVE_RAIN_GAIN = 1.5;   // 降っている間の倍率 (雨の風)
const int PUDDLE_WAVE_FIRST_LAYER = WATER_LAYERS - 2;

// footprint: 画素の大きさ (ブロック)。画素より細かい層は足さない (遠くの水たまりが砂目にならないように)
vec2 puddleWaveGradient(vec2 xz, float footprint) {
#ifdef WATER_WAVES
    float amp = PUDDLE_WAVE_SLOPE * WATER_RIPPLES * mix(1.0, PUDDLE_WAVE_RAIN_GAIN, rainStrength);
    float t = frameTimeCounter;
    vec2 g = vec2(0.0);
    for (int i = PUDDLE_WAVE_FIRST_LAYER; i < WATER_LAYERS; i++) {
        float r = waterLayerResolved(i, footprint);
        if (r <= 0.0) break;
        g += waterLayer(xz, i, amp * r, t).yz;
    }
    return g;
#else
    return vec2(0.0);
#endif
}

/*
 * 雨の波紋 (1 層)。セルの中に 1 つ、広がって消える輪を置く。戻り値は高さの勾配
 */
const float RIPPLE_CELL = 0.7;      // セルの大きさ (ブロック)
const float RIPPLE_RATE = 1.1;      // 1 秒あたりの発生回数
const float RIPPLE_FREQ = 55.0;     // 輪の細かさ
const float RIPPLE_STRENGTH = 0.012;

vec2 rippleLayer(vec2 p, float t, uint seed) {
    vec2 cell = floor(p);
    vec2 f = p - cell;
    vec3 h = hash3(uvec3(uvec2(ivec2(cell) + 32768), seed));
    vec2 c = 0.3 + 0.4 * h.xy;
    float phase = fract(t * RIPPLE_RATE + h.z);
    vec2 d = f - c;
    float r = length(d);
    // 輪の最大半径をセル端までに収めて隣のセルを見なくて済むようにする
    float x = (r - phase * 0.3) * RIPPLE_FREQ;
    float window = saturate(1.0 - abs(x) / TAU);
    float env = sqr(1.0 - phase) * window;
    return cos(x) * RIPPLE_FREQ * env * d / max(r, 1e-4);
}

// 雨の波紋の勾配 (ブロック座標)。strength は雨の強さ x 露天度
vec2 rainRipples(vec2 p, float strength) {
    if (strength <= 0.001) return vec2(0.0);
    float t = frameTimeCounter;
    vec2 g = rippleLayer(p / RIPPLE_CELL, t, 11u) + rippleLayer(p / RIPPLE_CELL + 0.5, t + 0.37, 23u);
    return g * RIPPLE_STRENGTH / RIPPLE_CELL * strength;
}

// 水面の 2D 座標系 (法線を z とする基底)。水平面はワールドの xz、側面は面内の 2 軸
mat3 waterBasis(vec3 geoNormal) {
    if (abs(geoNormal.y) > 0.5) {
        float s = sign(geoNormal.y);
        return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, s), geoNormal);
    }
    return tbnFromNormal(geoNormal);
}

/*
 * 流れの速度 (水面の 2D 座標, ブロック/秒)。faceNormal: 三角形の実際の向き (画面微分から)
 * バニラの流れる水の上面は角ごとに高さが違って傾き、法線は下流側へ倒れる。側面 (滝) は下へ流れる
 */
vec2 waterFlowVelocity(vec3 faceNormal, vec3 geoNormal) {
    if (abs(geoNormal.y) > 0.5) {
        vec2 tilt = faceNormal.xz * sign(geoNormal.y);
        float slope = length(tilt);
        if (slope < 0.02) return vec2(0.0);
        return tilt / slope * min(slope * WATER_FLOW_SPEED / max(abs(faceNormal.y), 0.2), WATER_FLOW_MAX);
    }
    mat3 basis = waterBasis(geoNormal);
    return vec2(-basis[0].y, -basis[1].y) * WATER_FALL_SPEED;
}

/*
 * 側面 (滝・流れの段差) の波。海の FFT の層をそのまま面に貼ると、海のバイオームでは 22 ブロックの長い波が
 * 1-2 ブロック幅の滝の上では一様な傾きになり、ゆっくり傾くだけの滑らかなガラス板に見えた
 * 落ちる水の乱れは流れの向きに引き伸ばされた細かい筋 (縦に長いさざ波) なので、同じ波テクスチャの短い帯だけを
 * 縦に引き伸ばして貼り、下へ流す。テクスチャの風下 (+x) を面の横に向けると波の峰が縦に並ぶ
 * 強さはバイオーム (風) によらない。滝の落ちる速さは WATER_FALL_SPEED
 */
const int WATER_FALL_LAYERS = 3;
// 層の横のタイルの大きさ (ブロック)。帯の中心の波長はタイル / WATER_BAND_CENTER (0.94, 0.33, 0.12 ブロック)
const float WATER_FALL_TILE[WATER_FALL_LAYERS] = float[](8.0, 2.8, 1.0);
// 層ごとの傾きの RMS (横方向。縦は WATER_FALL_STRETCH で割れる)
const float WATER_FALL_SLOPE[WATER_FALL_LAYERS] = float[](0.10, 0.08, 0.05);
// 層ごとの落ちる速さの倍率。同じ速さだと模様が 1 枚の絵のまま滑り落ちて見えるので、細かい乱れほど少し速くする
const float WATER_FALL_LAYER_SPEED[WATER_FALL_LAYERS] = float[](1.0, 1.25, 1.6);
const vec2 WATER_FALL_LAYER_OFFSET[WATER_FALL_LAYERS] = vec2[](vec2(0.21, 0.63), vec2(0.77, 0.18), vec2(0.45, 0.91));
const float WATER_FALL_STRETCH = 3.0;          // 縦の引き伸ばし
// 波テクスチャの時間の進み (層の周期に対する倍率)。テクスチャの波は風下 (= 面の横) へ進むので、速いと峰が横へ流れて見える
const float WATER_FALL_EVOLVE = 0.35;

// 側面の面内の座標 (x = 面の横, y = 高さ) と、その横の向き
vec3 waterFallTangent(vec3 geoNormal) { return normalize(vec3(-geoNormal.z, 0.0, geoNormal.x)); }

float waterFallLayerResolved(int i, float footprint) {
    return footprint > 0.0 ? 1.0 - smoothstep(WATER_LOD_FADE_START, WATER_LOD_FADE_END, footprint * WATER_TEX_SIZE / WATER_FALL_TILE[i]) : 1.0;
}

// 側面の波の勾配 (面内の 2D: x = 横, y = 高さ)
vec2 waterFallGradient(vec3 worldPos, vec3 geoNormal, float footprint) {
    vec2 p = vec2(dot(worldPos, waterFallTangent(geoNormal)), worldPos.y);
    float t = frameTimeCounter;
    vec2 g = vec2(0.0);
    for (int i = 0; i < WATER_FALL_LAYERS; i++) {
        float r = waterFallLayerResolved(i, footprint);
        if (r <= 0.0) break;
        float tile = WATER_FALL_TILE[i];
        // 高さに落ちた距離を足すと、同じ模様が時間とともに下へ動く
        vec2 q = vec2(p.x / tile, (p.y + WATER_FALL_SPEED * WATER_FALL_LAYER_SPEED[i] * t) / (tile * WATER_FALL_STRETCH))
            + WATER_FALL_LAYER_OFFSET[i];
        vec4 s = texture(waterWaveTex, vec3(q, t * WATER_FALL_EVOLVE / waterLayerPeriod(tile))) * 2.0 - 1.0;
        // 縦に引き伸ばした分だけ縦の傾きは緩む
        g += vec2(s.x, s.y / WATER_FALL_STRETCH) * (WATER_TEX_SLOPE_RANGE * WATER_FALL_SLOPE[i] * r);
    }
    return g;
}

// 側面の画素より細かい乱れの傾きの分散 (太陽の鏡面の粗さへ回す)
float waterFallUnresolvedSlopeVar(float footprint) {
    float v = 0.0;
    for (int i = 0; i < WATER_FALL_LAYERS; i++) {
        float r = waterFallLayerResolved(i, footprint);
        v += (1.0 - r * r) * sqr(WATER_FALL_SLOPE[i]);
    }
    return v;
}

vec3 waterFallNormal(vec3 worldPos, vec3 geoNormal, float footprint) {
    vec2 g = waterFallGradient(worldPos, geoNormal, footprint);
    return normalize(mat3(waterFallTangent(geoNormal), vec3(0.0, 1.0, 0.0), geoNormal) * vec3(-g, 1.0));
}

/*
 * 水面の法線 (player 空間)。worldPos は cameraPosition を足したワールド座標, footprint は waterFootprint, flow は waterFlowVelocity
 */
vec3 getWaterNormal(WaterSea sea, vec3 worldPos, vec3 geoNormal, float footprint, vec2 flow) {
#ifdef WATER_WAVES
    if (abs(geoNormal.y) <= 0.5) return waterFallNormal(worldPos, geoNormal, footprint);
    mat3 basis = waterBasis(geoNormal);
    vec2 p = vec2(dot(worldPos, basis[0]), dot(worldPos, basis[1]));
    vec2 g = waterChoppy(waterWaveSumFlow(sea, p, 0, WATER_LAYERS, footprint, flow)).yz;
    #ifdef HAS_SKY
        if (geoNormal.y > 0.5 && biome_precipitation == 1) g += rainRipples(p, rainStrength);
    #endif
    return normalize(basis * vec3(-g, 1.0));
#else
    return geoNormal;
#endif
}

/*
 * 反射方向に使う水面の法線。かすめ角では波の傾きを弱める
 * 遠くの島の映り込みは手前 (数十ブロック) の水面に入り、そこでは波が全部表せていて反射方向が島の見かけの高さ (数度) より
 * 大きく振れるので、映り込みが空と交互の細かい斑になって消えていた。太陽の照り返しと屈折・フレネルは元の法線のまま
 */
// 0.3 では中景の反射が地平線のもやを一様に映す白っぽい面になった。画素より細かい波は層ごと落とすようになり
// (waterFootprint を伸びた辺で測る)、中景に残るのは長い波だけで斑にならないので、傾きを多めに残して雲を映させる
const float WATER_REFLECT_GRAZING_KEEP = 0.6; // 真横から見た時に残す傾きの割合
const float WATER_REFLECT_GRAZING_NOV = 0.4;  // 視線と水面の cos がこれ以上なら傾きをそのまま使う

vec3 waterReflectNormal(vec3 N, vec3 V) {
    if (abs(N.y) < 0.5) return N;
    float keep = mix(WATER_REFLECT_GRAZING_KEEP, 1.0, smoothstep(0.0, WATER_REFLECT_GRAZING_NOV, abs(V.y)));
    return normalize(vec3(N.x * keep, N.y, N.z * keep));
}

/*
 * 水面の視差: 平均水面上の点 worldPos から視線方向 viewDir (カメラ -> 水面, 正規化) に沿って
 * 波の高さ場との交点を探す。上向きの面だけ。波の高さの +-WATER_PARALLAX_RANGE x RMS の間を等間隔に探して、最後に割線で詰める
 * (固定点反復は斜面の傾きが視線の傾きより大きいかすめ角で発散する)
 * かすめ角では探す距離が WATER_PARALLAX_MAX に収まるよう高さを縮める。そのままだと手前の大きな波の斜面が画面の大半に
 * 引き伸ばされてぼやけ、探す範囲を切った所で視差が途切れて段差が出た
 */
const int WATER_PARALLAX_STEPS = 5;
const float WATER_PARALLAX_RANGE = 2.5;
const float WATER_PARALLAX_MAX = 1.5;          // 視線に沿って探す最大距離 (ブロック)
// 視差に使う長い層の数。3 番目 (波長 1-8 ブロック) の高さは 0.03 ブロック前後で、足すと全画面の水で 1 ms 近く重くなる (GTX 1070, 1080p)
const int WATER_PARALLAX_LAYERS = 2;
/*
 * 高さの差が画素のこの倍率 (x = 0, y = 全部) の間で視差を 0 へ寄せる。画素に満たない所で打ち切るだけだと、その距離を境に
 * 法線を引く位置が最大 WATER_PARALLAX_MAX 跳び、短い波の模様が一定の距離の帯で段になった
 */
const vec2 WATER_PARALLAX_FADE = vec2(0.5, 1.0);

/*
 * 視差で法線を引く位置までの、視線に沿った距離 (ブロック、+-WATER_PARALLAX_MAX)。位置は worldPos + viewDir * 戻り値
 * 法線以外の波の評価 (composite2 の波頭・泡・きらめき) も同じ位置で引くので、G バッファで渡す (waterParallaxEncode)
 */
float waterParallaxDistance(WaterSea sea, vec3 worldPos, vec3 viewDir, float footprint) {
#if defined WATER_WAVES && defined WATER_PARALLAX
    float h2 = 0.0;
    for (int i = 0; i < WATER_PARALLAX_LAYERS; i++) h2 += sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
    float range = WATER_PARALLAX_RANGE * sqrt(h2);
    float scale = min(1.0, WATER_PARALLAX_MAX * -viewDir.y / max(range, 1e-5));
    range *= scale;
    // 高さの差が画素に満たなければ探さない
    float fade = smoothstep(WATER_PARALLAX_FADE.x, WATER_PARALLAX_FADE.y, range / max(footprint, 1e-6));
    if (viewDir.y >= -0.01 || fade <= 0.0) return 0.0;
    float t0 = range / viewDir.y;
    float t1 = -t0;
    // 視線の高さ - 波の高さ。始点では視線が波の上 (正)
    float prevT = t0;
    float prevD = viewDir.y * t0 - scale * waterWaveSum(sea, worldPos.xz + viewDir.xz * t0, 0, WATER_PARALLAX_LAYERS, footprint).x;
    for (int i = 1; i <= WATER_PARALLAX_STEPS; i++) {
        float t = mix(t0, t1, float(i) / float(WATER_PARALLAX_STEPS));
        float d = viewDir.y * t - scale * waterWaveSum(sea, worldPos.xz + viewDir.xz * t, 0, WATER_PARALLAX_LAYERS, footprint).x;
        if (d <= 0.0) return mix(prevT, t, prevD / max(prevD - d, 1e-5)) * fade;
        prevT = t;
        prevD = d;
    }
    return 0.0;
#else
    return 0.0;
#endif
}

// 視差の距離を 8 bit に詰める (0 がちょうど表せるよう 127 を中心にする。刻みは WATER_PARALLAX_MAX / 127 = 1.2 cm)
const float WATER_PARALLAX_CODE_HALF = 127.0;

float waterParallaxEncode(float t) {
    return (clamp(round(t / WATER_PARALLAX_MAX * WATER_PARALLAX_CODE_HALF), -WATER_PARALLAX_CODE_HALF, WATER_PARALLAX_CODE_HALF)
        + WATER_PARALLAX_CODE_HALF) / UNORM8_MAX;
}

float waterParallaxDecode(float e) { return (round(e * UNORM8_MAX) - WATER_PARALLAX_CODE_HALF) / WATER_PARALLAX_CODE_HALF * WATER_PARALLAX_MAX; }

/*
 * 水底のコースティクス (集光率)。receiverWorld: 受け面のワールド座標, depth: 光の方向に測った水面までの距離, L: 光源方向
 * 水面上の 3 点で屈折した光が水底でどれだけ広がるか (面積比) を求める。平らな水面なら厳密に 1
 * 最大の層 (波長 8 ブロック以上) は浅い水底ではほとんど集光しないので、2 番目から最小の手前までの 3 層を使う
 */
const float CAUSTICS_EPS = 0.06;
const float CAUSTICS_MAX = 5.0;

float waterCaustics(vec3 receiverWorld, float depth, vec3 L) {
#if defined WATER_CAUSTICS && defined WATER_WAVES
    if (L.y <= 0.05 || depth <= 0.02) return 1.0;
    WaterSea sea = waterSeaState(1.0);
    vec2 p0 = receiverWorld.xz + L.xz / L.y * depth;
    vec2 hit[3];
    for (int i = 0; i < 3; i++) {
        vec2 p = p0 + (i == 1 ? vec2(CAUSTICS_EPS, 0.0) : (i == 2 ? vec2(0.0, CAUSTICS_EPS) : vec2(0.0)));
        vec2 g = waterChoppy(waterWaveSum(sea, p, 1, WATER_LAYERS - 1, 0.0)).yz;
        vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
        vec3 r = refract(-L, n, 1.0 / WATER_IOR);
        float vertical = depth * L.y;
        hit[i] = p + r.xz * (vertical / max(-r.y, 0.05));
    }
    vec2 a = hit[1] - hit[0];
    vec2 b = hit[2] - hit[0];
    float area = abs(a.x * b.y - a.y * b.x);
    // 平らな水面なら 3 点とも同じだけずれるので面積は eps^2 のまま (比は厳密に 1)
    float ratio = (CAUSTICS_EPS * CAUSTICS_EPS) / max(area, 1e-6);
    // 深いほど焦点がずれてぼやけるので浅い所だけ強く出す
    float fade = exp(-depth * 0.08);
    return mix(1.0, min(ratio, CAUSTICS_MAX), fade);
#else
    return 1.0;
#endif
}

#endif
