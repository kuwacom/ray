/*
 * composite20: TAA (colortex0 + colortex13 履歴 -> colortex0, colortex13)
 * ジッターは lib/common/jitter.glsl、再投影は lib/post/velocity.glsl の getPreviousUv
 * 手順: 3x3 近傍の統計 (露出込みトーンマップ空間の YCoCg) -> 最も手前の深度で速度を拡張 ->
 *       Catmull-Rom で履歴を読む -> 前フレームの距離でディスオクルージョン判定 -> variance clipping -> 混合
 * colortex13: rgb = 履歴 (露出前の線形 HDR), a = 前フレームのカメラからの距離 (空 = TAA_SKY_DISTANCE, 手 = -1)
 * post モジュール (lib/post)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/exposure.glsl"
//@include "/lib/common/temporal.glsl"
//@include "/lib/post/post_internal.glsl"
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
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/exposure.glsl"
#include "/lib/common/temporal.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/post/velocity.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/post.glsl"
#include "/lib/post/post_constants.glsl"
#include "/lib/post/lens_presets.glsl"
#include "/lib/post/sampling.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/post/camera.glsl"
#include "/lib/post/grading.glsl"
#include "/lib/post/color_grade.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/post/lens_optics.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/post/lens_ghosts.glsl"
#include "/lib/post/lens_flare.glsl"
#include "/lib/post/lens.glsl"
#include "/lib/post/post_internal.glsl"
// END GENERATED includes

in vec2 texcoord;

#ifdef SPECULAR_SPARKLE
/* RENDERTARGETS: 0,13,17 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outHistory;
layout(location = 2) out vec4 outSparkle;
#else
/* RENDERTARGETS: 0,13 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outHistory;
#endif

const float TAA_HISTORY_DEPTH_ABS = 0.05;      // 履歴の距離の許容の固定分 (ブロック)。距離に比例した分を足す
const float TAA_MOVING_TOLERANCE_SCALE = 4.0;  // 動くエンティティの距離の許容の倍率
const float TAA_CLIP_MOTION_PX = 4.0;         // 動きがこの画素数で履歴の切り詰めが動き用に切り替わる
const float TAA_BLEND_MOTION_PX = 6.0;        // 動きがこの画素数で履歴の混ぜ方が動き用になる
const float TAA_NO_HISTORY_MEAN_BLEND = 0.3;  // 履歴が無い所で近傍平均へ寄せる割合
const float TAA_NEIGHBOR_COUNT = 9.0;         // 近傍の統計に使うサンプル数 (3x3)

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
 * 鏡面の白飛び分の割合 (deferred30 / composite2 / composite19 が colortex0.a = 1 + 割合で渡す)
 * 白を超えた分は 1 画素ほどの HDR の点になり、トーンマップ空間の近傍の箱と低い混合率では数十フレームかけないと履歴が追いつかず、
 * ブルームに届く前に平らな灰色へ潰れる。この分は箱の統計と本体の履歴から外し、線形のまま専用の短い履歴 (colortex17) で混ぜて足す
 * 位置は法線の反射で決まり、白より下は TAA を通すので輪郭はアンチエイリアスされる
 */
float sparkleShare(float a) { return clamp(a - 1.0, 0.0, 1.0); }

/*
 * 鏡面の白飛び分の時間積分。今フレームの値をそのまま足すと、1 画素未満の照り返しはジッターの当たり外れ、影の縁のディザ、
 * 雨の波紋の入れ替わりのまま毎フレーム点滅し、ブルーム・光条・玉ボケごと明滅する。カメラのシャッターと同じく線形の
 * 平均で混ぜるので、平均のエネルギーは変わらず点も消えない (トーンマップ空間で混ぜると明るい点ほど潰れる)
 * 近傍の箱による切り詰めは掛けない (掛けると当たり外れの点が履歴ごと消えて点滅に戻る)。尾は混合率で数フレームに収める
 * 混合率はフレーム単位 (秒にすると低いフレームレートで 1 に寄って点滅に戻る)
 * 上だけは今フレームの 3x3 の白飛び分の最大で抑える。波が動いて消えた照り返しの点が、混合率の尾の間だけ残像のように残らない
 * (画素の中で位置が揺れる点は 3x3 のどこかにあるので抑えられない)
 */
