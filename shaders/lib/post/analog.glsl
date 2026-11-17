/*
 * アナログ領域 (2000 年代の民生 CCD ビデオカメラの画、post モジュール)
 * 中身は ANALOG の時だけ入れる (ANALOG OFF の final の本文を今と同じにする)
 */
#ifndef POST_ANALOG_GLSL
#define POST_ANALOG_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/buffers/analog_smear.glsl"
//@include "/lib/post/analog_presets.glsl"
//@include "/lib/post/analog_formats.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/transforms.glsl"

#if defined ANALOG && defined ANALOG_SMEAR && defined SSBO_ANALOG_SMEAR_USE
/*
 * ### applyAnalogSmear
 * CCD の縦スミア。インターライン転送 CCD では明るい光が垂直転送レジスタへ漏れ、読み出しの転送の間に足され続けて列全体の筋になる
 * スミア比 (転送時間 / 蓄積時間) は列が一様に照らされた時の比なので、列の平均にそのまま掛ける。
 * 線形なのでしきい値も減衰も持たない (一様な画面は小さな一様の底上げで、明るい光の列だけが筋に見える)
 *
 * @param hdr - 露出前の線形の色
 * @param column - colortex0 の列 (composite26 が平均を取った座標)
 * @returns 筋を足した色
 */
vec3 applyAnalogSmear(vec3 hdr, int column) {
    vec3 mean = analogSmear.columns[clamp(column, 0, ANALOG_SMEAR_COLUMNS_ALLOC - 1)].rgb;
#if AP_SMEAR_TINT_MODE == 0
    vec3 streak = mean;
#else
    // 漏れた電荷は列のどの色の画素の読み出しにも同じだけ足されるので、筋は白い (列の平均の輝度)
    vec3 streak = vec3(luminance(mean));
#endif
    // AP_SMEAR_RATIO は % なので比に直す
    return hdr + streak * (AP_SMEAR_RATIO / 100.0);
}
#endif

#if defined ANALOG && defined ANALOG_CHROMA
// Y'CbCr の係数 (Kr, Kg, Kb)。SD の DV は BT.601、HDV は BT.709
#if AF_YCC_709 == 1
const vec3 ANALOG_LUMA_WEIGHTS = vec3(0.2126, 0.7152, 0.0722);
#else
const vec3 ANALOG_LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);
#endif
// 色差の 1 標本の箱を横に覆うタップの数。4:1:1 は箱が輝度の 4 画素 (1920 幅で約 11 px) と広いので 3、4:2:0 は 2
#if AF_CHROMA_X >= 4
const int ANALOG_CHROMA_TAPS = 3;
#else
const int ANALOG_CHROMA_TAPS = 2;
#endif

vec3 analogRgbToYcc(vec3 rgb) {
    float y = dot(rgb, ANALOG_LUMA_WEIGHTS);
    return vec3(y, (rgb.b - y) / (2.0 * (1.0 - ANALOG_LUMA_WEIGHTS.b)), (rgb.r - y) / (2.0 * (1.0 - ANALOG_LUMA_WEIGHTS.r)));
}

vec3 analogYccToRgb(vec3 ycc) {
    float r = ycc.x + 2.0 * (1.0 - ANALOG_LUMA_WEIGHTS.r) * ycc.z;
    float b = ycc.x + 2.0 * (1.0 - ANALOG_LUMA_WEIGHTS.b) * ycc.y;
    float g = (ycc.x - ANALOG_LUMA_WEIGHTS.r * r - ANALOG_LUMA_WEIGHTS.b * b) / ANALOG_LUMA_WEIGHTS.g;
    return vec3(r, g, b);
}

/*
 * 色差の標本 1 つの CbCr: 標本の位置 (仮想の輝度の画素の座標) を中心に、横 AF_CHROMA_X 画素 (4:2:0 は縦 2 線も) の箱の平均
 * CbCr は R'G'B' の一次式なので、箱の色の平均の CbCr が箱の CbCr の平均になる。箱は横に並べたタップと、
 * タップの間隔に合わせて太らせた colortex0 のミップの段で覆う (タップだけでは 1920 幅の 4:1:1 の箱の半分ほどしか覆えず、細かい模様が動くとちらつく)
 */
