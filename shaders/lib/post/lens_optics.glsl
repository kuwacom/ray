/*
 * レンズの光学: 画角の座標・波長・周辺減光・歪曲と魚眼の再投影・倍率色収差・口径食・グレイン
 * lib/post/lens.glsl が読む
 */
#ifndef POST_LENS_OPTICS_GLSL
#define POST_LENS_OPTICS_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/camera.glsl"
#include "/lib/post/lens_presets.glsl"
#include "/lib/post/post_constants.glsl"
#include "/lib/post/sampling.glsl"
#include "/lib/post/velocity.glsl"

#if LENS_QUALITY == 0
const int LENS_GHOST_LIMIT = 8;
const int LENS_SPECTRAL_SAMPLES = 3;
const int LENS_SCREEN_GHOST_LIMIT = 6;
#elif LENS_QUALITY == 1
const int LENS_GHOST_LIMIT = 12;
const int LENS_SPECTRAL_SAMPLES = 4;
const int LENS_SCREEN_GHOST_LIMIT = 8;
#elif LENS_QUALITY == 2
const int LENS_GHOST_LIMIT = 16;
const int LENS_SPECTRAL_SAMPLES = 5;
const int LENS_SCREEN_GHOST_LIMIT = 12;
#else
const int LENS_GHOST_LIMIT = 24;
const int LENS_SPECTRAL_SAMPLES = 7;
const int LENS_SCREEN_GHOST_LIMIT = 16;
#endif

// 画面中心からの距離の 2 乗 (縦横比を補正し、画面の隅で 1)
float lensRadius2(vec2 uv) {
    vec2 a = uv * 2.0 - 1.0;
    a.x *= aspectRatio;
    return dot(a, a) / (aspectRatio * aspectRatio + 1.0);
}

vec2 lensTanHalf() { return vec2(aspectRatio, 1.0) / gbufferProjection[1][1]; }
vec2 uvToTan(vec2 uv) { return (uv * 2.0 - 1.0) * lensTanHalf(); }
vec2 tanToUv(vec2 t) { return t / lensTanHalf() * 0.5 + 0.5; }

/*
 * 分光
 * 波長 (nm) -> 線形 sRGB の重み。CIE 1931 等色関数の多峰ガウス近似 (Wyman, Sloan, Shirley 2013) を
 * XYZ -> sRGB 変換して負を切り捨てる。サンプルの組ごとに重みの和で割って白を保つ
 */
float cieLobe(float l, float mu, float s1, float s2) {
    float t = (l - mu) / (l < mu ? s1 : s2);
    return exp(-0.5 * t * t);
}

vec3 wavelengthToRgb(float l) {
    vec3 xyz = vec3(
        1.056 * cieLobe(l, 599.8, 37.9, 31.0) + 0.362 * cieLobe(l, 442.0, 16.0, 26.7) - 0.065 * cieLobe(l, 501.1, 20.4, 26.2),
        0.821 * cieLobe(l, 568.8, 46.9, 40.5) + 0.286 * cieLobe(l, 530.9, 16.3, 31.1),
        1.217 * cieLobe(l, 437.0, 11.8, 36.0) + 0.681 * cieLobe(l, 459.0, 26.0, 13.8));
    return max(vec3(
        dot(vec3(3.2406, -1.5372, -0.4986), xyz),
        dot(vec3(-0.9689, 1.8758, 0.0415), xyz),
        dot(vec3(0.0557, -0.2040, 1.0570), xyz)), 0.0);
}

// n 個の波長サンプルの k 番目 (可視域を等間隔に)
float lensWavelength(int k, int n) {
    return mix(410.0, 690.0, (float(k) + 0.5) / float(n));
}

// 周辺減光
// 演出のビネット (cos^4 則に近い 1 / (1 + k r^2)^2 の形)。シーン線形に掛ける
float vignette(vec2 uv) {
    float k = VIGNETTE * VIGNETTE_SCALE;
    float rf = 1.0 + lensRadius2(uv) * k;
    return 1.0 / (rf * rf);
}

