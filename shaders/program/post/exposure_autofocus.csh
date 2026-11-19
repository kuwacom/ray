/*
 * composite25 (compute): 自動露出 (ヒストグラム -> FrameData.exposure) とオートフォーカス (FrameData.focusDistance)
 * - 測光: 画面を 64x64 の格子で中央重点サンプル (毎フレーム格子内の位置を R2 列でずらし、時間方向に全画素を覆う)
 * - ヒストグラム 256 ビン (log2 輝度) を共有メモリで集計し、上下のパーセンタイルを除いた log 平均を EV100 にする
 * - 順応は EV のまま指数補間。明るい場面へは EXPOSURE_SPEED_BRIGHT、暗い場面へは EXPOSURE_SPEED_DARK
 * - 適用 EV は完全補正にせず (EXPOSURE_CURVE)、EXPOSURE_MIN_EV .. MAX_EV で止める (夜と洞窟は暗いまま残る)
 *   屋外の夜だけは止めた後に、画面の暗い側の計測に応じて明るく写す (EXPOSURE_NIGHT_*。月が照らす夜は強め)
 * - フォーカス: 手を含まない深度 (depthtex2) の画面中央 9 点の中央値を log 空間で平滑化。水面・ガラス・氷は設定で焦点に入れる
 * DoF (composite22) はこのパスより前に走るので、1 フレーム前のフォーカスを使う
 * post モジュール (lib/post)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/common/celestial_shape.glsl"
//@include "/lib/common/gbuffer.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/material_ids.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/light/voxel_read.glsl"
//@include "/lib/post/post_internal.glsl"
//@include "/lib/sky/sky_color.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/post/velocity.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/post.glsl"
#include "/lib/post/post_constants.glsl"
#include "/lib/post/lens_presets.glsl"
#include "/lib/post/sampling.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/post/camera.glsl"
#include "/lib/post/grading.glsl"
#include "/lib/buffers/slots.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/post/lens_optics.glsl"
#include "/lib/post/lens_ghosts.glsl"
#include "/lib/post/lens_flare.glsl"
#include "/lib/post/lens.glsl"
#include "/lib/post/post_internal.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/sky/sky_color.glsl"
// END GENERATED includes

layout(local_size_x = 16, local_size_y = 16) in;
const ivec3 workGroups = ivec3(1, 1, 1);

const int METER_GRID = 64;
const int METER_PER_THREAD = METER_GRID / 16;
// フォーカス点の間隔 (画面高さ比)。草 1 本に引っ張られないよう少し広げる
const float FOCUS_TAP_SPACING = 0.012;

shared uint sharedHistogram[256];
#if defined EXPOSURE_AUTO && defined HAS_SKYLIGHT
// 灯りに照らされた所の重み (夜の持ち上げを外す割合。EXPOSURE_NIGHT_LIGHT_*)
shared uint sharedLightLit;
#endif

#ifdef HAS_SKY
const uint VIS_SCALE = 1024u;
shared uint sharedVisible;
shared uint sharedFarHidden;
#if defined LENS_FLARE && SUN_MOON_STYLE == 0
// 見えている点の格子位置の重み付きモーメント: x, y, x^2, y^2 (バニラの四角のどこが見えているか)
shared uint sharedMoments[4];
#endif

/*
 * 光源 (昼は太陽, 夜は月) の形の中の index 番目の点。画面の端へ寄せた座標と、画面の外へのはみ出し (UV) を返す。光源が後ろなら false
 * 丸い円盤は少し広めの円 (LENS_VIS_DISC_SCALE 倍)、バニラは明るい四角の格子 (周りの淡い光は光源に数えない)
 */
bool lightDiscTap(uint index, out vec2 clamped, out float outside) {
    clamped = vec2(0.0);
    outside = 0.0;
    if (shadowLightPosition.z >= 0.0) return false;
#if SUN_MOON_STYLE == 0
    CelestialShape shape = shadowLightShape();
    vec2 xi = (vec2(index % LENS_VIS_SQUARE_GRID, index / LENS_VIS_SQUARE_GRID) + 0.5) / float(LENS_VIS_SQUARE_GRID);
    vec3 tapView = mat3(gbufferModelView) * celestialShapeDir(shape, celestialShapePoint(shape, xi));
    vec2 p = viewToScreen(tapView).xy;
#else
    vec2 lightUv = viewToScreen(shadowLightPosition).xy;
    float radius = LENS_VIS_DISC_SCALE * shadowLightShape().size * gbufferProjection[1][1] * 0.5;
    radius = max(radius, 1.5 / viewHeight);
    vec2 p = lightUv + vogelDisk(int(index), 256, 0.0) * radius * vec2(1.0 / aspectRatio, 1.0);
#endif
    clamped = clamp(p, vec2(0.5) / viewSize(), vec2(1.0) - vec2(0.5) / viewSize());
    outside = length(p - clamped);
    return true;
}