const float SPARKLE_HISTORY_BLEND = 0.4;         // 静止時の今フレームの重み (尾は 0.6^n、4 フレームで 13%)
const float SPARKLE_HISTORY_BLEND_MOVING = 0.7;  // 動きが TAA_BLEND_MOTION_PX の時

/*
 * 今フレームのバッファの位置 pos (画素) の白飛び分を双線形で集める。ジッターを外した位置で読むので、
 * 照り返しの点はフレームごとにずれず、サブピクセルの位置へ重みで配られる (4 つの重みの和は 1 で、全体の量は変わらない)
 */
vec3 gatherSparkle(vec2 pos, ivec2 maxTexel) {
    vec2 b = pos - 0.5;
    ivec2 b0 = ivec2(floor(b));
    vec2 bf = b - vec2(b0);
    vec3 sparkle = vec3(0.0);
    for (int i = 0; i < 4; i++) {
        ivec2 o = ivec2(i & 1, i >> 1);
        vec4 s = texelFetch(colortex0, clamp(b0 + o, ivec2(0), maxTexel), 0);
        float w = (o.x == 1 ? bf.x : 1.0 - bf.x) * (o.y == 1 ? bf.y : 1.0 - bf.y);
        sparkle += sanitizeColor(s.rgb) * sparkleShare(s.a) * w;
    }
    return sparkle;
}

/*
 * 白飛び分の履歴と混ぜて、出力の色・a・履歴を書く。a は TAA の後では「正 = 白飛び分の割合、負 = 溶岩の発光の割合」
 * (同じ画素で両方は起きない。ブルームの縮小は負の側だけを読む)
 */
void writeTaaOutput(vec3 result, vec3 sparkleNow, vec3 sparkleMax, vec2 prevUv, bool valid, float motionPx, float rawA, float historyDist) {
#ifdef SPECULAR_SPARKLE
    vec3 sparkleHist = valid ? max(sanitizeColor(textureLod(colortex17, prevUv, 0.0).rgb), 0.0) : vec3(0.0);
    sparkleHist = min(sparkleHist, max(sparkleMax, sparkleNow));
    float sa = valid ? mix(SPARKLE_HISTORY_BLEND, SPARKLE_HISTORY_BLEND_MOVING, saturate(motionPx / TAA_BLEND_MOTION_PX)) : 1.0;
    vec3 sparkle = mix(sparkleHist, sparkleNow, sa);
    outSparkle = vec4(sparkle, 0.0);
#else
    vec3 sparkle = sparkleNow;
#endif
    vec3 color = result + sparkle;
    float share = saturate(luminance(sparkle) / max(luminance(color), 1e-6));
    outColor = vec4(color, rawA < 0.0 ? rawA : share);
    outHistory = vec4(result, historyDist);
}

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
    return abs(stored - expected) <= expected * tolerance + TAA_HISTORY_DEPTH_ABS;
}

// 前フレームのカメラから見た距離の予想値 (手 = -1, 空 = TAA_SKY_DISTANCE)
float expectedPreviousDistance(vec2 uv, float depth, out float tolerance) {
    tolerance = TAA_DEPTH_TOLERANCE;
    if (isHandDepth(depth)) return -1.0;
    if (depth >= 1.0) return TAA_SKY_DISTANCE;
    // 動くエンティティは前フレームの位置が分からないので、今の距離を緩い許容で比べる
    if (texture(colortex15, uv).a > 0.5) {
        tolerance = TAA_DEPTH_TOLERANCE * TAA_MOVING_TOLERANCE_SCALE;
        return length(screenToPlayer(vec3(uv, depth)));
    }
    return getPreviousViewDistance(uv, depth);
}

