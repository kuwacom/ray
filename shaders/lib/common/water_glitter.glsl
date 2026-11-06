/*
 * 画素より細かい波が太陽 (月) を映す点のきらめき (WATER_GLITTER)
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_GLITTER_GLSL
#define COMMON_WATER_GLITTER_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/water_waves.glsl"

/*
 * 曲がった水面の小さな面は、太陽の像を 1 つずつ映す (鏡面点)。単位面積あたりの点の数は「太陽を目へ返す傾きの確率密度 x ガウス曲率の
 * 絶対値の平均」で、1 つの点のエネルギーは曲率に反比例する (Longuet-Higgins 1960)。どちらも太陽の大きさによらない
 * 法線で表せない波を粗さ (ローブの広がり) にすると、本来は数個の画素に集まる光が広く薄く均され、照り返しがのっぺりした帯になる
 * ここでは粗さへ回した波の分を、ワールドに付いた点の集まりとして標本化する
 * - 点の数: 傾きの確率密度 (ガウス) x 曲率 (粗さへ回した層の曲率の 2 乗の和 x GLINT_CURVATURE)
 * - 1 つの明るさ: ローブ / 点の密度 に、曲率の小さい点ほど明るい 2 乗の裾の重みを掛ける。点の位置 (道の芯か端か) によらないので、
 *   道の端は点の数が減るだけで、1 つ 1 つは明るいまま光る
 * - 平均: 点がまばらな遠くは傾きの分布をガウスにしたローブ。GGX の裾にある薄い光 (道の外ののっぺりした滲み) は点にならない。
 *   点が詰まって滑らかな平均へ移る所と、粗さへ回した割合の小さい近景は GGX の裾を残す (道の縁を切り立たせない)
 * - 位置と寿命: セル (2 の冪、ワールドに固定) ごとに点を 1 つ置き、セルの格子を画面で見えている短い波 (無ければその大きさの波)
 *   の位相の速さで流す。寿命はセルの大きさの波の周期の半分 (TAA が積分できる GLINT_MIN_FRAMES より短くしない)。
 *   半周期ずらした 2 組を、立ち上がりの短い台形で交互に光らせる (和は常に 1)
 * - 密度: ワールドの面積あたりで決まり、画素の大きさによらない。画素の中に数が多い所だけ滑らかな平均へ移す
 * - むら: 粗さへ回した波の強さは場所ごとに違う (waterGlintPatch)。凪いだ所は細いローブのまま波の面が白く光り、粗い所に点が集まる
 * - 置く点: 理論の数のうち明るい側の一部だけを置き、置かない暗い点の光は置いた点へ寄せる (GLINT_KEEP)
 * - 形: 1 つの点は画面の横に並ぶ 2-5 個の子の鎖 (glintChain)
 * - 画素へは、標本の位置 (TAA のジッター込み) から鎖の子の半径 GLINT_RADIUS 画素の中を集める。TAA が画素の中の位置を積分する
 */
/*
 * ガウス曲率の絶対値の平均 / 曲率の 2 乗の和。一様な正規分布の面の理論の目安は 0.5 だが、それでは 2-10 m 先の道が白い点の
 * 砂目で埋まった。粗さが一様なままでは 0.15 でも露出後 10 前後の暗い点が一面に散って灰色のざらつきになり、0.03 まで下げると
 * 点がまばらで、どの点も白を大きく超えた同じ大きさの丸い塊になって隣とつながらなかった。点は場所ごとのさざ波の強さのむら
 * (waterGlintPatch) で粗い所に集まる。置くのはこのうち GLINT_KEEP の割合だけ
 */
const float GLINT_CURVATURE = 0.15;
const float GLINT_CHAIN_MEAN = 3.0;         // 1 つの鎖の子の数の平均の目安 (滑らかな平均へ移すときの画素の中の数に掛ける)
/*
 * 表面張力波が画素より大きい近く (1-3 m 以下) で点の数に掛ける倍率。近くでは 1 つ 1 つの面が分かれて見え、点が少ないと 1 つが
 * 明るすぎて大きな丸い玉になる。近くの照り返しの多くは凪いだ所の波の面 (細いローブ) が受け持つので、点の数では埋めない
 * (5 倍では近くの水面が細かい粒で埋まった)。照り返しの平均は変えない
 */