// 半径 r0 の円のうち、距離 d 離れた半径 r1 の円と重なる面積の割合
float circleOverlap(float r0, float r1, float d) {
    if (d >= r0 + r1) return 0.0;
    if (d <= abs(r1 - r0)) return sqr(min(r0, r1) / r0);
    float a0 = r0 * r0 * acos(clamp((d * d + r0 * r0 - r1 * r1) / (2.0 * d * r0), -1.0, 1.0));
    float a1 = r1 * r1 * acos(clamp((d * d + r1 * r1 - r0 * r0) / (2.0 * d * r1), -1.0, 1.0));
    float k = 0.5 * sqrt(max((-d + r0 + r1) * (d + r0 - r1) * (d - r0 + r1) * (d + r0 + r1), 0.0));
    return (a0 + a1 - k) / (PI * r0 * r0);
}

/*
 * 口径食: 画面の端では、絞りの像 (入射瞳) と前玉の縁の像がずれて重なった部分しか光が通らない
 * 戻り値 x = 入射瞳の半径 (前玉の縁 = 1), y = 縁のずれ (同じ単位)。開放ほど瞳が縁いっぱいになり強く効く
 * 同じ形を被写界深度のボケ (猫目) と周辺減光の両方に使う
 */
vec2 lensCatsEyeRho(float rho) {
    float pupil = clamp(LP_F_OPEN / lensFNumber(), 0.05, 1.0);
    return vec2(pupil, LP_CATS_EYE * LENS_CATS_EYE_SCALE * rho);
}

vec2 lensCatsEye(vec2 uv) {
    return lensCatsEyeRho(sqrt(lensRadius2(uv)));
}

float lensOpticalVignette(vec2 uv) {
    vec2 ce = lensCatsEye(uv);
    return circleOverlap(ce.x, 1.0, ce.y);
}

/*
 * 写像 (歪曲収差・魚眼)
 * TAA・DoF・ブルームは直線写像 (ゲームの描画) のまま行い、final の最初で出力の画素 -> 元画像の位置へ再投影する
 * 画面の位置 p: 中心 0、縦の半分 = 1、横は縦横比倍
 */
vec2 lensScreenPos(vec2 uv) { return (uv * 2.0 - 1.0) * vec2(aspectRatio, 1.0); }
vec2 lensScreenUv(vec2 p) { return p / vec2(aspectRatio, 1.0) * 0.5 + 0.5; }

// 歪曲の係数。処方どおりの歪曲 (Flektogon の陣笠で 2% 程度) は控えめなので、設定で強められる
const float LENS_K1 = LP_K1 * LENS_DISTORTION_SCALE;
const float LENS_K2 = LP_K2 * LENS_DISTORTION_SCALE;
const float LENS_K3 = LP_K3 * LENS_DISTORTION_SCALE;

// 歪曲収差 (Brown-Conrady の放射成分): 出力の半径の 2 乗 r2 (画面の隅で 1) から元画像を読む倍率
float lensDistortionFactor(float r2) {
    return 1.0 + LENS_K1 * r2 + LENS_K2 * r2 * r2 + LENS_K3 * r2 * r2 * r2;
}

/*
 * 画面の隅・上下端・左右端のどれも枠の外を読まないよう、最も外を読む点が枠に一致するよう拡大する
 * 陣笠型 (K1 と K2 の符号が逆) では最も外を読む点が端の途中に来ることがあるので、端に沿って調べる
 */
float lensDistortionNorm() {
    float a2 = aspectRatio * aspectRatio;
    float d2 = a2 + 1.0;
    float norm = max(lensDistortionFactor(1.0), max(lensDistortionFactor(1.0 / d2), lensDistortionFactor(a2 / d2)));
    if (LENS_K2 != 0.0 || LENS_K3 != 0.0) {
        for (int i = 1; i < LENS_DISTORTION_EDGE_STEPS; i++) {
            float t = float(i) / float(LENS_DISTORTION_EDGE_STEPS);
            norm = max(norm, lensDistortionFactor((t * t * a2 + 1.0) / d2));
            norm = max(norm, lensDistortionFactor((a2 + t * t) / d2));
        }
        // 調べた点の間で最大が少し上回る分 (Flektogon で 2e-5) の余裕
        norm *= 1.0 + LENS_DISTORTION_NORM_MARGIN;
    }
    return norm;
}

