/*
 * 局所トーンマップ (HDR モード, LOCAL_TONEMAP)。周りごと明るい所を下げ、暗い所を上げて画面の明暗の差を縮める
 * 局所の明るさはガイデッドフィルタ (He et al. 2010) を画素自身をガイドにして求める。composite23 が log2 輝度の平均と 2 乗の平均を
 * 1/32 のタイルに書き、composite24 がぼかし、final がその分散から境目かどうかを判断する:
 *   分散の小さい所 (模様だけの面) は窓の平均を局所の明るさにして模様の明暗を残し、
 *   分散の大きい所 (明るい物と暗い物の境目) は画素自身の明るさを使い、境目の向こうの明るさで上げ下げしない
 * ぼかした明るさをそのまま使うと、明るい物の周りの暗い所が明るい側に合わせて下げられて縁に暗い輪が出る。
 * ブルームの段ごとに明るさの差で重みを付けて混ぜる方法も試したが、段の切り替わりが境目に沿った縞になった
 * post モジュール (lib/post)
 */
#ifndef POST_LOCAL_TONEMAP_GLSL
#define POST_LOCAL_TONEMAP_GLSL

//@include "/lib/common/color.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/post/bloom.glsl"
//@include "/lib/post/post_constants.glsl"
//@include "/lib/post/sampling.glsl"
//@include "/lib/buffers/slots.glsl"

// タイルの縮小 (1 / 2^n)。窓の大きさがこれで決まる (ぼかしと双三次の拡大で 3〜4 テクセル)
const int LOCAL_TONEMAP_TILE_SHIFT = 5;
// タイルの 1 テクセルを colortex0 のミップの 4x4 点で集める (ミップは 1/8)
const int LOCAL_TONEMAP_TAPS = 4;
const float LOCAL_TONEMAP_TAP_LOD = float(LOCAL_TONEMAP_TILE_SHIFT - 2);
// 境目と見なす分散 (EV^2)。窓の明暗の標準偏差がこの平方根 (EV) を超えると画素自身の明るさに寄る
const float LOCAL_TONEMAP_EDGE_VARIANCE = 1.0;
// 上げ下げの上限 (EV)。暗い所はノイズを持ち上げすぎない程度まで
const float LOCAL_TONEMAP_LIFT_MAX = 2.0;
const float LOCAL_TONEMAP_CUT_MAX = 3.0;
const float LOCAL_TONEMAP_LUM_MIN = 1e-6;

// 1/32 のタイルの場所。画面のフレアのタイル (1/4) の右の空き
ivec4 localTonemapTileRectPx() {
    ivec2 screen = ivec2(viewSize());
    const int scale = 1 << LOCAL_TONEMAP_TILE_SHIFT;
    ivec4 flare = flareTileRectPx();
    return ivec4(flare.x + flare.z + BLOOM_PADDING, 0, max((screen + scale - 1) / scale, ivec2(1)));
}

bool isInLocalTonemapTile(ivec2 p, out ivec4 rect) {
    rect = localTonemapTileRectPx();
    return all(greaterThanEqual(p, rect.xy)) && all(lessThan(p, rect.xy + rect.zw));
}

/*
 * タイルの 1 テクセル: x = log2 輝度の平均、y = log2 輝度の 2 乗の平均 (露出前)。colortex0 のミップが要る (composite23)
 * 線形の平均の log ではなく log の平均にする。線形の平均は小さな灯りに引っ張られ、灯りの周りの暗い所を下げてしまう
 */
vec2 sampleLocalTonemapSource(sampler2D source, vec2 uv) {
    vec2 tapStep = exp2(LOCAL_TONEMAP_TAP_LOD) * texelSize();
    vec2 sum = vec2(0.0);
    for (int y = 0; y < LOCAL_TONEMAP_TAPS; y++) {
        for (int x = 0; x < LOCAL_TONEMAP_TAPS; x++) {
            vec2 p = clamp(uv + (vec2(x, y) - 0.5 * float(LOCAL_TONEMAP_TAPS - 1)) * tapStep, vec2(0.0), vec2(1.0));
            float l = log2(max(luminance(sanitizeColor(textureLod(source, p, LOCAL_TONEMAP_TAP_LOD).rgb)), LOCAL_TONEMAP_LUM_MIN));
            sum += vec2(l, l * l);
        }
    }
    return sum / float(LOCAL_TONEMAP_TAPS * LOCAL_TONEMAP_TAPS);
}

/*
 * color: 露出後の線形色。pivot: 露出後の画面の平均輝度 (ここを境に上げ下げするので、画面全体の明るさは自動露出のまま)
 * uv はブルームのタイルと同じ座標 (final の uvL)
 */
vec3 applyLocalTonemap(vec3 color, vec2 uv, float exposure, float pivot) {
    vec2 screen = viewSize();
    vec4 rect = vec4(localTonemapTileRectPx());
    vec2 moments = sampleBSplineClamped4(TEX_BLOOM, (rect.xy + uv * rect.zw) / screen, screen,
                                         (rect.xy + 0.5) / screen, (rect.xy + rect.zw - 0.5) / screen).xy;
    float own = log2(max(luminance(color), LOCAL_TONEMAP_LUM_MIN));
    float mean = moments.x + log2(exposure);
    float variance = max(moments.y - moments.x * moments.x, 0.0);
    float a = variance / (variance + LOCAL_TONEMAP_EDGE_VARIANCE);
    float base = mix(mean, own, a);
    float ev = (log2(max(pivot, LOCAL_TONEMAP_LUM_MIN)) - base) * optLocalTonemapStrength;
    return color * exp2(clamp(ev, -LOCAL_TONEMAP_CUT_MAX, LOCAL_TONEMAP_LIFT_MAX));
}

#endif