vec2 analogChromaSample(vec2 center, float lod) {
    const vec2 grid = vec2(AF_SAMPLES, AF_LINES);
    vec3 sum = vec3(0.0);
    for (int i = 0; i < ANALOG_CHROMA_TAPS; i++) {
        float dx = (float(i) + 0.5) / float(ANALOG_CHROMA_TAPS) * float(AF_CHROMA_X) - 0.5 * float(AF_CHROMA_X);
        sum += textureLod(colortex0, vec2(center.x + dx, center.y) / grid, lod).rgb;
    }
    return analogRgbToYcc(sum / float(ANALOG_CHROMA_TAPS)).yz;
}

/*
 * ### applyAnalogChroma
 * DV の色差の間引き (4:1:1 / 4:2:0)。表示値 (composite27 の出力) の色差を、形式の標本の格子で作り直して戻す。輝度 Y' はそのまま
 * 標本は左寄せ (4:1:1 は輝度の 4 画素ごとの先頭)、4:2:0 の縦は 2 線の間の中央
 *
 * @param uv - 出力の座標
 * @param texel - 出力の画素
 * @returns 色差を間引いた表示値 (0-1 に収める前)
 */
vec3 applyAnalogChroma(vec2 uv, ivec2 texel) {
    vec3 color = texelFetch(colortex0, texel, 0).rgb;
    // 仮想の輝度の画素の座標 (画素の中心が n + 0.5)。縦の 2 線の組は下から数えても上からと同じ (走査線の数が偶数)
    vec2 p = uv * vec2(AF_SAMPLES, AF_LINES);
    // タップの間隔 (出力の px)。双線形の三角形の幅 2 x 2^lod がこれに合う段で読む
    float spacing = float(AF_CHROMA_X) / float(ANALOG_CHROMA_TAPS) * viewWidth / float(AF_SAMPLES);
#if AF_CHROMA_Y > 1
    spacing = max(spacing, float(AF_CHROMA_Y) * viewHeight / float(AF_LINES));
#endif
    float lod = log2(max(0.5 * spacing, 1.0));

    // 標本 k の中心 x_k = k * AF_CHROMA_X + 0.5 (左寄せ)。4:2:0 の標本 j の中心 y_j = j * 2 + 1
    float kf = (p.x - 0.5) / float(AF_CHROMA_X);
#if AF_CHROMA_Y > 1
    float jf = (p.y - 0.5 * float(AF_CHROMA_Y)) / float(AF_CHROMA_Y);
#endif
#if AP_CHROMA_UPSAMPLE_MODE == 1
    // 最近傍: 一番近い標本をそのまま使う (色の境目が階段になる)
    float k = floor(kf + 0.5);
    #if AF_CHROMA_Y > 1
    float y = (floor(jf + 0.5) + 0.5) * float(AF_CHROMA_Y);
    #else
    float y = p.y;
    #endif
    vec2 chroma = analogChromaSample(vec2(k * float(AF_CHROMA_X) + 0.5, y), lod);
#else
    // 補間: 両隣の標本を線形に (4:2:0 は縦も)
    float k0 = floor(kf);
    float tx = kf - k0;
    vec2 x01 = vec2(k0, k0 + 1.0) * float(AF_CHROMA_X) + 0.5;
    #if AF_CHROMA_Y > 1
    float j0 = floor(jf);
    float ty = jf - j0;
    vec2 y01 = (vec2(j0, j0 + 1.0) + 0.5) * float(AF_CHROMA_Y);
    vec2 chroma = mix(mix(analogChromaSample(vec2(x01.x, y01.x), lod), analogChromaSample(vec2(x01.y, y01.x), lod), tx),
                      mix(analogChromaSample(vec2(x01.x, y01.y), lod), analogChromaSample(vec2(x01.y, y01.y), lod), tx), ty);
    #else
    vec2 chroma = mix(analogChromaSample(vec2(x01.x, p.y), lod), analogChromaSample(vec2(x01.y, p.y), lod), tx);
    #endif
#endif
    vec3 ycc = analogRgbToYcc(color);
    ycc.yz = mix(ycc.yz, chroma, AP_CHROMA_STRENGTH);
    return analogYccToRgb(ycc);
}
#endif

#endif
