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
//@include "/lib/common/jitter.glsl"
//@include "/lib/post/post_constants.glsl"
//@include "/lib/post/lens_presets.glsl"
//@include "/lib/post/velocity.glsl"
//@include "/lib/post/lens_optics.glsl"

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

#if defined ANALOG && (defined ANALOG_CHROMA || defined ANALOG_RESOLUTION || defined ANALOG_SHARPEN || defined ANALOG_INTERLACE)
#define ANALOG_RECORD_STAGE 1

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

// 双線形の三角形の幅 2 x 2^lod が出力の px の間隔 spacing に合うミップの段 (タップの間を覆う)
float analogTapLod(float spacing) {
    return log2(max(0.5 * spacing, 1.0));
}

#ifdef ANALOG_INTERLACE
#if ANALOG_INTERLACE_MODE == 0
// 古いフィールドの走査線で読む位置から引く量 (出力の uv)。applyAnalogRecord が中心の画素で 1 回だけ求める
vec2 analogFieldShift = vec2(0.0);
#else
// フィールド表示で今出しているフィールドの走査線の偶奇 (上から数えて 0 = 上のフィールド)
int analogFieldPhase = 0;
#endif

// final の colortex0 (出力の座標) の位置 uv に写っている元画像の位置 (深度・速度を読む位置)。歪曲を現像で掛ける時も含む
bool analogLensRemapped() {
#ifdef LENS_DISTORTION
    const bool distort = LP_K1 != 0.0 || LP_K2 != 0.0 || LP_K3 != 0.0 || LENS_PROJECTION == 1;
#else
    const bool distort = false;
#endif
    return LENS_WARP_TAA || distort;
}

vec2 analogSourceUv(vec2 uv) {
    if (!analogLensRemapped()) return uv;
    float rho;
    return clamp(lensProjectUv(uv, rho), 0.5 / viewSize(), 1.0 - 0.5 / viewSize());
}

/*
 * 1 フィールド分の視点の動き (出力の uv)。前フレームの位置 - 今 を、フィールドの時間とフレームの長さの比で縮める
 * フレームレートによらず同じ櫛の幅になる。速度はカメラの動きだけ (物体自身の動きは入らない)
 */
vec2 analogFieldMotion(vec2 uv) {
    vec2 src = analogSourceUv(uv);
    float depth = texelFetch(depthtex0, ivec2(src * viewSize()), 0).r;
    vec2 previous;
    if (analogLensRemapped()) {
        // getPreviousUv はジッター込みのバッファの位置を受け取り、同じだけずれた位置を返す (postPreviousUv と同じ扱い)
        vec2 jitter = taaJitterUv();
        previous = lensForwardUv(getPreviousUv(src + jitter, depth) - jitter);
    } else {
        previous = getPreviousUv(uv, depth);
    }
    vec2 d = (previous - uv) * ((1.0 / AF_FIELD_RATE) / max(frameTime, ANALOG_FRAME_TIME_MIN));
    float len = length(d * viewSize());
    return len > ANALOG_INTERLACE_MAX_PX ? d * (ANALOG_INTERLACE_MAX_PX / len) : d;
}
#endif

/*
 * 表示値 (composite27 の出力) を記録の段の位置 uv で読む。インターレースは読む位置の走査線ごとに選ぶ:
 * 織り込みは古いフィールドの走査線を 1 フィールド前の位置で読み (動いた所の櫛)、フィールド表示は今のフィールドでない走査線を上下の線から補う
 */
vec3 analogFetch(vec2 uv, float lod) {
#ifdef ANALOG_INTERLACE
    int parity = int(floor((1.0 - uv.y) * float(AF_LINES))) & 1;
    #if ANALOG_INTERLACE_MODE == 0
    if (parity == AF_OLDER_FIELD) uv -= analogFieldShift;
    #else
    if (parity != analogFieldPhase) {
        vec2 line = vec2(0.0, 1.0 / float(AF_LINES));
        return 0.5 * (textureLod(colortex0, uv + line, lod).rgb + textureLod(colortex0, uv - line, lod).rgb);
    }
    #endif
#endif
    return textureLod(colortex0, uv, lod).rgb;
}

#ifdef ANALOG_RESOLUTION
/*
 * 解像: 出力の uv を中心に、仮想の画素の間隔で並べた 3x3 のタップの輝度のガウスの平均
 * 仮想の画素の中心へは丸めない (丸めると同じ仮想の画素の出力の画素が同じ値になり、2 px と 3 px のモザイクになる)
 */
float analogSoftLuma(vec2 uv, float centerLuma) {
    vec2 step = 1.0 / vec2(AF_SAMPLES, AF_LINES);
    float lod = analogTapLod(viewWidth / float(AF_SAMPLES));
    vec2 sigma = vec2(ANALOG_SOFT_SIGMA_X * AP_RESOLUTION_H, ANALOG_SOFT_SIGMA_Y / ANALOG_KELL * AP_RESOLUTION_V);
    float sum = 0.0;
    float weight = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 o = vec2(i, j);
            float w = exp(-0.5 * dot(o / sigma, o / sigma));
            float y = (i == 0 && j == 0) ? centerLuma : dot(analogFetch(uv + o * step, lod), ANALOG_LUMA_WEIGHTS);
            sum += w * y;
            weight += w;
        }
    }
    return sum / weight;
}
#endif

