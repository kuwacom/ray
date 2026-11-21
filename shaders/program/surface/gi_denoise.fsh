/*
 * deferred11: GI / AO のアップサンプル + デノイズ (giRawImg + colortex9 -> colortex9)
 * 出力 colortex9: rgb = 間接光の照度, a = AO。今フレームの出力と次フレームの履歴を兼ねる
 * surface モジュール (lib/surface)
 *
 * 1. 空間: 低解像度テクセルの近傍 (GI_DENOISE=2 で 5x5、それ以外 3x3) を深度・法線の差で重み付けして集める (joint bilateral)
 *    各テクセルが表すフル解像度のピクセルは lowResOffset(frameCounter) で復元し、その深度・法線と比べる
 *    履歴が GI_SHORT_HISTORY より短い画素は、外側を 2 テクセルおき + 内側の 3x3 にして幅を 2 倍にする (再投影を先に行う)
 * 2. 時間 (GI_DENOISE>=1): 履歴の長さ n を持ち、GI は 1/n で混ぜる (上限 GI_HISTORY_MAX)
 *    再投影は 2x2 の双線形で、履歴の視線距離が合わないタップを捨てる (ディスオクルージョンで長さを 0 に戻す)
 *    変化の検出: 輝度の速い履歴 (平均と分散、混合率 GI_FAST_ALPHA) と GI の履歴の差が、速い履歴の揺れの
 *    GI_CHANGE_K 倍を超えたら n を縮める (Schied et al. 2017 の時間方向の分散、ReBLUR の速い履歴と同じ考え方)
 *    生値の近傍の標準偏差で履歴を切る方式は、当たりが稀な暗所ほど幅が狭くなって毎フレーム履歴を捨て、揺れと暗さの偏りが残った
 *    AO は画面空間で求めていて視点で変わるので、今までどおり近傍の幅に収めてから混ぜる
 */
//@include "/lib/buffers/images.glsl"
//@include "/lib/common/common.glsl"
//@include "/lib/common/joint_bilateral.glsl"
//@include "/lib/common/temporal.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/surface/surface.glsl"
//@include "/lib/post/post.glsl"
//@include "/lib/buffers/slots.glsl"
//@include "/lib/common/pre_exposure.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/buffers/images.glsl"
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
#include "/lib/common/joint_bilateral.glsl"
#include "/lib/common/temporal.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/slots.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glitter.glsl"
#include "/lib/common/water_lod.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/post/velocity.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/post.glsl"
#include "/lib/common/pre_exposure.glsl"
// END GENERATED includes

in vec2 texcoord;

#if GI_DENOISE >= 1
/* RENDERTARGETS: 9,10 */
#else
/* RENDERTARGETS: 9 */
#endif
layout(location = 0) out vec4 outHistory;
#if GI_DENOISE >= 1
// r = 履歴の長さ (フレーム), g = 視線距離, b = 速い履歴の輝度の平均, a = その分散
layout(location = 1) out vec4 outHistoryInfo;
#endif

#if GI_DENOISE == 2
    const int GI_FILTER_RADIUS = 2;
#else
    const int GI_FILTER_RADIUS = 1;
#endif
const float GI_DEPTH_SIGMA = 0.04;     // 相対深度差の許容
const float GI_NORMAL_POWER = 16.0;
const float GI_HISTORY_CLIP = 1.5;     // AO の履歴を収める標準偏差の幅
#if GI_RES == 1
    const float GI_TEMPORAL_ALPHA = 0.1;
#else
    const float GI_TEMPORAL_ALPHA = 0.16; // 1/4 のピクセルしか毎フレーム更新されないので少し速く追従させる