// ディスオクルージョン: 履歴の 2x2 の距離のどれかが、中心か最も手前の点の予想距離と合えば有効
bool taaHistoryValid(vec2 prevUv, ivec2 maxTexel, float expCenter, float tolCenter, float expClosest, float tolClosest) {
    ivec2 base = ivec2(floor(prevUv * viewSize() - 0.5));
    bool matched = false;
    for (int i = 0; i < 4; i++) {
        ivec2 p = clamp(base + ivec2(i & 1, i >> 1), ivec2(0), maxTexel);
        float stored = texelFetch(colortex13, p, 0).a;
        matched = matched || historyMatches(stored, expCenter, tolCenter) || historyMatches(stored, expClosest, tolClosest);
    }
    return matched;
}

// 履歴 (線形 HDR) を近傍の統計 (平均・標準偏差・min/max) の箱へ切り詰めて YCoCg で返す
vec3 taaClipHistory(vec3 history, float exposure, vec3 mean, vec3 sigma, vec3 boxMin, vec3 boxMax, float motionPx) {
    float motion = saturate(motionPx / TAA_CLIP_MOTION_PX);
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
    return clipToBox(rgbToYCoCg(taaCompress(history, exposure)), clipMin, clipMax);
}

float taaBlendAlpha(float motionPx, float centerDepth) {
    float alpha = mix(TAA_BLEND_STATIC, TAA_BLEND_MOVING, saturate(motionPx / TAA_BLEND_MOTION_PX));
    if (isHandDepth(centerDepth)) alpha = max(alpha, TAA_BLEND_HAND);
    return alpha;
}

// center の周り 3x3 の統計 (露出込みの YCoCg の平均・標準偏差・min/max) と、最も手前の深度とその位置
struct TaaNeighborhood {
    vec3 mean;
    vec3 sigma;
    vec3 boxMin;
    vec3 boxMax;
    float closestDepth;
    ivec2 closestOffset;
    vec3 sparkleMax;    // 白飛び分の最大 (線形)
};

TaaNeighborhood taaNeighborhood(ivec2 center, ivec2 maxTexel, float exposure, float centerDepth) {
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    TaaNeighborhood nb;
    nb.boxMin = vec3(1e9);
    nb.boxMax = vec3(-1e9);
    nb.closestDepth = centerDepth;
    nb.closestOffset = ivec2(0);
    nb.sparkleMax = vec3(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            ivec2 p = clamp(center + ivec2(x, y), ivec2(0), maxTexel);
            vec4 s = texelFetch(colortex0, p, 0);
            vec3 sc = sanitizeColor(s.rgb);
            nb.sparkleMax = max(nb.sparkleMax, sc * sparkleShare(s.a));
            vec3 c = rgbToYCoCg(taaCompress(sc * (1.0 - sparkleShare(s.a)), exposure));
            m1 += c;
            m2 += c * c;
            nb.boxMin = min(nb.boxMin, c);
            nb.boxMax = max(nb.boxMax, c);
            float d = texelFetch(depthtex0, p, 0).r;
            if (d < nb.closestDepth) {
                nb.closestDepth = d;
                nb.closestOffset = ivec2(x, y);
            }
        }
    }
    nb.mean = m1 / TAA_NEIGHBOR_COUNT;
    nb.sigma = momentSigma(m2, nb.mean, TAA_NEIGHBOR_COUNT);
    return nb;
}

/*
 * 歪曲・魚眼を TAA の中で組み立てる (LENS_WARP_TAA, lib/post/lens.glsl)
 * 出力 (再投影後) の画素ごとに、写っている元画像の点を今フレーム (ジッター込み) から読み、出力の座標の履歴に積む
 * 魚眼の中央は元画像を 2 倍以上に引き伸ばすので、1 フレームの補間ではぼける。ジッターで毎フレーム違う所に来る
 * 元の画素のうち、出力の画素の中心に近いものほど強く混ぜると、静止時は元画像より細かい像が履歴に溜まる (時間方向の超解像)
 * 再投影: 出力 uv -> 元 uv -> 深度 -> 前フレームの元 uv -> lensForwardUv で前フレームの出力 uv
 */
