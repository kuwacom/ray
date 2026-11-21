/*
 * composite24: ブルームタイルのぼかし (colortex14 -> colortex14) と画面のレンズフレア
 * - 各タイルの中で 3x3 のテントフィルタ (双線形 9 タップ, 実効 5x5 ガウス相当) を掛け、縮小で残った角張りを丸める。タイルの外は読まない
 * - フレアタイル (lib/post/bloom.glsl flareTileRectPx, 1/4 解像度) に、明るい画素 (たいまつ・溶岩・反射など) の
 *   ゴーストと横ストリークを書く。ゴーストの位置・大きさ・色は太陽と同じレンズ設計の表 (lens_ghosts.glsl) から取る
 * post モジュール (lib/post)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/exposure.glsl"
//@include "/lib/post/post_internal.glsl"
//@include "/lib/post/local_tonemap.glsl"
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
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/exposure.glsl"
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
#include "/lib/post/camera_exposure.glsl"
#include "/lib/post/camera.glsl"
#include "/lib/post/grading.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/buffers/slots.glsl"
#include "/lib/common/pre_exposure.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/post/lens_optics.glsl"
#include "/lib/common/celestial_shape.glsl"
#include "/lib/post/lens_ghosts.glsl"
#include "/lib/post/lens_flare.glsl"
#include "/lib/post/lens.glsl"
#include "/lib/post/post_internal.glsl"
#include "/lib/post/local_tonemap.glsl"
// END GENERATED includes

in vec2 texcoord;

/* RENDERTARGETS: 14 */
layout(location = 0) out vec4 outBloom;

// テントの半径 (テクセル)。1 を少し超えると双線形が隣のテクセルも拾い、ガウスに近づく
const float BLOOM_BLUR_OFFSET = 1.25;
// 横ストリークのタップ数 (片側)
const int STREAK_TAPS = 48;

#if defined LENS_SCREEN_FLARE && defined LENS_FLARE
// 露出後の閾値を超えた分 (シーン単位)。ソフトニー (幅 knee) で閾値の境目に輪郭を出さない
vec3 flareHighlight(vec3 c, float exposure, float threshold, float knee) {
    float l = luminance(c) * exposure;
    float x = clamp(l - threshold + knee, 0.0, 2.0 * knee);
    float over = max(l - threshold, x * x / (4.0 * knee));
    return c * (over / max(l, 1e-6));
}

/*
 * 太陽・月の付近は解析的なフレア (final) が受け持つので、画面ゴーストの元から外す (二重に出さない)
 * 半径はタイルのぼけの広がり分を足す
 */
/*
 * 光条とストリークは 1/4 タイル (レベル 2) を読むので、外す半径はそのぼけ (約 3 テクセル x 4 画素) だけ足せば足りる。
 * 広く外すと、夕方の海で太陽の真下の照り返しの道から光条とストリークが消える
 */
const float FLARE_LEVEL2_SPREAD_PX = 3.0 * 4.0;

float sunMask(vec2 uv, float spreadPx) {
#ifdef HAS_SKY
    if (shadowLightPosition.z >= 0.0) return 1.0;
    vec2 lightUv = viewToScreen(shadowLightPosition).xy;
    // 歪曲・魚眼を TAA で組み立てた時は、ブルームのタイルも出力の座標
    if (LENS_WARP_TAA) lightUv = lensForwardUv(lightUv);
    vec2 d = (uv - lightUv) * vec2(aspectRatio, 1.0);
    float r = 0.012 + spreadPx / viewHeight;
    return smoothstep(r, r * 2.0, length(d));
#else
    return 1.0;
#endif
}

#if defined LENS_STARBURST && LENS_BLADES > 0
/*
 * 小さく明るい画素 (水面の輝点・映り込んだ太陽・遠くの灯り) の光条。太陽・月そのものは final の解析的な光条が受け持つ
 * 光条の向きは絞り羽根に垂直 (lens.glsl の lensStarburst と同じ本数・向き)。光条の線に沿って光源の側を集める
 * 元は 1/4 タイルの周囲 (2 段粗いレベル) より明るい分だけ (一様に明るい空・雪原からは出さない)
 */
/*
 * 光条 1 本 (片側) のタップの間隔 (画素) と数の範囲。間隔は光条の長さに依らず一定にする
 * 間隔が広いと、白を大きく超えた光源 (夜の長時間露光・明るい溶岩) で光条がタップごとの点に割れ、光源の周りに点の輪が何重にも並んだ
 * (6 タップを光源の近くほど細かく刻んでいた時、外側の間隔は F8 で 20 画素を超えた)
 * 8 画素は 1/4 タイルの双線形 (半径 4 画素) と、フレアのタイルの拡大のぼけで線につながる間隔
 */
