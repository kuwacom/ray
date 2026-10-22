/*
 * deferred21: 雲の時間アップスケール (colortex10 + 履歴 -> colortex11 フル解像度)
 * - 今フレームに計算されたピクセル: 履歴と強めに混ぜる
 * - それ以外: 低解像度のバイリニア補間と弱く混ぜ、履歴は低解像度近傍の min/max でクランプしてゴーストを抑える
 * 再投影は雲までの距離 (層の入口付近) で行うので、高速移動でも雲がカメラに貼り付かない
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"

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

vec4 fetchLowRes(ivec2 q) {
    return texelFetch(colortex10, clamp(q, ivec2(0), cloudLowResSize() - 1), 0);
}

// 雲の再投影距離。層を通らない (雲の無い) 方向は無限遠として回転だけで戻す
vec2 cloudPreviousUv(vec3 dir) {
    vec2 seg = cloudLayerSegment(cameraPosition.y, dir.y, CLOUD_BASE, CLOUD_TOP);
    if (seg.y > seg.x) {
        float dist = min(seg.x + 0.3 * (seg.y - seg.x), 30000.0 / CLOUD_KH);
        return playerToPrevScreen(dir * dist).xy;
    }
    vec3 prevView = mat3(gbufferPreviousModelView) * dir;
    if (prevView.z >= 0.0) return vec2(-1.0);
    return projectAndDivide(gbufferPreviousProjection, prevView).xy * 0.5 + 0.5;
}

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
        vec4 pad = (hi - lo) * CLOUD_CLAMP_EXPAND + vec4(vec3(1e-4), 0.01);
        bool exact = all(equal(texel, nearest * CLOUD_RES + offset));
        if (exact) current = fetchLowRes(nearest);
        #if CLOUD_RES == 1
            // フル解像度は毎フレームの値がブルーノイズのディザで粗い (夜の雲で 1 フレーム 2 割ほど揺れる)。
            // 隣同士で逆向きに振れるので 3x3 のテントで均してから履歴に入れる (雲は柔らかいので 1 画素のぼけは目立たない)
            current = tent / max(tentWeight, 1.0);
        #endif

        vec3 dir = normalize(viewToPlayerDir(screenToView(vec3(texcoord, 1.0))));
        vec2 prevUv = cloudPreviousUv(dir);
        bool valid = all(greaterThanEqual(prevUv, vec2(0.0))) && all(lessThanEqual(prevUv, vec2(1.0))) && frameData.skyParams[1].y > 1.5;
        if (valid) {
            vec4 history = texture(colortex11, prevUv);
            history = clamp(history, lo - pad, hi + pad);
            current = mix(history, current, exact ? CLOUD_BLEND_EXACT : CLOUD_BLEND_INTERPOLATED);
        }
    #endif
    outClouds = vec4(max(current.rgb, 0.0), saturate(current.a));
#else
    outClouds = vec4(0.0, 0.0, 0.0, 1.0);
#endif
}
