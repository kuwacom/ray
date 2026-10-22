/*
 * composite20: TAA (colortex0 + colortex13 履歴 -> colortex0, colortex13)
 * ジッターは lib/common/jitter.glsl、再投影は lib/post/velocity.glsl の getPreviousUv
 * 手順: 3x3 近傍の統計 (露出込みトーンマップ空間の YCoCg) -> 最も手前の深度で速度を拡張 ->
 *       Catmull-Rom で履歴を読む -> 前フレームの距離でディスオクルージョン判定 -> variance clipping -> 混合
 * colortex13: rgb = 履歴 (露出前の線形 HDR), a = 前フレームのカメラからの距離 (空 = TAA_SKY_DISTANCE, 手 = -1)
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0,13 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outHistory;

/*
 * 露出込みの可逆トーンマップ (Karis 2014)
 * HDR のまま混ぜると明るい画素が履歴を支配してちらつくので、表示に近い空間で混ぜてから戻す
 */
vec3 taaCompress(vec3 c, float exposure) {
    c *= exposure;
    return c / (1.0 + luminance(c));
}

vec3 taaExpand(vec3 c, float exposure) {
    return c / max(1.0 - luminance(c), 1e-3) / exposure;
}

// 履歴を近傍の箱へ「中心に向かって」切り詰める (成分ごとの clamp より色ずれが少ない, Playdead INSIDE)
vec3 clipToBox(vec3 history, vec3 boxMin, vec3 boxMax) {
    vec3 c = 0.5 * (boxMax + boxMin);
    vec3 e = 0.5 * (boxMax - boxMin) + 1e-5;
    vec3 v = history - c;
    float m = maxOf(abs(v / e));
    return m > 1.0 ? c + v / m : history;
}

/*
 * 水面の輝点の割合 (composite1 / composite11 が colortex0.a = 1 + 割合で渡す)
 * 輝点は 1 画素ほどの HDR の点で、トーンマップ空間の近傍の箱と低い混合率では数十フレームかけないと履歴が追いつかず、
 * ブルームに届く前に平らな灰色へ潰れていた。輝点の分は箱の統計と履歴から外し、TAA の結果に今フレームの値を足す
 * (位置はワールドに固定してあり、ジッターで動かないので TAA を通さなくても静止時はちらつかない)
 */
float glintShare(float a) { return clamp(a - 1.0, 0.0, 1.0); }

// colortex13.a に書く「このピクセルの距離」
float historyDistance(vec2 uv, float depth) {
    if (isHandDepth(depth)) return -1.0;
    if (depth >= 1.0) return TAA_SKY_DISTANCE;
    return length(screenToPlayer(vec3(uv, depth)));
}

// 前フレームにこの点があったなら履歴の距離 stored と一致するはず
bool historyMatches(float stored, float expected, float tolerance) {
    if (expected < 0.0) return stored < 0.0;
    if (expected >= TAA_SKY_DISTANCE) return stored >= TAA_SKY_DISTANCE * 0.5;
    if (stored < 0.0) return false;
    return abs(stored - expected) <= expected * tolerance + 0.05;
}