const float GLINT_NEAR_DENSITY = 1.5;
const int GLINT_SHORT_FIRST = 3;            // 画面で波と分かる短い層 (0.93 / 0.32 ブロック) の最初の番号 (この層と次の層の 2 つ)
/*
 * 場所ごとのさざ波の強さのむら (waterGlintPatch)。倍率は対数正規で、GLINT_PATCH_SIGMA はその対数の標準偏差
 * 重みは元にする量の割合 (長い 3 層の高さ / 短い 2 層の高さ / 風の息の値ノイズ)。2 乗の和で割って使う
 * 波の高さだけでは、むらが波テクスチャのタイルの繰り返しに沿って並ぶので、風下へ流れる値ノイズ (風の息) を混ぜる
 */
const float GLINT_PATCH_SIGMA = 1.2;
const float GLINT_PATCH_LONG = 0.4;
const float GLINT_PATCH_SHORT = 0.5;
const float GLINT_PATCH_GUST = 0.3;
const float GLINT_PATCH_NORM = inversesqrt(GLINT_PATCH_LONG * GLINT_PATCH_LONG + GLINT_PATCH_SHORT * GLINT_PATCH_SHORT
    + GLINT_PATCH_GUST * GLINT_PATCH_GUST);
const float GLINT_GUST_SIZE = 4.0;          // 風の息の大きさ (ブロック)
const float GLINT_GUST_DRIFT = 1.5;         // 風の息が風下へ流れる速さ (ブロック/秒)
const float GLINT_GUST_RATE = 0.08;         // 風の息の形が変わる速さ (1/秒)
const float GLINT_GUST_SIGMA = 0.185;       // 値ノイズ (valueNoise3d) の標準偏差
const float GLINT_PATCH_MAX = 8.0;          // 倍率の上限 (正規分布の 3 sigma の先。1 つの粗い所が道の外まで広がらない)
/*
 * 曲率の裾の一様乱数の下限 (1 つの点は平均の 16 倍まで)。裾が長いと、光の多くが少数のとても明るい点に入って丸い大きな塊になり、
 * 残りの点は白に届かず、白く飛ぶ点がまばらになった
 */
const float GLINT_WEIGHT_MIN = 1e-3;
/*
 * 置く点の割合 (明るい側から)。置かない暗い点の光は置いた点へ寄せる (光の総量は同じ)。理論の数のまま置くと、白に届かない
 * 小さな点が道一面に散って数えきれない粒に見えた。1 組のセルに置き切れない分を平均へ回すと、道の芯がのっぺりした白い板になった
 * - GLINT_PRESENT_MAX: 1 組のセルに点を置く確率の上限 (点の詰まった道の芯でも数えられるほどにする)
 * - GLINT_CONCENTRATE_MAX: 寄せて明るくする倍率の上限。上限で寄せ切れない分は平均 (滑らかな照り返し) になるので、
 *   点が画素より細かく詰まる遠くは滑らかなまま
 */
const float GLINT_KEEP = 0.04;
const float GLINT_PRESENT_MAX = 0.15;
const float GLINT_CONCENTRATE_MAX = 8.0;
const float GLINT_RADIUS = 0.75;            // 点を画素へ配る半径 (画素)
// セルの一辺の下限 (視線方向に伸びた画素)。縦は 2 つのセルで半径の中を全部探せる大きさ (横は鎖の長さの分だけ広く探す)
const float GLINT_CELL = 1.8;
/*
 * 1 つの点の形: 横に並ぶ短い鎖。実写の点は、表面張力波の稜線のうち太陽へ向く傾きの所が稜線に沿っていくつも並んで光るので、
 * 2-5 個が横に並んで隣と接し、横長の光や点の列になる (幅 / 高さは低い太陽で 2-3、高い太陽の見下ろしで 1-1.3)。
 * 1 つずつ独立に置いた点は、数を増やしても減らしても 1 つずつ浮いた粒のままだった
 * - 鎖は画面の横 (水平な視線と直交する向き) に並べる。かすめ角では奥行きが縮むので稜線は画面の横に寝る
 * - 子の間隔は画素の単位の乱数で、隣とつながる詰まった間隔と、暗い隙間を挟んで並ぶ間隔が混ざる (横長の光と点の列)。
 *   どちらか 1 種だと、全部つながった 1 本の棒か、等間隔の点線になった。鎖の長さはかすめ角ほど長く (1 / NoV)、
 *   明るい点 (曲率の小さい面) ほど子が多い
 * - 子の明るさは乱数で分け、和は 1 つの点と同じ (重みの面積で割るので、伸ばした子も丸の子と同じエネルギー)
 */
