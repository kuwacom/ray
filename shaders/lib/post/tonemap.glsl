/*
 * トーンマップ (post モジュール)
 * 入力: 露出適用済みの線形 HDR (Rec.709), 出力: 表示用の線形 [0,1] (sRGB エンコードは final で行う)
 * TONEMAP 0 = AgX, 1 = AgX Punchy, 2 = ACES (Hill の近似 fit), 3 = Reinhard-Jodie, 4 = AgX Golden, 5 = Khronos PBR Neutral
 */
#ifndef POST_TONEMAP_GLSL
#define POST_TONEMAP_GLSL

/*
 * ASC CDL (slope / offset / power + saturation)
 * 彩度は SOP 後の Rec.709 輝度を軸にする (ASC の仕様どおり)
 */
vec3 applyCdl(vec3 c, vec3 slope, vec3 offset, vec3 power, float sat) {
    c = pow(max(c * slope + offset, 0.0), power);
    float l = luminance(c);
    return l + sat * (c - l);
}

/*
 * AgX (Troy Sobotka の AgX を Blender / three.js 系の多項式近似で書いたもの)
 * 対数ドメインで 16.5 EV を圧縮するので高輝度でも色が飽和しにくく「デジカメ的」な階調になる
 * 行列は AgX の入力 (inset) / 出力 (outset) 変換、範囲は 0.18 中心に -12.47 .. +4.03 EV (Blender 既定。ここでは下の定数で 13 EV に狭めている)
 */
const mat3 AGX_INSET = mat3(
    0.842479062253094, 0.0423282422610123, 0.0423756549057051,
    0.0784335999999992, 0.878468636469772, 0.0784336,
    0.0792237451477643, 0.0791661274605434, 0.879142973793104
);
const mat3 AGX_OUTSET = mat3(
    1.19687900512017, -0.0528968517574562, -0.0529716355144438,
    -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
    -0.0990297440797205, -0.0989611768448433, 1.15107367264116
);
/*
 * 対数レンジ。Blender 既定 (-12.47 .. +4.03, 16.5 EV) は中間調の傾きが緩く、昼は灰色に濁り、
 * 木材などの色比も 1 EV あたりの表示差が小さくなって色が抜けた
 * iterationT の実効値 (13 EV、白は 0.18 の約 +5.3 EV で飽和) に合わせ、コントラスト・彩度・白の伸びを確保する
 */
const float AGX_MIN_EV = -10.18;
const float AGX_MAX_EV = 2.82;

// AgX のシグモイド (log エンコード値 -> 表示エンコード値) の 6 次多項式近似
vec3 agxContrastCurve(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

// look: 0 = なし, 1 = Punchy (Blender の AgX Punchy 相当: コントラストと彩度を盛る), 2 = Golden (青を抑えた暖色の look)
vec3 tonemapAgx(vec3 x, int look) {
    vec3 v = AGX_INSET * max(x, 0.0);
    v = clamp(log2(max(v, 1e-10)), AGX_MIN_EV, AGX_MAX_EV);
    v = (v - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV);
    v = saturate(agxContrastCurve(v));
    if (look == 1) {
        v = applyCdl(v, vec3(1.0), vec3(0.0), vec3(1.35), 1.4);
    } else if (look == 2) {
        v = applyCdl(v, vec3(1.0, 0.9, 0.5), vec3(0.0), vec3(0.8), 0.8);
    }
    v = AGX_OUTSET * v;
    // AgX の出力は 2.2 乗のディスプレイを前提にエンコードされているので線形へ戻す
    return pow(saturate(v), vec3(2.2));
}

/*
 * ACES (Stephen Hill の RRT + ODT 近似 fit, sRGB 出力)
 * 0.18 が AgX とおおよそ同じ明るさに来るよう入力に倍率を掛ける
 */
const mat3 ACES_INPUT = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777
);
const mat3 ACES_OUTPUT = mat3(
    1.60475, -0.10208, -0.00327,
    -0.53108, 1.10813, -0.07276,
    -0.07367, -0.00605, 1.07602
);
const float ACES_PRE_GAIN = 1.6;

vec3 tonemapAces(vec3 x) {
    vec3 v = ACES_INPUT * (x * ACES_PRE_GAIN);
    v = (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081);
    return saturate(ACES_OUTPUT * v);
}