const float SCREEN_STAR_SPACING_PX = 8.0;
const int SCREEN_STAR_TAPS_MIN = 6;                // 光条 1 本 (片側) のタップ数の下限 (以前の固定のタップ数)
const int SCREEN_STAR_TAPS_MAX = 32;
// 上限のタップ数でも間隔が広い長い光条は、この倍率 x 双線形の半径 (2^level 画素) が間隔を覆う粗いレベルで読む
const float SCREEN_STAR_SPACING_PER_RADIUS = 2.0;
const float LENS_SCREEN_STAR_LENGTH = 0.07;    // 光条の長さの目安 (画面の高さ比, F2.14 の時)
const float LENS_SCREEN_STAR_THRESHOLD = 1.5;  // 露出後の明るさの閾値 (1/4 タイル)
// ニーの幅。回折の光条は本来明るさに比例するので、閾値の付近で明るさが揺れる点の光条が点いたり消えたりしないよう、閾値と同じ幅で 0 からなめらかに立ち上げる
const float LENS_SCREEN_STAR_KNEE = LENS_SCREEN_STAR_THRESHOLD;
const float LENS_SCREEN_STAR_GAIN = 0.12;
/*
 * 光条の太さ・先端の鋭さ (LENS_STARBURST_WIDTH / TAPER)。筋に直交する向きの 3 タップ (中心と両脇 1 テクセル) で
 * 元の像の横の広がりだけを絞る (中心 x (1 + 2k) - 両脇 x k)、または広げる (k < 0)。筋に沿う向きは絞らないので、
 * タップの間隔と点の輪の条件 (SCREEN_STAR_SPACING_PX) は変わらない。太さ 1.0・鋭さ 0.0 では元の 1 タップのまま
 * 筋の幅の大半は縮小 (composite23) と final のフレアタイル (1/4 解像度) の拡大のぼけで、ここでは絞れないので、
 * 細くできるのは 0.8 倍くらいまで (それより細い値は 0.8 倍のまま)。ぼけを打ち消すほど強く絞ると縁が負になり、切り捨てで明るさだけ崩れる
 */
const bool SCREEN_STAR_SHAPED = LENS_STARBURST_WIDTH != 1.0 || LENS_STARBURST_TAPER != 0.0;
// 太さ W -> k: 細く (W < 1) は k = 0.3 (1 - W) / (W - 0.8)、太く は k = -(W - 1)。点の光源の筋の FWHM がほぼ W 倍になるよう、オフラインの描画で当てた
const float SCREEN_STAR_NARROW_GAIN = 0.3;
const float SCREEN_STAR_WIDTH_FLOOR = 0.8;
const float SCREEN_STAR_WIDEN_GAIN = 1.0;
const float SCREEN_STAR_K_MIN = -0.5;  // 中心の重み 0 (両脇の平均) まで
const float SCREEN_STAR_K_MAX = 1.5;   // これより強く絞っても幅はほとんど変わらず、縁の負の分の切り捨てで明るさだけ崩れる
// 中心の明るさの変わり方 (1 + この値 x k)。割り戻して、点の光源の筋の中心の明るさを太さに依らずそろえる (太陽・月の光条と同じ)
const float SCREEN_STAR_CENTER_PER_K = 0.6;
// 両脇を読む明るさの下限 (この画素の周りの明るさ + 閾値 x この値)
const float SCREEN_STAR_SHAPE_MIN = 1.0;
// ゲートの上で、絞りの強さを 0 から上げ切るまでの幅 (閾値の比)
const float SCREEN_STAR_SHAPE_RAMP = 3.0;

float screenStarSharpen(float width) {
    float k = width < 1.0 ? SCREEN_STAR_NARROW_GAIN * (1.0 - width) / max(width - SCREEN_STAR_WIDTH_FLOOR, 1e-3)
                          : -SCREEN_STAR_WIDEN_GAIN * (width - 1.0);
    return clamp(k, SCREEN_STAR_K_MIN, SCREEN_STAR_K_MAX);
}