// 出力の画素 uv が写す元画像の位置。LP_K1 > 0 で樽型 (端ほど広い範囲を詰め込む), < 0 で糸巻き型
vec2 lensDistortUv(vec2 uv) {
    return (uv - 0.5) * (lensDistortionFactor(lensRadius2(uv)) / lensDistortionNorm()) + 0.5;
}

#if LENS_PROJECTION == 1
/*
 * 魚眼の像高 r = F h(θ)。k > 0: sin(kθ)/k (0.5 = 等立体角, 1 = 正射影), k = 0: θ (等距離),
 * k < 0: tan(|k|θ)/|k| (-0.5 = 立体射影)
 */
float fisheyeHeight(float theta) {
    float k = LP_FISHEYE_K;
    if (abs(k) < 1e-3) return theta;
    return k > 0.0 ? sin(k * theta) / k : tan(-k * theta) / -k;
}

// 像高 h (= r / F) の画角。写像の範囲外 (sin が 1 を超える) は 90 度以上を返す
float fisheyeAngle(float h) {
    float k = LP_FISHEYE_K;
    if (abs(k) < 1e-3) return h;
    if (k > 0.0) return k * h >= 1.0 ? PI : asin(k * h) / k;
    return atan(-k * h) / -k;
}

/*
 * 出力の焦点距離 (画面の縦の半分 = 1)。描画の範囲 (直線写像の FOV) から決める
 * LENS_FISHEYE_FIT 0: 出力の隅が元画像の隅に当たる (隅まで埋まる)
 *                  1: 出力の左右端が元画像の左右端に当たる (実物の画角に近い。隅は描画の範囲外なので黒)
 */
float fisheyeFocal() {
#if LENS_FISHEYE_FIT == 1
    float r = aspectRatio;
#else
    float r = sqrt(aspectRatio * aspectRatio + 1.0);
#endif
    return r / fisheyeHeight(atan(r * lensTanHalf().y));
}
#endif

/*
 * 出力の画素 uv が写す元画像の位置 (再投影)。rhoLens は周辺光量などの表を引く正規化半径
 * (直線写像は画面の隅で 1、魚眼は表の画角 LENS_FISHEYE_TABLE_ANGLE で 1)
 * 元画像に無い方向 (魚眼の「横幅に合わせる」の隅) は [0, 1] の外を返す
 */
vec2 lensProjectUv(vec2 uv, out float rhoLens) {
#if LENS_PROJECTION == 1
    vec2 p = lensScreenPos(uv);
    float r = length(p);
    float focal = fisheyeFocal();
    float theta = fisheyeAngle(r / focal);
    rhoLens = fisheyeHeight(theta) / fisheyeHeight(LENS_FISHEYE_TABLE_ANGLE);
    if (theta >= 0.5 * PI - 1e-3) return vec2(-1.0);
    // 中心付近では tan(θ) / r -> 1 / F
    float scale = r > 1e-5 ? tan(theta) / r : 1.0 / focal;
    return lensScreenUv(p * (scale / lensTanHalf().y));
#else
    rhoLens = sqrt(lensRadius2(uv));
    return lensDistortUv(uv);
#endif
}

