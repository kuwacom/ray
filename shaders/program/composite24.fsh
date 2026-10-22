/*
 * composite24: ブルームタイルのぼかし (colortex14 -> colortex14) と画面のレンズフレア
 * - 各タイルの中で 3x3 のテントフィルタ (双線形 9 タップ, 実効 5x5 ガウス相当) を掛け、縮小で残った角張りを丸める。タイルの外は読まない
 * - フレアタイル (lib/post/bloom.glsl flareTileRectPx, 1/4 解像度) に、明るい画素 (たいまつ・溶岩・反射など) の
 *   ゴーストと横ストリークを書く。ゴーストの位置・大きさ・色は太陽と同じレンズ設計の表 (lens_ghosts.glsl) から取る
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 14 */
layout(location = 0) out vec4 outBloom;

// テントの半径 (テクセル)。1 を少し超えると双線形が隣のテクセルも拾い、ガウスに近づく
const float BLOOM_BLUR_OFFSET = 1.25;
// 横ストリークのタップ数 (片側)
const int STREAK_TAPS = 48;

#if defined LENS_SCREEN_FLARE && defined LENS_FLARE
// 露出後の閾値を超えた分 (シーン単位)。ソフトニーで閾値の境目に輪郭を出さない
vec3 flareHighlight(vec3 c, float exposure, float threshold) {
    float l = luminance(c) * exposure;
    float knee = threshold * 0.5;
    float x = clamp(l - threshold + knee, 0.0, 2.0 * knee);
    float over = max(l - threshold, x * x / (4.0 * knee));
    return c * (over / max(l, 1e-6));
}

/*
 * 太陽・月の付近は解析的なフレア (final) が受け持つので、画面ゴーストの元から外す (二重に出さない)
 * 半径はタイルのぼけの広がり分を足す
 */
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
const int SCREEN_STAR_TAPS = 6;                // 光条 1 本 (片側) のタップ数
const float LENS_SCREEN_STAR_LENGTH = 0.07;    // 光条の長さの目安 (画面の高さ比, F2.14 の時)
const float LENS_SCREEN_STAR_THRESHOLD = 1.5;  // 露出後の明るさの閾値 (1/4 タイル)
const float LENS_SCREEN_STAR_GAIN = 0.12;

vec3 screenStars(vec2 uv, float exposure, float fNumber) {
    if (LP_STARBURST <= 0.0) return vec3(0.0);
    const int spikes = LENS_BLADES % 2 == 0 ? LENS_BLADES : LENS_BLADES * 2;
    const int lines = spikes / 2;
    // 解析的な光条と同じく、絞るほど長く強く、丸い羽根と開放付近では弱い
    float n = fNumber / LENS_F_REFERENCE;
    float len = LENS_SCREEN_STAR_LENGTH * LP_STAR_SIZE * sqrt(n);
    float gain = LP_STARBURST * LENS_SCREEN_STAR_GAIN * clamp(n, 0.5, 3.0) * (1.0 - 0.7 * LP_BLADE_ROUNDNESS);
    gain *= mix(LENS_STAR_OPEN, 1.0, saturate((fNumber / LP_F_OPEN - 1.0) / LENS_STAR_STOPDOWN_RANGE));
    vec3 sum = vec3(0.0);
    for (int j = 0; j < lines; j++) {
        float a = DOF_BLADE_ROTATION + float(j) * TAU / float(spikes);
        vec2 dir = vec2(cos(a) / aspectRatio, sin(a));
        for (int t = 0; t < SCREEN_STAR_TAPS; t++) {
            // 光源の近くほど細かく刻む。重みは光条の裾 (指数減衰) x 刻み幅
            float x0 = float(t) / float(SCREEN_STAR_TAPS);
            float x1 = float(t + 1) / float(SCREEN_STAR_TAPS);
            float r = len * sqr(0.5 * (x0 + x1));
            float w = exp(-r / (0.3 * len)) * (sqr(x1) - sqr(x0));
            for (int side = -1; side <= 1; side += 2) {
                vec2 src = uv - dir * (r * float(side));
                if (any(lessThan(src, vec2(0.0))) || any(greaterThan(src, vec2(1.0)))) continue;
                vec3 local = sampleBloomTileLinear(2, src);
                vec3 surround = sampleBloomTileLinear(4, src);
                sum += flareHighlight(max(local - surround, 0.0), exposure, LENS_SCREEN_STAR_THRESHOLD) * (w * sunMask(src, 48.0));
            }
        }
    }
    return sum * gain;
}
#endif

vec3 screenFlare(vec2 uv) {
    float exposure = getExposure();
    vec2 yTan = uvToTan(uv);
    float fNumber = lensFNumber();
    float rEp = 0.5 / fNumber;
    vec2 tanHalf = lensTanHalf();
    vec3 sum = vec3(0.0);

    // ゴースト: 画素 y には、光源像が y / S にある光が届く。広がりは前玉の倍率 A x 入射瞳
    // 輝度はゴーストの写像で面積が S^2 倍に広がる分だけ下がる (反射率 R / S^2)
    if (LP_SCREEN_GHOSTS > 0.0) {
        for (int g = 0; g < LENS_SCREEN_GHOST_COUNT; g++) {
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
            refl = mix(vec3(dot(refl, vec3(1.0 / 3.0))), refl, LENS_SCREEN_GHOST_SATURATION);
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
                vec3 hl = flareHighlight(max(local - surround, 0.0), exposure, LENS_SCREEN_THRESHOLD * exp2(-2.0 * float(level - 2)));
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
            streak += flareHighlight(sampleBloomTileLinear(2, p), exposure, LENS_STREAK_THRESHOLD) * (w * sunMask(p, 48.0));
        }
        vec3 tint = LP_STREAK_TINT / luminance(LP_STREAK_TINT);
        sum += tint * luminance(streak / wSum) * (LP_STREAK * LENS_STREAK_GAIN);
    }

#if defined LENS_STARBURST && LENS_BLADES > 0
    sum += screenStars(uv, exposure, fNumber);
#endif
    return sum * LENS_FLARE_STRENGTH;
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
            sum += textureLod(colortex14, p, 0.0) * w;
        }
    }
    outBloom = sum / 16.0;
}
