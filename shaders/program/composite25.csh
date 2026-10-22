/*
 * composite25 (compute): 自動露出 (ヒストグラム -> FrameData.exposure) とオートフォーカス (FrameData.focusDistance)
 * - 測光: 画面を 64x64 の格子で中央重点サンプル (毎フレーム格子内の位置を R2 列でずらし、時間方向に全画素を覆う)
 * - ヒストグラム 256 ビン (log2 輝度) を共有メモリで集計し、上下のパーセンタイルを除いた log 平均を EV100 にする
 * - 順応は EV のまま指数補間。明るい場面へは EXPOSURE_SPEED_BRIGHT、暗い場面へは EXPOSURE_SPEED_DARK
 * - 適用 EV は完全補正にせず (EXPOSURE_CURVE)、EXPOSURE_MIN_EV .. MAX_EV で止める (夜と洞窟は暗いまま残る)
 *   屋外の夜だけは止めた後に暗さに応じて明るく写す (EXPOSURE_NIGHT_*)
 * - フォーカス: 手を含まない深度 (depthtex2) の画面中央 9 点の中央値を log 空間で平滑化
 * DoF (composite22) はこのパスより前に走るので、1 フレーム前のフォーカスを使う
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

layout(local_size_x = 16, local_size_y = 16) in;
const ivec3 workGroups = ivec3(1, 1, 1);

const int METER_GRID = 64;
const int METER_PER_THREAD = METER_GRID / 16;
// フォーカス点の間隔 (画面高さ比)。草 1 本に引っ張られないよう少し広げる
const float FOCUS_TAP_SPACING = 0.012;

shared uint sharedHistogram[256];

#if defined LENS_FLARE && defined HAS_SKY
/*
 * レンズフレアの光源 (昼は太陽, 夜は月) の見え具合 -> FrameData.postParams[2].x (平滑化済み), .y (今フレーム)
 * 256 スレッドがそれぞれ光源の円盤内の 1 点を調べ、見えている割合を集計する (木の葉越しの部分的な遮蔽も割合で効く)
 * - 地形・手: 深度が空 (1.0) でなければ遮蔽
 * - 雲: その点の明るさと空の平均の比 (雲に隠れると円盤が空と同じ明るさに落ちる)
 * - 画面の外: 一番近い画面端の画素で判定し、外へ離れるほど弱める (画面のすぐ外の太陽からもフレアは出る)
 * 1 画素ごとに final で判定していたのをここへ移し、時間方向にも平滑化してちらつきを抑える
 */
const uint VIS_SCALE = 1024u;
shared uint sharedVisible;

uint flareVisibilityTap(uint index) {
    if (shadowLightPosition.z >= 0.0) return 0u;
    vec2 lightUv = viewToScreen(shadowLightPosition).xy;
    float radius = LENS_VIS_DISC_SCALE * LENS_LIGHT_ANGULAR_RADIUS * gbufferProjection[1][1] * 0.5;
    radius = max(radius, 1.5 / viewHeight);
    vec2 p = lightUv + vogelDisk(int(index), 256, 0.0) * radius * vec2(1.0 / aspectRatio, 1.0);
    vec2 clamped = clamp(p, vec2(0.5) / viewSize(), vec2(1.0) - vec2(0.5) / viewSize());
    float outside = length(p - clamped);
    if (outside >= LENS_VIS_OFFSCREEN) return 0u;
    if (texelFetch(depthtex0, ivec2(clamped * viewSize()), 0).r < 1.0) return 0u;
    float vis = 1.0 - smoothstep(0.0, LENS_VIS_OFFSCREEN, outside);
    if (outside <= 0.0) {
        // SH の DC 項 x Y00 = 空の平均放射
        float skyLum = luminance(frameData.skySH[0].rgb) * 0.282095;
        if (skyLum > 1e-6) {
            float l = luminance(sanitizeColor(textureLod(colortex0, clamped, 0.0).rgb));
            vis *= saturate(log2(max(l / skyLum, 1.0) / 4.0) / 10.0);
        }
    }
    return uint(vis * float(VIS_SCALE) + 0.5);
}
#endif

float meteringWeight(vec2 uv) {
    vec2 d = (uv - 0.5) * vec2(aspectRatio, 1.0);
    return mix(METERING_EDGE_WEIGHT, 1.0, exp(-dot(d, d) * 6.0));
}

// ヒストグラムの [low, high] パーセンタイル区間の log2 輝度の平均
float histogramLogAverage(float lowPercent, float highPercent, out bool ok) {
    float total = 0.0;
    for (int i = 0; i < 256; i++) total += float(sharedHistogram[i]);
    ok = total > 0.0;
    if (!ok) return 0.0;

    float lo = total * lowPercent;
    float hi = total * highPercent;
    float cumulative = 0.0;
    float sumLog = 0.0;
    float sumWeight = 0.0;
    for (int i = 0; i < 256; i++) {
        float n = float(sharedHistogram[i]);
        float inside = max(min(cumulative + n, hi) - max(cumulative, lo), 0.0);
        sumLog += inside * histogramBinToLog(float(i));
        sumWeight += inside;
        cumulative += n;
    }
    return sumWeight > 0.0 ? sumLog / sumWeight : histogramBinToLog(0.0);
}