void taaWarped() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 maxTexel = ivec2(viewSize()) - 1;
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    float rho;
    vec2 src = lensProjectUv(uv, rho);
    // 出力の 1 画素が元画像の何画素に当たるか (微分は早期 return の前に取る)
    vec2 srcPx = src * viewSize();
    float footprint = max(length(dFdx(srcPx)), length(dFdy(srcPx)));
    if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) {
        // 魚眼の「横幅に合わせる」の隅 (描画の範囲外)。final が黒にする
        outColor = vec4(0.0);
        outHistory = vec4(0.0, 0.0, 0.0, TAA_SKY_DISTANCE);
#ifdef SPECULAR_SPARKLE
        outSparkle = vec4(0.0);
#endif
        return;
    }
    float exposure = getExposure();
    vec2 jitter = taaJitterUv();

    // 今フレームのバッファの上で、この点が写っている位置 (ラスタライズはジッター分ずれている)
    vec2 pos = (src + jitter) * viewSize();
    ivec2 nearest = clamp(ivec2(floor(pos)), ivec2(0), maxTexel);
    vec2 nearestUv = (vec2(nearest) + 0.5) * texelSize();
    // 拡大している所だけ超解像を効かせる (縮小している周辺は 1 フレームの補間のまま)
    float magnify = 1.0 / max(footprint, 1e-3);
    float superRes = saturate((magnify - 1.0) * LENS_WARP_TAA_SR_RAMP);
    // 一番近い元の画素の中心と出力の画素の中心の距離 (出力の画素)
    float distOut = length(pos - (vec2(nearest) + 0.5)) * magnify;
    float nearWeight = exp(-LENS_WARP_TAA_KERNEL * distOut * distOut);

    vec4 nearRaw = texelFetch(colortex0, nearest, 0);
    vec3 nearColor = sanitizeColor(nearRaw.rgb) * (1.0 - sparkleShare(nearRaw.a));
    float centerDepth = texelFetch(depthtex0, nearest, 0).r;

    // 1 フレームの補間 (final で引き伸ばす方式と同じ Catmull-Rom)。白飛び分は双線形で別に取り出す
    vec2 posUv = pos * texelSize();
    vec3 sparkle = gatherSparkle(pos, maxTexel);
    vec3 smoothColor = max(sanitizeColor(sampleCatmullRom(colortex0, posUv, viewSize())) - sparkle, 0.0);

    // 一番近い元の画素の周りの統計と、最も手前の深度 (元画像の座標。歪曲なしの TAA と同じ)
    TaaNeighborhood nb = taaNeighborhood(nearest, maxTexel, exposure, centerDepth);
    vec3 mean = nb.mean;
    vec3 sigma = nb.sigma;
    vec3 boxMin = nb.boxMin;
    vec3 boxMax = nb.boxMax;
    float closestDepth = nb.closestDepth;

    // 前フレームの出力の位置
    vec2 closestUv = nearestUv + vec2(nb.closestOffset) * texelSize();
    vec2 prevSrc = src + (getPreviousUv(closestUv, closestDepth) - closestUv);
    vec2 prevUv = lensForwardUv(prevSrc);
    float motionPx = length((prevUv - uv) * viewSize());
    // 速く動く時は 1 フレームの補間に寄せる (ずれた元の画素を強く混ぜると残像になる)
    float superResEff = superRes * (1.0 - saturate(motionPx / LENS_WARP_TAA_SR_MOTION));
    vec3 currentColor = mix(smoothColor, nearColor, superResEff);
    vec3 currentYcc = rgbToYCoCg(taaCompress(currentColor, exposure));

    bool valid = reprojectionInside(prevUv);
    vec3 history = vec3(0.0);
    if (valid) {
        float tolCenter, tolClosest;
        float expCenter = expectedPreviousDistance(nearestUv - jitter, centerDepth, tolCenter);
        float expClosest = expectedPreviousDistance(closestUv - jitter, closestDepth, tolClosest);
        valid = taaHistoryValid(prevUv, maxTexel, expCenter, tolCenter, expClosest, tolClosest);
        history = sanitizeColor(sampleCatmullRom(colortex13, prevUv, viewSize()));
    }

    vec3 resultYcc;
    if (valid) {
        vec3 historyYcc = taaClipHistory(history, exposure, mean, sigma, boxMin, boxMax, motionPx);
        float alpha = taaBlendAlpha(motionPx, centerDepth);
        // 出力の画素の中心から遠い元の画素は弱く混ぜる
        alpha = max(alpha * mix(1.0, nearWeight, superResEff), LENS_WARP_TAA_MIN_BLEND);
        resultYcc = mix(historyYcc, currentYcc, alpha);
    } else {
        // 履歴が無い所は 1 フレームの補間 (final で引き伸ばす方式と同じぼけ方)
        resultYcc = mix(rgbToYCoCg(taaCompress(smoothColor, exposure)), mean, TAA_NO_HISTORY_MEAN_BLEND * (1.0 - superRes));
    }

    vec3 result = sanitizeColor(taaExpand(yCoCgToRgb(resultYcc), exposure));
    writeTaaOutput(result, sparkle, nb.sparkleMax, prevUv, valid, motionPx, nearRaw.a, historyDistance(src, centerDepth));
}