const int GLINT_CHAIN_MAX = 5;              // 鎖の子の数の上限
const int GLINT_CHAIN_MIN = 2;
const vec2 GLINT_CHAIN_GAP = vec2(1.0, 1.6); // 隣とつながる間隔の範囲 (画素)
const vec2 GLINT_CHAIN_GAP_APART = vec2(2.4, 3.2); // 暗い隙間を挟んで並ぶ間隔の範囲 (画素)
const float GLINT_CHAIN_APART = 0.6;        // 隙間を挟む間隔の割合
const float GLINT_CHAIN_REACH = 3.5;        // 鎖の長さの半分の上限 x NoV (画素)
const float GLINT_CHAIN_HALF_MAX = 8.0;     // 鎖の長さの半分の上限 (画素。夕日のかすめ角)
const float GLINT_CHAIN_JITTER = 0.5;       // 子の縦のずれの幅 (画素)
const float GLINT_CHAIN_WEIGHT_MIN = 0.5;   // 子の明るさの乱数 (0-1) に足す下限 (どの子も消えない)
const float GLINT_CHILD_STRETCH = 0.35;     // 子を横に伸ばす割合 (かすめ角の 1 / NoV 倍の伸びに対して)
const float GLINT_STRETCH_MAX = 8.0;        // 横に伸ばす倍率の上限
const float GLINT_STRETCH_DIM = 0.8;        // いちばん暗い点の子の数の割合 (明るい点を 1 とした割合)
const float GLINT_TILT = 0.17;              // 鎖の向きの傾きの乱数の幅 (ラジアン)
const int GLINT_SEARCH_MAX = 5;             // 鎖を探すセルの数の上限 (1 軸)
/*
 * 傾きの分布の指数 x の上限。ここで exp(-x) は 1e-13 で、点も重みも無いのと同じ。上限が無いと exp(-x) x (1 + x)^2 の
 * 計算の順番をコンパイラが入れ替えた時に 0 x 無限大で NaN になり、鏡面の上限 (min) が NaN を円盤の明るさに置き換えて道が白飛びした
 */
const float GLINT_X_MAX = 30.0;
/*
 * 点の寿命の下限 (フレーム)。TAA が 1 つの点を積めるよう、物理の寿命 (数十 ms) が短くても数フレームは残す
 * フレームの長さは prepare が平滑化して半オクターブの段に丸めた値 (waterGlintFrameStep)。生の frameTime はフレームごとに揺れ、
 * 時刻 / 寿命 の床関数が毎フレーム跳んで全部の点が振り直されるため
 */
const float GLINT_MIN_FRAMES = 3.0;
/*
 * 1 つの点の明滅の立ち上がり (寿命の割合)。点は面が太陽を映している間だけ光り、向きが変わるとすぐ消える。寿命全体で
 * じわっと明滅させると、波が動いて消えた所に点だけが残像のように残った。半周期ずらした 2 組の和は常に 1 (エネルギーは同じ)
 */
const float GLINT_FADE = 0.3;
// 画素の中の点の数がこの範囲で滑らかな平均へ移す
const vec2 GLINT_SMOOTH_LAMBDA = vec2(4.0, 16.0);
/*
 * 点の密度 (1 / ブロック^2) がこれより少ない所は平均のまま (道の外。道の芯の 1-2%)。画素の中の数で切ると、画素の小さい
 * 近くほど道の縁の点が多く消え、距離で道の幅が変わる。低くしすぎると点を探す画素が増えて重くなる (0.05 で +3-5 ms)
 */
const float GLINT_SKIP = 1.0;
// セルの大きさの 2 段を混ぜる帯 (log2 の端数)。帯の中は独立な 2 組の点が半分の明るさで重なり、粒が増えて費用も 2 倍になる
const vec2 GLINT_LEVEL_BLEND = vec2(0.4, 0.6);
const float GLINT_FRACTION_MIN = 0.01;      // ローブのうち粗さへ回した分がこれより少ない所 (近景) は変えない