// 計測 EV -> 適用 EV (完全補正にしない。基準から離れるほど明暗を残し、明るい場面はさらに明るく写す)
float exposureCurve(float ev) {
    float boost = EXPOSURE_BRIGHT_BOOST * smoothstep(EXPOSURE_BRIGHT_EV_LOW, EXPOSURE_BRIGHT_EV_HIGH, ev);
    return EXPOSURE_ANCHOR_EV + (ev - EXPOSURE_ANCHOR_EV) * EXPOSURE_CURVE - boost;
}

// 目の位置のブロックライト [0,1]。手持ちの光源は eyeBrightness に入らないので持っている光源の明るさも見る
float eyeBlockLight() {
    float held = float(max(heldBlockLightValue, heldBlockLightValue2)) / 15.0;
    return max(float(eyeBrightnessSmooth.x) / 240.0, held);
}

/*
 * 曲線と下限で止めた EV を目の位置の明るさ (屋外 / 屋内・洞窟) で補正する
 * 屋外の夜は明るく写す (下限 EXPOSURE_MIN_EV は洞窟の暗さのために残す)、灯りの点いた屋内・洞窟は少し暗く写す
 */
float applyEnvironmentExposure(float appliedEv, float ev) {
#ifdef HAS_SKYLIGHT
    // 窓のある部屋 (スカイライト 11 前後) は屋内、木の下・軒下 (14) は屋外として扱う
    // 下端 0.6 では窓のある部屋 (0.73) が 3 割屋外になり、屋内の暗さがほとんど効かなかった
    float outdoor = smoothstep(0.75, 0.93, float(eyeBrightnessSmooth.y) / 240.0);
    float lift = min(EXPOSURE_NIGHT_SLOPE * max(EXPOSURE_NIGHT_EV_START - ev, 0.0), EXPOSURE_NIGHT_MAX_LIFT);
    float night = 1.0 - smoothstep(-0.2, -0.05, getSunDir().y);
    lift = max(lift, EXPOSURE_NIGHT_MIN_LIFT * night);
    float dim = EXPOSURE_INDOOR_DIM * smoothstep(EXPOSURE_INDOOR_EV.x, EXPOSURE_INDOOR_EV.y, ev)
              * (1.0 - smoothstep(EXPOSURE_INDOOR_EV.z, EXPOSURE_INDOOR_EV.w, ev))
              * smoothstep(EXPOSURE_INDOOR_BLOCKLIGHT.x, EXPOSURE_INDOOR_BLOCKLIGHT.y, eyeBlockLight());
    float weather = mix(EXPOSURE_RAIN_DIM * rainStrength, EXPOSURE_THUNDER_DIM, thunderStrength)
                  * smoothstep(EXPOSURE_NIGHT_EV_START - 1.5, EXPOSURE_NIGHT_EV_START + 1.5, ev);
    float underwater = isEyeInWater == 1 ? EXPOSURE_UNDERWATER_DIM : 0.0;
    return appliedEv - lift * outdoor + dim * (1.0 - outdoor) + weather * outdoor + underwater;
#else
    return appliedEv + (isEyeInWater == 1 ? EXPOSURE_UNDERWATER_DIM : 0.0);
#endif
}

/*
 * 水面越しは水面に合わせる。depthtex2 は半透明を含まないので、海を見ると水底 (数十ブロック先) に合い、
 * 手前の水面と映り込みが前ボケになってつやの無いぼやけた面に見えた。ガラス越しは従来どおり奥に合わせる
 */
float focusTapDistance(vec2 uv) {
    ivec2 p = ivec2(uv * viewSize());
    float d = texelFetch(depthtex2, p, 0).r;
    if (isEyeInWater == 0) {
        float d0 = texelFetch(depthtex0, p, 0).r;
        if (d0 < d && !isHandDepth(d0)) {
            vec3 n;
            vec2 lm;
            int mat;
            decodeTranslucentData(texelFetch(colortex5, p, 0), n, lm, mat);
            if (mat == MAT_WATER) d = d0;
        }
    }
    return d >= 1.0 ? far : linearizeDepth(d);
}