/*
 * 光源の円盤の 1 点が、影マップの範囲より遠い地形に隠れているか (霧の光を抑える用。FrameData.skyParams[3].z)
 * 範囲内の遮蔽物は影マップが見るので数えない。画面の外は端の画素で見て、離れるほど信用しない (隠れていないとする)
 */
uint farHiddenTap(uint index) {
    vec2 clamped;
    float outside;
    if (!lightDiscTap(index, clamped, outside) || outside >= LENS_VIS_OFFSCREEN) return 0u;
    float depth = texelFetch(depthtex0, ivec2(clamped * viewSize()), 0).r;
    if (depth >= 1.0 || isHandDepth(depth)) return 0u;
#ifdef HAS_SUN_SHADOWS
    if (linearizeDepth(depth) < shadowDistance) return 0u;
#endif
    return uint((1.0 - smoothstep(0.0, LENS_VIS_OFFSCREEN, outside)) * float(VIS_SCALE) + 0.5);
}
#endif

#if defined LENS_FLARE && defined HAS_SKY
/*
 * レンズフレアの光源 (昼は太陽, 夜は月) の見え具合 -> FrameData.postParams[2].x (平滑化済み), .y (今フレーム)
 * 256 スレッドがそれぞれ光源の形 (丸い円盤 / バニラの四角) の中の 1 点を調べ、見えている割合を集計する (木の葉越し・雲の縁の部分的な遮蔽も割合で効く)
 * - 地形・手: 深度が空 (1.0) でなければ遮蔽
 * - 雲: その点の明るさと空の平均の比 (雲に隠れると円盤が空と同じ明るさに落ちる)
 * - 画面の外: 一番近い画面端の画素で判定し、外へ離れるほど弱める (画面のすぐ外の太陽からもフレアは出る)
 * 1 画素ごとに final で判定していたのをここへ移し、時間方向にも平滑化してちらつきを抑える
 * バニラの四角では、見えている点の格子位置のモーメントも同じ重みで集計する (FrameData.postParams[3])。final が見えている部分の
 * 中心と広がりを求め、フレアの光源の位置と大きさを遮られていない部分に合わせる
 */
uint flareVisibilityTap(uint index) {
    vec2 clamped;
    float outside;
    if (!lightDiscTap(index, clamped, outside)) return 0u;
    if (outside >= LENS_VIS_OFFSCREEN) return 0u;
    if (texelFetch(depthtex0, ivec2(clamped * viewSize()), 0).r < 1.0) return 0u;
    float vis = 1.0 - smoothstep(0.0, LENS_VIS_OFFSCREEN, outside);
    // カメラが雲の中なら光源は雲に隠れる (画面の外の光源は画素の明るさでは分からないので、雲の中の濃さで隠す。frameData.skyParams[4].a)
    vis *= 1.0 - frameData.skyParams[4].a;
#if CLOUDS >= 2
    // 円盤の点ごとの雲の透過率を掛ける (明るさの比だけだと、雲の縁で光る薄い雲や縁に隠れかけた円盤で見えている割合より多く残る)
    vis *= saturate(texelFetch(colortex11, ivec2(clamped * viewSize()), 0).a);
#endif
#ifdef HAS_SUN_SHADOWS
    // 画面の外の太陽は端の画素しか見えない (洞窟の口や尾根の上の空が写っていても太陽は隠れている) ので、目の位置の影マップの判定を使う
    vis *= mix(1.0, saturate(frameData.skyParams[3].x), smoothstep(0.0, LENS_VIS_EYE_FADE, outside));
#endif
    if (outside <= 0.0) {
        // SH の DC 項 x Y00 = 空の平均放射 (ルックの空の環境光の強さは空の明るさではないので外す)
        float skyLum = luminance(frameData.skySH[0].rgb) * (0.282095 / LK_SKY_AMBIENT);
        if (skyLum > 1e-6) {
            // 歪曲・魚眼を TAA で組み立てた時は colortex0 が出力の座標なので、光源の出力の位置で読む
            vec2 colorUv = LENS_WARP_TAA ? lensForwardUv(clamped) : clamped;
            float l = luminance(sanitizeColor(textureLod(colortex0, colorUv, 0.0).rgb));
#if SUN_MOON_STYLE >= 1
            // 夜の円盤は白飛びさせるために明るく描いてある。フレアの見え具合は円盤を白飛びさせる前の明るさで比べる
            if (frameData.shadowLightIrradiance.a <= 0.5) l /= moonSkyDiscBoost(getSunDir().y);
#endif
            vis *= saturate(log2(max(l / skyLum, 1.0) / LENS_VIS_SKY_RATIO.x) / LENS_VIS_SKY_RATIO.y);
        }
    }
    return uint(vis * float(VIS_SCALE) + 0.5);
}
#endif

