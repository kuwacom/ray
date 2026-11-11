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
 * - 平均: 照り返しのローブと同じガウスの傾きの分布 (Beckmann)。点がまばらな所も、点が詰まって滑らかな平均へ移る所も、
 *   広がりは同じなので、目の高さで道の幅が変わらない
 * - 位置と寿命: セル (2 の冪、ワールドに固定) ごとに点を 1 つ置き、セルの格子を画面で見えている短い波 (無ければその大きさの波)
 *   の位相の速さで流す。寿命はセルの大きさの波の周期の半分 (TAA が積分できる GLINT_MIN_FRAMES より短くしない)。
 *   半周期ずらした 2 組を、立ち上がりの短い台形で交互に光らせる (和は常に 1)
 * - 密度: ワールドの面積あたりで決まり、画素の大きさによらない。画素の中に数が多い所だけ滑らかな平均へ移す
 * - むら: 粗さへ回した波の強さは場所ごとに違う (waterGlintPatch)。凪いだ所は細いローブのまま波の面が白く光り、粗い所に点が集まる
 * - 置く点: 理論の数のうち明るい側の一部だけを置き、置かない暗い点の光は置いた点へ寄せる (GLINT_KEEP)
 * - 形: 1 つの点は波の稜線に沿って並ぶ 2-7 個の子と、子の間をつなぐ細い光の鎖 (glintChain)
 * - 画素へは、標本の位置 (TAA のジッター込み) から鎖の子の半径 GLINT_RADIUS 画素の中を集める。TAA が画素の中の位置を積分する
 */
/*
 * ガウス曲率の絶対値の平均 / 曲率の 2 乗の和。一様な正規分布の面の理論の目安は 0.5 だが、それでは 2-10 m 先の道が白い点の
 * 砂目で埋まった。粗さが一様なままでは 0.15 でも露出後 10 前後の暗い点が一面に散って灰色のざらつきになり、0.03 まで下げると
 * 点がまばらで、どの点も白を大きく超えた同じ大きさの丸い塊になって隣とつながらなかった。点は場所ごとのさざ波の強さのむら
 * (waterGlintPatch) で粗い所に集まる。置くのはこのうち GLINT_KEEP の割合だけ
 * 設定 WATER_GLITTER_DENSITY がこの値に掛かる。1 つの明るさは点の数に反比例するので、光の総量は変わらない
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
const float GLINT_PATCH_FLOOR = 0.4;        // 波の面が画素より細かい中景の倍率の下限
/*
 * 曲率の裾の一様乱数の下限 (1 つの点は平均の 16 倍まで)。裾が長いと、光の多くが少数のとても明るい点に入って丸い大きな塊になり、
 * 残りの点は白に届かず、白く飛ぶ点がまばらになった
 */
const float GLINT_WEIGHT_MIN = 1e-3;
/*
 * 置く点の割合 (明るい側から)。置かない暗い点の光は置いた点へ寄せる (光の総量は同じ)。理論の数のまま置くと、白に届かない
 * 小さな点が道一面に散って数えきれない粒に見えた。1 組のセルに置き切れない分を平均へ回すと、道の芯がのっぺりした白い板になった
 * - GLINT_PRESENT_MAX: 1 組のセルに点を置く確率の上限 (点の詰まった道の芯でも数えられるほどにする)
 * - 寄せて明るくする倍率の上限: 波の形が画素より細かい中景は GLINT_CONCENTRATE_MAX、波の形が見える近くは GLINT_CONCENTRATE_NEAR
 *   (近くは寄せ切らない分が波の形の白い面として光る)。上限で寄せ切れない分は平均 (滑らかな照り返し) になるので、
 *   点が画素より細かく詰まる遠くは滑らかなまま
 */
