/*
 * deferred21: 雲の時間アップスケール (TEX_CLOUD_LOW + 履歴 -> colortex11 フル解像度)
 * - 今フレームに計算されたピクセル: 履歴と強めに混ぜる
 * - それ以外: 低解像度のバイリニア補間と弱く混ぜ、履歴は低解像度近傍の min/max でクランプしてゴーストを抑える
 * 再投影は雲までの距離 (層の入口付近) で行うので、高速移動でも雲がカメラに貼り付かない
 * sky モジュール (lib/sky)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/temporal.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/buffers/slots.glsl"
//@include "/lib/common/pre_exposure.glsl"
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
#include "/lib/common/temporal.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/polarizer.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/common/pre_exposure.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/buffers/slots.glsl"
// END GENERATED includes

in vec2 texcoord;

/* RENDERTARGETS: 11 */
layout(location = 0) out vec4 outClouds;

// 今フレームに計算したピクセル / 補間しただけのピクセルの、新しい値の混合率
// 補間値 (低解像度のバイリニア) を混ぜるほど縁がにじむので、補間ピクセルは履歴をほぼ保ち (ゴーストは近傍クランプで抑える)、
// 計算したピクセルは強めに入れ替えて縁のシャープさを保つ。フル解像度 (CLOUD_RES 1) は後段の TAA でも積むので軽めに
// 0.3 では静止していても雲に画素単位の粒が残り、夜の露出で持ち上がると目立った (月の周りの前方散乱の強い縁ほど粗い)。
// 粒は 3 秒で入れ替わる時間方向のノイズの残り (動かない模様ではない) なので、履歴を長く持たせて均す。
// 風で流れる雲の縁のにじみは近傍クランプで抑える
const float CLOUD_BLEND_EXACT = CLOUD_RES == 1 ? 0.05 : 0.6;
const float CLOUD_BLEND_INTERPOLATED = 0.03;
// 近傍クランプの箱をノイズ分だけ広げる割合 (狭いとディザのノイズで履歴が揺れる)
const float CLOUD_CLAMP_EXPAND = CLOUD_RES == 1 ? 1.0 : 0.5;
const vec4 CLOUD_CLAMP_PAD = vec4(vec3(1e-4), 0.01);
#if CLOUD_MOTION > 0
// 動き・雲の中 (CLOUD_MOTION): 視差で履歴の平均が許す画素数までしかずれないよう、今フレームの重みの下限を上げる (lagWeight)。
// 補間画素が無く履歴が長い CLOUD_RES 1 はノイズが出やすいので多めに許し、補間画素の多い CLOUD_RES 4 は階段が見えやすいので少なめにする
const float CLOUD_LAG_TOLERANCE = CLOUD_RES == 1 ? 1.5 : (CLOUD_RES == 2 ? 1.0 : 0.75);
// 重みの下限が高い画素の近傍クランプの箱の広がりの倍率 (箱を広げるのは、ノイズで揺れる履歴を残すための処置)
const float CLOUD_CLAMP_MOVING_SHRINK = 0.25;
#endif

vec4 fetchLowRes(ivec2 q) {
    return hdrFromStore(texelFetch(TEX_CLOUD_LOW, clamp(q, ivec2(0), cloudLowResSize() - 1), 0));
}

// 層の区間 seg の雲を戻す距離 (ワールド)
float cloudReprojectionDistance(vec2 seg) {
    float dist = min(seg.x + 0.3 * (seg.y - seg.x), 30000.0 / CLOUD_KH);
    #ifndef CLOUD_VANILLA_SHAPE
    // 層の中では雲のマーチが手前を細かく歩き、見える雲の多くが手前にあるので、手前の区間の中ほどで戻す (層の 3 割の距離では動くと手前の雲がずれる)
    if (seg.x <= 0.0) dist = 0.5 * min(seg.y, CLOUD_NEAR_LENGTH);
    #endif
    return dist;
}

// 雲の再投影距離。層を通らない (雲の無い) 方向は無限遠として回転だけで戻す
vec2 cloudPreviousUv(vec3 dir) {
    vec2 seg = cloudPrimarySegment(cameraPosition.y, dir.y);
    if (seg.y > seg.x) {
        return playerToPreviousScreen(dir * cloudReprojectionDistance(seg)).xy;
    }
    vec3 prevView = mat3(gbufferPreviousModelView) * dir;
    if (prevView.z >= 0.0) return vec2(-1.0);
    return projectAndDivide(gbufferPreviousProjection, prevView).xy * 0.5 + 0.5;
}

#if CLOUD_MOTION == 1
/*
 * 履歴の重みの下限 trust (1 フレームあたりの実効の重み) を、画素ごとの今フレームの重みにする
 * CLOUD_RES 2 以上は CLOUD_RES^2 フレームに 1 回、計算した画素を強く入れ替える (CLOUD_BLEND_EXACT) ので、補間画素の重みを trust にそろえると
 * 履歴を短くしすぎてノイズが出る。巡回の実効の重みが trust になる補間画素の重みを解く:
 * (1 - wInterp)^(n - 1) (1 - wExact) = (1 - trust)^n、n = CLOUD_RES^2。trust = 0 は従来の重み、1 は履歴を使わない
 */
