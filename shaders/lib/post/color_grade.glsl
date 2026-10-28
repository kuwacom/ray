/*
 * カラーグレーディング (post モジュール, final だけが使う)
 * DaVinci Resolve のノードの考え方に合わせて、シーンの値 (露出後・トーンマップ前) で掛けるものと、表示値 (トーンマップ・sRGB エンコード後) で掛けるものに分ける
 * - シーンの値 (対数で考える): ホワイトバランス -> ティント -> オフセット -> コントラストとピボット -> 明部の伸び (ルック) -> ゾーン
 *   (シャドー・ミッド・ハイライト) -> ハイライトの圧縮・シャドーの持ち上げ -> 彩度 -> バイブランス -> 色相ごとの調整。
 *   露出の段 (EV) で効くので、明るさの変わる昼・夜・洞窟で同じように効き、トーンマップがはみ出しを畳むのでクリップしにくい
 * - 表示値: リフト・ガンマ・ゲイン -> トーンカーブ -> スプリットトーン -> ルックの LUT -> CDL。黒 0・白 1 が決まった値の上で掛ける
 *   (リフトは黒、ゲインは白を動かす)。フィルムの LUT は Resolve でフィルムのエミュレーションを最後に置くのと同じで、グレードの後に掛ける
 * 設定 (GRADE_*) とルックのプリセットの基準 (LKG_*, look_presets.glsl) は、足す値は和、掛ける値は積で合わせる。
 * 既定値ではどの段も恒等で、定数畳み込みで丸ごと消える
 */
#ifndef POST_COLOR_GRADE_GLSL
#define POST_COLOR_GRADE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/look_presets.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/post/post_constants.glsl"

// 実効値
const float G_TINT = GRADE_TINT + LKG_TINT;
const vec3 G_OFFSET = vec3(GRADE_OFFSET_R, GRADE_OFFSET_G, GRADE_OFFSET_B) + LKG_OFFSET;
const float G_PIVOT = GRADE_PIVOT + LKG_PIVOT;

const vec4 G_SHADOW = vec4(GRADE_SHADOW_R, GRADE_SHADOW_G, GRADE_SHADOW_B, GRADE_SHADOW_Y) + LKG_SHADOW;
const vec4 G_MID = vec4(GRADE_MID_R, GRADE_MID_G, GRADE_MID_B, GRADE_MID_Y) + LKG_MID;
const vec4 G_HIGHLIGHT = vec4(GRADE_HIGHLIGHT_R, GRADE_HIGHLIGHT_G, GRADE_HIGHLIGHT_B, GRADE_HIGHLIGHT_Y) + LKG_HIGHLIGHT;
// ゾーンごとの彩度・コントラスト (x = シャドー, y = ミッド, z = ハイライト)
const vec3 G_ZONE_SAT = vec3(GRADE_SHADOW_SAT, GRADE_MID_SAT, GRADE_HIGHLIGHT_SAT) * LKG_ZONE_SAT;
const vec3 G_ZONE_CONTRAST = vec3(GRADE_SHADOW_CONTRAST, GRADE_MID_CONTRAST, GRADE_HIGHLIGHT_CONTRAST) * LKG_ZONE_CONTRAST;
const float G_SHADOW_END = GRADE_SHADOW_END;
const float G_HIGHLIGHT_START = GRADE_HIGHLIGHT_START;
const float G_ZONE_SOFTNESS = GRADE_ZONE_SOFTNESS;

const float G_HIGHLIGHT_COMPRESS = GRADE_HIGHLIGHT_COMPRESS + LKG_HIGHLIGHT_COMPRESS;
const float G_SHADOW_LIFT = GRADE_SHADOW_LIFT + LKG_SHADOW_LIFT;
const float G_VIBRANCE = GRADE_VIBRANCE + LKG_VIBRANCE;

// 色相ごと: 赤, 橙, 黄, 緑, 水色, 青, 紫, マゼンタ
const float G_HUE_SHIFT[8] = float[8](
    GRADE_HUE_RED + LKG_HUE_SHIFT[0], GRADE_HUE_ORANGE + LKG_HUE_SHIFT[1], GRADE_HUE_YELLOW + LKG_HUE_SHIFT[2], GRADE_HUE_GREEN + LKG_HUE_SHIFT[3],
    GRADE_HUE_AQUA + LKG_HUE_SHIFT[4], GRADE_HUE_BLUE + LKG_HUE_SHIFT[5], GRADE_HUE_PURPLE + LKG_HUE_SHIFT[6], GRADE_HUE_MAGENTA + LKG_HUE_SHIFT[7]);
