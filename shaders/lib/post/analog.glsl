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
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/math.glsl"

#ifdef ANALOG
// Rec.709 の OETF とその逆 (ニーと、記録の段で表示値の近似の線形と行き来する所で使う。ニーが無い時も同じ式で近似)
vec3 analogOetf709(vec3 l) {
    return mix(4.5 * l, 1.099 * pow(max(l, 0.0), vec3(0.45)) - 0.099, step(0.018, l));
}

vec3 analogOetf709Inverse(vec3 v) {
    return mix(v / 4.5, pow(max((v + 0.099) / 1.099, 0.0), vec3(1.0 / 0.45)), step(0.081, v));
}
#endif

#if defined ANALOG && defined ANALOG_KNEE
/*
 * ### applyAnalogKnee
 * ビデオのニーと白飛び (トーンマップの代わり)。チャンネルごとに Rec.709 の OETF を掛け、ニーの始まりより上を、
 * AP_KNEE_RANGE 段分の明部が記録の上限 (109 %) に収まる傾きへ寝かせる。上限を超えた所は切れる。
 * チャンネルごとに切れるので、明るい色は切れたチャンネルから白へ抜けて色相がずれる (ビデオらしい白飛び)
 *
 * @param l - 露出とグレーディングの後のシーンの線形
 * @returns 表示値 (709 の値をそのまま出す。sRGB へは変換しない。PC で DV を見た時の扱い)
 */
vec3 applyAnalogKnee(vec3 l) {
    vec3 v = analogOetf709(l);
    float top = analogOetf709(vec3(exp2(AP_KNEE_RANGE))).x;
    float slope = (ANALOG_KNEE_CLIP - AP_KNEE_POINT) / (top - AP_KNEE_POINT);
    v = mix(v, AP_KNEE_POINT + (v - AP_KNEE_POINT) * slope, step(AP_KNEE_POINT, v));
#if ANALOG_KNEE_SUPERWHITE_MODE == 1
    // (b) 記録の 109 % を表示の 1.0 に写す (明部は 2 段分見えるが、100 % の白が 1 / 1.09 に下がる)
    v /= ANALOG_KNEE_CLIP;
#endif
    // (a) は 109 % まで記録し、表示では 100 % で切る
    return min(v, 1.0);
}
#endif

#if defined ANALOG && defined ANALOG_BLOOMING
/*
 * ### applyAnalogBlooming
 * CCD のブルーミング。飽和容量を超えた電荷が同じ列の上下の画素へあふれ、明るい点の上下が白くつぶれる。
 * 縦だけにして、等方のブルームと点像の裾に重ねない。上下の ANALOG_BLOOMING_TAPS 点ずつを AP_BLOOMING_LENGTH 本の
 * 仮想の走査線に広げて読み、あふれた分を三角の重みで配る (重みの和は両側で 1。あふれた電荷の総量を輝度で保つ)
 *
 * @param hdr - 露出前の線形の色
 * @param uv - シーン (colortex0) を読む位置
 * @param exposure - 露出の倍率
 * @returns あふれを足した色
 */
vec3 applyAnalogBlooming(vec3 hdr, vec2 uv, float exposure) {
    // 記録の上限に当たる露出の後の明るさ (ニーがあれば、ニーで収まる明部の上限)
#ifdef ANALOG_KNEE
    float saturation = AP_BLOOMING_THRESHOLD * exp2(AP_KNEE_RANGE);
#else
    float saturation = AP_BLOOMING_THRESHOLD;
#endif
    float spacing = float(AP_BLOOMING_LENGTH) / float(ANALOG_BLOOMING_TAPS) / float(AF_LINES);
    vec3 overflow = vec3(0.0);
    for (int i = 1; i <= ANALOG_BLOOMING_TAPS; i++) {
        vec2 offset = vec2(0.0, spacing * float(i));
        vec3 up = max(textureLod(colortex0, uv + offset, 0.0).rgb * exposure - saturation, 0.0);
        vec3 down = max(textureLod(colortex0, uv - offset, 0.0).rgb * exposure - saturation, 0.0);
        // 三角の重み: 近いタップほど重く、和は片側で 1/2
        float w = (1.0 - (float(i) - 0.5) / float(ANALOG_BLOOMING_TAPS)) / float(ANALOG_BLOOMING_TAPS);
        overflow += w * (up + down);
    }
    // 色フィルターは列の中で隣どうし違う色なので、あふれた電荷はどの色の画素にも入る (あふれは白い)。露出の前の単位へ戻す
    return hdr + vec3(luminance(overflow)) / exposure;
}
#endif

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
#if AP_SMEAR_SHUTTER_STOPS > 0
    // 露出連動: 比は 1 / 蓄積時間に比例する。明るい場面ほどシャッターが速く、暗い場面 (1/60 秒) より 2^段 倍まで強い
    float bright = saturate((frameData.postParams[0].w - ANALOG_SMEAR_SHUTTER_EV_DARK) / (ANALOG_SMEAR_SHUTTER_EV_DAY - ANALOG_SMEAR_SHUTTER_EV_DARK));
    streak *= exp2(float(AP_SMEAR_SHUTTER_STOPS) * bright);