// 重み 1 / sqrt(v) (v は [GLINT_WEIGHT_MIN, 1] の一様乱数) の平均
const float GLINT_WEIGHT_MEAN = 2.0 * (1.0 - sqrt(GLINT_WEIGHT_MIN)) / (1.0 - GLINT_WEIGHT_MIN);

/*
 * フレームの長さの段 (frameData.surfaceParams[3]: x = 平滑化した frameTime, y = 段の長さ (秒), z = 段の番号)
 * 段は 1/60 秒の半オクターブ刻みで、平滑化した値以上の最小の段。境目の近くで行き来しないよう、段を変えるのは 0.15 段を越えた時だけ
 */
const float GLINT_FRAME_SMOOTH = 0.05;      // 1 フレームあたりの平滑化の割合
const float GLINT_FRAME_LEVELS = 2.0;       // 1 オクターブの段の数
const float GLINT_FRAME_HYSTERESIS = 0.15;

#ifdef SSBO_FRAME_DATA_WRITE
void waterGlintFrameStore() {
    vec4 p = frameData.surfaceParams[3];
    float ft = clamp(frameTime, 1e-3, 0.5);
    bool valid = p.x > 0.0 && p.y > 0.0;
    float s = valid ? mix(p.x, ft, GLINT_FRAME_SMOOTH) : ft;
    float e = log2(s * 60.0) * GLINT_FRAME_LEVELS;
    float level = p.z;
    if (!valid || e > level + GLINT_FRAME_HYSTERESIS || e < level - 1.0 - GLINT_FRAME_HYSTERESIS) level = ceil(e);
    frameData.surfaceParams[3] = vec4(s, exp2(level / GLINT_FRAME_LEVELS) / 60.0, level, 0.0);
}
#endif

float waterGlintFrameStep() { return max(frameData.surfaceParams[3].y, 1.0 / 240.0); }

// 有限か (指数のビットが全部 1 でない)。isnan / isinf はドライバの最適化で常に偽になることがあるのでビットで見る
bool waterGlintFinite(float v) { return (floatBitsToUint(v) & 0x7F800000u) != 0x7F800000u; }

/*
 * 場所ごとのさざ波の強さの倍率 (場所の平均 1)。太陽の照り返しの粗さへ回した細かい波の分散と曲率に掛ける
 * 実際の水面では、表面張力波の強さは長い波の変調と寄生さざ波で場所ごとに違う。凪いだ所はゆるやかな波の面が太陽をそのまま
 * 映して波の形のまま白く飛び、さざ波の強い所には点が密に出て隣とつながる。粗さが場所によらず一様だと、照り返しの光が
 * どこでも同じように薄まり、「広く薄いローブ」か「同じ大きさの孤立した点」のどちらかになっていた
 * - 長い 3 層の高さ: 短い波は長い波の波頭の側に集まる (数 m-20 m のむら)
 * - 短い 2 層の高さ: 寄生さざ波は短い重力波の波頭の前の面に乗る (0.3-1 m の、波の筋に沿ったむら)
 * - 風の息: 突風の当たった所だけさざ波が立つ (数 m の、風下へ流れるむら)
 * 倍率は exp(s g - s^2 v / 2)。g はそれぞれの高さを標準偏差で割って重みを掛けた和 (分散 v) なので、場所の平均は 1
 * 画素より細かい層は画素の中で平均されるので、表せている分散の割合で g も v も薄める (表せる層の無い遠くは 1)
 * ローブは正規化したまま粗さだけを変えるので、照り返しの量は場所の平均で変わらない (平均のローブは芯が尖り裾が長い。
 * 海面の傾きの分布の尖り (Cox-Munk) と同じ向き)
 * ampLong / ampShort: 長い 3 層と短い 2 層の傾きの RMS (海の状態の配列を丸ごと渡さず、使う値だけ受ける),
 * hLong: 長い 3 層の高さ (waterWaveSum の 0-3、表せる割合を掛けた和)
 */
