/*
 * composite22: 被写界深度 (MIP-Bokeh + 前景/背景の 2 層 gather)
 * - ボケ半径は薄レンズの物理モデル (lib/post/camera.glsl)。サンプル点ごとに自分の深度からボケ半径を取り直す
 * - サンプル配置は Vogel 円板を絞り羽根の多角形へ写したもの。間隔に応じて colortex0 のミップを読むので点状のノイズが出ない
 * - 背景層: 中心より奥のサンプルは中心のボケ半径までしか寄与しない (ピントの合った前景へ背景が滲まない)
 * - 前景層: 中心より手前で大きくボケたサンプルは、覆っている割合をアルファにして上に重ねる (前ボケが輪郭の外へ広がる)
 * - 手は除外 (ぼかさず、周りへも滲ませない)。TAA より後なのでサンプル配置は固定 (時間ノイズを出さない)
 * - レンズの収差 (プリセット lib/post/lens_presets.glsl): 口径食 (猫目), 非点収差 (ぐるぐるボケ), 像面湾曲,
 *   軸上色収差 (チャンネルごとのボケ半径), アナモルフィックの楕円ボケ, 縁の明るいボケ (球面収差), 縁の溶けるボケ (アポダイゼーション)
 * フォーカス距離は FrameData.focusDistance (composite25 が前フレームに平滑化して書いた値)
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

const bool colortex0MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

#if DOF_QUALITY == 0
const int DOF_SAMPLE_COUNT = 30;
#elif DOF_QUALITY == 1
const int DOF_SAMPLE_COUNT = 50;
#else
const int DOF_SAMPLE_COUNT = 75;
#endif

#ifdef LENS_SWIRL
const float SWIRL = LP_SWIRL * LENS_SWIRL_STRETCH;
const float FIELD_CURVATURE = LP_FIELD_CURVATURE * LENS_FIELD_CURVATURE_SCALE;
#else
const float SWIRL = 0.0;
const float FIELD_CURVATURE = 0.0;
#endif
#ifdef LENS_OPTICAL_VIGNETTING
const bool CATS_EYE = LP_CATS_EYE > 0.0;
#else
const bool CATS_EYE = false;
#endif

float dofDistance(float depth) {
    return depth >= 1.0 ? far * 4.0 : linearizeDepth(depth);
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec4 centerRaw = texelFetch(colortex0, texel, 0);
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    // 歪曲・魚眼を TAA で組み立てた時は colortex0 が出力の座標なので、深度は元画像の位置で読む (lib/post/lens.glsl)
    float depth0 = texelFetch(depthtex0, LENS_WARP_TAA ? postSourceTexel(uv) : texel, 0).r;
    if (isHandDepth(depth0)) {
        outColor = centerRaw;
        return;
    }

    // 収差の強さを決める半径。魚眼は final で再投影されるので、出力 (レンズの画角) 側の半径で引く
#if LENS_PROJECTION == 1
    float rhoField = lensFieldRho(uv);
    float r2 = rhoField * rhoField;
#else
    float r2 = lensRadius2(uv);
    float rhoField = sqrt(r2);
#endif
    /*
     * TAA で組み立てた時は、画面がすでに出力の座標なので出力の半径で引く
     * ボケの大きさ (元画像の画素) は出力の拡大率を掛けて直し、放射と接線の拡大率の差はボケの縦横比にする
     */
    vec2 warpMag = postMagnification(uv);
    float cocMag = 1.0;
    if (LENS_WARP_TAA) {
        lensProjectUv(uv, rhoField);
        r2 = rhoField * rhoField;
        cocMag = sqrt(warpMag.x * warpMag.y);
    }
    // 像面湾曲: 正は周辺ほどピントが手前に来る (背景のボケが周辺で増える)、負は奥に来る
    float focus = max(frameData.focusDistance, 0.1) / max(1.0 + FIELD_CURVATURE * r2, LENS_FIELD_CURVATURE_MIN);
    float maxRadius = dofMaxRadius();
    /*
     * 処方の像面湾曲・非点収差 (lib/post/lens.glsl lensFieldDefocus): 像面の焦点ずれをボケ半径に足す
     * 子午と球欠の平均はボケの大きさに、差はボケの縦横比 (下の axisScale) に効く
     */