#endif
    // AP_SMEAR_RATIO は % なので比に直す
    return hdr + streak * (AP_SMEAR_RATIO / 100.0);
}
#endif

#if defined ANALOG && (defined ANALOG_CHROMA || defined ANALOG_RESOLUTION || defined ANALOG_SHARPEN || defined ANALOG_INTERLACE || defined ANALOG_NOISE || defined ANALOG_BLOCK || defined ANALOG_MOSQUITO || defined ANALOG_DROPOUT)
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
#endif

#if (defined ANALOG_INTERLACE && ANALOG_INTERLACE_MODE == 0) || defined ANALOG_BLOCK || defined ANALOG_DROPOUT
// 視点の動き (速度) を読む効果: 織り込みのインターレース、ブロックの動き、ドロップアウト
#define ANALOG_NEEDS_MOTION 1
// 1 フィールド分の視点の動き (強さを掛ける前)。applyAnalogRecord が中心の画素で 1 回だけ求める
vec2 analogMotion = vec2(0.0);

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

#if defined ANALOG_NOISE && (defined ANALOG_SHOT_NOISE || defined ANALOG_DARK_NOISE || defined ANALOG_FPN || defined ANALOG_HOT_PIXELS)
// センサーのノイズがある時だけ、タップごとに線形へ戻して揺らす (無ければ往復の計算を入れない)
#define ANALOG_SENSOR_NOISE 1
#endif

#if defined ANALOG_NOISE || defined ANALOG_MOSQUITO || defined ANALOG_DROPOUT
// フィールドの番号と乱数を使う効果
#define ANALOG_NEEDS_RANDOM 1
// フィールドの番号 (1 から数える。古いフィールドの 1 つ前が 0 になる)。applyAnalogRecord が画素ごとに 1 回だけ求める
uint analogField = 1u;

// 種類ごとの一様乱数 (各成分 -0.5〜0.5)。種類 (salt) が違えば q・t が何でも hash3 の入力が重ならず、互いに独立になる
// 時間で変わる種類は t = フィールドの番号 (1 以上)、画面に固定の種類は t = 0
vec3 analogRandom(vec2 q, uint t, uint salt) {
    return hash3(uvec3(uvec2(ivec2(floor(q))), t * ANALOG_SEED_COUNT + salt)) - 0.5;
}

// このタップの走査線のフィールドの番号 (織り込みでは古いフィールドの線は 1 つ前)
uint analogFieldOf(vec2 uv) {
#if defined ANALOG_INTERLACE && ANALOG_INTERLACE_MODE == 0
    int parity = int(floor((1.0 - uv.y) * float(AF_LINES))) & 1;
    return parity == AF_OLDER_FIELD ? analogField - 1u : analogField;
#else
    return analogField;
#endif
}
#endif

#ifdef ANALOG_NOISE
// 自動ゲイン (暗い場面で上がる)。applyAnalogRecord が画素ごとに 1 回だけ求める
float analogGain = 1.0;

/*
 * センサーのノイズ: 表示値を線形へ戻し、仮想の画素ごとの乱数で揺らして戻す
 * ショットは光の粒の数の揺らぎで σ ∝ sqrt(ゲイン x 明るさ)、暗部は読み出しと暗電流の揺らぎで σ ∝ ゲイン (明るさによらない)。
 * FPN (画素と列のむら) とホットピクセル (常に電荷の多い欠陥) は素子の画素に付いているので画面に固定 (t = 0) で、ゲインで増える。
 * Rec.709 の傾きは暗部ほど大きいので、同じ揺らぎでも暗部ほど目立つ
 */
