/*
 * deferred2: ブロックライト直接光のアップサンプル + 時空間デノイズ
 * 入力: blockLightRawImg / blockLightAuxImg (deferred1), colortex7 (履歴)  出力: colortex6 (今フレーム), colortex7 (履歴)
 *
 * 比の推定 (lib/light/light_select.glsl の説明参照):
 *   可視率 R = Σw S / Σw U を低解像度の近傍から深度・法線のエッジ停止付きで集め (空間)、
 *   再投影した前フレームの R と分散クリップ付きで混ぜる (時間)。
 *   最後にフル解像度・テクスチャ法線で求めた影なし照度に R を掛けて colortex6 に書く
 * colortex7: rgb = 可視率 R, a = 視線方向の距離 (再投影時の遮蔽判定用)
 * LIGHT_DENOISE: 0 = 最寄りの 1 サンプルのみ, 1 = 2x2 + 時間, 2 = 4x4 + 時間
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"
#include "/lib/post/post.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 6,7 */
layout(location = 0) out vec4 outBlockLight;
layout(location = 1) out vec4 outHistory;

#if LIGHT_DENOISE >= 2
    const int TAP_MIN = -1;
    const int TAP_MAX = 2;
    const float SPATIAL_SIGMA = 1.0;
    const float TEMPORAL_ALPHA = 0.1;
#else
    const int TAP_MIN = 0;
    const int TAP_MAX = 1;
    const float SPATIAL_SIGMA = 0.7;
    const float TEMPORAL_ALPHA = 0.15;
#endif
// 深度の許容 (視線距離に対する比 + 固定分)、法線の鋭さ
const float DEPTH_TOLERANCE_REL = 0.03;
const float DEPTH_TOLERANCE_ABS = 0.05;
const float NORMAL_POWER = 16.0;
// 履歴の分散クリップの幅 (標準偏差の倍数) と最低限の幅
const float CLIP_GAMMA = 1.5;
const float CLIP_MIN_WIDTH = 0.05;
// 履歴の深度の許容 (再投影の遮蔽判定)
const float HISTORY_DEPTH_REL = 0.05;
const float HISTORY_DEPTH_ABS = 0.1;

// 比の安定化: 輝度の比を下地にして、ある色成分の U がほぼ 0 でも発散しない
vec3 safeRatio(vec3 s, vec3 u) {
    float lu = luminance(u);
    float lr = luminance(s) / max(lu, 1e-8);
    float k = 0.02 * lu + 1e-7;
    return saturate((s + k * lr) / (u + k));
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex0, texel, 0).r;
    if (depth >= 1.0) {
        outBlockLight = vec4(0.0);
        outHistory = vec4(1.0, 1.0, 1.0, 0.0);
        return;
    }
    float hd = fixHandDepth(depth);
    vec3 viewPos = screenToView(vec3(texcoord, hd));
    vec3 playerPos = viewToPlayer(viewPos);
    float viewDist = -viewPos.z;
    vec4 c2 = texelFetch(colortex2, texel, 0);
    vec3 normal = octDecode(c2.rg);
    vec3 geoNormal = octDecode(unpack2x8(c2.b));

    vec3 voxelPos = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);
    vec3 full = sumBinLightsUnshadowed(voxelPos, normal, geoNormal);
    if (maxOf(full) <= 0.0) {
        outBlockLight = vec4(0.0, 0.0, 0.0, 1.0);
        outHistory = vec4(1.0, 1.0, 1.0, viewDist);
        return;
    }

    // ---- 空間: 低解像度サンプルの深度・法線付き重み付き和 ----
    ivec2 offset = traceFrameOffset(frameCounter);
    ivec2 lowSize = traceLowSize();
    vec2 lp = vec2(texel - offset) / float(LIGHT_TRACE_RES);
    vec3 ratio;
    vec3 mean = vec3(1.0);
    vec3 sigma = vec3(0.0);

#if LIGHT_DENOISE == 0
    {
        ivec2 l = traceNearestLow(texel, frameCounter);
        ratio = safeRatio(texelFetch(blockLightRawSampler, l, 0).rgb, texelFetch(blockLightAuxSampler, l, 0).rgb);
    }