#if defined LENS_SWIRL && defined LENS_FIELD_TABLE
    vec2 fieldCoc = lensFieldDefocus(rhoField);
#else
    const vec2 fieldCoc = vec2(0.0);
#endif
    float cocBias = 0.5 * (fieldCoc.x + fieldCoc.y);
    float dist0 = dofDistance(depth0);
    float objectCoc0 = circleOfConfusion(dist0, focus) * cocMag;
    float cocSigned0 = clamp(objectCoc0 + cocBias, -maxRadius, maxRadius);

    /*
     * 軸上色収差: 波長ごとにピント位置がずれる。緑を基準に赤と青 (マゼンタ) のボケ半径を負の側へずらすと、
     * 前ボケの縁が紫、後ボケの縁が緑に色付き、ピント面の明るい縁にも紫のにじみが出る (補正不足の大口径レンズの典型)
     */
#ifdef LENS_AXIAL_CA
    vec3 lca = -vec3(1.0, 0.0, 0.85) * (LENS_AXIAL_CA_PX * LP_AXIAL_CA * lensApertureFactor() * viewHeight / 1080.0);
#else
    const vec3 lca = vec3(0.0);
#endif
    vec3 coc03 = abs(cocSigned0 + lca);
    float coc0 = abs(cocSigned0);

    /*
     * 周囲に大きくボケた前景があるか (あれば中心がピント内でも探索半径を広げる)
     * 上限半径が既定より広い時は輪を増やす (輪の間隔を既定と同程度に保ち、細い前景の取りこぼしを防ぐ)
     */
    float nearCoc = 0.0;
    int rings = clamp(int(ceil(2.0 * maxRadius / (DOF_MAX_RADIUS * viewHeight) - 0.01)), 2, 6);
    for (int ring = 1; ring <= rings; ring++) {
        float reach = maxRadius * float(ring) / float(rings);
        for (int i = 0; i < 8; i++) {
            float a = (float(i) + 0.5 * float(ring)) * (TAU / 8.0);
            vec2 p = uv + vec2(cos(a), sin(a)) * reach * texelSize();
            if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) continue;
            float d = texelFetch(depthtex0, postSourceTexel(p), 0).r;
            if (isHandDepth(d)) continue;
            float dist = dofDistance(d);
            if (dist >= dist0) continue;
            float c = -clamp(circleOfConfusion(dist, focus) * cocMag + cocBias, -maxRadius, maxRadius);
            if (c > reach * 0.5) nearCoc = max(nearCoc, c);
        }
    }

    float radius = min(max(max(coc03.r, max(coc03.g, coc03.b)), nearCoc), maxRadius);
    if (radius < 0.5) {
        outColor = centerRaw;
        return;
    }

    // 大きなボケは、1 サンプルの受け持ち幅が DOF_SAMPLE_SPACING (1080p 換算) 以下になるまでサンプルを増やす
    float spacingLimit = DOF_SAMPLE_SPACING * viewHeight / 1080.0;
    int sampleCount = clamp(int(ceil(PI * sqr(radius / spacingLimit))), DOF_SAMPLE_COUNT, DOF_SAMPLE_LIMIT);
    float sampleCountF = float(sampleCount);
    // サンプル 1 個が受け持つ円板の幅。ミップはこの幅に合わせる (MIP-Bokeh)
    float spacing = radius * sqrt(PI / sampleCountF);
    /*
     * 既定の上限半径を超える大きなボケでは、サンプル間隔より粗いミップで読む
     * 間隔と同じ幅だと、Vogel 配置とミップの格子のうなりで玉ボケの中がまだらになり、縁も花のように欠ける
     */
    float largeBlend = saturate(radius / (DOF_MAX_RADIUS * viewHeight) - 1.0);
    float lod = clamp(log2(spacing) + DOF_LARGE_LOD_BIAS * largeBlend, 0.0, largeBlend > 0.0 ? DOF_MAX_LOD_LARGE : DOF_MAX_LOD);

    // 画面中心から見た放射方向 (縦横比込み)。猫目・ぐるぐるの向きに使う
    vec2 radial = (uv - 0.5) * vec2(aspectRatio, 1.0);
    radial = length(radial) > 1e-5 ? normalize(radial) : vec2(1.0, 0.0);
    vec2 tangent = vec2(-radial.y, radial.x);
    /*
     * 非点収差: 周辺のボケは接線方向と放射方向で大きさが違い、後ボケは接線方向に伸びて背景が渦を巻く (ぐるぐるボケ)
     * 前ボケでは伸びる向きが入れ替わる
     */