#ifdef ANALOG_SENSOR_NOISE
vec3 applyAnalogSensorNoise(vec3 v, vec2 uv) {
    vec2 q = uv * vec2(AF_SAMPLES, AF_LINES);
    uint f = analogFieldOf(uv);
    vec3 l = analogOetf709Inverse(saturate(v));
    vec3 dl = vec3(0.0);
#ifdef ANALOG_SHOT_NOISE
    if (AP_SHOT_NOISE_STRENGTH > 0.0) {
        vec3 r = mix(vec3(analogRandom(q, f, ANALOG_SEED_SHOT_Y).x), analogRandom(q, f, ANALOG_SEED_SHOT_RGB), AP_SHOT_NOISE_CHROMA);
        dl += AP_SHOT_NOISE_STRENGTH * ANALOG_SHOT_NOISE_SCALE * sqrt(analogGain * l) * r;
    }
#endif
#ifdef ANALOG_DARK_NOISE
    if (AP_DARK_NOISE_STRENGTH > 0.0) {
        dl += AP_DARK_NOISE_STRENGTH * ANALOG_DARK_NOISE_SCALE * analogGain * analogRandom(q / AP_DARK_NOISE_SIZE, f, ANALOG_SEED_DARK).x;
    }
#endif
#ifdef ANALOG_FPN
    if (AP_FPN_STRENGTH > 0.0) {
        // 列の乱数は縦の位置を 0 に固定する (垂直転送のむら = 縦縞)
        float pixel = analogRandom(q, 0u, ANALOG_SEED_FPN_PIXEL).x;
        float column = analogRandom(vec2(q.x, 0.0), 0u, ANALOG_SEED_FPN_COLUMN).x;
        dl += AP_FPN_STRENGTH * ANALOG_FPN_SCALE * analogGain * mix(pixel, column, AP_FPN_COLUMN);
    }
#endif
#ifdef ANALOG_HOT_PIXELS
    if (AP_HOT_PIXELS_DENSITY > 0.0) {
        bool hot = analogRandom(q, 0u, ANALOG_SEED_HOT).x + 0.5 < AP_HOT_PIXELS_DENSITY;
        dl += hot ? AP_HOT_PIXELS_BRIGHTNESS * ANALOG_HOT_PIXELS_SCALE * analogGain : 0.0;
    }
#endif
    return analogOetf709(max(l + ANALOG_NOISE_STRENGTH * dl, 0.0));
}
#endif

#ifdef ANALOG_CHROMA_NOISE
// 色ノイズ: 色差の標本 (k = 色差の格子の位置) ごとの斑点。暗部 (1 - Y') ^ 偏り で強い。実機では間引きの前に乗るので標本ごとに足す
vec2 analogChromaNoise(vec2 k, float luma, uint f) {
    if (AP_CHROMA_NOISE_STRENGTH <= 0.0) return vec2(0.0);
    float shadow = pow(saturate(1.0 - luma), AP_CHROMA_NOISE_SHADOW);
    return ANALOG_NOISE_STRENGTH * AP_CHROMA_NOISE_STRENGTH * ANALOG_CHROMA_NOISE_SCALE * analogGain * shadow
         * analogRandom(k / AP_CHROMA_NOISE_SIZE, f, ANALOG_SEED_CHROMA).xy;
}
#endif
#endif

#ifdef ANALOG_DROPOUT
/*
 * テープのドロップアウト: ANALOG_DROPOUT_FIELDS フィールドごとの窓で、起きたかを画面で 1 つ引き、起きた窓では
 * 8x8 の仮想のブロックを AP_DROPOUT_AMOUNT の割合で散らして隠す (DV は誤り隠蔽で前のフレームの同じ画素に差し替える)
 * 前フレームは持たず、速度で 1 フレーム (2 フィールド) 前の位置を読む。視点が止まっていれば今の像と同じになる
 */
bool analogDropoutHit = false;
uint analogDropoutWindow = 0u;

bool analogDropoutHidden(vec2 uv) {
    if (!analogDropoutHit) return false;
    vec2 block = floor(uv * vec2(AF_SAMPLES, AF_LINES) / ANALOG_BLOCK_SIZE);
    return analogRandom(block, analogDropoutWindow, ANALOG_SEED_DROPOUT_BLOCK).x + 0.5 < AP_DROPOUT_AMOUNT;
}
#endif