// 測光の重み。古い方式の自動露出は機材の測光に決め打ち (VHS は中央重点、DV は平均)
#if EXPOSURE_RESPONSE_MODE == 1
    #define METERING_ACTIVE_MODE 1
#elif EXPOSURE_RESPONSE_MODE == 2
    #define METERING_ACTIVE_MODE 3
#else
    #define METERING_ACTIVE_MODE EXPOSURE_METERING_MODE
#endif
// 重みはヒストグラムに整数で足すので、この倍率で丸める (中央重点の外側 0.05 も 0 にならないように)
const float METERING_WEIGHT_SCALE = 64.0;

float meteringWeight(vec2 uv) {
    vec2 d = (uv - 0.5) * vec2(aspectRatio, 1.0);
#if METERING_ACTIVE_MODE == 1
    float r = length(d) / (0.5 * METERING_CENTER_DIAMETER * aspectRatio);
    return mix(1.0, METERING_CENTER_OUTSIDE, smoothstep(METERING_CIRCLE_EDGE.x, METERING_CIRCLE_EDGE.y, r));
#elif METERING_ACTIVE_MODE == 2
    float r = length(d) / (0.5 * METERING_SPOT_DIAMETER * aspectRatio);
    return 1.0 - smoothstep(METERING_CIRCLE_EDGE.x, METERING_CIRCLE_EDGE.y, r);
#elif METERING_ACTIVE_MODE == 3
    return 1.0;
#else
    return mix(METERING_EDGE_WEIGHT, 1.0, exp(-dot(d, d) * 6.0));
#endif
}