#else
    ivec2 l0 = ivec2(floor(lp));
    vec3 sumS = vec3(0.0), sumU = vec3(0.0);
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    float wStat = 0.0;
    vec3 nearestRatio = vec3(1.0);
    float nearestD = 1e9;
    float depthTol = viewDist * DEPTH_TOLERANCE_REL + DEPTH_TOLERANCE_ABS;
    for (int y = TAP_MIN; y <= TAP_MAX; y++)
    for (int x = TAP_MIN; x <= TAP_MAX; x++) {
        ivec2 l = l0 + ivec2(x, y);
        if (any(lessThan(l, ivec2(0))) || any(greaterThanEqual(l, lowSize))) continue;
        vec4 raw = texelFetch(blockLightRawSampler, l, 0);
        if (raw.a < 0.0) continue;
        vec3 u = texelFetch(blockLightAuxSampler, l, 0).rgb;
        ivec2 src = traceSourceTexel(l, frameCounter);
        vec3 n = octDecode(unpack2x8(texelFetch(colortex2, src, 0).b));
        vec2 d = vec2(l) - lp;
        float d2 = dot(d, d);
        float w = exp(-d2 / (2.0 * SPATIAL_SIGMA * SPATIAL_SIGMA));
        w *= exp(-abs(raw.a - viewDist) / depthTol);
        w *= pow(saturate(dot(n, geoNormal)), NORMAL_POWER);
        vec3 r = safeRatio(raw.rgb, u);
        if (d2 < nearestD) { nearestD = d2; nearestRatio = r; }
        if (w < 1e-4) continue;
        sumS += raw.rgb * w;
        sumU += u * w;
        if (luminance(u) > 0.0) {
            m1 += r * w;
            m2 += r * r * w;
            wStat += w;
        }
    }
    ratio = luminance(sumU) > 0.0 ? safeRatio(sumS, sumU) : nearestRatio;
    if (wStat > 1e-4) {
        mean = m1 / wStat;
        sigma = sqrt(max(m2 / wStat - mean * mean, 0.0));
    } else {
        mean = ratio;
    }

    // ---- 時間: 再投影 + 遮蔽判定 + 分散クリップ ----
    vec2 prevUv = getPreviousUv(texcoord, hd);
    if (all(greaterThanEqual(prevUv, vec2(0.0))) && all(lessThan(prevUv, vec2(1.0)))) {
        // 動くもの (速度ベクトルあり) は距離がほぼ変わらないとみなし、静止物は前フレームのカメラで距離を求める
        float expected = viewDist;
        if (texture(colortex15, texcoord).a < 0.5) {
            vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
            expected = -(gbufferPreviousModelView * vec4(prevPlayer, 1.0)).z;
        }
        float tol = expected * HISTORY_DEPTH_REL + HISTORY_DEPTH_ABS;
        vec2 pp = prevUv * viewSize() - 0.5;
        ivec2 p0 = ivec2(floor(pp));
        vec2 f = pp - vec2(p0);
        vec3 hist = vec3(0.0);
        float hw = 0.0;
        for (int i = 0; i < 4; i++) {
            ivec2 o = ivec2(i & 1, i >> 1);
            ivec2 p = clamp(p0 + o, ivec2(0), ivec2(viewSize()) - 1);
            vec4 h = texelFetch(colortex7, p, 0);
            vec2 bw = mix(1.0 - f, f, vec2(o));
            float w = bw.x * bw.y * (abs(h.a - expected) < tol ? 1.0 : 0.0);
            hist += h.rgb * w;
            hw += w;
        }
        if (hw > 0.05) {
            hist /= hw;
            vec3 width = max(sigma * CLIP_GAMMA, vec3(CLIP_MIN_WIDTH));
            hist = clamp(hist, mean - width, mean + width);
            ratio = mix(hist, ratio, TEMPORAL_ALPHA);
        }
    }
#endif

    ratio = saturate(ratio);
    outBlockLight = vec4(full * ratio, 1.0);
    outHistory = vec4(ratio, viewDist);
}