#ifdef ANALOG_CHROMA
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
        sum += analogFetch(vec2(center.x + dx, center.y) / grid, lod);
    }
    return analogRgbToYcc(sum / float(ANALOG_CHROMA_TAPS)).yz;
}

/*
 * DV の色差の間引き (4:1:1 / 4:2:0): 色差を形式の標本の格子で作り直して戻した CbCr
 * 標本は左寄せ (4:1:1 は輝度の 4 画素ごとの先頭)、4:2:0 の縦は 2 線の間の中央
 */
vec2 analogSubsampledChroma(vec2 uv) {
    // 仮想の輝度の画素の座標 (画素の中心が n + 0.5)。縦の 2 線の組は下から数えても上からと同じ (走査線の数が偶数)
    vec2 p = uv * vec2(AF_SAMPLES, AF_LINES);
    float spacing = float(AF_CHROMA_X) / float(ANALOG_CHROMA_TAPS) * viewWidth / float(AF_SAMPLES);
#if AF_CHROMA_Y > 1
    spacing = max(spacing, float(AF_CHROMA_Y) * viewHeight / float(AF_LINES));
#endif
    float lod = analogTapLod(spacing);

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
    return analogChromaSample(vec2(k * float(AF_CHROMA_X) + 0.5, y), lod);
#else
    // 補間: 両隣の標本を線形に (4:2:0 は縦も)
    float k0 = floor(kf);
    float tx = kf - k0;
    vec2 x01 = vec2(k0, k0 + 1.0) * float(AF_CHROMA_X) + 0.5;
    #if AF_CHROMA_Y > 1
    float j0 = floor(jf);
    float ty = jf - j0;
    vec2 y01 = (vec2(j0, j0 + 1.0) + 0.5) * float(AF_CHROMA_Y);
    return mix(mix(analogChromaSample(vec2(x01.x, y01.x), lod), analogChromaSample(vec2(x01.y, y01.x), lod), tx),
               mix(analogChromaSample(vec2(x01.x, y01.y), lod), analogChromaSample(vec2(x01.y, y01.y), lod), tx), ty);
    #else
    return mix(analogChromaSample(vec2(x01.x, p.y), lod), analogChromaSample(vec2(x01.y, p.y), lod), tx);
    #endif
#endif
}
#endif

/*
 * ### applyAnalogRecord
 * 記録の段: 表示値 (composite27 の出力) に、インターレース -> 解像 -> 輪郭強調 (輝度) -> 色差の間引きを掛ける
 * 輝度と色差を分けて扱う (輪郭強調を色に掛けると縁に色の縁取りが出て、色差のにじみと逆向きになる)
 *
 * @param uv - 出力の座標
 * @returns 記録の段を掛けた表示値 (0-1 に収める前。輪郭強調のはみ出しは切らない)
 */
vec3 applyAnalogRecord(vec2 uv) {
#ifdef ANALOG_INTERLACE
    #if ANALOG_INTERLACE_MODE == 0
    analogFieldShift = AP_INTERLACE_STRENGTH * analogFieldMotion(uv);
    #else
    analogFieldPhase = int(floor(frameTimeCounter * AF_FIELD_RATE)) & 1;
    #endif
#endif
    vec3 ycc = analogRgbToYcc(analogFetch(uv, 0.0));
#ifdef ANALOG_RESOLUTION
    float luma = analogSoftLuma(uv, ycc.x);
#else
    float luma = ycc.x;
#endif
#ifdef ANALOG_SHARPEN
    if (AP_SHARPEN_STRENGTH > 0.0) {
        // ぼかした輝度は、半径 (仮想の画素) の 2 倍の箱に合うミップの段の 1 タップ
        float blur = dot(analogFetch(uv, log2(max(2.0 * AP_SHARPEN_RADIUS * viewWidth / float(AF_SAMPLES), 1.0))), ANALOG_LUMA_WEIGHTS);
        float detail = luma - blur;
        // コアリング: 細かい揺らぎ (ノイズ) までは強調しない
        float cored = sign(detail) * max(abs(detail) - AP_SHARPEN_CORING * ANALOG_SHARPEN_CORING, 0.0);
        luma += AP_SHARPEN_STRENGTH * ANALOG_SHARPEN_GAIN * cored;
    }
#endif
    ycc.x = luma;
#ifdef ANALOG_CHROMA
    ycc.yz = mix(ycc.yz, analogSubsampledChroma(uv), AP_CHROMA_STRENGTH);
#endif
    return analogYccToRgb(ycc);
}
#endif

#endif