const float GLINT_KEEP = 0.04;
const float GLINT_PRESENT_MAX = 0.10;
const float GLINT_CONCENTRATE_MAX = 8.0;
const float GLINT_CONCENTRATE_NEAR = 4.0;
const float GLINT_RADIUS = 0.75;            // 点を画素へ配る半径 (画素)
// セルの一辺の下限 (視線方向に伸びた画素)。縦は 2 つのセルで半径の中を全部探せる大きさ (横は鎖の長さの分だけ広く探す)
const float GLINT_CELL = 1.8;
/*
 * 1 つの点の形: 横に並ぶ短い鎖。実写の点は、表面張力波の稜線のうち太陽へ向く傾きの所が稜線に沿っていくつも並んで光るので、
 * 2-7 個が横に並んで隣と接し、横長の光や点の列になる (幅 / 高さは低い太陽で 2-3、高い太陽の見下ろしで 1-1.3)。
 * 1 つずつ独立に置いた点は、数を増やしても減らしても 1 つずつ浮いた粒のままだった
 * - 鎖は波の稜線に沿って並べる (GLINT_CREST_SCALE)。かすめ角では奥行きが縮むので稜線は画面の横に寝る
 * - 鎖の長さは点像のにじみの直径の 2-3 倍。にじみと同じくらいの長さでは、にじむと丸い玉になった
 * - 鎖の長さは設定 WATER_GLITTER_LENGTH で、子の間隔と長さの上限に掛ける
 * - 子の間隔は画素の単位の乱数で、隣とつながる詰まった間隔と、暗い隙間を挟んで並ぶ間隔が混ざる (横長の光と点の列)。
 *   どちらか 1 種だと、全部つながった 1 本の棒か、等間隔の点線になった。鎖の長さはかすめ角ほど長く (1 / NoV)、
 *   明るい点 (曲率の小さい面) ほど子が多い
 * - 子の明るさは乱数で分け、和は 1 つの点と同じ (重みの面積で割るので、伸ばした子・大きさを変えた子も丸の子と同じエネルギー)
 * - 子の明るさ・大きさ・間隔・鎖の向きのばらつきが小さいと、同じ大きさの点が同じ間隔で並ぶ点線になり、隣の鎖と平行に
 *   並んで雨の筋のように見えた。端の子が白に届かず暗く消える鎖も混ぜて、長さと形をそろえない
 * - 子ごとに光る時刻を少しずらす (1 本の鎖が一斉に光って一斉に消えない)
 * - 置いた点のうち特に明るい (曲率が小さく、大きな 1 つの面が太陽を映す) 点は、稜線に割れずに 1 つの点のまま光ることがある
 *   (WATER_GLITTER_SINGLE x 置いた点の中での明るさの割合。既定の 0.55 で置いた点の 1-2 割)
 */
const int GLINT_CHAIN_MAX = 7;              // 鎖の子の数の上限
const int GLINT_CHAIN_MIN = 2;
const vec2 GLINT_CHAIN_GAP = vec2(1.5, 2.5); // 隣とつながる間隔の範囲 (画素。点像のにじみで埋まる)
const vec2 GLINT_CHAIN_GAP_APART = vec2(2.0, 4.5); // 暗い隙間を挟んで並ぶ間隔の範囲 (画素)
const float GLINT_CHAIN_APART = 0.35;       // 隙間を挟む間隔の割合 (残りはつながる間隔)
const float GLINT_CHAIN_REACH = 6.0;        // 鎖の長さの半分の上限 x NoV (画素)
const float GLINT_CHAIN_HALF_MAX = 12.0;    // 鎖の長さの半分の上限 (画素。夕日のかすめ角)
const float GLINT_CHAIN_JITTER = 0.5;       // 子の縦のずれの幅 (画素)
const float GLINT_CHAIN_WEIGHT_MIN = 0.15;  // 子の明るさ (0-1 の乱数の 2 乗) に足す下限
const vec2 GLINT_CHILD_SIZE = vec2(0.7, 1.3); // 子の半径の倍率の乱数の範囲
const float GLINT_CHILD_PHASE = 0.12;       // 子の光る時刻のずれの幅 (寿命の割合)
const float GLINT_CHILD_STRETCH = 0.35;     // 子を横に伸ばす割合 (かすめ角の 1 / NoV 倍の伸びに対して)
const float GLINT_STRETCH_MAX = 8.0;        // 横に伸ばす倍率の上限
const float GLINT_STRETCH_DIM = 0.8;        // いちばん暗い点の子の数の割合 (明るい点を 1 とした割合)
const float GLINT_TILT = 0.3;               // 鎖の向きの傾きの乱数の幅 (ラジアン)
const int GLINT_SEARCH_MAX = 9;             // 鎖を探すセルの数の上限 (1 軸)
/*
 * 鎖の向きは、点を生んだ面の波の稜線 (高さの等高線) に沿わせる。表した波の傾きは稜線に沿ってほぼ一定なので、照り返しの白い帯も
 * 稜線と平行に走り、稜線に沿う鎖は帯の上に乗る。画面の横に固定すると、波を横から見た時に縦に走る波の筋と直交する線が並んだ
 * - 向きの元は鎖より長い波だけ (層の波長が鎖の長さの約 1.3-3 倍で入れる。画素の大きさに GLINT_CREST_SCALE を掛けて表せる層)
 * - 勾配の小さい所 (山の頂・谷・凪) は向きが定まらないので画面の横へ混ぜる (傾きの RMS に対する勾配の大きさ GLINT_CREST_FLAT)
 * - かすめ角では奥行きが NoV 倍に縮むので、どの向きの稜線も画面の横に寝る。視線に沿う稜線だけが縦寄りの短い列になる
 */