/*
 * 表示値 (composite27 の出力) を記録の段の位置 uv で読む。インターレースは読む位置の走査線ごとに選ぶ:
 * 織り込みは古いフィールドの走査線を 1 フィールド前の位置で読み (動いた所の櫛)、フィールド表示は今のフィールドでない走査線を上下の線から補う
 * ドロップアウトで隠したブロックは 1 フレーム前の位置で読む
 * センサーのノイズはタップの位置の仮想の画素で引く (解像と輪郭強調のタップごとに同じ式で掛かり、ぼけと強調を受ける)
 */
vec3 analogFetch(vec2 uv, float lod) {
    vec2 at = uv;
    vec3 c;
#ifdef ANALOG_DROPOUT
    if (AP_DROPOUT_RATE > 0.0 && analogDropoutHidden(at)) {
        c = textureLod(colortex0, uv - 2.0 * analogMotion, lod).rgb;
    } else
#endif
    {
#ifdef ANALOG_INTERLACE
        int parity = int(floor((1.0 - uv.y) * float(AF_LINES))) & 1;
    #if ANALOG_INTERLACE_MODE == 0
        if (parity == AF_OLDER_FIELD) uv -= analogFieldShift;
        c = textureLod(colortex0, uv, lod).rgb;
    #else
        if (parity != analogFieldPhase) {
            vec2 line = vec2(0.0, 1.0 / float(AF_LINES));
            c = 0.5 * (textureLod(colortex0, uv + line, lod).rgb + textureLod(colortex0, uv - line, lod).rgb);
        } else {
            c = textureLod(colortex0, uv, lod).rgb;
        }
    #endif
#else
        c = textureLod(colortex0, uv, lod).rgb;
#endif
    }
#ifdef ANALOG_SENSOR_NOISE
    if (ANALOG_NOISE_STRENGTH > 0.0) c = applyAnalogSensorNoise(c, at);
#endif
    return c;
}

#if defined ANALOG_BLOCK || defined ANALOG_MOSQUITO
/*
 * DV のブロック (8x8 の DCT の量子化) とモスキートノイズの近似。輝度だけ
 * ブロックの 4 つの 4x4 の区画の平均をミップで読み、DC と 1 次の 2 係数の平面 y_q で近似する。
 * 平面から外れた細部 r は、デッドゾーンより小さい分を捨てる (小さな係数を 0 に丸める量子化。ノイズも減る)。動いた所はデッドゾーンが広い。
 * 区画の段差が大きい (縁がある) ブロックには、量子化の誤差が縁の周りに散ったちらつく斑点を足す。格子は画面に固定
 */
float applyAnalogBlock(float luma, vec2 uv) {
    vec2 p = uv * vec2(AF_SAMPLES, AF_LINES);
    vec2 corner = floor(p / ANALOG_BLOCK_SIZE) * ANALOG_BLOCK_SIZE;
    vec2 grid = 1.0 / vec2(AF_SAMPLES, AF_LINES);
    // 区画 (半分の大きさ) の箱に合うミップの段
    float lod = log2(max(0.5 * ANALOG_BLOCK_SIZE * viewWidth / float(AF_SAMPLES), 1.0));
    float q = 0.25 * ANALOG_BLOCK_SIZE;
    float m00 = dot(textureLod(colortex0, (corner + vec2(q, q)) * grid, lod).rgb, ANALOG_LUMA_WEIGHTS);
    float m10 = dot(textureLod(colortex0, (corner + vec2(3.0 * q, q)) * grid, lod).rgb, ANALOG_LUMA_WEIGHTS);
    float m01 = dot(textureLod(colortex0, (corner + vec2(q, 3.0 * q)) * grid, lod).rgb, ANALOG_LUMA_WEIGHTS);
    float m11 = dot(textureLod(colortex0, (corner + vec2(3.0 * q, 3.0 * q)) * grid, lod).rgb, ANALOG_LUMA_WEIGHTS);
    float dc = 0.25 * (m00 + m10 + m01 + m11);
#ifdef ANALOG_BLOCK
    if (AP_BLOCK_STRENGTH > 0.0) {
        // 区画の中心の間隔は 2q (仮想の画素) なので、差を 2 区画分で割って 1 画素あたりの傾きにする
        float gx = ((m10 + m11) - (m00 + m01)) / (2.0 * 2.0 * q);
        float gy = ((m01 + m11) - (m00 + m10)) / (2.0 * 2.0 * q);
        vec2 o = p - (corner + 0.5 * ANALOG_BLOCK_SIZE);
        float plane = dc + gx * o.x + gy * o.y;
        float r = luma - plane;
        // 1 フィールドでブロック 1 つ分動けば 1
        float moving = clamp(length(analogMotion * vec2(AF_SAMPLES, AF_LINES)) / ANALOG_BLOCK_SIZE, 0.0, 1.0);
        float deadzone = AP_BLOCK_STRENGTH * ANALOG_BLOCK_DEADZONE * (1.0 + AP_BLOCK_MOTION * moving);
        luma = plane + sign(r) * max(abs(r) - deadzone, 0.0);
    }
#endif
#ifdef ANALOG_MOSQUITO
    if (AP_MOSQUITO_STRENGTH > 0.0) {
        float edge = max(max(abs(m00 - dc), abs(m10 - dc)), max(abs(m01 - dc), abs(m11 - dc)));
        luma += AP_MOSQUITO_STRENGTH * ANALOG_MOSQUITO_GAIN * max(edge - AP_MOSQUITO_EDGE, 0.0)
              * analogRandom(p, analogFieldOf(uv), ANALOG_SEED_MOSQUITO).x;
    }
#endif
    return luma;
}
#endif

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
    vec3 ycc = analogRgbToYcc(sum / float(ANALOG_CHROMA_TAPS));