#endif
// 履歴の視線距離の許容 (再投影の遮蔽判定。ブロックライトの履歴と同じ値)
const float GI_HISTORY_DEPTH_REL = 0.05;
const float GI_HISTORY_DEPTH_ABS = 0.1;
const float GI_HISTORY_MIN_WEIGHT = 0.05;
// 速い履歴の混合率 (約 4 フレーム)。変化の検出の基準で、表示には使わない
const float GI_FAST_ALPHA = 0.25;
// 変化とみなす差 = 速い履歴の揺れ x GI_CHANGE_K + 輝度 x GI_CHANGE_REL (揺れの推定が 0 に近い所で小さな差を拾わないため)
const float GI_CHANGE_K = 2.0 / GI_RESPONSE_STRENGTH;
const float GI_CHANGE_REL = 0.02;
const float GI_HISTORY_MIN = 1.0;      // 変化を検出した時に残す長さの下限

// エッジ停止は幾何法線で見る (GI / AO は幾何法線で計算している。テクスチャ法線だとテクセルごとに重みが切れてノイズが残る)
vec3 readGeoNormal(ivec2 texel) { return octDecode(unpack2x8(texelFetch(colortex2, texel, 0).b)); }

#if GI_DENOISE >= 1 && GI_SHORT_HISTORY > 0
/*
 * 前フレームの GI と付属 (長さ・視線距離・速い履歴) を 2x2 の双線形で再投影する
 * 視線距離が合わないタップは捨て、有効な重みが足りなければ info = 0 (長さ 0 = 履歴なし)
 * 空間のフィルタより前に長さが要る GI_SHORT_HISTORY の時だけ使う。0 の時は main の中の同じ処理
 * (関数にすると、切った時の機械語が前と変わる)
 */
void reprojectGiHistory(ivec2 texel, float depth, float linZ, ivec2 screen, out vec4 history, out vec4 info) {
    history = vec4(0.0);
    info = vec4(0.0);
    vec2 prevUv = getPreviousUv(texcoord, depth);
    if (reprojectionInside(prevUv) && screenHistoryValid()) {
        // 動くもの (速度ベクトルあり) は距離がほぼ変わらないとみなし、静止物は前フレームのカメラで距離を求める
        float expected = linZ;
        if (texelFetch(colortex15, texel, 0).a < 0.5) {
            vec3 prevPlayer = screenToPlayer(vec3(texcoord, depth)) + (cameraPosition - previousCameraPosition);
            expected = -(gbufferPreviousModelView * vec4(prevPlayer, 1.0)).z;
        }
        float tol = expected * GI_HISTORY_DEPTH_REL + GI_HISTORY_DEPTH_ABS;
        vec2 pp = prevUv * vec2(screen) - 0.5;
        ivec2 p0 = ivec2(floor(pp));
        vec2 f = pp - vec2(p0);
        float hw = 0.0;
        for (int i = 0; i < 4; i++) {
            ivec2 o = ivec2(i & 1, i >> 1);
            ivec2 p = clamp(p0 + o, ivec2(0), screen - 1);
            vec4 hi = texelFetch(TEX_GI_AUX, p, 0);
            vec2 bw = mix(1.0 - f, f, vec2(o));
            float w = bw.x * bw.y * (hi.r > 0.0 && abs(hi.g - expected) < tol ? 1.0 : 0.0);
            history += hdrFromStorePrev(texelFetch(TEX_GI_HIST, p, 0)) * w;
            info += hi * w;
            hw += w;
        }
        if (hw > GI_HISTORY_MIN_WEIGHT) {
            history /= hw;
            info /= hw;
        } else {
            info = vec4(0.0);
        }
    }
}
#endif

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex1, texel, 0).r;
    if (depth >= 1.0 || isHandDepth(depth)) {
        outHistory = vec4(0.0, 0.0, 0.0, 1.0);
#if GI_DENOISE >= 1
        outHistoryInfo = vec4(0.0);
#endif
        return;
    }
    float linZ = linearizeDepth(depth);
    vec3 normal = readGeoNormal(texel);
    ivec2 screen = ivec2(viewSize());

#if GI_RES == 1
    ivec2 offset = ivec2(0);
    ivec2 center = texel;
    ivec2 lowSize = screen;
    const int scale = 1;