const float GLINT_CREST_SCALE = 8.0;
const vec2 GLINT_CREST_FLAT = vec2(0.1, 0.5);
const float GLINT_CHAIN_BRIDGE = 0.5;       // 鎖の光のうち、子の間をつなぐ横長の核へ配る割合
const float GLINT_BRIDGE_WIDTH = 0.8;       // 横長の核の縦の半径 (子の半径の割合)
/*
 * 傾きの分布の指数 x の上限。ここで exp(-x) は 1e-13 で、点も重みも無いのと同じ。上限が無いと x に掛ける式の計算の順番を
 * コンパイラが入れ替えた時に 0 x 無限大で NaN になり、鏡面の上限 (min) が NaN を円盤の明るさに置き換えて道が白飛びした
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
/*
 * 点の量の倍率 (WATER_GLITTER_DENSITY)。月が光源の夜は WATER_GLITTER_NIGHT_DENSITY を掛ける
 * 月の道は太陽の道より桁違いに暗く、細かい点を密に置くと一つ一つが白に届かない。点を減らすと、同じ総量が
 * まばらで明るい点に集まる (点の明るさは点の数に反比例し、光の総量は変わらない)
 */
float waterGlitterDensity() {
    return WATER_GLITTER_DENSITY * (frameData.shadowLightIrradiance.a > 0.5 ? 1.0 : WATER_GLITTER_NIGHT_DENSITY);
}

// 画素の中の点の数がこの範囲で滑らかな平均へ移す
const vec2 GLINT_SMOOTH_LAMBDA = vec2(4.0, 16.0);
const float GLINT_SMOOTH_NEAR = 1.0;         // 近くで数える点の割合 (1 で置く前の全部の点)
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
 * longWave: 長い 3 層の高さと勾配 (waterWaveSum の 0-3 の xyz、表せる割合を掛けた和)
 * crest: 点の鎖を並べる稜線の向きを決める勾配 (鎖より長い波だけの和を、その傾きの RMS で割ったもの。平らな所は 0 に近い)
 */