float updateFocus(float dt) {
#if DOF_FOCUS_MODE == 1
    frameData.postParams[1].x = DOF_MANUAL_FOCUS;
    return DOF_MANUAL_FOCUS;
#else
    float taps[9];
    for (int i = 0; i < 9; i++) {
        vec2 o = vec2(i % 3 - 1, i / 3 - 1) * FOCUS_TAP_SPACING * vec2(1.0 / aspectRatio, 1.0);
        taps[i] = focusTapDistance(0.5 + o);
    }
    // 挿入ソートで中央値
    for (int i = 1; i < 9; i++) {
        float v = taps[i];
        int j = i - 1;
        while (j >= 0 && taps[j] > v) {
            taps[j + 1] = taps[j];
            j--;
        }
        taps[j + 1] = v;
    }
    float target = taps[4];
    #if DOF_FOCUS_MODE == 2
        // オート + オフセット: マニュアル距離 8 m を基準にした倍率でオートの距離をずらす (8 = オフセットなし)
        target *= DOF_MANUAL_FOCUS / 8.0;
    #endif
    target = clamp(target, 0.1, max(far, 1.0));
    frameData.postParams[1].x = target;

    float prev = frameData.focusDistance;
    if (!(prev > 0.0) || isinf(prev)) prev = target;
    float t = 1.0 - exp(-DOF_FOCUS_SPEED * dt);
    return exp2(mix(log2(prev), log2(target), t));
#endif
}

void main() {
    uint index = gl_LocalInvocationIndex;
    sharedHistogram[index] = 0u;
#if defined LENS_FLARE && defined HAS_SKY
    if (index == 0u) sharedVisible = 0u;
#endif
    barrier();
#if defined LENS_FLARE && defined HAS_SKY
    atomicAdd(sharedVisible, flareVisibilityTap(index));
#endif

#if EXPOSURE_MODE != 0
    vec2 jitter = r2Sequence(frameCounter & 255);
    vec2 screen = viewSize();
    for (int j = 0; j < METER_PER_THREAD; j++) {
        for (int i = 0; i < METER_PER_THREAD; i++) {
            ivec2 cell = ivec2(gl_LocalInvocationID.xy) + ivec2(i, j) * 16;
            vec2 uv = (vec2(cell) + jitter) / float(METER_GRID);
            ivec2 p = ivec2(uv * screen);
            // 手 (たいまつを持った手など) は露出を引っ張らないよう測らない
            if (isHandDepth(texelFetch(depthtex0, p, 0).r)) continue;
            // テクセルの角で双線形サンプルすると 2x2 の平均が 1 回で取れる
            vec2 corner = vec2(max(p, ivec2(1))) / screen;
            float l = luminance(sanitizeColor(textureLod(colortex0, corner, 0.0).rgb));
            uint w = uint(meteringWeight(uv) * 16.0 + 0.5);
            atomicAdd(sharedHistogram[luminanceToHistogramBin(l)], w);
        }
    }
#endif
    barrier();
    frameData.histogram[index] = sharedHistogram[index];

    if (index != 0u) return;

    float dt = clamp(frameTime, 0.0, 0.5);
    bool initialized = frameData.postParams[0].z == EXPOSURE_INIT_MARKER;

#if EXPOSURE_MODE == 0
    float measuredEv = EXPOSURE_MANUAL_EV;
    float adaptedEv = measuredEv;
    float appliedEv = measuredEv;
    float targetEv = measuredEv;
#else
    #if EXPOSURE_MODE == 1
        const float lowPercent = 0.0;
        const float highPercent = 1.0;
    #else
        const float lowPercent = HISTOGRAM_LOW_PERCENT;
        const float highPercent = HISTOGRAM_HIGH_PERCENT;
    #endif
    bool ok;
    float logAverage = histogramLogAverage(lowPercent, highPercent, ok);
    float prevEv = frameData.postParams[0].x;
    float measuredEv = ok ? luminanceToEv100(exp2(logAverage)) : prevEv;
    if (!initialized || isnan(prevEv) || isinf(prevEv)) prevEv = measuredEv;

    float speed = measuredEv > prevEv ? EXPOSURE_SPEED_BRIGHT : EXPOSURE_SPEED_DARK;
    float adaptedEv = mix(prevEv, measuredEv, 1.0 - exp(-speed * dt));
    float appliedEv = applyEnvironmentExposure(clamp(exposureCurve(adaptedEv), EXPOSURE_MIN_EV, EXPOSURE_MAX_EV), adaptedEv);
    float targetEv = applyEnvironmentExposure(clamp(exposureCurve(measuredEv), EXPOSURE_MIN_EV, EXPOSURE_MAX_EV), measuredEv);
#endif

    float bias = exp2(EXPOSURE_BIAS);
    frameData.exposure = ev100ToExposure(appliedEv) * bias;
    frameData.exposureTarget = ev100ToExposure(targetEv) * bias;
    frameData.averageLuminance = ev100ToLuminance(adaptedEv);
    frameData.postParams[0] = vec4(adaptedEv, measuredEv, EXPOSURE_INIT_MARKER, appliedEv);

    frameData.focusDistance = updateFocus(dt);

#if defined LENS_FLARE && defined HAS_SKY
    float visNow = float(sharedVisible) / float(VIS_SCALE * 256u) * (1.0 - 0.85 * rainStrength);
    float visPrev = frameData.postParams[2].x;
    if (!initialized || isnan(visPrev) || isinf(visPrev)) visPrev = visNow;
    frameData.postParams[2].xy = vec2(mix(visPrev, visNow, 1.0 - exp(-LENS_VIS_SPEED * dt)), visNow);
#endif
}