void main() {
    if (LENS_WARP_TAA) {
        taaWarped();
        return;
    }
    ivec2 texel = ivec2(gl_FragCoord.xy);
    ivec2 maxTexel = ivec2(viewSize()) - 1;
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    vec2 unjitteredUv = uv - taaJitterUv();
    float exposure = getExposure();

    vec4 centerRaw = texelFetch(colortex0, texel, 0);
    vec3 centerColor = sanitizeColor(centerRaw.rgb);
    vec3 centerSparkle = centerColor * sparkleShare(centerRaw.a);
    centerColor -= centerSparkle;
    float centerDepth = texelFetch(depthtex0, texel, 0).r;

    // 3x3 近傍の統計と、最も手前の深度 (エッジでは手前の物体の速度を使うと輪郭のゴーストが減る)
    TaaNeighborhood nb = taaNeighborhood(texel, maxTexel, exposure, centerDepth);
    vec3 mean = nb.mean;
    vec3 sigma = nb.sigma;
    vec3 boxMin = nb.boxMin;
    vec3 boxMax = nb.boxMax;
    float closestDepth = nb.closestDepth;
    vec3 currentYcc = rgbToYCoCg(taaCompress(centerColor, exposure));

    vec2 closestUv = uv + vec2(nb.closestOffset) * texelSize();
    vec2 prevUv = uv + (getPreviousUv(closestUv, closestDepth) - closestUv);
    float motionPx = length((prevUv - uv) * viewSize());

    bool valid = reprojectionInside(prevUv);

    vec3 history = vec3(0.0);
    if (valid) {
        float tolCenter, tolClosest;
        float expCenter = expectedPreviousDistance(unjitteredUv, centerDepth, tolCenter);
        float expClosest = expectedPreviousDistance(closestUv - taaJitterUv(), closestDepth, tolClosest);
        valid = taaHistoryValid(prevUv, maxTexel, expCenter, tolCenter, expClosest, tolClosest);
        history = sanitizeColor(sampleCatmullRom(colortex13, prevUv, viewSize()));
    }

    vec3 resultYcc;
    if (valid) {
        vec3 historyYcc = taaClipHistory(history, exposure, mean, sigma, boxMin, boxMax, motionPx);
        float alpha = taaBlendAlpha(motionPx, centerDepth);
        resultYcc = mix(historyYcc, currentYcc, alpha);
    } else {
        // 履歴が無い所は 1 フレームだけなのでジャギーが目立つ。近傍平均へ少し寄せて和らげる
        resultYcc = mix(currentYcc, mean, TAA_NO_HISTORY_MEAN_BLEND);
    }

    vec3 result = sanitizeColor(taaExpand(yCoCgToRgb(resultYcc), exposure));
    // 白飛び分は本体の履歴に入れず、ジッターを外した位置で集めて専用の履歴と混ぜて足す
    // a < 0 は溶岩の発光の割合 (composite19)。モーションブラー・DoF を素通りしてブルームの縮小 (composite23) が読む
    vec3 sparkleNow = gatherSparkle((uv + taaJitterUv()) * viewSize(), maxTexel);
    writeTaaOutput(result, sparkleNow, nb.sparkleMax, prevUv, valid, motionPx, centerRaw.a, historyDistance(unjitteredUv, centerDepth));
}