float waterGlintPatch(vec3 ampLong, vec2 ampShort, vec2 p, float footprint, vec3 longWave, out vec2 crest) {
    float g = 0.0;
    float v = 0.0;
    float varLong = 0.0;
    float varLongAll = 0.0;
    float slopeVar = 0.0;
    for (int i = 0; i < 3; i++) {
        float s2 = sqr(ampLong[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
        float r2 = sqr(waterLayerResolved(i, footprint));
        varLongAll += s2;
        varLong += s2 * r2;
        slopeVar += sqr(ampLong[i]) * r2;
    }
    if (varLong > 0.0) {
        float w = GLINT_PATCH_LONG * GLINT_PATCH_NORM * sqrt(varLong / varLongAll);
        g += w * longWave.x * inversesqrt(varLong);
        v += w * w;
    }
    float t = frameTimeCounter;
    float h = 0.0;
    float var = 0.0;
    float varAll = 0.0;
    vec2 grad = longWave.yz;
    for (int k = 0; k < 2; k++) {
        int i = GLINT_SHORT_FIRST + k;
        float r = waterLayerResolved(i, footprint);
        float s2 = sqr(ampShort[k] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
        varAll += s2;
        if (r > 0.0 && ampShort[k] > 0.0) {
            var += s2 * r * r;
            vec3 layer = waterLayer(p, i, ampShort[k] * r, t).xyz;
            h += layer.x;
            // 鎖の長さより短い波は鎖の中で向きが変わり、画素ごとに鎖の形がずれて折れるので、稜線の向きには入れない
            float rc = waterLayerResolved(i, footprint * GLINT_CREST_SCALE);
            grad += layer.yz * (rc / r);
            slopeVar += sqr(ampShort[k] * rc);
        }
    }
    crest = slopeVar > 0.0 ? grad * inversesqrt(slopeVar) : vec2(0.0);
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
    float m = min(exp(GLINT_PATCH_SIGMA * g - 0.5 * sqr(GLINT_PATCH_SIGMA) * v), GLINT_PATCH_MAX);
    // 最短の層が画素より細かい中景は、凪いだ所の細いローブが波の形を持たずに隣とつながり、道の芯が一面の白い板になるので、凪に下限を付ける
    return max(m, GLINT_PATCH_FLOOR * (1.0 - waterLayerResolved(GLINT_SHORT_FIRST + 1, footprint)));
}

// (1 - r^2)^2 の重み (r^2 は点の半径を 1 とした距離の 2 乗)
float glintKernel(float r2) { return r2 < 1.0 ? sqr(1.0 - r2) : 0.0; }

/*
 * 寿命の中の時刻 age (0-1) の明滅。三角波を立ち上がり GLINT_FADE の台形にする (半周期ずらした 2 組の三角波の和は 1 なので、
 * 台形の和も 1)。寿命の両端の (1 - GLINT_FADE) / 4 ずつは消えている
 */
float glintEnvelope(float age) { return saturate((0.5 - abs(2.0 * age - 1.0)) / GLINT_FADE + 0.5); }

/*
 * 1 つの点 (鎖) の重み。子の明るさの和で割るので、面積は丸い点 1 つと同じ
 * m: 標本から点までの差 (x = 視線の向き, y = 横) を半径の単位にしたもの, chainHalf: 鎖の長さの半分の上限 (半径の単位),
 * stretchMax: かすめ角の横の伸びの倍率, bright: 0-1 (明るい点ほど 1), seed: 点ごとの乱数の種, age: 寿命の中の時刻 (0-1),
 * peak: 置いた点の中での明るさの割合 (いちばん明るい点で 1), base: 画面の横の向き (m と同じ単位の単位ベクトル)
 */
float glintChain(vec2 m, float chainHalf, float stretchMax, float bright, uvec3 seed, float age, float peak, vec2 base) {
    vec3 hs = hash3(seed);
    vec3 hg = hash3(seed ^ uvec3(0x68E31DA4u, 0xB5297A4Du, 0x1B56C4E9u));
    int n = clamp(int(float(GLINT_CHAIN_MIN) + float(GLINT_CHAIN_MAX + 1 - GLINT_CHAIN_MIN) * hs.x * mix(GLINT_STRETCH_DIM, 1.0, bright)),
        GLINT_CHAIN_MIN, GLINT_CHAIN_MAX);
    if (hs.z < WATER_GLITTER_SINGLE * peak) n = 1;
    /*
     * 間隔は 2 種: 隣とつながる詰まった間隔と、暗い隙間を挟む間隔 (乱数 u の GLINT_CHAIN_APART より下を隙間の側に使う)
     * 子が 2 つだけの鎖はつながる間隔にする (隙間を挟むと、にじんだ同じくらいの 2 つの玉が対に並んで見えた)
     * 長さの上限 (かすめ角ほど長い) を超える子は付けない
     */
    float gaps[GLINT_CHAIN_MAX - 1];
    float total = 0.0;
    bool firstApart = false;
    for (int j = 0; j < GLINT_CHAIN_MAX - 1; j++) {
        gaps[j] = 0.0;
        if (j >= n - 1) continue;
        float u = j == 0 ? hg.x : hash1(seed.x * 0x27D4EB2Fu ^ seed.y * 0x165667B1u ^ seed.z ^ uint(j) * 0xD3A2646Cu);
        bool apart = u < GLINT_CHAIN_APART && n > 2;
        float tg = u < GLINT_CHAIN_APART ? u / GLINT_CHAIN_APART : (u - GLINT_CHAIN_APART) / (1.0 - GLINT_CHAIN_APART);
        float g = (apart ? mix(GLINT_CHAIN_GAP_APART.x, GLINT_CHAIN_GAP_APART.y, tg) : mix(GLINT_CHAIN_GAP.x, GLINT_CHAIN_GAP.y, tg))
            * WATER_GLITTER_LENGTH / GLINT_RADIUS;
        if (total + g > 2.0 * chainHalf) {
            n = j + 1;
            continue;
        }
        if (j == 0) firstApart = apart;
        gaps[j] = g;
        total += g;
    }
    if (n == 2 && firstApart) {
        // 長さの上限で 2 つに切れた鎖も、つながる間隔へ縮める
        total = mix(GLINT_CHAIN_GAP.x, GLINT_CHAIN_GAP.y, hg.y) * WATER_GLITTER_LENGTH / GLINT_RADIUS;
        gaps[0] = total;
    }
    float a = (hs.y - 0.5) * 2.0 * GLINT_TILT;
    vec2 dir = vec2(base.x * cos(a) + base.y * sin(a), base.y * cos(a) - base.x * sin(a));
    vec2 side = vec2(dir.y, -dir.x);
    float o = -0.5 * total;
    float sumK = 0.0;
    float sumE = 0.0;
    for (int j = 0; j < GLINT_CHAIN_MAX; j++) {
        if (j >= n) break;
        if (j > 0) o += gaps[j - 1];
        vec3 hc = hash3(seed ^ uvec3(uint(j + 1) * 0x9E3779B1u, uint(j + 1) * 0x85EBCA77u, 0xC2B2AE3Du));
        float e = GLINT_CHAIN_WEIGHT_MIN + sqr(hc.x);
        float s = 1.0 + (stretchMax - 1.0) * GLINT_CHILD_STRETCH * hc.y;
        float r = mix(GLINT_CHILD_SIZE.x, GLINT_CHILD_SIZE.y, fract(hc.x * 13.17 + hc.y * 5.71));
        float shift = (fract(hc.z * 11.3 + hc.y * 2.9) - 0.5) * 2.0 * GLINT_CHILD_PHASE;
        vec2 p = (m - dir * o - side * ((hc.z - 0.5) * GLINT_CHAIN_JITTER / GLINT_RADIUS)) / r;
        // 半径 r 倍の核は面積が r^2 倍なので割る。光る時刻をずらしても、寿命の中の光の量は同じ
        sumK += e * glintEnvelope(age + shift) * glintKernel(sqr(dot(p, side)) + sqr(dot(p, dir) / s)) / (s * r * r);
        sumE += e;
    }
    if (n < 2) return sumK / sumE;
    /*
     * 子の間をつなぐ細い横の光 (稜線の面のうち太陽へ向く傾きが続く所)。子だけでは、明るさの割れた子のうち白に届くのは 1-2 個で、
     * 点像でにじむと丸い玉になり、横長の光がほとんど残らなかった。鎖の全長に広がる横長の核へ GLINT_CHAIN_BRIDGE を配る
     */
    float L = 0.5 * total + 1.0;
    float bridge = glintKernel(sqr(dot(m, side) / GLINT_BRIDGE_WIDTH) + sqr(dot(m, dir) / L)) / (L * GLINT_BRIDGE_WIDTH);
    return mix(sumK / sumE, glintEnvelope(age) * bridge, GLINT_CHAIN_BRIDGE);
}

/*
 * 格子 1 段 (セルの一辺 2^level) の倍率 (期待値 1)
 * pos: 標本の位置, rho: 点の密度 (1 / ブロック^2), axisAlong / axisAcross: ワールドの水平の差を画素の半径の単位へ直す 2 軸,
 * kernelArea: 1 つの点を配る重みの面積 (ブロック^2), chainHalf: 鎖の長さの半分の上限 (半径の単位), stretchMax: 子の横の伸びの倍率,
 * concentrateMax: 置いた点へ寄せて明るくする倍率の上限, base: 鎖を並べる画面の横の向き (axisAlong / axisAcross の単位)
 */
float glintLevel(vec2 pos, float level, float rho, vec2 axisAlong, vec2 axisAcross, float kernelArea, float chainHalf, float stretchMax,
    float concentrateMax, vec2 base) {
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
    float reachAcross = GLINT_CHILD_SIZE.y * (1.0 + (stretchMax - 1.0) * GLINT_CHILD_STRETCH) + chainHalf * min(abs(base.y) + GLINT_TILT, 1.0)
        + 0.5 * GLINT_CHAIN_JITTER / GLINT_RADIUS;
    float reachAlong = GLINT_CHILD_SIZE.y + chainHalf * min(abs(base.x) + GLINT_TILT, 1.0) + 0.5 * GLINT_CHAIN_JITTER / GLINT_RADIUS;
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
                // どの子も消えている組 (寿命の両端) は乱数と形を求めない。子の時刻のずれは寿命の中に収まる
                float age = fract(ts);
                if (abs(2.0 * age - 1.0) >= 0.5 + 0.5 * GLINT_FADE + 2.0 * GLINT_CHILD_PHASE) continue;
                uint slot = uint(int(floor(ts))) * 512u + levelTag * 2u + uint(s);
                vec3 h = hash3(uvec3(uc, slot));
                if (h.x >= present) continue;
                vec2 d = (vec2(c) + h.yz) * cell - q;
                vec2 m = vec2(dot(d, axisAlong), dot(d, axisAcross));
                if (abs(m.x) >= reachAlong || abs(m.y) >= reachAcross) continue;
                float v = mix(GLINT_WEIGHT_MIN, vMax, h.x / present);
                sum += inversesqrt(v) * glintChain(m, chainHalf, stretchMax, 1.0 - sqrt(v), uvec3(uc, slot ^ 0xA511E9B3u), age,
                    sqrt(GLINT_WEIGHT_MIN / v), base);
            }
        }
    }
    return sum / (GLINT_WEIGHT_MEAN * rho * kernelArea) * ((1.0 - rest) / max(placed, 1e-4)) + rest;
}