// 順応: EV のまま指数補間。明るい場面へは EXPOSURE_SPEED_BRIGHT、暗い場面へは EXPOSURE_SPEED_DARK
float adaptEv(float prev, float measured, bool initialized, float dt) {
    if (!initialized || isnan(prev) || isinf(prev)) return measured;
    float speed = measured > prev ? EXPOSURE_SPEED_BRIGHT : EXPOSURE_SPEED_DARK;
    return mix(prev, measured, 1.0 - exp(-speed * dt));
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

// ヒストグラムの重みの合計
float histogramTotal() {
    float total = 0.0;
    for (int i = 0; i < 256; i++) total += float(sharedHistogram[i]);
    return total;
}

// ヒストグラムの重みの上位 1 - percent の境の log2 輝度 (ビンの中は一様とみなして補間)
float histogramPercentileLog(float percent) {
    float total = 0.0;
    for (int i = 0; i < 256; i++) total += float(sharedHistogram[i]);
    if (total <= 0.0) return HISTOGRAM_LOG_MIN;
    float target = total * percent;
    float cumulative = 0.0;
    for (int i = 0; i < 256; i++) {
        float n = float(sharedHistogram[i]);
        if (n > 0.0 && cumulative + n >= target) {
            return histogramBinToLog(float(i) - 0.5 + (target - cumulative) / n);
        }
        cumulative += n;
    }
    return HISTOGRAM_LOG_MAX;
}

// 計測 EV -> 適用 EV (完全補正にしない。基準から離れるほど明暗を残し、明るい場面はさらに明るく写す)
float exposureCurve(float ev) {
    float boost = EXPOSURE_BRIGHT_BOOST * smoothstep(EXPOSURE_BRIGHT_EV_LOW, EXPOSURE_BRIGHT_EV_HIGH, ev);
    return EXPOSURE_ANCHOR_EV + (ev - EXPOSURE_ANCHOR_EV) * EXPOSURE_CURVE - boost;
}

#if EXPOSURE_RESPONSE_MODE != 0
/*
 * 古い方式の自動露出 (EXPOSURE_RESPONSE_MODE)。測光 EV -> 目標 (今の曲線より完全補正に近い) -> 絞りの動きと暗い所の AGC
 * 絞りは開放 (RESPONSE_IRIS_OPEN_EV) より明るくは写せず、その先はゲインで上げる (上限 RESPONSE_GAIN_MAX 段)
 * VHS: 測光の検波の遅れの後に、絞りのサーボが 2 次の遅れで動く (行き過ぎて行ったり来たりする)
 * DV: 絞りとゲインが 1 次の遅れでゆっくり追う (明るい所に入ると、しばらく白く飛んでから戻る)
 * state: x = 絞りの EV, y = 絞りの動く速さ (EV/秒), z = ゲイン (段), w = 検波した測光 EV
 */
float responseTargetEv(float ev) {
    return EXPOSURE_ANCHOR_EV + (ev - EXPOSURE_ANCHOR_EV) * RESPONSE_CURVE;
}

float responseIrisEv(float ev) { return clamp(responseTargetEv(ev), RESPONSE_IRIS_OPEN_EV, EXPOSURE_MAX_EV); }
float responseGain(float ev) { return clamp(RESPONSE_IRIS_OPEN_EV - responseTargetEv(ev), 0.0, RESPONSE_GAIN_MAX); }

vec4 updateResponse(vec4 state, float measuredEv, bool initialized, float dt) {
    if (!initialized || any(isnan(state)) || any(isinf(state))) {
        return vec4(responseIrisEv(measuredEv), 0.0, responseGain(measuredEv), measuredEv);
    }
#if EXPOSURE_RESPONSE_MODE == 1
    // 2 次の式は刻みを細かくして解く (フレームの時間が長いと発散する)
    int steps = int(ceil(dt / RESPONSE_STEP_MAX));
    float h = dt / float(max(steps, 1));
    for (int i = 0; i < steps; i++) {
        state.w = mix(state.w, measuredEv, 1.0 - exp(-VHS_SENSE_SPEED * h));
        float accel = VHS_SERVO_OMEGA * VHS_SERVO_OMEGA * (responseIrisEv(state.w) - state.x)
                    - 2.0 * VHS_SERVO_DAMPING * VHS_SERVO_OMEGA * state.y;
        state.y += accel * h;
        state.x += state.y * h;
        // 絞りの端 (開放と最小) に当たると止まる
        if (state.x < RESPONSE_IRIS_OPEN_EV || state.x > EXPOSURE_MAX_EV) {
            state.x = clamp(state.x, RESPONSE_IRIS_OPEN_EV, EXPOSURE_MAX_EV);
            state.y = 0.0;
        }
    }
    state.z = mix(state.z, responseGain(state.w), 1.0 - exp(-VHS_AGC_SPEED * dt));
#else
    float iris = responseIrisEv(measuredEv);
    state.x = mix(state.x, iris, 1.0 - exp(-(iris > state.x ? DV_SPEED_BRIGHT : DV_SPEED_DARK) * dt));
    float gain = responseGain(measuredEv);
    state.z = mix(state.z, gain, 1.0 - exp(-(gain < state.z ? DV_SPEED_BRIGHT : DV_SPEED_DARK) * dt));
    state.y = 0.0;
    state.w = measuredEv;
#endif
    return state;
}
#endif

// 太陽が地平線の下 [0,1]
float nightFactor() { return 1.0 - smoothstep(-0.2, -0.05, getSunDir().y); }

// 目の位置のブロックライト [0,1]。手持ちの光源は eyeBrightness に入らないので持っている光源の明るさも見る
float eyeBlockLight() {
    float held = float(max(heldBlockLightValue, heldBlockLightValue2)) / LIGHT_LEVEL_MAX;
    return max(float(eyeBrightnessSmooth.x) / EYE_BRIGHTNESS_MAX, held);
}

/*
 * 曲線と下限で止めた EV を目の位置の明るさ (屋外 / 屋内・洞窟) で補正する
 * 屋外の夜は明るく写す (下限 EXPOSURE_MIN_EV は洞窟の暗さのために残す)、灯りの点いた屋内・洞窟は少し暗く写す
 * darkEv は画面の暗い側だけの計測 EV (EXPOSURE_NIGHT_DARK_PERCENT)。夜の持ち上げだけに使う
 * lightShare は灯りに照らされた所の割合 (EXPOSURE_NIGHT_LIGHT_*)。灯りの多い夜景では持ち上げを外す
 */
float applyEnvironmentExposure(float appliedEv, float ev, float darkEv, float lightShare) {
#ifdef HAS_SKYLIGHT
    float outdoor = eyeOutdoor();
    float night = nightFactor();
    // 月が照らす夜だけ強く持ち上げる (新月・雨の夜の暗さは残す)。水中は EXPOSURE_UNDERWATER_DIM の暗さを打ち消さないよう外す
    float moonLit = moonPhaseFactor() * (1.0 - rainStrength) * night * (isEyeInWater == 0 ? 1.0 : 0.0);
    // 実写の夜景のように暗い所 (水面・地面・空の暗い所) に合わせて持ち上げる (EXPOSURE_NIGHT_DARK_PERCENT)。昼・新月・雨は平均の計測のまま
    float liftEv = mix(ev, min(darkEv, ev), moonLit);
    float slope = EXPOSURE_NIGHT_SLOPE + EXPOSURE_NIGHT_MOON_SLOPE * moonLit;
    float lift = min(slope * max(EXPOSURE_NIGHT_EV_START - liftEv, 0.0), EXPOSURE_NIGHT_MAX_LIFT);
    lift *= 1.0 - smoothstep(EXPOSURE_NIGHT_LIGHT_SHARE.x, EXPOSURE_NIGHT_LIGHT_SHARE.y, lightShare);
    lift = max(lift, EXPOSURE_NIGHT_MIN_LIFT * night) * EXPOSURE_NIGHT_LIFT_STRENGTH;
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
 * 半透明の面は、見えている物の表面として焦点に入れる (depthtex2 は半透明を含まないので、入れないと奥に合う)
 * - 水面 (DOF_FOCUS_WATER): 海を見ると水底 (数十ブロック先) に合い、手前の水面と映り込みが前ボケになって
 *   つやの無いぼやけた面に見える。水中から見上げた水面は奥に合わせたいので、水の外にいる時に限る
 * - ガラス・氷など形のある物 (DOF_FOCUS_GLASS): 窓越しの景色はぼける
 * - 半透明の経路で描くエンティティ (プレイヤーのスキン・マネキン・旗等) は常に。三人称やフリーカメラで自分の体を見ると、
 *   奥の地面に合って体がぼけていた。光の柱・雷は透けて見えるので除く
 */
bool isFocusTranslucent(int mat) {
#ifdef DOF_FOCUS_WATER
    if (mat == MAT_WATER) return isEyeInWater == 0;
#endif
#ifdef DOF_FOCUS_GLASS
    if (mat == MAT_GLASS || mat == MAT_STAINED_GLASS || mat == MAT_ICE || mat == MAT_SLIME_HONEY) return true;
#endif
    return isEntityMaterial(mat) && mat != MAT_BEACON_BEAM && mat != MAT_LIGHTNING;
}

#ifdef DOF_FOCUS_GLASS
/*
 * 透明なガラス (cutout の BLOCK_GLASS・BLOCK_GLASS_PANE) は透明なテクセルが depthtex2 に入らず、枠の画素しか深度に残らない
 * ので、カメラから dir へ maxDist までのボクセルを辿って最初のガラスのセルまでの距離を返す (無ければ -1)
 * 板ガラスは繋がり方で形が変わるので、セルの中心を通る面で近似する (誤差は半ブロック以内)
 */
const float FOCUS_GLASS_MAX_DIST = 48.0; // これより遠いガラスは奥とボケの差がほとんど無い
const int FOCUS_GLASS_MAX_STEPS = 96;

float focusClearGlassDistance(vec3 dir, float maxDist) {
    vec3 origin = playerToVoxel(vec3(0.0));
    ivec3 cell = ivec3(floor(origin));
    ivec3 stepDir = ivec3(greaterThanEqual(dir, vec3(0.0))) * 2 - 1;
    vec3 tDelta = 1.0 / max(abs(dir), vec3(1e-7));
    vec3 fr = origin - vec3(cell);
    vec3 tMax = mix(fr, 1.0 - fr, vec3(greaterThan(stepDir, ivec3(0)))) * tDelta;
    for (int i = 0; i < FOCUS_GLASS_MAX_STEPS; i++) {
        float tEnter = minOf(tMax);
        if (tEnter >= maxDist) break;
        if (tMax.x == tEnter) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y == tEnter) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
        if (!isInVoxelVolume(cell)) break;
        int id = fetchVoxelBlockId(cell);
        if (id == BLOCK_GLASS) return tEnter;
        if (id == BLOCK_GLASS_PANE) return clamp(dot(vec3(cell) + 0.5 - origin, dir), tEnter, minOf(tMax));
    }
    return -1.0;
}
#endif

float focusTapDistance(vec2 uv) {
    ivec2 p = ivec2(uv * viewSize());
    float d = texelFetch(depthtex2, p, 0).r;
    float d0 = texelFetch(depthtex0, p, 0).r;
    if (d0 < d && !isHandDepth(d0)) {
        vec3 n;
        vec2 lm;
        int mat;
        decodeTranslucentData(texelFetch(colortex5, p, 0), n, lm, mat);
        if (isFocusTranslucent(mat)) d = d0;
    }
    float dist = d >= 1.0 ? far : linearizeDepth(d);
#ifdef DOF_FOCUS_GLASS
    // 視線の向きと、奥行き (線形深度) に対する視線方向の長さの比。どの深度でも向きは同じなので中間の深度で取る
    vec3 viewRay = screenToPlayer(vec3(uv, 0.5));
    vec3 dir = normalize(viewRay);
    float cosForward = linearizeDepth(0.5) / length(viewRay);
    float glass = focusClearGlassDistance(dir, min(dist / cosForward, FOCUS_GLASS_MAX_DIST));
    if (glass >= 0.0) dist = min(dist, glass * cosForward);
#endif
    return dist;
}

float updateFocus(float dt) {
#if DOF_FOCUS_MODE == 1
    frameData.postParams[1].x = optDofManualFocus;
    return optDofManualFocus;
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
        target *= optDofManualFocus / 8.0;
    #endif
    target = clamp(target, 0.1, max(far, 1.0));
    frameData.postParams[1].x = target;

    float prev = frameData.focusDistance;
    if (prev == 0.0) prev = optDofManualFocus;  // setup の初期値 (cameraFocusDistance と同じ)
    else if (!(prev > 0.0) || isinf(prev)) prev = target;
    float t = 1.0 - exp(-optDofFocusSpeed * dt);
    return exp2(mix(log2(prev), log2(target), t));
#endif
}

void main() {
    uint index = gl_LocalInvocationIndex;
    sharedHistogram[index] = 0u;
#if defined EXPOSURE_AUTO && defined HAS_SKYLIGHT
    if (index == 0u) sharedLightLit = 0u;
#endif
#ifdef HAS_SKY
    if (index == 0u) {
        sharedVisible = 0u;
        sharedFarHidden = 0u;
    #if defined LENS_FLARE && SUN_MOON_STYLE == 0
        sharedMoments[0] = 0u;
        sharedMoments[1] = 0u;
        sharedMoments[2] = 0u;
        sharedMoments[3] = 0u;
    #endif
    }
#endif
    barrier();
#ifdef HAS_SKY
    #ifdef LENS_FLARE
    uint tapVisible = flareVisibilityTap(index);
    atomicAdd(sharedVisible, tapVisible);
        #if SUN_MOON_STYLE == 0
    uvec2 tapCell = uvec2(index % LENS_VIS_SQUARE_GRID, index / LENS_VIS_SQUARE_GRID);
    atomicAdd(sharedMoments[0], tapVisible * tapCell.x);
    atomicAdd(sharedMoments[1], tapVisible * tapCell.y);
    atomicAdd(sharedMoments[2], tapVisible * tapCell.x * tapCell.x);
    atomicAdd(sharedMoments[3], tapVisible * tapCell.y * tapCell.y);
        #endif
    #endif
    atomicAdd(sharedFarHidden, farHiddenTap(index));
#endif

#ifdef EXPOSURE_AUTO
    vec2 jitter = r2Sequence(frameCounter & 255);
    vec2 screen = viewSize();
    #ifdef HAS_SKYLIGHT
        // 灯りの割合は前のフレームの暗い側の測光から決めた明るさで数える (このフレームの暗い側は集計の後でしか分からない)
        float prevDark = frameData.postParams[1].y;
        float lightLum = isnan(prevDark) || isinf(prevDark) ? 1e30 : ev100ToLuminance(prevDark) * exp2(EXPOSURE_NIGHT_LIGHT_EV);
    #endif
    for (int j = 0; j < METER_PER_THREAD; j++) {
        for (int i = 0; i < METER_PER_THREAD; i++) {
            ivec2 cell = ivec2(gl_LocalInvocationID.xy) + ivec2(i, j) * 16;
            vec2 uv = (vec2(cell) + jitter) / float(METER_GRID);
            ivec2 p = ivec2(uv * screen);
            // 手 (たいまつを持った手など) は露出を引っ張らないよう測らない
            if (isHandDepth(texelFetch(depthtex0, LENS_WARP_TAA ? postSourceTexel(uv) : p, 0).r)) continue;
            // テクセルの角で双線形サンプルすると 2x2 の平均が 1 回で取れる
            vec2 corner = vec2(max(p, ivec2(1))) / screen;
            float l = luminance(sanitizeColor(textureLod(colortex0, corner, 0.0).rgb));
            uint w = uint(meteringWeight(uv) * METERING_WEIGHT_SCALE + 0.5);
            atomicAdd(sharedHistogram[luminanceToHistogramBin(l)], w);
            #ifdef HAS_SKYLIGHT
            /*
             * 灯りに照らされた所 = 暗い側より明るく、ライトマップのブロックライトのある所。明るさだけで数えると、
             * 月の照り返しの道 (夜の海) と月明かりの雪の明るい所まで灯りに数え、月夜の持ち上げが外れた
             */
            if (l > lightLum) {
                ivec2 g = LENS_WARP_TAA ? postSourceTexel(uv) : p;
                if (unpack2x8(texelFetch(colortex2, g, 0).a).x >= EXPOSURE_NIGHT_LIGHT_BLOCK) atomicAdd(sharedLightLit, w);
            }
            #endif
        }
    }
#endif
    barrier();
    frameData.histogram[index] = sharedHistogram[index];

    if (index != 0u) return;

    float dt = clamp(frameTime, 0.0, 0.5);
    bool initialized = frameData.postParams[0].z == EXPOSURE_INIT_MARKER;

#ifndef EXPOSURE_AUTO
    float measuredEv = EXPOSURE_MANUAL_EV;
    float adaptedEv = measuredEv;
    float appliedEv = measuredEv;
    float targetEv = measuredEv;
#else
    // 古い方式の測光は外れ値を除かない平均 (ビデオの信号の平均を見る)
    #if EXPOSURE_MODE == 1 || EXPOSURE_RESPONSE_MODE != 0
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
    float adaptedEv = adaptEv(prevEv, measuredEv, initialized, dt);
#endif
#if defined EXPOSURE_AUTO && EXPOSURE_RESPONSE_MODE != 0
    vec4 response = updateResponse(frameData.postParams[6], measuredEv, initialized, dt);
    frameData.postParams[6] = response;
    float underwater = isEyeInWater == 1 ? EXPOSURE_UNDERWATER_DIM : 0.0;
    float appliedEv = response.x - response.z + underwater;
    float targetEv = responseIrisEv(measuredEv) - responseGain(measuredEv) + underwater;
    // Purkinje と局所トーンマップの基準 (averageLuminance) は、測光の順応ではなく今の絞りとゲインが中間グレーに写す明るさにする
    adaptedEv = EXPOSURE_ANCHOR_EV + (response.x - response.z - EXPOSURE_ANCHOR_EV) / RESPONSE_CURVE;
#elif defined EXPOSURE_AUTO

    // 暗い所の計測 EV (夜の持ち上げ用)。平均の側と同じ速さで順応させ、持ち上げが跳ばないようにする
    float measuredDarkEv = measuredEv;
    float adaptedDarkEv = adaptedEv;
    float lightShare = 0.0;
    #ifdef HAS_SKYLIGHT
        bool darkOk;
        float darkLogAverage = histogramLogAverage(EXPOSURE_NIGHT_DARK_PERCENT.x, EXPOSURE_NIGHT_DARK_PERCENT.y, darkOk);
        float measuredDarkSide = darkOk ? luminanceToEv100(exp2(darkLogAverage)) : measuredEv;
        float adaptedDarkSide = adaptEv(frameData.postParams[1].y, measuredDarkSide, initialized, dt);
        frameData.postParams[1].y = adaptedDarkSide;
        #if EXPOSURE_MODE == 2
            measuredDarkEv = measuredDarkSide;
            adaptedDarkEv = adaptedDarkSide;
        #endif
        // 灯りに照らされた所の割合。暗い側より EXPOSURE_NIGHT_LIGHT_EV 明るい所を数える (月明かりの地面と空はこの差に届かない)
        float total = histogramTotal();
        float measuredShare = total > 0.0 ? float(sharedLightLit) / total : 0.0;
        float prevShare = frameData.postParams[5].z;
        lightShare = initialized && !isnan(prevShare) && !isinf(prevShare)
                   ? mix(prevShare, measuredShare, 1.0 - exp(-EXPOSURE_SPEED_DARK * dt)) : measuredShare;
        frameData.postParams[5].z = lightShare;
    #endif
    float appliedEv = applyEnvironmentExposure(clamp(exposureCurve(adaptedEv), EXPOSURE_MIN_EV, EXPOSURE_MAX_EV), adaptedEv, adaptedDarkEv, lightShare);
    float targetEv = applyEnvironmentExposure(clamp(exposureCurve(measuredEv), EXPOSURE_MIN_EV, EXPOSURE_MAX_EV), measuredEv, measuredDarkEv, lightShare);
    #if METERING_ACTIVE_MODE == 0 && defined HAS_SKYLIGHT
        /*
         * 評価測光: 夜の屋外で灯りに照らされた所が白く飛ぶ時は、白を超える所が重みの EXPOSURE_NIGHT_CLIP_SHARE までになる所まで暗く写す
         * (最大 EXPOSURE_NIGHT_CLIP_MAX EV)。平均を見る測光は暗い地面と空に引かれて、灯りの周りを白く飛ばす
         */
        float measuredClipEv = luminanceToEv100(exp2(histogramPercentileLog(1.0 - EXPOSURE_NIGHT_CLIP_SHARE)))
                             + log2(EXPOSURE_KEY / EXPOSURE_NIGHT_CLIP_LEVEL) + LOOK_EXPOSURE_BIAS;
        float adaptedClipEv = adaptEv(frameData.postParams[5].y, measuredClipEv, initialized, dt);
        frameData.postParams[5].y = adaptedClipEv;
        float nightOutdoor = nightFactor() * eyeOutdoor();
        appliedEv += nightOutdoor * clamp(adaptedClipEv - appliedEv, 0.0, EXPOSURE_NIGHT_CLIP_MAX);
        targetEv += nightOutdoor * clamp(measuredClipEv - targetEv, 0.0, EXPOSURE_NIGHT_CLIP_MAX);
    #endif
    #if METERING_ACTIVE_MODE == 4
        // ハイライト重点: 明るい側が露出後に METERING_HIGHLIGHT_LEVEL を超えるほど明るくは写さない (夜の持ち上げの後にも効かせる)
        bool highOk;
        float highLogAverage = histogramLogAverage(METERING_HIGHLIGHT_PERCENT.x, METERING_HIGHLIGHT_PERCENT.y, highOk);
        float measuredHighEv = highOk ? luminanceToEv100(exp2(highLogAverage)) + log2(EXPOSURE_KEY / METERING_HIGHLIGHT_LEVEL) + LOOK_EXPOSURE_BIAS : targetEv;
        float adaptedHighEv = adaptEv(frameData.postParams[5].x, measuredHighEv, initialized, dt);
        frameData.postParams[5].x = adaptedHighEv;
        appliedEv = min(max(appliedEv, adaptedHighEv), EXPOSURE_MAX_EV);
        targetEv = min(max(targetEv, measuredHighEv), EXPOSURE_MAX_EV);
    #endif
    #ifdef EXPOSURE_DR_ACTIVE
        /*
         * DR の補正: 明るい側 (重みの上位 DR_PROTECT_SHARE) が露出後に DR_PROTECT_LEVEL を超える分だけ、最大 DR_HIGHLIGHT_MAX EV 暗く撮る
         * 暗く撮った量は final (applyDynamicRange) が中間と暗い所で戻す
         */
        float protectEv = luminanceToEv100(exp2(histogramPercentileLog(1.0 - DR_PROTECT_SHARE))) + log2(EXPOSURE_KEY / DR_PROTECT_LEVEL) + LOOK_EXPOSURE_BIAS;
        float measuredDr = clamp(protectEv - targetEv, 0.0, DR_HIGHLIGHT_MAX);
        float prevDr = frameData.postParams[5].w;
        float drEv = initialized && !isnan(prevDr) && !isinf(prevDr)
                   ? mix(prevDr, measuredDr, 1.0 - exp(-EXPOSURE_SPEED_BRIGHT * dt)) : measuredDr;
        frameData.postParams[5].w = drEv;
        appliedEv += drEv;
        targetEv += measuredDr;
    #endif
#endif

    float bias = exp2(LOOK_EXPOSURE_BIAS);
    frameData.exposure = ev100ToExposure(appliedEv) * bias;
    frameData.exposureTarget = ev100ToExposure(targetEv) * bias;
    frameData.averageLuminance = ev100ToLuminance(adaptedEv);
    frameData.postParams[0] = vec4(adaptedEv, measuredEv, EXPOSURE_INIT_MARKER, appliedEv);

    frameData.focusDistance = updateFocus(dt);

#ifdef HAS_SKY
    float hiddenNow = float(sharedFarHidden) / float(VIS_SCALE * 256u);
    float hiddenPrev = frameData.skyParams[3].z;
    if (!initialized || isnan(hiddenPrev) || isinf(hiddenPrev)) hiddenPrev = hiddenNow;
    frameData.skyParams[3].z = mix(hiddenPrev, hiddenNow, 1.0 - exp(-LENS_VIS_SPEED * dt));
#endif
#if defined LENS_FLARE && defined HAS_SKY
    float visScale = (1.0 - 0.85 * rainStrength) / float(VIS_SCALE * 256u);
    float visNow = float(sharedVisible) * visScale;
    float visPrev = frameData.postParams[2].x;
    if (!initialized || isnan(visPrev) || isinf(visPrev)) visPrev = visNow;
    // 隠れる向きは速く追う (平滑化はちらつきを抑えるためで、遮られた光源のフレアを残すためではない)
    float visSpeed = visNow < visPrev ? LENS_VIS_HIDE_SPEED : LENS_VIS_SPEED;
    float visBlend = 1.0 - exp(-visSpeed * dt);
    frameData.postParams[2].xy = vec2(mix(visPrev, visNow, visBlend), visNow);
    #if SUN_MOON_STYLE == 0
    // 見えている部分の位置と広がり。見え具合と同じ重みと平滑で持つので、final が割れば同じ時刻の重心と分散になる
    vec4 momentsNow = vec4(sharedMoments[0], sharedMoments[1], sharedMoments[2], sharedMoments[3]) * visScale;
    vec4 momentsPrev = frameData.postParams[3];
    if (!initialized || any(isnan(momentsPrev)) || any(isinf(momentsPrev))) momentsPrev = momentsNow;
    frameData.postParams[3] = mix(momentsPrev, momentsNow, visBlend);
    #endif
#endif
#ifdef LENS_FLARE
    // フレアのループの回数 (final の lensGhosts と bloom_blur の screenFlare が読む。lib/post/lens_flare.glsl)
    frameData.postParams[4] = vec4(LENS_GHOST_COUNT, LENS_SPECTRAL_SAMPLES, LENS_SCREEN_STAR_LINES, LENS_SCREEN_GHOST_COUNT);
#endif
}