const float G_HUE_SAT[8] = float[8](
    GRADE_SAT_RED * LKG_HUE_SAT[0], GRADE_SAT_ORANGE * LKG_HUE_SAT[1], GRADE_SAT_YELLOW * LKG_HUE_SAT[2], GRADE_SAT_GREEN * LKG_HUE_SAT[3],
    GRADE_SAT_AQUA * LKG_HUE_SAT[4], GRADE_SAT_BLUE * LKG_HUE_SAT[5], GRADE_SAT_PURPLE * LKG_HUE_SAT[6], GRADE_SAT_MAGENTA * LKG_HUE_SAT[7]);
const float G_HUE_LUM[8] = float[8](
    GRADE_LUM_RED + LKG_HUE_LUM[0], GRADE_LUM_ORANGE + LKG_HUE_LUM[1], GRADE_LUM_YELLOW + LKG_HUE_LUM[2], GRADE_LUM_GREEN + LKG_HUE_LUM[3],
    GRADE_LUM_AQUA + LKG_HUE_LUM[4], GRADE_LUM_BLUE + LKG_HUE_LUM[5], GRADE_LUM_PURPLE + LKG_HUE_LUM[6], GRADE_LUM_MAGENTA + LKG_HUE_LUM[7]);

// リフト・ガンマ・ゲイン (rgb = 色, a = 輝度 (全チャンネル))
const vec4 G_LIFT = vec4(GRADE_LIFT_R, GRADE_LIFT_G, GRADE_LIFT_B, GRADE_LIFT_Y) + LKG_LIFT;
const vec4 G_GAMMA = vec4(GRADE_GAMMA_R, GRADE_GAMMA_G, GRADE_GAMMA_B, GRADE_GAMMA_Y) + LKG_GAMMA;
const vec4 G_GAIN = vec4(GRADE_GAIN_R, GRADE_GAIN_G, GRADE_GAIN_B, GRADE_GAIN_Y) * LKG_GAIN;

// トーンカーブの制御点 (入力の位置は固定、出力は設定 + プリセットのずらし)
const float G_CURVE_X[7] = float[7](0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0);
const float G_CURVE_Y[7] = float[7](
    GRADE_CURVE_0 + LKG_CURVE[0], GRADE_CURVE_10 + LKG_CURVE[1], GRADE_CURVE_25 + LKG_CURVE[2], GRADE_CURVE_50 + LKG_CURVE[3],
    GRADE_CURVE_75 + LKG_CURVE[4], GRADE_CURVE_90 + LKG_CURVE[5], GRADE_CURVE_100 + LKG_CURVE[6]);

// 段ごとの有効フラグ (既定値の段は定数畳み込みで消える)
const bool G_BALANCE_ON = G_TINT != 0.0 || G_OFFSET != vec3(0.0);
const bool G_ZONES_ON = G_SHADOW != vec4(0.0) || G_MID != vec4(0.0) || G_HIGHLIGHT != vec4(0.0) || G_ZONE_CONTRAST != vec3(1.0);
const bool G_ZONE_SAT_ON = G_ZONE_SAT != vec3(1.0);
const bool G_HSL_ON =
    G_HUE_SHIFT[0] != 0.0 || G_HUE_SHIFT[1] != 0.0 || G_HUE_SHIFT[2] != 0.0 || G_HUE_SHIFT[3] != 0.0 ||
    G_HUE_SHIFT[4] != 0.0 || G_HUE_SHIFT[5] != 0.0 || G_HUE_SHIFT[6] != 0.0 || G_HUE_SHIFT[7] != 0.0 ||
    G_HUE_SAT[0] != 1.0 || G_HUE_SAT[1] != 1.0 || G_HUE_SAT[2] != 1.0 || G_HUE_SAT[3] != 1.0 ||
    G_HUE_SAT[4] != 1.0 || G_HUE_SAT[5] != 1.0 || G_HUE_SAT[6] != 1.0 || G_HUE_SAT[7] != 1.0 ||
    G_HUE_LUM[0] != 0.0 || G_HUE_LUM[1] != 0.0 || G_HUE_LUM[2] != 0.0 || G_HUE_LUM[3] != 0.0 ||
    G_HUE_LUM[4] != 0.0 || G_HUE_LUM[5] != 0.0 || G_HUE_LUM[6] != 0.0 || G_HUE_LUM[7] != 0.0;