#if defined ANALOG_NOISE && defined ANALOG_CHROMA_NOISE
    if (ANALOG_NOISE_STRENGTH > 0.0) ycc.yz += analogChromaNoise(floor(center / vec2(AF_CHROMA_X, AF_CHROMA_Y)), ycc.x, analogFieldOf(center / grid));
#endif
    return ycc.yz;
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
#ifdef ANALOG_NEEDS_MOTION
    analogMotion = analogFieldMotion(uv);
#endif
#ifdef ANALOG_INTERLACE
    #if ANALOG_INTERLACE_MODE == 0
    analogFieldShift = AP_INTERLACE_STRENGTH * analogMotion;
    #else
    analogFieldPhase = int(floor(frameTimeCounter * AF_FIELD_RATE)) & 1;
    #endif
#endif
#ifdef ANALOG_NEEDS_RANDOM
    // 乱数はフィールドの速さで切り替える (高いフレームレートでも 1 秒にフィールドの数だけ変わる)
    analogField = uint(floor(frameTimeCounter * AF_FIELD_RATE)) + 1u;
#endif
#ifdef ANALOG_NOISE
    // 自動ゲイン: 適用 EV が AP_AGC_EV より暗い分だけ、AP_AGC_MAX 段まで上げる
    if (ANALOG_NOISE_STRENGTH > 0.0) analogGain = exp2(clamp(AP_AGC_EV - frameData.postParams[0].w, 0.0, float(AP_AGC_MAX)));
#endif
#ifdef ANALOG_DROPOUT
    if (AP_DROPOUT_RATE > 0.0) {
        // 1 分あたりの回数 -> 窓ごとの確率 (1 分の窓の数は 60 x フィールドの速さ / 窓のフィールドの数)
        analogDropoutWindow = analogField / ANALOG_DROPOUT_FIELDS;
        float chance = min(AP_DROPOUT_RATE * float(ANALOG_DROPOUT_FIELDS) / (60.0 * AF_FIELD_RATE), 1.0);
        analogDropoutHit = analogRandom(vec2(0.0), analogDropoutWindow, ANALOG_SEED_DROPOUT_EVENT).x + 0.5 < chance;
    }
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
#if defined ANALOG_BLOCK || defined ANALOG_MOSQUITO
    luma = applyAnalogBlock(luma, uv);
#endif
    ycc.x = luma;
#ifdef ANALOG_CHROMA
    ycc.yz = mix(ycc.yz, analogSubsampledChroma(uv), AP_CHROMA_STRENGTH);
#elif defined ANALOG_NOISE && defined ANALOG_CHROMA_NOISE
    // 色差を間引かない時は、仮想の画素ごとに色ノイズを足す
    if (ANALOG_NOISE_STRENGTH > 0.0) ycc.yz += analogChromaNoise(floor(uv * vec2(AF_SAMPLES, AF_LINES)), ycc.x, analogFieldOf(uv));
#endif
    return analogYccToRgb(ycc);
}
#endif

#endif