vec3 screenStars(vec2 uv, float exposure, float fNumber) {
    if (LP_STARBURST <= 0.0) return vec3(0.0);
    const int spikes = LENS_BLADES % 2 == 0 ? LENS_BLADES : LENS_BLADES * 2;
    // 線の数は SSBO の値で決め、展開させない (理由は lib/post/lens_flare.glsl の lensGhosts)
    int lines = min(int(frameData.postParams[4].z), LENS_SCREEN_STAR_LINES);
    // 解析的な光条と同じく、絞るほど長く強く、丸い羽根と開放付近では弱い
    float n = fNumber / LENS_F_REFERENCE;
    float len = LENS_SCREEN_STAR_LENGTH * LP_STAR_SIZE * sqrt(n);
    float gain = LP_STARBURST * LENS_SCREEN_STAR_GAIN * clamp(n, 0.5, 3.0) * (1.0 - 0.7 * LP_BLADE_ROUNDNESS);
    gain *= mix(LENS_STAR_OPEN, 1.0, saturate((fNumber / LP_F_OPEN - 1.0) / LENS_STAR_STOPDOWN_RANGE));
    float lenPx = len * viewHeight;
    int taps = clamp(int(ceil(lenPx / SCREEN_STAR_SPACING_PX)), SCREEN_STAR_TAPS_MIN, SCREEN_STAR_TAPS_MAX);
    int level = clamp(int(ceil(log2(max(lenPx / float(taps) / SCREEN_STAR_SPACING_PER_RADIUS, 1.0)))), 2, BLOOM_LEVELS - 2);
    // 粗いレベルほど小さな光源は薄まるので、閾値もその分だけ下げる (画面ゴーストと同じ)
    float dilution = exp2(-2.0 * float(level - 2));
    float spreadPx = 3.0 * exp2(float(level));
    vec4 localRect = vec4(bloomTileRectPx(level));
    vec4 surroundRect = vec4(bloomTileRectPx(level + 2));
    float shapeRampInv = 1.0 / (SCREEN_STAR_SHAPE_RAMP * LENS_SCREEN_STAR_THRESHOLD * dilution);
    float shapeMin = SCREEN_STAR_SHAPED ? SCREEN_STAR_SHAPE_MIN * LENS_SCREEN_STAR_THRESHOLD * dilution + luminance(sampleBloomRectLinear(surroundRect, uv)) * exposure : 0.0;
    vec3 sum = vec3(0.0);
    for (int j = 0; j < lines; j++) {
        float a = DOF_BLADE_ROTATION + float(j) * TAU / float(spikes);
        vec2 dir = vec2(cos(a) / aspectRatio, sin(a)) * len;
        // 筋に直交する向きの 1 テクセル (読むレベル)
        vec2 across = vec2(-sin(a) / aspectRatio, cos(a)) * (exp2(float(level)) / viewHeight);
        for (int t = 0; t < taps; t++) {
            // 以前は光源の近くほど細かく刻んでいたが、外側の間隔が広がって明るい光源で点に割れたので、等間隔にして光条の長さでタップ数を決める
            // 重みは光条の裾 (指数減衰) x 刻み幅
            float x = (float(t) + 0.5) / float(taps);
            float w = exp(-x / 0.3) / float(taps);
            // 先端の細り: 光源からの距離 (光条の長さ比) に比例して太さを絞る (太陽・月の光条と同じ)
            float k = SCREEN_STAR_SHAPED ? screenStarSharpen(LENS_STARBURST_WIDTH * (1.0 - LENS_STARBURST_TAPER * x)) : 0.0;
            float centerNorm = 1.0 / (1.0 + SCREEN_STAR_CENTER_PER_K * k);
            for (int side = -1; side <= 1; side += 2) {
                vec2 src = uv - dir * (x * float(side));
                if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) continue;
                vec4 center = sampleBloomRectLinear4(localRect, src);
                vec3 local = bloomWithoutLavaGain(center);
                /*
                 * 両脇は、周りより閾値以上明るいタップだけで読む (重さの大半はタップの数なので、暗い所を飛ばして増えた分を抑える。
                 * 毎回読むと 1070・720p で +0.8 ms)。飛ばした所の寄与はおおむねニーの下 (明るさ^2 / 4 閾値) で、明るい筋の中心よりずっと小さい
                 * 周りの明るさはこの画素の分を使う。タップの分 (surround) を待って分岐すると読み込みの待ちを隠せず、それだけで +0.1 ms
                 * 境で元の値から絞った値へ跳ぶと、露出や輝点の明滅で光条の尾が段になって明滅するので、ゲートの上の閾値 3 つ分 (SCREEN_STAR_SHAPE_RAMP) で絞りの強さを 0 からなめらかに上げる
                 * (読む範囲はゲートより上のままなので重さは変わらない)
                 */
                // 溶岩の倍率を外した輝度 (a が輝度以下なら bloomWithoutLavaGain の輝度は 輝度 - a x (倍率 - 1) / 倍率。割り算を待たずに分岐できる)
                float lum = (luminance(center.rgb) - center.a * ((LAVA_BLOOM_GAIN - 1.0) / LAVA_BLOOM_GAIN)) * exposure;
                if (SCREEN_STAR_SHAPED && lum > shapeMin) {
                    // 絞りの強さをゲートの上で 0 から上げる (g = 0 で元の値そのもの)。割り戻しも g で混ぜ、g ごとの割り算を避ける (割り算にすると +0.1 ms)
                    float g = saturate((lum - shapeMin) * shapeRampInv);
                    g *= g * (3.0 - 2.0 * g);
                    // 溶岩の倍率は混ぜた後に 1 回だけ外す (色の比は線形の混合でほぼ保たれる)
                    vec4 c = center + (center * 2.0 - sampleBloomRectLinear4(localRect, src + across) - sampleBloomRectLinear4(localRect, src - across)) * (k * g);
                    local = bloomWithoutLavaGain(max(c, 0.0)) * mix(1.0, centerNorm, g);
                }
                vec3 surround = sampleBloomRectLinear(surroundRect, src);
                sum += flareHighlight(max(local - surround, 0.0), exposure, LENS_SCREEN_STAR_THRESHOLD * dilution, LENS_SCREEN_STAR_KNEE * dilution)
                     * (w * sunMask(src, spreadPx));
            }
        }
    }
    return sum * gain;
}
#endif