#else
    ivec2 offset = lowResOffset(frameCounter);
    ivec2 center = (texel - offset) / 2;
    ivec2 lowSize = (screen + 1) / 2;
    const int scale = 2;
#endif

#if GI_DENOISE >= 1 && GI_SHORT_HISTORY > 0
    // 履歴の短い画素 (画面の外から入った・遮蔽が外れた・変化を検出した直後) は時間で均せないので、
    // 同じタップ数のまま 2 画素おきに取って空間の幅を広げる (a-trous の 2 段目と同じ形)。長さは前フレームの値なので循環しない
    vec4 history;
    vec4 info;
    reprojectGiHistory(texel, depth, linZ, screen, history, info);
    int tapStep = info.r < float(GI_SHORT_HISTORY) ? 2 : 1;
    #define GI_TAP_OFFSET(o) ((o) * tapStep)
#else
    #define GI_TAP_OFFSET(o) (o)
#endif

    vec4 sum = vec4(0.0);
    vec4 sum2 = vec4(0.0);
    float wsum = 0.0;
    float w2sum = 0.0;
    for (int dy = -GI_FILTER_RADIUS; dy <= GI_FILTER_RADIUS; dy++) {
        for (int dx = -GI_FILTER_RADIUS; dx <= GI_FILTER_RADIUS; dx++) {
            ivec2 L = clamp(center + GI_TAP_OFFSET(ivec2(dx, dy)), ivec2(0), lowSize - 1);
            ivec2 P = min(L * scale + offset, screen - 1);
            float dP = texelFetch(depthtex1, P, 0).r;
            if (dP >= 1.0 || isHandDepth(dP)) continue;
            vec4 raw = hdrFromStore(texelFetch(TEX_GI_RAW, L, 0));
            float wDepth = bilateralDepthWeight(linearizeDepth(dP), linZ, linZ * GI_DEPTH_SIGMA + 0.05);
            float wNormal = bilateralNormalWeight(normal, readGeoNormal(P), GI_NORMAL_POWER);
            float wSpatial = exp(-float(dx * dx + dy * dy) / float(GI_FILTER_RADIUS * GI_FILTER_RADIUS + 1));
            float w = wDepth * wNormal * wSpatial + 1e-5;
            sum += raw * w;
            sum2 += raw * raw * w;
            wsum += w;
            w2sum += w * w;
        }
    }
#if GI_DENOISE >= 1 && GI_SHORT_HISTORY > 0
    // 2 画素おきのタップだけだと、隣り合う画素が別のタップの組を読んで画素ごとの粒が増える。内側の 3x3 を 1 画素おきで足して埋める
    if (tapStep == 2) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) continue;
                ivec2 L = clamp(center + ivec2(dx, dy), ivec2(0), lowSize - 1);
                ivec2 P = min(L * scale + offset, screen - 1);
                float dP = texelFetch(depthtex1, P, 0).r;
                if (dP >= 1.0 || isHandDepth(dP)) continue;
                vec4 raw = hdrFromStore(texelFetch(TEX_GI_RAW, L, 0));
                float wDepth = bilateralDepthWeight(linearizeDepth(dP), linZ, linZ * GI_DEPTH_SIGMA + 0.05);
                float wNormal = bilateralNormalWeight(normal, readGeoNormal(P), GI_NORMAL_POWER);
                // 距離は外側のタップの間隔 (2) を 1 とする単位で、外側と同じ形の重み
                float wSpatial = exp(-0.25 * float(dx * dx + dy * dy) / float(GI_FILTER_RADIUS * GI_FILTER_RADIUS + 1));
                float w = wDepth * wNormal * wSpatial + 1e-5;
                sum += raw * w;
                sum2 += raw * raw * w;
                wsum += w;
                w2sum += w * w;
            }
        }
    }
#endif
    vec4 mean = wsum > 0.0 ? sum / wsum : hdrFromStore(texelFetch(TEX_GI_RAW, clamp(center, ivec2(0), lowSize - 1), 0));
    vec4 result = mean;