// 前フレームのカメラから見た距離の予想値 (手 = -1, 空 = TAA_SKY_DISTANCE)
float expectedPreviousDistance(vec2 uv, float depth, out float tolerance) {
    tolerance = TAA_DEPTH_TOLERANCE;
    if (isHandDepth(depth)) return -1.0;
    if (depth >= 1.0) return TAA_SKY_DISTANCE;
    // 動くエンティティは前フレームの位置が分からないので、今の距離を緩い許容で比べる
    if (texture(colortex15, uv).a > 0.5) {
        tolerance = TAA_DEPTH_TOLERANCE * 4.0;
        return length(screenToPlayer(vec3(uv, depth)));
    }
    return getPreviousViewDistance(uv, depth);
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 maxTexel = ivec2(viewSize()) - 1;
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    vec2 unjitteredUv = uv - taaJitterUv();
    float exposure = getExposure();

    vec4 centerRaw = texelFetch(colortex0, texel, 0);
    vec3 centerColor = sanitizeColor(centerRaw.rgb);
    vec3 centerGlint = centerColor * glintShare(centerRaw.a);
    centerColor -= centerGlint;
    float centerDepth = texelFetch(depthtex0, texel, 0).r;

    // 3x3 近傍の統計と、最も手前の深度 (エッジでは手前の物体の速度を使うと輪郭のゴーストが減る)
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    vec3 boxMin = vec3(1e9);
    vec3 boxMax = vec3(-1e9);
    float closestDepth = centerDepth;
    ivec2 closestOffset = ivec2(0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 p = clamp(texel + ivec2(x, y), ivec2(0), maxTexel);
            vec4 s = texelFetch(colortex0, p, 0);
            vec3 c = rgbToYCoCg(taaCompress(sanitizeColor(s.rgb) * (1.0 - glintShare(s.a)), exposure));
            m1 += c;
            m2 += c * c;
            boxMin = min(boxMin, c);
            boxMax = max(boxMax, c);
            float d = texelFetch(depthtex0, p, 0).r;
            if (d < closestDepth) {
                closestDepth = d;
                closestOffset = ivec2(x, y);
            }
        }
    }
    vec3 mean = m1 / 9.0;
    vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
    vec3 currentYcc = rgbToYCoCg(taaCompress(centerColor, exposure));

    vec2 closestUv = uv + vec2(closestOffset) * texelSize();
    vec2 prevUv = uv + (getPreviousUv(closestUv, closestDepth) - closestUv);
    float motionPx = length((prevUv - uv) * viewSize());

    bool valid = all(greaterThanEqual(prevUv, vec2(0.0))) && all(lessThanEqual(prevUv, vec2(1.0)));

    vec3 history = vec3(0.0);
    if (valid) {
        // ディスオクルージョン: 履歴の 2x2 の距離のどれかが、中心か最も手前の点の予想距離と合えば有効
        float tolCenter, tolClosest;
        float expCenter = expectedPreviousDistance(unjitteredUv, centerDepth, tolCenter);
        float expClosest = expectedPreviousDistance(closestUv - taaJitterUv(), closestDepth, tolClosest);
        ivec2 base = ivec2(floor(prevUv * viewSize() - 0.5));
        bool matched = false;
        for (int i = 0; i < 4; i++) {
            ivec2 p = clamp(base + ivec2(i & 1, i >> 1), ivec2(0), maxTexel);
            float stored = texelFetch(colortex13, p, 0).a;
            matched = matched || historyMatches(stored, expCenter, tolCenter) || historyMatches(stored, expClosest, tolClosest);
        }
        valid = matched;
        history = sanitizeColor(sampleCatmullRom(colortex13, prevUv, viewSize()));
    }

    vec3 resultYcc;
    if (valid) {
        float motion = saturate(motionPx / 4.0);
        float gamma = mix(TAA_GAMMA_STATIC, TAA_GAMMA_MOVING, motion);
        /*
         * 静止時は分散の箱だけで切る。min-max の箱と重ねると、ジッターで近傍の極値が毎フレーム入れ替わる高コントラストの
         * テクスチャ (自動法線の付いた石・鉱石) で履歴が毎フレーム別の値に切り詰められ、静止していてもテクセル単位でちらつく
         * 動いている時はゴーストを減らすため min-max の箱とも重ねる
         */
        vec3 clipMin = mean - gamma * sigma;
        vec3 clipMax = mean + gamma * sigma;
        if (motion > 0.0) {
            clipMin = mix(clipMin, max(boxMin, clipMin), motion);
            clipMax = mix(clipMax, min(boxMax, clipMax), motion);
        }
        vec3 historyYcc = clipToBox(rgbToYCoCg(taaCompress(history, exposure)), clipMin, clipMax);

        float alpha = mix(TAA_BLEND_STATIC, TAA_BLEND_MOVING, saturate(motionPx / 6.0));
        if (isHandDepth(centerDepth)) alpha = max(alpha, TAA_BLEND_HAND);
        resultYcc = mix(historyYcc, currentYcc, alpha);
    } else {
        // 履歴が無い所は 1 フレームだけなのでジャギーが目立つ。近傍平均へ少し寄せて和らげる
        resultYcc = mix(currentYcc, mean, 0.3);
    }

    vec3 result = sanitizeColor(taaExpand(yCoCgToRgb(resultYcc), exposure));
    // 輝点は履歴に入れず、今フレームの値を足す (a は以降のパスでは使わないので 1 に戻す)
    // a < 0 は溶岩の発光の割合 (composite11)。モーションブラー・DoF を素通りしてブルームの縮小 (composite23) が読む
    outColor = vec4(result + centerGlint, min(centerRaw.a, 0.0));
    outHistory = vec4(result, historyDistance(unjitteredUv, centerDepth));
}