const bool G_CHROMA_ON = G_ZONE_SAT_ON || G_VIBRANCE != 0.0 || G_HSL_ON;
const bool G_LGG_ON = G_LIFT != vec4(0.0) || G_GAMMA != vec4(0.0) || G_GAIN != vec4(1.0);
const bool G_CURVE_ON =
    G_CURVE_Y[0] != G_CURVE_X[0] || G_CURVE_Y[1] != G_CURVE_X[1] || G_CURVE_Y[2] != G_CURVE_X[2] || G_CURVE_Y[3] != G_CURVE_X[3] ||
    G_CURVE_Y[4] != G_CURVE_X[4] || G_CURVE_Y[5] != G_CURVE_X[5] || G_CURVE_Y[6] != G_CURVE_X[6];
const bool G_SPLIT_ON = GRADE_SPLIT_SHADOW_AMOUNT + LKG_SPLIT_SHADOW_AMOUNT > 0.0 || GRADE_SPLIT_HIGHLIGHT_AMOUNT + LKG_SPLIT_HIGHLIGHT_AMOUNT > 0.0;

// Oklab (Björn Ottosson 2020)。HDR の線形でも、明るさを k 倍すると L・a・b がそろって k^(1/3) 倍になるので、色相と a,b / L の比は露出に依らない
const mat3 OKLAB_M1 = mat3(
    0.4122214708, 0.2119034982, 0.0883024619,
    0.5363325363, 0.6806995451, 0.2817188376,
    0.0514459929, 0.1073969566, 0.6299787005
);
const mat3 OKLAB_M2 = mat3(
    0.2104542553, 1.9779984951, 0.0259040371,
    0.7936177850, -2.4285922050, 0.7827717662,
    -0.0040720468, 0.4505937099, -0.8086757660
);
const mat3 OKLAB_M2_INV = mat3(
    1.0, 1.0, 1.0,
    0.3963377774, -0.1055613458, -0.0894841775,
    0.2158037573, -0.0638541728, -1.2914855480
);
const mat3 OKLAB_M1_INV = mat3(
    4.0767416621, -1.2684380046, -0.0041960863,
    -3.3077115913, 2.6097574011, -0.7034186147,
    0.2309699292, -0.3413193965, 1.7076147010
);

const float HUE_TURN = 360.0;  // 色相の一周 (度)

vec3 linearToOklab(vec3 c) {
    vec3 lms = OKLAB_M1 * c;
    return OKLAB_M2 * (sign(lms) * pow(abs(lms), vec3(1.0 / 3.0)));
}

vec3 oklabToLinear(vec3 lab) {
    vec3 lms = OKLAB_M2_INV * lab;
    return OKLAB_M1_INV * (lms * lms * lms);
}