vec3 screenFlare(vec2 uv) {
    // タイルは P 倍の colortex0 から作ったまま読むので、閾値に掛ける露出もそろえる (出力のフレアも P 倍で、final が戻す)
    float exposure = getExposure() / preExposure();
    vec2 yTan = uvToTan(uv);
    float fNumber = lensFNumber();
    float rEp = 0.5 / fNumber;
    vec2 tanHalf = lensTanHalf();
    vec3 sum = vec3(0.0);

    // ゴースト: 画素 y には、光源像が y / S にある光が届く。広がりは前玉の倍率 A x 入射瞳
    // 輝度はゴーストの写像で面積が S^2 倍に広がる分だけ下がる (反射率 R / S^2)
    if (LP_SCREEN_GHOSTS > 0.0) {
        // 回数は SSBO の値で決め、展開させない (理由は lib/post/lens_flare.glsl の lensGhosts)
        int ghostCount = min(int(frameData.postParams[4].w), LENS_SCREEN_GHOST_COUNT);
        for (int g = 0; g < ghostCount; g++) {
#ifdef LENS_GHOST_TUNED
            if (((LP_GHOST_MASK >> g) & 1) == 0) continue;
#endif
            float radiusPx = abs(GHOST_A[g].y) * rEp / tanHalf.y * viewHeight * 0.5;
            // タイルのぼけ (約 1.5 テクセル) がゴーストの大きさになるレベル
            int level = clamp(int(log2(max(radiusPx / 1.5, 1.0)) + 0.5), 2, BLOOM_LEVELS - 1);
            float spreadPx = 3.0 * exp2(float(level));
            vec3 s = vec3(GHOST_S[g].z, GHOST_S[g].y, GHOST_S[g].x);
            /*
             * Minecraft の発光は露出後 5-7 程度で、現実の灯り (露出の数千倍) よりずっと暗いので反射率に倍率を掛ける
             * 反射率は物理どおり (マルチコートで 1e-5, 単層で 1e-4 前後) にし、コーティングの差をそのまま残す。
             * 平方根で縮めるとマルチコートでも洞窟のたいまつから濃い赤紫の円が出た
             * 色はコートの反射色を半分だけ残す (マルチコートは緑と赤の差が 40 倍あり、そのままだと純色の円になる)
             */
            vec3 refl = vec3(ghostReflectance(g, 650.0), ghostReflectance(g, 550.0), ghostReflectance(g, 450.0));
#ifdef LENS_GHOST_TUNED
            refl = mix(vec3(dot(refl, vec3(1.0 / 3.0))), refl, LENS_SCREEN_GHOST_SATURATION * LP_GHOST_SATURATION);
#else
            refl = mix(vec3(dot(refl, vec3(1.0 / 3.0))), refl, LENS_SCREEN_GHOST_SATURATION);
#endif
            for (int c = 0; c < 3; c++) {
                // 縮小率の小さいゴーストは画面全体の光を 1 点に集めて白い塊になるので、集光を抑える
                float sc = abs(s[c]) < 0.05 ? (s[c] < 0.0 ? -0.05 : 0.05) : s[c];
                vec2 src = tanToUv(yTan / sc);
                vec2 edge = min(src, 1.0 - src);
                if (min(edge.x, edge.y) <= 0.0) continue;
                float fade = smoothstep(0.0, 0.08, min(edge.x, edge.y));
                /*
                 * 周囲 (2 段粗いレベル) より明るい分だけを元にする (帯域通過)。一様に明るい空や雪原からは出さず、
                 * 小さく明るい光源 (たいまつ・溶岩・反射) だけがゴーストを作る。粗いレベルは双三次で読み、拡大の角張りを出さない
                 */
                vec3 local = sampleBloomTile(level, src);
                vec3 surround = sampleBloomTile(min(level + 2, BLOOM_LEVELS), src);
                // 閾値は光の量 (輝度 x 面積) で比べる。粗いレベルほど小さな光源は薄まるので、その分だけ下げる
                float threshold = LENS_SCREEN_THRESHOLD * exp2(-2.0 * float(level - 2));
                vec3 hl = flareHighlight(max(local - surround, 0.0), exposure, threshold, threshold * 0.5);
                sum[c] += hl[c] * refl[c] * min(1.0 / (sc * sc), LENS_SCREEN_GHOST_MAX_GATHER) * fade * sunMask(src, spreadPx);
            }
        }
        sum *= LP_SCREEN_GHOSTS * LENS_SCREEN_GHOST_GAIN;
    }

    // 横ストリーク (アナモルフィック): 1/8 タイルを横に指数減衰の重みで集める。色はコーティングの青
    if (LP_STREAK > 0.0) {
        vec3 streak = vec3(0.0);
        float wSum = 0.0;
        // 等間隔のタップ。間隔 (画面幅の 0.7%) を 1/4 タイルのぼけ (約 6 画素) に近づけて点の列に割れないようにする
        for (int i = -STREAK_TAPS; i <= STREAK_TAPS; i++) {
            float x = float(i) / float(STREAK_TAPS) * LENS_STREAK_LENGTH;
            float w = exp(-abs(x) / (LENS_STREAK_LENGTH * 0.3));
            vec2 p = uv + vec2(x, 0.0);
            wSum += w;
            if (p.x < 0.0 || p.x > 1.0) continue;
            // 太陽・月は final の解析的なストリークが受け持つ
            streak += flareHighlight(sampleBloomTileLinear(2, p), exposure, LENS_STREAK_THRESHOLD, LENS_STREAK_THRESHOLD * 0.5) * (w * sunMask(p, FLARE_LEVEL2_SPREAD_PX));
        }
        vec3 tint = LP_STREAK_TINT / luminance(LP_STREAK_TINT);
        sum += tint * luminance(streak / wSum) * (LP_STREAK * LENS_STREAK_GAIN);
    }

#if defined LENS_STARBURST && LENS_BLADES > 0
    sum += screenStars(uv, exposure, fNumber);
#endif
    return sum * FLARE_GAIN;
}
#endif