float waterGlintPatch(vec3 ampLong, vec2 ampShort, vec2 p, float footprint, float hLong) {
    float g = 0.0;
    float v = 0.0;
    float varLong = 0.0;
    float varLongAll = 0.0;
    for (int i = 0; i < 3; i++) {
        float s2 = sqr(ampLong[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
        varLongAll += s2;
        varLong += s2 * sqr(waterLayerResolved(i, footprint));
    }
    if (varLong > 0.0) {
        float w = GLINT_PATCH_LONG * GLINT_PATCH_NORM * sqrt(varLong / varLongAll);
        g += w * hLong * inversesqrt(varLong);
        v += w * w;
    }
    float t = frameTimeCounter;
    float h = 0.0;
    float var = 0.0;
    float varAll = 0.0;
    for (int k = 0; k < 2; k++) {
        int i = GLINT_SHORT_FIRST + k;
        float r = waterLayerResolved(i, footprint);
        float s2 = sqr(ampShort[k] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
        varAll += s2;
        if (r > 0.0 && ampShort[k] > 0.0) {
            var += s2 * r * r;
            h += waterLayer(p, i, ampShort[k] * r, t).x;
        }
    }
    if (var > 0.0) {
        float w = GLINT_PATCH_SHORT * GLINT_PATCH_NORM * sqrt(var / varAll);
        g += w * h * inversesqrt(var);
        v += w * w;
    }
    // 風の息は、その大きさを波長とする波と同じ割合で画素の中で平均する
    float gust = GLINT_PATCH_GUST * GLINT_PATCH_NORM * waterTileResolved(GLINT_GUST_SIZE * WATER_BAND_CENTER, footprint);
    if (gust > 0.0) {
        vec2 q = p - vec2(cos(WATER_WIND_ANGLE), sin(WATER_WIND_ANGLE)) * (GLINT_GUST_DRIFT * t);
        g += gust * (valueNoise3d(vec3(q / GLINT_GUST_SIZE, t * GLINT_GUST_RATE)) - 0.5) / GLINT_GUST_SIGMA;
        v += gust * gust;
    }
    return min(exp(GLINT_PATCH_SIGMA * g - 0.5 * sqr(GLINT_PATCH_SIGMA) * v), GLINT_PATCH_MAX);
}

// (1 - r^2)^2 の重み (r^2 は点の半径を 1 とした距離の 2 乗)
float glintKernel(float r2) { return r2 < 1.0 ? sqr(1.0 - r2) : 0.0; }

/*
 * 1 つの点 (鎖) の重み。子の明るさの和で割るので、面積は丸い点 1 つと同じ
 * m: 標本から点までの差 (x = 視線の向き, y = 横) を半径の単位にしたもの, chainHalf: 鎖の長さの半分の上限 (半径の単位),
 * stretchMax: かすめ角の横の伸びの倍率, bright: 0-1 (明るい点ほど 1), seed: 点ごとの乱数の種
 */
float glintChain(vec2 m, float chainHalf, float stretchMax, float bright, uvec3 seed) {
    vec3 hs = hash3(seed);
    vec3 hg = hash3(seed ^ uvec3(0x68E31DA4u, 0xB5297A4Du, 0x1B56C4E9u));
    int n = clamp(int(float(GLINT_CHAIN_MIN) + float(GLINT_CHAIN_MAX + 1 - GLINT_CHAIN_MIN) * hs.x * mix(GLINT_STRETCH_DIM, 1.0, bright)),
        GLINT_CHAIN_MIN, GLINT_CHAIN_MAX);
    // 間隔は 2 種: 隣とつながる詰まった間隔と、暗い隙間を挟む間隔 (乱数 u の GLINT_CHAIN_APART より下を隙間の側に使う)
    vec4 u = vec4(hg, fract(hg.x * 7.31 + hg.y * 3.17));
    bvec4 apart = lessThan(u, vec4(GLINT_CHAIN_APART));
    vec4 tGap = mix((u - GLINT_CHAIN_APART) / (1.0 - GLINT_CHAIN_APART), u / GLINT_CHAIN_APART, vec4(apart));
    vec4 gaps = mix(mix(vec4(GLINT_CHAIN_GAP.x), vec4(GLINT_CHAIN_GAP.y), tGap),
        mix(vec4(GLINT_CHAIN_GAP_APART.x), vec4(GLINT_CHAIN_GAP_APART.y), tGap), vec4(apart)) / GLINT_RADIUS;
    // 長さの上限 (かすめ角ほど長い) を超える子は付けない
    float total = 0.0;
    for (int j = 0; j < GLINT_CHAIN_MAX - 1; j++) {
        if (j >= n - 1) break;
        if (total + gaps[j] > 2.0 * chainHalf) {
            n = j + 1;
            break;
        }
        total += gaps[j];
    }
    float a = (hs.y - 0.5) * 2.0 * GLINT_TILT;
    vec2 dir = vec2(sin(a), cos(a));
    vec2 side = vec2(dir.y, -dir.x);
    float o = -0.5 * total;
    float sumK = 0.0;
    float sumE = 0.0;
    for (int j = 0; j < GLINT_CHAIN_MAX; j++) {
        if (j >= n) break;
        if (j > 0) o += gaps[j - 1];
        vec3 hc = hash3(seed ^ uvec3(uint(j + 1) * 0x9E3779B1u, uint(j + 1) * 0x85EBCA77u, 0xC2B2AE3Du));
        float e = GLINT_CHAIN_WEIGHT_MIN + hc.x;
        float s = 1.0 + (stretchMax - 1.0) * GLINT_CHILD_STRETCH * hc.y;
        vec2 p = m - dir * o - side * ((hc.z - 0.5) * GLINT_CHAIN_JITTER / GLINT_RADIUS);
        sumK += e * glintKernel(sqr(dot(p, side)) + sqr(dot(p, dir) / s)) / s;
        sumE += e;
    }
    return sumK / sumE;
}

/*
 * 格子 1 段 (セルの一辺 2^level) の倍率 (期待値 1)
 * pos: 標本の位置, rho: 点の密度 (1 / ブロック^2), axisAlong / axisAcross: ワールドの水平の差を画素の半径の単位へ直す 2 軸,
 * kernelArea: 1 つの点を配る重みの面積 (ブロック^2), chainHalf: 鎖の長さの半分の上限 (半径の単位), stretchMax: 子の横の伸びの倍率,
 * concentrateMax: 置いた点へ寄せて明るくする倍率の上限
 */
float glintLevel(vec2 pos, float level, float rho, vec2 axisAlong, vec2 axisAcross, float kernelArea, float chainHalf, float stretchMax,
    float concentrateMax) {
    float cell = exp2(level);
    // 点はこの大きさの波が作るとみなし、その波の周期の半分で入れ替わる
    float wavelength = max(cell, WATER_CAPILLARY_WAVELENGTH);
    float speed = waterPhaseSpeed(wavelength);
    float life = max(0.5 * wavelength / speed, GLINT_MIN_FRAMES * waterGlintFrameStep());
    /*
     * 点を運ぶ速さ: 寄生さざ波は短い重力波の波頭の前の面に乗り、その波と一緒に進む。この段の画素で波として見えている
     * 短い層があればその層の向きと位相の速さで流し、点を画面の波頭に付けたまま動かす (遅く流すと、波頭が過ぎた所に点が残る)
     * 段ごとに 1 つに決める (画素ごとに速さを変えると、時刻 x 速さの差で隣の画素の点がばらばらになる)
     */
    vec2 drift = vec2(cos(WATER_WIND_ANGLE), sin(WATER_WIND_ANGLE)) * speed;
    float levelFootprint = cell / GLINT_CELL;
    for (int k = 1; k >= 0; k--) {
        int i = GLINT_SHORT_FIRST + k;
        if (waterLayerResolved(i, levelFootprint) >= 0.5) {
            float a = WATER_WIND_ANGLE + WATER_LAYER_ANGLE[i];
            drift = vec2(cos(a), sin(a)) * waterPhaseSpeed(waterLayerTile(i) / WATER_BAND_CENTER);
            break;
        }
    }
    float t = frameTimeCounter;
    vec2 q = pos - drift * t;

    // 置かない暗い点 (重みの一様乱数の大きい側) の光は、置いた点を concentrateMax 倍まで明るくして寄せ、残りを平均へ回す
    float count = rho * cell * cell;
    float present = min(count * GLINT_KEEP, GLINT_PRESENT_MAX);
    float vMax = GLINT_WEIGHT_MIN + (present / count) * (1.0 - GLINT_WEIGHT_MIN);
    float placed = (sqrt(vMax) - sqrt(GLINT_WEIGHT_MIN)) / (1.0 - sqrt(GLINT_WEIGHT_MIN));
    float rest = max(1.0 - concentrateMax * placed, 0.0);

    /*
     * 鎖の届く範囲 (半径の単位): 横は鎖の半分の長さと子の伸び、縦は 1 つの半径と鎖の傾き・子の縦のずれ
     * その範囲を囲むセルを探す (鎖の向きはワールドの格子と揃わないので、範囲に掛からないセルは乱数を引く前に外す)
     */
    float reachAcross = chainHalf + 1.0 + (stretchMax - 1.0) * GLINT_CHILD_STRETCH;
    float reachAlong = 1.0 + chainHalf * GLINT_TILT + 0.5 * GLINT_CHAIN_JITTER / GLINT_RADIUS;
    vec2 ext = abs(axisAlong) * (reachAlong / dot(axisAlong, axisAlong)) + abs(axisAcross) * (reachAcross / dot(axisAcross, axisAcross));
    ivec2 lo = ivec2(floor((q - ext) / cell));
    ivec2 hi = min(ivec2(floor((q + ext) / cell)), lo + (GLINT_SEARCH_MAX - 1));
    // セルの中のどこに点があっても届くかを見る、セルの半分の大きさ (半径の単位)
    vec2 cellHalf = 0.5 * cell * vec2(abs(axisAlong.x) + abs(axisAlong.y), abs(axisAcross.x) + abs(axisAcross.y));
    uint levelTag = uint(int(level) + 128);
    float sum = 0.0;
    for (int cy = lo.y; cy <= hi.y; cy++) {
        for (int cx = lo.x; cx <= hi.x; cx++) {
            ivec2 c = ivec2(cx, cy);
            vec2 dc = (vec2(c) + 0.5) * cell - q;
            if (abs(dot(dc, axisAlong)) >= reachAlong + cellHalf.x || abs(dot(dc, axisAcross)) >= reachAcross + cellHalf.y) continue;
            uvec2 uc = uvec2(c);
            // セルごとに時刻をずらし、点が揃って入れ替わらないようにする
            float phase = hash1(uc.x * 0x9E3779B1u ^ uc.y * 0x85EBCA77u ^ levelTag * 0xC2B2AE3Du);
            for (int s = 0; s < 2; s++) {
                float ts = t / life + phase + 0.5 * float(s);
                // 三角波を立ち上がり GLINT_FADE の台形にする (2 組の三角波の和は 1 なので、台形の和も 1)
                // 消えている組 (寿命の 35%) は乱数と形を求めない
                float tri = 1.0 - abs(2.0 * fract(ts) - 1.0);
                float envelope = saturate((tri - 0.5) / GLINT_FADE + 0.5);
                if (envelope <= 0.0) continue;
                uint slot = uint(int(floor(ts))) * 512u + levelTag * 2u + uint(s);
                vec3 h = hash3(uvec3(uc, slot));
                if (h.x >= present) continue;
                vec2 d = (vec2(c) + h.yz) * cell - q;
                vec2 m = vec2(dot(d, axisAlong), dot(d, axisAcross));
                if (abs(m.x) >= reachAlong || abs(m.y) >= reachAcross) continue;
                float v = mix(GLINT_WEIGHT_MIN, vMax, h.x / present);
                float shape = glintChain(m, chainHalf, stretchMax, 1.0 - sqrt(v), uvec3(uc, slot ^ 0xA511E9B3u));
                sum += envelope * inversesqrt(v) * shape;
            }
        }
    }
    return sum / (GLINT_WEIGHT_MEAN * rho * kernelArea) * ((1.0 - rest) / max(placed, 1e-4)) + rest;
}

/*
 * 太陽 (月) の照り返しのローブに掛ける倍率。ローブのうち粗さへ回した分の割合だけ効かせる (近景は表した波の法線のまま)
 * pos: 標本の位置 (ワールドの水平, TAA のジッター込み), N: 表した波の法線, L: 太陽 (月) の向き, alpha2: 照り返しのローブの alpha^2,
 * unresolved: 粗さへ回した (傾きの分散, 曲率の 2 乗の和), pixelWorld: 水面上の画素の幅 (視線と直交する向き, ブロック),
 * NoVGeo: 平均水面と視線の cos
 * alpha2 と unresolved には、場所ごとのさざ波の強さのむら (waterGlintPatch) を掛けた値を渡す
 */
float waterGlitter(vec2 pos, vec3 N, vec3 V, vec3 L, float alpha2, vec2 unresolved, float pixelWorld, float NoVGeo) {
    if (alpha2 <= 0.0 || pixelWorld <= 0.0) return 1.0;
    float fraction = saturate(unresolved.x / alpha2);
    if (fraction < GLINT_FRACTION_MIN) return 1.0;
    float NoH = dot(N, normalize(L + V));
    if (NoH <= 0.0) return 1.0;
    // 傾きの分布をローブと同じ alpha^2 のガウスにする。期待値はガウス / GGX の比で、GGX の長い裾の分は点にならない
    float x = clamp((1.0 / (NoH * NoH) - 1.0) / alpha2, 0.0, GLINT_X_MAX);
    float gauss = exp(-x);
    float expected = gauss * sqr(1.0 + x);
    // 点の密度はワールドの面積あたりで決まる (画素の大きさによらない)。近づくと画面の中の数が減り、1 つは明るく大きくなる
    float rho = gauss / (PI * alpha2) * GLINT_CURVATURE * unresolved.y;

    float NoV = max(NoVGeo, 0.02);
    float footprint = pixelWorld / NoV;
    rho *= mix(1.0, GLINT_NEAR_DENSITY, 0.5 * (waterTileResolved(waterCapillaryTile(0), footprint) + waterTileResolved(waterCapillaryTile(1), footprint)));
    float pixelArea = pixelWorld * footprint;
    // 置いた鎖の子の数で見る
    float smoothW = smoothstep(GLINT_SMOOTH_LAMBDA.x, GLINT_SMOOTH_LAMBDA.y, rho * pixelArea * GLINT_KEEP * GLINT_CHAIN_MEAN);
    float level = log2(GLINT_CELL * footprint);
    float levelLo = floor(level) + 1.0;
    float g = 1.0;
    if (smoothW < 1.0 && rho >= GLINT_SKIP) {
        // 画素の単位: 視線の向き (水平) には 1 / NoV 倍に伸びた画素
        vec2 along = V.xz;
        along = dot(along, along) > 1e-8 ? normalize(along) : vec2(1.0, 0.0);
        vec2 axisAlong = along * NoV / (pixelWorld * GLINT_RADIUS);
        vec2 axisAcross = vec2(-along.y, along.x) / (pixelWorld * GLINT_RADIUS);
        // (1 - r^2)^2 の重みの面積
        float kernelArea = PI * sqr(GLINT_RADIUS) / 3.0 * pixelArea;
        // かすめ角の横の伸び (奥行きが縮む分) と、鎖の長さの半分の上限 (半径の単位)
        float stretchMax = clamp(GLINT_CELL / (2.0 * GLINT_RADIUS * NoV), 1.0, GLINT_STRETCH_MAX);
        float chainHalf = min(GLINT_CHAIN_REACH / NoV, GLINT_CHAIN_HALF_MAX) / GLINT_RADIUS;
        float concentrateMax = GLINT_CONCENTRATE_MAX;
        // どちらの段も期待値は同じなので、混ぜるのは切り替わりの帯だけにし、帯の外は片方の段だけを探す
        float wHi = smoothstep(GLINT_LEVEL_BLEND.x, GLINT_LEVEL_BLEND.y, fract(level));
        float gLo = wHi < 1.0 ? glintLevel(pos, levelLo, rho, axisAlong, axisAcross, kernelArea, chainHalf, stretchMax, concentrateMax) : 0.0;
        float gHi = wHi > 0.0 ? glintLevel(pos, levelLo + 1.0, rho, axisAlong, axisAcross, kernelArea, chainHalf, stretchMax, concentrateMax) : 0.0;
        g = mix(mix(gLo, gHi, wHi), 1.0, smoothW);
    }
    /*
     * 点がまばらで粗さへ回した割合の大きい所 (gaussian 1) はガウスのローブを点で、点が詰まった所と近景 (0) は GGX のまま。
     * 間は GGX のうちガウスと重なる分を点にし、GGX の裾 (ガウスを超える分) を滑らかに残す (近景の道の縁を切り立たせない)。
     * どの値でも GGX と同じエネルギー (ガウスと GGX の重なりは 0.796、残りが裾)
     */
    float sparse = 1.0 - smoothW;
    float gaussian = sparse * fraction;
    float points = min(expected, 1.0) + gaussian * max(expected - 1.0, 0.0);
    float tail = (1.0 - gaussian) * max(1.0 - expected, 0.0);
    // g の期待値は画素ごとに 1
    return mix(1.0, g * points + tail, fraction);
}

#endif