// HSV の色相 (度, 0 = 赤, 120 = 緑, 240 = 青) の純色を、Oklab の a,b の単位ベクトルにする (スプリットトーンの色)
vec2 hueToOklabDir(float hueDeg) {
    vec3 rgb = saturate(abs(mod(hueDeg / 60.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0);
    vec2 ab = linearToOklab(srgbToLinear(rgb)).yz;
    return ab / max(length(ab), 1e-6);
}

// シーンの値の段

// ティントで動かす緑の量 (EV)。+ でマゼンタ、- で緑
const float GRADE_TINT_EV = 1.0;

/*
 * ティント (緑-マゼンタ) とオフセット (チャンネルごとの露出, Resolve のログホイールの Offset)
 * ティントは白の輝度を保つように正規化する
 */
vec3 gradeBalance(vec3 c) {
    if (!G_BALANCE_ON) return c;
    vec3 tint = vec3(1.0, exp2(-G_TINT * GRADE_TINT_EV), 1.0);
    return c * (tint / luminance(tint)) * exp2(G_OFFSET);
}

// コントラストの軸 (シーンの線形)。中間グレーから G_PIVOT EV
const float G_PIVOT_LEVEL = EXPOSURE_KEY * exp2(G_PIVOT);

// ハイライトの圧縮・シャドーの持ち上げの始まりの折れ目の幅 (EV)
const float GRADE_KNEE = 0.5;

/*
 * ゾーン (シャドー・ミッド・ハイライト) とハイライトの圧縮・シャドーの持ち上げ
 * ゾーンは中間グレーからの EV で分ける (Resolve の HDR ホイールと同じ考え方)。境目は G_ZONE_SOFTNESS EV で滑らかに重ねる
 * - 色と明るさ: ゾーンの重みでチャンネルごとの EV を足す
 * - コントラスト: シャドーは境目 (G_SHADOW_END)、ハイライトは境目 (G_HIGHLIGHT_START)、ミッドはピボットを軸に、EV の差を何倍にするか
 * - 圧縮・持ち上げ: 境目より外の EV の差 a を a / sqrt(1 + k a) に縮める (傾きは境目で 1、離れるほど緩む。上限で潰さないので太陽や光源の階調が残る)
 */
float gradeZoneWeights(float e, out float wShadow, out float wHighlight) {
    wShadow = 1.0 - smoothstep(G_SHADOW_END - G_ZONE_SOFTNESS, G_SHADOW_END + G_ZONE_SOFTNESS, e);
    wHighlight = smoothstep(G_HIGHLIGHT_START - G_ZONE_SOFTNESS, G_HIGHLIGHT_START + G_ZONE_SOFTNESS, e);
    // 境目が近く柔らかさが大きいと重なるので、合計を 1 以下にする
    float sum = wShadow + wHighlight;
    if (sum > 1.0) { wShadow /= sum; wHighlight /= sum; }
    return 1.0 - wShadow - wHighlight;
}

vec3 gradeZones(vec3 c) {
    if (!G_ZONES_ON && G_HIGHLIGHT_COMPRESS <= 0.0 && G_SHADOW_LIFT <= 0.0) return c;
    float e = log2(max(luminance(c), 1e-8) / EXPOSURE_KEY);
    vec3 ev = vec3(0.0);
    if (G_ZONES_ON) {
        float wS, wH;
        float wM = gradeZoneWeights(e, wS, wH);
        ev = wS * (G_SHADOW.rgb + G_SHADOW.a) + wM * (G_MID.rgb + G_MID.a) + wH * (G_HIGHLIGHT.rgb + G_HIGHLIGHT.a);
        ev += wS * (G_ZONE_CONTRAST.x - 1.0) * (e - G_SHADOW_END)
            + wM * (G_ZONE_CONTRAST.y - 1.0) * (e - G_PIVOT)
            + wH * (G_ZONE_CONTRAST.z - 1.0) * (e - G_HIGHLIGHT_START);
    }
    if (G_HIGHLIGHT_COMPRESS > 0.0) {
        float x = e - G_HIGHLIGHT_START;
        float a = 0.5 * (x + sqrt(x * x + GRADE_KNEE * GRADE_KNEE));
        ev -= a - a / sqrt(1.0 + G_HIGHLIGHT_COMPRESS * a);
    }
    if (G_SHADOW_LIFT > 0.0) {
        float y = G_SHADOW_END - e;
        float b = 0.5 * (y + sqrt(y * y + GRADE_KNEE * GRADE_KNEE));
        ev += b - b / sqrt(1.0 + G_SHADOW_LIFT * b);
    }
    return c * exp2(ev);
}

// 色相ごとの中心 (Oklab の色相, 度)。sRGB の赤・黄・緑・シアン・青・マゼンタの原色と、その間の橙 (1, 0.5, 0)・紫 (0.5, 0, 1)
const float G_HUE_CENTER[8] = float[8](29.2, 55.6, 109.8, 142.5, 194.8, 264.1, 292.6, 328.4);
// 色の薄い所では色相が定まらないので、a,b / L がここまでの所は色相ごとの調整を弱める
const float GRADE_HUE_CHROMA_MIN = 0.02;
const float GRADE_HUE_CHROMA_FULL = 0.08;
// バイブランス: a,b / L がここより鮮やかな所には効かせない
const float GRADE_VIBRANCE_REF = 0.3;
// 色相の回転の設定 1 あたりの度
const float GRADE_HUE_SHIFT_DEG = 1.0;

/*
 * 色相ごとの調整の値 (隣り合う中心の間を smoothstep で補間する。全部の色を同じにすれば全体に同じだけ効く)
 * 戻り値: x = 色相の回転 (度), y = 彩度の倍率, z = 明るさ (EV)
 */
vec3 gradeHueValues(float hue) {
    // 最初の中心より小さい色相は、最後の中心 (マゼンタ) から一周した続きとして扱う
    float h = hue < G_HUE_CENTER[0] ? hue + HUE_TURN : hue;
    // h 以下の中心の数 - 1 が区間の番号 (分岐の多いループより速い)
    int i = -1;
    for (int k = 0; k < 8; k++) i += h >= G_HUE_CENTER[k] ? 1 : 0;
    int j = (i + 1) % 8;
    float h0 = G_HUE_CENTER[i];
    float h1 = G_HUE_CENTER[j] + (j == 0 ? HUE_TURN : 0.0);
    float t = smoothstep(0.0, 1.0, (h - h0) / (h1 - h0));
    return mix(vec3(G_HUE_SHIFT[i], G_HUE_SAT[i], G_HUE_LUM[i]), vec3(G_HUE_SHIFT[j], G_HUE_SAT[j], G_HUE_LUM[j]), t);
}

/*
 * ゾーンごとの彩度・バイブランス・色相ごとの調整 (Oklab の a,b で、明るさを変えずに掛ける)
 * バイブランスは色の薄い所ほど強く効き、もう鮮やかな所はそのまま (肌や花が飽和しない)
 */
vec3 gradeChroma(vec3 c) {
    if (!G_CHROMA_ON) return c;
    vec3 lab = linearToOklab(max(c, 0.0));
    if (lab.x <= 1e-6) return c;
    float chroma = length(lab.yz);
    float rel = chroma / lab.x;
    float k = 1.0;
    if (G_ZONE_SAT_ON) {
        float e = log2(max(luminance(c), 1e-8) / EXPOSURE_KEY);
        float wS, wH;
        float wM = gradeZoneWeights(e, wS, wH);
        k *= dot(vec3(wS, wM, wH), G_ZONE_SAT);
    }
    if (G_VIBRANCE != 0.0) k *= max(1.0 + G_VIBRANCE * (1.0 - saturate(rel / GRADE_VIBRANCE_REF)), 0.0);
    float lumEv = 0.0;
    if (G_HSL_ON) {
        float hue = degrees(atan(lab.z, lab.y));
        hue = hue < 0.0 ? hue + HUE_TURN : hue;
        vec3 hv = gradeHueValues(hue);
        float m = smoothstep(GRADE_HUE_CHROMA_MIN, GRADE_HUE_CHROMA_FULL, rel);
        float rot = radians(hv.x * GRADE_HUE_SHIFT_DEG * m);
        lab.yz = mat2(cos(rot), sin(rot), -sin(rot), cos(rot)) * lab.yz;
        k *= mix(1.0, hv.y, m);
        lumEv = hv.z * m;
    }
    lab.yz *= k;
    return max(oklabToLinear(lab), 0.0) * exp2(lumEv);
}

// 表示値の段

/*
 * リフト・ガンマ・ゲイン (表示値)。out = (gain (x + lift (1 - x)))^(2^-gamma)
 * リフトは黒を持ち上げて白は動かさず、ゲインは白を動かして黒は動かさず、ガンマは両端を残して中間を動かす (+ で明るく)
 */
vec3 gradeLiftGammaGain(vec3 v) {
    if (!G_LGG_ON) return v;
    vec3 lift = G_LIFT.rgb + G_LIFT.a;
    vec3 gain = G_GAIN.rgb * G_GAIN.a;
    vec3 gamma = G_GAMMA.rgb + G_GAMMA.a;
    v = gain * (v + lift * (1.0 - v));
    return pow(max(v, 0.0), exp2(-gamma));
}

/*
 * トーンカーブ: 7 点を通る単調な 3 次エルミート補間。制御点が単調なら出力も単調で、行き過ぎ (リンギング) が出ない
 * 傾きは Fritsch-Butland (隣の区間の傾きの重み付き調和平均、向きが変わる点では 0)。定数だけで決まるので const にして画素ごとに計算しない
 * 0-1 の外は端の傾きで延ばす
 */
const float G_CURVE_D[6] = float[6](
    (G_CURVE_Y[1] - G_CURVE_Y[0]) / (G_CURVE_X[1] - G_CURVE_X[0]), (G_CURVE_Y[2] - G_CURVE_Y[1]) / (G_CURVE_X[2] - G_CURVE_X[1]),
    (G_CURVE_Y[3] - G_CURVE_Y[2]) / (G_CURVE_X[3] - G_CURVE_X[2]), (G_CURVE_Y[4] - G_CURVE_Y[3]) / (G_CURVE_X[4] - G_CURVE_X[3]),
    (G_CURVE_Y[5] - G_CURVE_Y[4]) / (G_CURVE_X[5] - G_CURVE_X[4]), (G_CURVE_Y[6] - G_CURVE_Y[5]) / (G_CURVE_X[6] - G_CURVE_X[5]));
#define G_CURVE_H(k) (G_CURVE_X[k + 1] - G_CURVE_X[k])
#define G_CURVE_M(k) (G_CURVE_D[k - 1] * G_CURVE_D[k] <= 0.0 ? 0.0 : \
    (3.0 * G_CURVE_H(k) + 3.0 * G_CURVE_H(k - 1)) / ((2.0 * G_CURVE_H(k) + G_CURVE_H(k - 1)) / G_CURVE_D[k - 1] + (G_CURVE_H(k) + 2.0 * G_CURVE_H(k - 1)) / G_CURVE_D[k]))
const float G_CURVE_TAN[7] = float[7](G_CURVE_D[0], G_CURVE_M(1), G_CURVE_M(2), G_CURVE_M(3), G_CURVE_M(4), G_CURVE_M(5), G_CURVE_D[5]);
#undef G_CURVE_M
#undef G_CURVE_H

vec3 gradeCurve(vec3 x) {
    vec3 y;
    for (int c = 0; c < 3; c++) {
        float v = x[c];
        // v 以上の内側の点の数が区間の番号 (0-5)
        int k = 0;
        for (int i = 1; i < 6; i++) k += v >= G_CURVE_X[i] ? 1 : 0;
        float h = G_CURVE_X[k + 1] - G_CURVE_X[k];
        float t = saturate((v - G_CURVE_X[k]) / h);
        float t2 = t * t;
        float t3 = t2 * t;
        y[c] = (2.0 * t3 - 3.0 * t2 + 1.0) * G_CURVE_Y[k] + (t3 - 2.0 * t2 + t) * h * G_CURVE_TAN[k]
             + (-2.0 * t3 + 3.0 * t2) * G_CURVE_Y[k + 1] + (t3 - t2) * h * G_CURVE_TAN[k + 1];
        // 0-1 の外は端の傾きで延ばす
        y[c] += min(v, 0.0) * G_CURVE_TAN[0] + max(v - 1.0, 0.0) * G_CURVE_TAN[6];
    }
    return y;
}
vec3 gradeToneCurve(vec3 v) {
    if (!G_CURVE_ON) return v;
#if GRADE_CURVE_MODE == 1
    // 輝度だけに掛けて色の比を保つ (コントラストを上げても彩度が上がらない)
    float y = luminance(v);
    float c = gradeCurve(vec3(y)).x;
    return y > 1e-5 ? v * (c / y) : vec3(c);
#else
    return gradeCurve(v);
#endif
}

// スプリットトーンの量 1 で、明るさ L に対して足す a,b の大きさ (L に比例させ、黒は色付けない)
const float GRADE_SPLIT_CHROMA = 0.15;

/*
 * スプリットトーン: シャドーとハイライトに別の色を足す (Oklab の a,b に足すので明るさは変わらない)
 * バランスで境目 (表示の明るさ 0.5 が既定) を上下に動かす
 */
vec3 gradeSplitTone(vec3 v) {
    if (!G_SPLIT_ON) return v;
    vec3 lab = linearToOklab(srgbToLinear(saturate(v)));
    float pivot = 0.5 + 0.35 * clamp(GRADE_SPLIT_BALANCE + LKG_SPLIT_BALANCE, -1.0, 1.0);
    float wS = 1.0 - smoothstep(0.0, pivot, lab.x);
    float wH = smoothstep(pivot, 1.0, lab.x);
    vec2 shadowAb = GRADE_SPLIT_SHADOW_AMOUNT * hueToOklabDir(GRADE_SPLIT_SHADOW_HUE) + LKG_SPLIT_SHADOW_AMOUNT * hueToOklabDir(LKG_SPLIT_SHADOW_HUE);
    vec2 highlightAb = GRADE_SPLIT_HIGHLIGHT_AMOUNT * hueToOklabDir(GRADE_SPLIT_HIGHLIGHT_HUE) + LKG_SPLIT_HIGHLIGHT_AMOUNT * hueToOklabDir(LKG_SPLIT_HIGHLIGHT_HUE);
    lab.yz += (shadowAb * wS + highlightAb * wH) * (GRADE_SPLIT_CHROMA * lab.x);
    return linearToSrgb(max(oklabToLinear(lab), 0.0));
}

vec3 gradeDisplay(vec3 v) {
    v = gradeLiftGammaGain(v);
    v = gradeToneCurve(v);
    return gradeSplitTone(v);
}

#endif