void main() {
#if defined LENS_SCREEN_FLARE && defined LENS_FLARE
    ivec4 flareRect = flareTileRectPx();
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (all(greaterThanEqual(pixel, flareRect.xy)) && all(lessThan(pixel, flareRect.xy + flareRect.zw))) {
        vec2 uv = (gl_FragCoord.xy - vec2(flareRect.xy)) / vec2(flareRect.zw);
        outBloom = vec4(screenFlare(uv), 1.0);
        return;
    }
#endif

    ivec4 rect;
    int level = bloomTileLevelAt(ivec2(gl_FragCoord.xy), rect);
#ifdef LOCAL_TONEMAP_TILE
    // 局所トーンマップのタイル (log2 輝度の平均と 2 乗の平均) も同じテントでぼかす
    if (level == 0 && isInLocalTonemapTile(ivec2(gl_FragCoord.xy), rect)) level = -1;
#endif
    if (level == 0) {
        outBloom = vec4(0.0);
        return;
    }

    vec2 px = texelSize();
    vec2 rectMin = (vec2(rect.xy) + 0.5) * px;
    vec2 rectMax = (vec2(rect.xy + rect.zw) - 0.5) * px;
    vec2 uv = gl_FragCoord.xy * px;

    // a (溶岩の発光の輝度, composite23) も同じようにぼかす
    vec4 sum = vec4(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float w = float((2 - abs(x)) * (2 - abs(y)));
            vec2 p = clamp(uv + vec2(x, y) * BLOOM_BLUR_OFFSET * px, rectMin, rectMax);
            sum += textureLod(TEX_BLOOM, p, 0.0) * w;
        }
    }
    outBloom = sum / 16.0;
}