#if defined LENS_SWIRL && defined LENS_FIELD_TABLE
    // 処方の非点収差: 放射方向の広がりは子午、接線方向は球欠の焦点ずれで決まる (前ボケと後ボケで伸びる向きが入れ替わる)
    vec2 axisScale = clamp(abs(vec2(objectCoc0) + fieldCoc) / max(abs(cocSigned0), 1.0), 0.25, 4.0);
#else
    float stretch = 1.0 + SWIRL * r2;
    vec2 axisScale = cocSigned0 >= 0.0 ? vec2(1.0 / sqrt(stretch), stretch) : vec2(stretch, 1.0 / sqrt(stretch));
#endif
    // 魚眼の周辺は放射方向に縮むので、出力ではボケも放射方向に潰れる
    if (LENS_WARP_TAA) axisScale *= warpMag / cocMag;
    // 口径食: 入射瞳 (半径 pupil) のうち、ずれた前玉の縁 (半径 1) の内側だけが通る -> 猫目 (レモン形) のボケ
    vec2 catsEye = lensCatsEyeRho(rhoField);
    float catsShift = max(catsEye.y - (1.0 - catsEye.x), 0.0) * 0.5 / catsEye.x;

    /*
     * 上限を広げた大きなボケでは、中心も他のサンプルと同じミップで読む
     * 生の画素のままだと、遠くの点光源が広い円板に薄まった中に元の点として残る。既定の上限以下は従来どおり生の画素
     * 探索半径 (radius) ではなく中心自身のボケで決める。ピントの合った被写体が手前の大きな前ボケの近くにあると、
     * radius だけ大きくなり被写体までミップでぼけてしまう
     */
    float centerFiltered = saturate(max(coc03.r, max(coc03.g, coc03.b)) / (DOF_MAX_RADIUS * viewHeight) - 1.0);
    vec3 bgSum = sanitizeColor(centerRaw.rgb);
    if (centerFiltered > 0.0) bgSum = mix(bgSum, sanitizeColor(textureLod(colortex0, uv, lod).rgb), centerFiltered);
    /*
     * 中心自体が前ボケの時は、同じ面 (と手前) のサンプルも前景層に入れ、奥のサンプルは「半透明にボケた前景の向こうの背景」
     * として円板全体から集める。中心の生の画素は背景層に入れない (前景の色なので、輪郭の内側が前景の色で固まる)
     * こうしないと前景の内側は前景の色だけになり、輪郭の外側にだけ滲んで縁に段差が残る
     */
    bool centerNear = cocSigned0 < -DOF_NEAR_CENTER_COC
                   && (DOF_NEAR_CENTER_AT_DEFAULT || maxRadius > DOF_MAX_RADIUS * viewHeight * 1.001);
    vec3 bgWeight = vec3(1.0);
    if (centerNear) {
        bgSum *= 1e-3;
        bgWeight *= 1e-3;
    }
    vec3 nearSum = vec3(0.0);
    vec3 nearWeight = vec3(0.0);
    float nearCocSum = 0.0;
    float nearCount = 0.0;
    float accepted = 0.0;
    /*
     * アポダイゼーションの瞳の透過率 exp(-β ρp^2)。絞ると開口の外側 (透過率の低い所) が切れて普通の円板に近づくので、
     * ρp の範囲は開放の口径に対する今の口径の比まで。円板全体の平均の重みが 1 になるよう割る
     */
    float apodScale = clamp(LP_F_OPEN / lensFNumber(), 0.05, 1.0);
    float apodBeta = LP_APODIZATION * apodScale * apodScale;
    float apodNorm = apodBeta > 1e-4 ? apodBeta / (1.0 - exp(-apodBeta)) : 1.0;

    for (int i = 0; i < sampleCount; i++) {
        float r = sqrt((float(i) + 0.5) / sampleCountF);
        float theta = float(i) * GOLDEN_ANGLE;
        // 円板上の半径 r の点を、絞りの形の同じ「等高線」上へ移す (単位は開口半径)
        vec2 o = vec2(cos(theta), sin(theta)) * (r * apertureShape(theta));
        if (CATS_EYE) {
            if (length(o * catsEye.x - radial * catsEye.y) > 1.0) continue;
            o -= radial * catsShift;
        }
        o = radial * (dot(o, radial) * axisScale.x) + tangent * (dot(o, tangent) * axisScale.y);
        // アナモルフィック: 横に圧縮された縦長の楕円ボケ
        o.x /= LP_SQUEEZE;
        accepted += 1.0;

        float rDisc = r * radius;
        vec2 uvS = uv + o * radius * texelSize();
        if (any(lessThan(uvS, vec2(0.0))) || any(greaterThan(uvS, vec2(1.0)))) continue;

        float depthS = texelFetch(depthtex0, postSourceTexel(uvS), 0).r;
        if (isHandDepth(depthS)) continue;
        float distS = dofDistance(depthS);
        float cocSignedS = clamp(circleOfConfusion(distS, focus) * cocMag + cocBias, -maxRadius, maxRadius);
        float cocS = abs(cocSignedS);
        vec3 cocS3 = abs(cocSignedS + lca);
        vec3 colorS = sanitizeColor(textureLod(colortex0, uvS, lod).rgb);
        /*
         * 球面収差: ボケの縁が明るい (正) / 中心が明るい (負)。円板全体の平均の重みは 1 のまま
         * LP_SA_RIM は後ボケの値で、前ボケでは符号が逆になる (補正不足のレンズは後ボケが柔らかく前ボケの縁が立つ)
         */
        float rim = 1.0 + (LP_BOKEH_RIM + (cocSignedS >= 0.0 ? LP_SA_RIM : -LP_SA_RIM)) * (2.0 * r * r - 1.0);
        // アポダイゼーション (STF): ボケの円板の中での位置 rDisc / cocS を瞳の半径にして、周辺ほど暗くする
        if (LP_APODIZATION > 0.0) rim *= exp(-apodBeta * sqr(min(rDisc / max(cocS, 0.5), 1.0))) * apodNorm;

        bool inFront = centerNear ? cocSignedS < 0.0 && distS < dist0 * 1.03 + 0.05
                                  : distS < dist0 * 0.97 - 0.05 && cocS > coc0;
        if (inFront) {
            vec3 coverage = saturate((cocS3 - rDisc) / spacing + 0.5) * rim;
            nearSum += colorS * coverage;
            nearWeight += coverage;
            nearCocSum += cocS * coverage.g;
            nearCount += coverage.g;
        } else {
            vec3 cocEff = distS > dist0 ? (centerNear ? coc03 : min(cocS3, coc03)) : cocS3;
            vec3 coverage = saturate((cocEff - rDisc) / spacing + 0.5) * rim;
            bgSum += colorS * coverage;
            bgWeight += coverage;
        }
    }

    vec3 result = bgSum / bgWeight;
    if (nearCount > 0.0) {
        // 前景のボケ円板の内側に入るはずのサンプル数に対して、実際に覆っていた割合 = 前景の不透明度
        float nearRadius = nearCocSum / nearCount;
        float expected = accepted * sqr(min(nearRadius / radius, 1.0));
        vec3 alpha = saturate(nearWeight / max(expected, 1.0));
        result = mix(result, nearSum / max(nearWeight, vec3(1e-4)), alpha);
    }
    outColor = vec4(result, centerRaw.a);
}