// Reinhard-Jodie: 輝度で圧縮した色とチャンネル別に圧縮した色を、明るさに応じて混ぜる (高輝度ほど白へ)
vec3 tonemapReinhardJodie(vec3 x) {
    float l = luminance(x);
    vec3 tv = x / (1.0 + x);
    return saturate(mix(x / (1.0 + l), tv, tv));
}

/*
 * Khronos PBR Neutral (Khronos 3D Commerce の公開仕様)
 * 0.8 付近までは素通しで、それより明るい所だけ圧縮して白へ寄せる。素材色を崩さない
 */
const float PBR_NEUTRAL_START = 0.76;
const float PBR_NEUTRAL_DESATURATION = 0.15;

vec3 tonemapPbrNeutral(vec3 c) {
    c = max(c, 0.0);
    float x = minOf(c);
    c -= x < 0.08 ? x - 6.25 * x * x : 0.04;
    float peak = maxOf(c);
    if (peak < PBR_NEUTRAL_START) return c;
    float d = 1.0 - PBR_NEUTRAL_START;
    float newPeak = 1.0 - d * d / (peak + d - PBR_NEUTRAL_START);
    c *= newPeak / peak;
    float g = 1.0 - 1.0 / (PBR_NEUTRAL_DESATURATION * (peak - newPeak) + 1.0);
    return saturate(mix(c, vec3(newPeak), g));
}

vec3 tonemap(vec3 x) {
#if TONEMAP == 0
    return tonemapAgx(x, 0);
#elif TONEMAP == 1
    return tonemapAgx(x, 1);
#elif TONEMAP == 2
    return tonemapAces(x);
#elif TONEMAP == 3
    return tonemapReinhardJodie(x);
#elif TONEMAP == 4
    return tonemapAgx(x, 2);
#else
    return tonemapPbrNeutral(x);
#endif
}

/*
 * 溶岩用: 色相と彩度を保つトーンマップ
 * AgX は入力の行列で赤の 4-8% を緑・青へ回してからチャンネルごとに圧縮するので、明るい橙は青が持ち上がって白・サーモン色に抜ける
 * 最大チャンネルにだけ tonemap の灰色の曲線を掛け、色の比は残す。白への抜けは明るい所だけ、弱いチャンネルを
 * 冪で持ち上げる形 (橙 -> 黄 -> 白、黒体の色の順) にする
 */
// 曲線の出力がここを超えると白へ抜け始める。0.75 では露出後の上限を上げた溶岩の橙の地まで淡くなったので、黄色い筋だけが抜けるよう上げた
// -> 曲線の出力で決めると、最大チャンネルが曲線の上端 (露出後 7 付近) で 1 に張り付き、それより明るい地と割れ目が同じ色になって
//    模様が消え、青も同じだけ上がってサーモン色に寄った (溶岩を明るくした時)。持ち上げは最大チャンネルの対数で決め、
//    青は緑より弱くする (橙 -> 黄 -> 黄白の順。黒体の色も青は最後に上がる)
//    始まりを溶岩の暗い殻 (LAVA_BRIGHTNESS 既定で露出後 2-3) より上に置き、殻は濃い橙のまま割れ目だけ黄色へ寄せる
const float EMISSIVE_LIFT_START = 4.0;   // 露出後の最大チャンネルがここを超えると弱いチャンネルを持ち上げ始める
const float EMISSIVE_LIFT_RANGE = 3.0;   // 持ち上げが最大になるまでの段数 (EV)
const vec3 EMISSIVE_WHITE_LIFT = vec3(0.8, 0.8, 0.35);   // 最大での弱いチャンネルの持ち上げ (比の 1 - この値 乗)

vec3 tonemapEmissive(vec3 x) {
    x = max(x, 0.0);
    float peak = maxOf(x);
    if (peak <= 1e-6) return vec3(0.0);
    vec3 mapped = tonemap(vec3(peak));
    float w = saturate(log2(peak / EMISSIVE_LIFT_START) / EMISSIVE_LIFT_RANGE);
    return mapped * pow(x / peak, 1.0 - EMISSIVE_WHITE_LIFT * w);
}

#endif