float cloudBlend(bool exact, float trust) {
    float wExact = max(CLOUD_BLEND_EXACT, trust);
    if (exact || CLOUD_RES == 1) return wExact;
    const float CYCLE = float(CLOUD_RES * CLOUD_RES);
    float keep = min(pow(1.0 - trust, CYCLE) / max(1.0 - wExact, 1e-4), 1.0);
    return max(1.0 - pow(keep, 1.0 / (CYCLE - 1.0)), CLOUD_BLEND_INTERPOLATED);
}

/*
 * 視線 dir の雲の履歴を、今フレームにどれだけ譲るか (0 = 従来の重みのまま、1 = 履歴を使わない)
 * 戻す距離 D (cloudReprojectionDistance) と、近い雲までの距離 s の食い違いが、カメラの平行移動で出す位置のずれから決める。
 * s は層の外なら層の入口、層の中は prepare2 の見積もり (skyParams[1].w)。止まっている時と層を通らない視線は 0
 */
float cloudHistoryTrust(vec3 dir) {
    vec2 seg = cloudPrimarySegment(cameraPosition.y, dir.y);
    if (seg.y <= seg.x) return 0.0;
    float inside = frameData.skyParams[1].w > 0.0 ? frameData.skyParams[1].w : CLOUD_MOTION_GAP_DISTANCE;
    float nearest = seg.x > 0.0 ? seg.x : inside;
    return lagWeight(parallaxPx(dir, 1.0 / cloudReprojectionDistance(seg), 1.0 / max(nearest, 1.0)), CLOUD_LAG_TOLERANCE);
}
#endif

void main() {
#if CLOUDS >= 2 && defined HAS_SKY
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 offset = cloudSampleOffset(frameCounter);

    // 低解像度テクセル q のサンプル位置はフル解像度の q*R + offset。それを整数格子とする座標
    vec2 lowPos = (vec2(texel) - vec2(offset)) / float(CLOUD_RES);
    ivec2 base = ivec2(floor(lowPos));
    vec2 f = lowPos - vec2(base);
    vec4 c00 = fetchLowRes(base);
    vec4 c10 = fetchLowRes(base + ivec2(1, 0));
    vec4 c01 = fetchLowRes(base + ivec2(0, 1));
    vec4 c11 = fetchLowRes(base + ivec2(1, 1));
    vec4 current = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);

    #ifdef CLOUD_TEMPORAL
        ivec2 nearest = ivec2(round(lowPos));
        vec4 lo = vec4(1e9), hi = vec4(-1e9);
        vec4 tent = vec4(0.0);
        float tentWeight = 0.0;
        bool centerSky = texelFetch(depthtex1, texel, 0).r >= 1.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec4 s = fetchLowRes(nearest + ivec2(x, y));
                lo = min(lo, s);
                hi = max(hi, s);
                #if CLOUD_RES == 1
                    // 空と地形の境目をまたいで混ぜない (地形の輪郭に雲がにじむ)
                    ivec2 p = clamp(texel + ivec2(x, y), ivec2(0), ivec2(viewSize()) - 1);
                    float w = float((2 - abs(x)) * (2 - abs(y))) * float((texelFetch(depthtex1, p, 0).r >= 1.0) == centerSky);
                    tent += s * w;
                    tentWeight += w;
                #endif
            }
        }
        vec4 pad = neighborBoxMargin(lo, hi, CLOUD_CLAMP_EXPAND, CLOUD_CLAMP_PAD);
        bool exact = all(equal(texel, nearest * CLOUD_RES + offset));
        if (exact) current = fetchLowRes(nearest);
        #if CLOUD_RES == 1
            // フル解像度は毎フレームの値がブルーノイズのディザで粗い (夜の雲で 1 フレーム 2 割ほど揺れる)。
            // 隣同士で逆向きに振れるので 3x3 のテントで均してから履歴に入れる (雲は柔らかいので 1 画素のぼけは目立たない)
            current = tent / max(tentWeight, 1.0);
        #endif

        // CLOUD_MOTION 2 は履歴を使わない (今フレームの低解像度の補間だけ)
        #if CLOUD_MOTION != 2
        vec3 dir = normalize(viewToPlayerDir(screenToView(vec3(texcoord, 1.0))));
        vec2 prevUv = cloudPreviousUv(dir);
        bool valid = reprojectionInside(prevUv) && screenHistoryValid() && frameData.skyParams[1].y > 1.5;
        if (valid) {
            #if CLOUD_MOTION == 1
            float trust = cloudHistoryTrust(dir);
            vec4 history = hdrFromStorePrev(sampleCatmullRom4(colortex11, prevUv, viewSize()));
            pad = neighborBoxMargin(lo, hi, CLOUD_CLAMP_EXPAND * mix(1.0, CLOUD_CLAMP_MOVING_SHRINK, trust), CLOUD_CLAMP_PAD);
            #else
            vec4 history = hdrFromStorePrev(texture(colortex11, prevUv));
            #endif
            history = clamp(history, lo - pad, hi + pad);
            float blend = exact ? CLOUD_BLEND_EXACT : CLOUD_BLEND_INTERPOLATED;
            #if CLOUD_MOTION == 1
            blend = cloudBlend(exact, trust);
            #endif
            current = mix(history, current, blend);
        }
        #endif
    #endif
    outClouds = vec4(hdrToStore(max(current.rgb, 0.0)), saturate(current.a));
#else
    outClouds = vec4(0.0, 0.0, 0.0, 1.0);
#endif
}