#if GI_DENOISE >= 1
    vec4 sigma = momentSigma(sum2, mean, max(wsum, 1e-5));
#if GI_SHORT_HISTORY == 0
    vec4 history = vec4(0.0);
    vec4 info = vec4(0.0);
    vec2 prevUv = getPreviousUv(texcoord, depth);
    if (reprojectionInside(prevUv) && screenHistoryValid()) {
        // 動くもの (速度ベクトルあり) は距離がほぼ変わらないとみなし、静止物は前フレームのカメラで距離を求める
        float expected = linZ;
        if (texelFetch(colortex15, texel, 0).a < 0.5) {
            vec3 prevPlayer = screenToPlayer(vec3(texcoord, depth)) + (cameraPosition - previousCameraPosition);
            expected = -(gbufferPreviousModelView * vec4(prevPlayer, 1.0)).z;
        }
        float tol = expected * GI_HISTORY_DEPTH_REL + GI_HISTORY_DEPTH_ABS;
        vec2 pp = prevUv * vec2(screen) - 0.5;
        ivec2 p0 = ivec2(floor(pp));
        vec2 f = pp - vec2(p0);
        float hw = 0.0;
        for (int i = 0; i < 4; i++) {
            ivec2 o = ivec2(i & 1, i >> 1);
            ivec2 p = clamp(p0 + o, ivec2(0), screen - 1);
            vec4 hi = texelFetch(TEX_GI_AUX, p, 0);
            vec2 bw = mix(1.0 - f, f, vec2(o));
            float w = bw.x * bw.y * (hi.r > 0.0 && abs(hi.g - expected) < tol ? 1.0 : 0.0);
            history += hdrFromStorePrev(texelFetch(TEX_GI_HIST, p, 0)) * w;
            info += hi * w;
            hw += w;
        }
        if (hw > GI_HISTORY_MIN_WEIGHT) {
            history /= hw;
            info /= hw;
        } else {
            info = vec4(0.0);
        }
    }
#endif

    float n = info.r;
    float lumNow = luminance(mean.rgb);
    if (n > 0.0) {
        float lumHist = luminance(history.rgb);
        // 速い履歴: 分散を直接持つ (2 次モーメントの差は fp16 で暗所の桁が落ちる)
        float af = max(1.0 / (n + 1.0), GI_FAST_ALPHA);
        float delta = lumNow - info.b;
        float fastMean = info.b + af * delta;
        float fastVar = (1.0 - af) * (info.a + af * delta * delta);
        // 入力の 1 フレームの揺れは、時間方向の推定と、空間の近傍の標準偏差 x 重みの比 (sqrt(Σw²) / Σw) の大きい方
        float sigmaIn = max(sqrt(fastVar), luminance(sigma.rgb) * sqrt(w2sum) / max(wsum, 1e-5));
        float tau = GI_CHANGE_K * sigmaIn * sqrt(af / (2.0 - af)) + GI_CHANGE_REL * max(fastMean, lumHist) + 1e-5;
        float d = abs(fastMean - lumHist);
        float shrink = min(tau * tau / max(d * d, 1e-12), 1.0);
        n = max(n * shrink, min(n, GI_HISTORY_MIN));
        n = min(n + 1.0, float(GI_HISTORY_MAX));
        result.rgb = mix(history.rgb, mean.rgb, 1.0 / n);
        float aoHist = clamp(history.a, mean.a - sigma.a * GI_HISTORY_CLIP - 1e-3, mean.a + sigma.a * GI_HISTORY_CLIP + 1e-3);
        result.a = mix(aoHist, mean.a, max(1.0 / n, GI_TEMPORAL_ALPHA));
        info = vec4(n, linZ, fastMean, fastVar);
    } else {
        info = vec4(1.0, linZ, lumNow, 0.0);
    }
    outHistoryInfo = info;
#endif

    outHistory = hdrToStore(result);
}