/*
 * 太陽 (月) の照り返しのローブに掛ける倍率。ローブのうち粗さへ回した分の割合だけ効かせる (近景は表した波の法線のまま)
 * pos: 標本の位置 (ワールドの水平, TAA のジッター込み), N: 表した波の法線, L: 太陽 (月) の向き, alpha2: 照り返しのローブの alpha^2,
 * unresolved: 粗さへ回した (傾きの分散, 曲率の 2 乗の和), pixelWorld: 水面上の画素の幅 (視線と直交する向き, ブロック),
 * NoVGeo: 平均水面と視線の cos, crest: 稜線の向きを決める勾配 (waterGlintPatch)
 * alpha2 と unresolved には、場所ごとのさざ波の強さのむら (waterGlintPatch) を掛けた値を渡す
 */
float waterGlitter(vec2 pos, vec3 N, vec3 V, vec3 L, float alpha2, vec2 unresolved, float pixelWorld, float NoVGeo, vec2 crest) {
    if (alpha2 <= 0.0 || pixelWorld <= 0.0) return 1.0;
    float fraction = saturate(unresolved.x / alpha2);
    if (fraction < GLINT_FRACTION_MIN) return 1.0;
    float NoH = dot(N, normalize(L + V));
    if (NoH <= 0.0) return 1.0;
    // 傾きの分布は照り返しのローブ (Beckmann) と同じ alpha^2 のガウス。点の期待値はローブと同じなので、倍率の期待値は 1
    float x = clamp((1.0 / (NoH * NoH) - 1.0) / alpha2, 0.0, GLINT_X_MAX);
    float gauss = exp(-x);
    // 点の密度はワールドの面積あたりで決まる (画素の大きさによらない)。近づくと画面の中の数が減り、1 つは明るく大きくなる
    float rho = gauss / (PI * alpha2) * GLINT_CURVATURE * waterGlitterDensity() * unresolved.y;

    float NoV = max(NoVGeo, 0.02);
    float footprint = pixelWorld / NoV;
    rho *= mix(1.0, GLINT_NEAR_DENSITY, 0.5 * (waterTileResolved(waterCapillaryTile(0), footprint) + waterTileResolved(waterCapillaryTile(1), footprint)));
    float pixelArea = pixelWorld * footprint;
    /*
     * 波の形が画素に見える近くは、点の詰まった所を滑らかな照り返し (波の形の白い面) にする。波が画素より細かい中景は、
     * 置いた鎖の子の数で見て点のまま残す (滑らかにすると波の形の無い白い板が道の芯に広がった)
     */
    float nearShape = waterLayerResolved(GLINT_SHORT_FIRST + 1, footprint);
    float smoothDensity = mix(GLINT_KEEP * GLINT_CHAIN_MEAN, GLINT_SMOOTH_NEAR, nearShape);
    float smoothW = smoothstep(GLINT_SMOOTH_LAMBDA.x, GLINT_SMOOTH_LAMBDA.y, rho * pixelArea * smoothDensity);
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
        float chainHalf = min(GLINT_CHAIN_REACH / NoV, GLINT_CHAIN_HALF_MAX) * WATER_GLITTER_LENGTH / GLINT_RADIUS;
        float concentrateMax = mix(GLINT_CONCENTRATE_MAX, GLINT_CONCENTRATE_NEAR, nearShape);
        /*
         * 稜線の向きが定まらない所は画面の横に並べる。視線と直交する水平の向きは、画面の端では透視で傾き、同じ角度の斜めの筋が並んで雨のように見えた
         * (横に回さないカメラでは、水平の水面の上で画面の横へ動く向きは、どの画素でもカメラの右の向き)
         */
        vec2 right = gbufferModelViewInverse[0].xz;
        vec2 base = vec2(dot(right, axisAlong), dot(right, axisAcross));
        base = dot(base, base) > 1e-8 ? normalize(base) : vec2(0.0, 1.0);
        /*
         * 稜線の向きへ回す (GLINT_CREST_SCALE の説明)。ワールドの稜線 t を点の座標へ写すと、縦 (視線の向き) は NoV 倍に縮む
         * 鎖の長さはワールドの長さに合わせ、写した長さの比 (画面の横の向きで 1、視線に沿う向きで NoV) を掛ける
         * 子の横の伸びはかすめ角で小さな面が縦につぶれる分なので、鎖が横に寝ている分だけ掛ける (縦の列の子を縦に伸ばすと雨の筋になる)
         */
        float crestW = smoothstep(GLINT_CREST_FLAT.x, GLINT_CREST_FLAT.y, length(crest));
        if (crestW > 0.0) {
            vec2 t = normalize(vec2(-crest.y, crest.x));
            vec2 b = vec2(dot(t, axisAlong), dot(t, axisAcross));
            float scale = length(b) * pixelWorld * GLINT_RADIUS;
            b = normalize(b);
            vec2 dir = mix(base, dot(b, base) < 0.0 ? -b : b, crestW);
            base = dot(dir, dir) > 1e-8 ? normalize(dir) : b;
            chainHalf *= mix(1.0, scale, crestW);
            stretchMax = 1.0 + (stretchMax - 1.0) * sqr(base.y);
        }
        // どちらの段も期待値は同じなので、混ぜるのは切り替わりの帯だけにし、帯の外は片方の段だけを探す
        float wHi = smoothstep(GLINT_LEVEL_BLEND.x, GLINT_LEVEL_BLEND.y, fract(level));
        float gLo = wHi < 1.0 ? glintLevel(pos, levelLo, rho, axisAlong, axisAcross, kernelArea, chainHalf, stretchMax, concentrateMax, base) : 0.0;
        float gHi = wHi > 0.0 ? glintLevel(pos, levelLo + 1.0, rho, axisAlong, axisAcross, kernelArea, chainHalf, stretchMax, concentrateMax, base) : 0.0;
        g = mix(mix(gLo, gHi, wHi), 1.0, smoothW);
    }
    // g の期待値は画素ごとに 1。ローブのうち粗さへ回した分の割合だけ点にする
    return mix(1.0, g, fraction);
}

#endif