// 元画像の位置 -> 出力の位置 (lensProjectUv の逆)。太陽・月のフレアの光源の位置に使う
vec2 lensForwardUv(vec2 uvSrc) {
#if LENS_PROJECTION == 1
    vec2 t = lensScreenPos(uvSrc) * lensTanHalf().y;
    float tl = length(t);
    if (tl < 1e-6) return uvSrc;
    float r = fisheyeFocal() * fisheyeHeight(atan(tl));
    return lensScreenUv(t * (r / tl));
#else
    // 放射方向の 1 変数の方程式 u f(u^2) / norm = s を Newton 法で解く (u, s は画面の隅で 1 の半径)
    vec2 p = lensScreenPos(uvSrc);
    float s = length(p) / sqrt(aspectRatio * aspectRatio + 1.0);
    if (s < 1e-6) return uvSrc;
    float norm = lensDistortionNorm();
    float u = s;
    for (int i = 0; i < 4; i++) {
        float u2 = u * u;
        float f = lensDistortionFactor(u2);
        float df = LENS_K1 + 2.0 * LENS_K2 * u2 + 3.0 * LENS_K3 * u2 * u2;
        u -= (u * f / norm - s) / max((f + 2.0 * u2 * df) / norm, 1e-3);
    }
    return lensScreenUv(p * (u / s));
#endif
}

// 元画像の位置の、表を引く正規化半径 (lensProjectUv の rhoLens と同じ尺度)。DoF は元画像の空間で行うので使う
float lensFieldRho(vec2 uvSrc) {
#if LENS_PROJECTION == 1 && defined LENS_DISTORTION
    float theta = atan(length(lensScreenPos(uvSrc)) * lensTanHalf().y);
    return fisheyeHeight(theta) / fisheyeHeight(LENS_FISHEYE_TABLE_ANGLE);
#else
    return sqrt(lensRadius2(uvSrc));
#endif
}

/*
 * 歪曲・魚眼を TAA の中で組み立てるか (LENS_WARP_IN_TAA)
 * true なら composite20 (TAA) が出力 (再投影後) の画面を作り、以降の colortex0 は出力の座標になる
 * (final での再投影はしない)。深度・G バッファ・速度は元画像のままなので、後段は postSourceUv で読む位置を写す
 * 自動: 魚眼か、歪曲で画面の倍率が LENS_WARP_AUTO_AMOUNT より大きく変わる時
 */
#define LENS_FACTOR_AT(r2) (1.0 + LENS_K1 * (r2) + LENS_K2 * (r2) * (r2) + LENS_K3 * (r2) * (r2) * (r2))
const float LENS_DISTORTION_AMOUNT = max(max(abs(LENS_FACTOR_AT(0.25) - 1.0), abs(LENS_FACTOR_AT(0.5) - 1.0)),
                                         max(abs(LENS_FACTOR_AT(0.75) - 1.0), abs(LENS_FACTOR_AT(1.0) - 1.0)));
#if defined TAA && defined LENS_DISTORTION && LENS_WARP_IN_TAA == 2
const bool LENS_WARP_TAA = LENS_PROJECTION == 1 || LENS_DISTORTION_AMOUNT > 0.0;
#elif defined TAA && defined LENS_DISTORTION && LENS_WARP_IN_TAA == 0
const bool LENS_WARP_TAA = LENS_PROJECTION == 1 || LENS_DISTORTION_AMOUNT > LENS_WARP_AUTO_AMOUNT;
#else
const bool LENS_WARP_TAA = false;
#endif

// TAA 以降の画面 (colortex0) の位置 uv に写っている元画像の位置 (深度・G バッファ・速度を読む位置。ジッターは含まない)
vec2 postSourceUv(vec2 uv) {
    if (!LENS_WARP_TAA) return uv;
    float rho;
    return clamp(lensProjectUv(uv, rho), 0.5 / viewSize(), 1.0 - 0.5 / viewSize());
}

ivec2 postSourceTexel(vec2 uv) { return ivec2(postSourceUv(uv) * viewSize()); }

// TAA 以降の画面の位置 uv (深度 depth) の、前フレームでの同じ座標系の位置
vec2 postPreviousUv(vec2 uv, float depth) {
    if (!LENS_WARP_TAA) return getPreviousUv(uv, depth);
    vec2 jitter = taaJitterUv();
    vec2 src = postSourceUv(uv);
    // getPreviousUv はジッター込みのバッファの位置を受け取り、同じだけずれた位置を返す
    return lensForwardUv(getPreviousUv(src + jitter, depth) - jitter);
}

/*
 * TAA 以降の画面での、元画像からの拡大率 (出力の画素 / 元の画素)。x = 放射方向、y = 接線方向
 * DoF のボケの大きさ (元画像の画素で計算) を出力の画素に直すのに使う。魚眼の中央で 2 倍以上、周辺で 1 未満
 */
vec2 postMagnification(vec2 uv) {
    if (!LENS_WARP_TAA) return vec2(1.0);
    vec2 p = uv - 0.5;
    vec2 radial = length(p * vec2(aspectRatio, 1.0)) > 1e-4 ? normalize(p * vec2(aspectRatio, 1.0)) : vec2(1.0, 0.0);
    vec2 tangent = vec2(-radial.y, radial.x);
    // 出力で 1 画素動いた時の元画像での移動 (画素)
    vec2 stepUv = 1.0 / viewSize();
    vec2 src = postSourceUv(uv) * viewSize();
    float dr = length(postSourceUv(uv + radial * stepUv) * viewSize() - src);
    float dt = length(postSourceUv(uv + tangent * stepUv) * viewSize() - src);
    return 1.0 / max(vec2(dr, dt), vec2(1e-3));
}

// 9 点の表 (rho = 0, 1/8, ..., 1) を Catmull-Rom で補間する (折れ線だと周辺減光の傾きの継ぎ目が空に輪になって見える)
float lensTable9(float t[9], float rho) {
    float x = clamp(rho, 0.0, 1.0) * 8.0;
    int i = min(int(x), 7);
    float f = x - float(i);
    float p0 = t[max(i - 1, 0)];
    float p1 = t[i];
    float p2 = t[i + 1];
    float p3 = t[min(i + 2, 8)];
    return p1 + 0.5 * f * (p2 - p0 + f * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + f * (3.0 * (p1 - p2) + p3 - p0)));
}

#ifdef LENS_RI_TABLE
// 処方の周辺光量。開放から 2 段絞るまでは F 値の段数で補間する (さらに絞っても口径食の抜けた 2 段の値のまま)
float lensRelativeIllumination(float rho) {
    float stops = saturate(log2(lensFNumber() / LP_F_OPEN) * 0.5);
    return max(mix(lensTable9(LP_RI_OPEN, rho), lensTable9(LP_RI_STOP, rho), stops), 0.0);
}
#endif

#ifdef LENS_SOFT_HALO_TABLE
// 開放から 0 / 1 / 2 / 3 段の 4 点の表を、段数 stops で折れ線補間する
float lensHaloTable(vec4 t, float stops) {
    float x = clamp(stops, 0.0, 3.0);
    int i = min(int(x), 2);
    return mix(t[i], t[i + 1], x - float(i));
}

/*
 * 処方の球面収差のハロー (ソフトフォーカス): ピントの合った点にも、芯の周りに大きなにじみが付く
 * rgb = ハローの半径に合うブルームのタイル (正規化した PSF), a = ハローに行く光の割合。どちらも今の F 値で表を引く
 */
vec4 lensSoftHalo(vec2 uv) {
    float stops = 2.0 * log2(lensFNumber() / LP_F_OPEN);
    float share = lensHaloTable(LP_HALO_SHARE, stops);
    float radiusPx = lensHaloTable(LP_HALO_RADIUS, stops) * viewHeight;
    // タイルのレベル L はおよそ σ = 2^L 画素のぼけ。表の半径は 95% のエネルギーの半径なので、ガウスの 2.45σ とみなす
    float level = clamp(log2(max(radiusPx / 2.45, 1.0)), 1.0, float(BLOOM_LEVELS));
    int l0 = int(floor(level));
    int l1 = min(l0 + 1, BLOOM_LEVELS);
    vec3 c = mix(sampleBloomTile(l0, uv), sampleBloomTile(l1, uv), level - float(l0));
    return vec4(c, share);
}
#endif

#ifdef LENS_FIELD_TABLE
/*
 * 処方の像面湾曲・非点収差によるボケ半径 (px, 符号は circleOfConfusion と同じで正 = 後ボケ側)
 * x: 子午像面 (ボケが放射方向に広がる), y: 球欠像面 (接線方向に広がる)
 * 像面がレンズ側 (Δz < 0) にあると、ピントの合った物の像もセンサーの手前で結ぶので後ボケと同じ向きにぼける
 * センサー上の直径 Δz / N を、画面の隅 = 135 判の隅の尺度で画素にする
 */
vec2 lensFieldDefocus(float rho) {
    float frameHeightMm = 2.0 * LENS_FRAME_HALF_DIAGONAL_MM / sqrt(aspectRatio * aspectRatio + 1.0);
    vec2 dz = vec2(lensTable9(LP_FIELD_ZT, rho), lensTable9(LP_FIELD_ZS, rho));
    vec2 px = -dz / lensFNumber() * (0.5 / frameHeightMm * viewHeight);
    float limit = LENS_FIELD_DEFOCUS_MAX * viewHeight;
    return clamp(px, -limit, limit);
}
#endif

/*
 * 倍率色収差
 * 波長ごとに像の倍率が違う (画面の端ほど虹色にずれる)。波長を LENS_SPECTRAL_SAMPLES 個サンプルし、
 * 各サンプルの色をその波長の RGB 重みで積分する。平坦な面の色は変わらず、縁だけが紫 / 緑に色付く
 */
vec3 lensChromaticSample(sampler2D tex, vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    float r2 = lensRadius2(uv);
    vec3 sum = vec3(0.0);
    vec3 wSum = vec3(0.0);
    for (int k = 0; k < LENS_SPECTRAL_SAMPLES; k++) {
        float l = lensWavelength(k, LENS_SPECTRAL_SAMPLES);
        vec3 w = wavelengthToRgb(l);
        float scale = 1.0 + amount * LENS_CA_SCALE * ((l - 550.0) / 140.0) * r2;
        sum += sanitizeColor(textureLod(tex, 0.5 + d * scale, 0.0).rgb) * w;
        wSum += w;
    }
    return sum / max(wSum, 1e-6);
}

#if LENS_PROJECTION == 1
/*
 * 魚眼の倍率色収差: 波長ごとの倍率は出力 (像面) の上で掛け、それぞれを元画像へ写して読む
 * 中心は 2 倍以上に引き伸ばすので、双線形ではなく Catmull-Rom で読む
 */
vec3 lensChromaticProjected(sampler2D tex, vec2 uv, float amount) {
    vec2 d = uv - 0.5;
    float r2 = lensRadius2(uv);
    vec3 sum = vec3(0.0);
    vec3 wSum = vec3(0.0);
    for (int k = 0; k < LENS_SPECTRAL_SAMPLES; k++) {
        float l = lensWavelength(k, LENS_SPECTRAL_SAMPLES);
        vec3 w = wavelengthToRgb(l);
        float scale = 1.0 + amount * LENS_CA_SCALE * ((l - 550.0) / 140.0) * r2;
        float rho;
        vec2 src = clamp(lensProjectUv(0.5 + d * scale, rho), vec2(0.0), vec2(1.0));
        sum += sanitizeColor(sampleCatmullRom(tex, src, viewSize())) * w;
        wSum += w;
    }
    return sum / max(wSum, 1e-6);
}
#endif

/*
 * フィルムグレイン: 中間調で最も目立ち、黒と白飛びでは消える (sRGB で足す)
 * 単色にして色ノイズに見えないようにする
 */
vec3 applyGrain(vec3 srgb, vec2 pixel) {
    float n = hash1(uint(pixel.x) + uint(pixel.y) * 7919u + uint(frameCounter) * 104729u) - 0.5;
    float l = luminance(srgb);
    float amp = FILM_GRAIN * 4.0 * l * (1.0 - l);
    return srgb + n * amp;
}

#endif
