/*
 * composite23: ブルームの縮小タイル生成 (colortex0 のミップ -> colortex14 にタイル配置, lib/post/bloom.glsl)
 * 各レベルは 1 つ上のミップから Jimenez 2014 (COD: AW) の 13 タップで縮小する
 * ハードウェアのミップ (箱フィルタ) を直接使うよりエイリアスとちらつきが少ない
 * レベル 1 だけは 5 つの箱を輝度で重み付けする (Karis average) ことで、1 画素の極端な明るさ (ホタル) が円盤に広がるのを防ぐ
 * 閾値は掛けない (エネルギーを捨てない物理寄りのブルーム。強さは final の混合率で決まる)
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

const bool colortex0MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 14 */
layout(location = 0) out vec4 outBloom;

/*
 * rgb = ブルームの元の色、a = そのうち溶岩の発光の輝度 (final が溶岩の滲みを溶岩と同じ色を保つトーンマップに寄せる)
 * colortex0.a < 0 は溶岩の発光の割合 (composite11 -> TAA)。ミップは範囲の平均の割合になる
 */
vec4 fetchSource(vec2 uv, float lod) {
    vec4 s = textureLod(colortex0, clamp(uv, vec2(0.0), vec2(1.0)), lod);
    vec3 c = sanitizeColor(s.rgb);
    float lava = clamp(-s.a, 0.0, 1.0);
    return vec4(c * (1.0 + (LAVA_BLOOM_GAIN - 1.0) * lava), luminance(c) * LAVA_BLOOM_GAIN * lava);
}

float karisWeight(vec3 c) { return 1.0 / (1.0 + luminance(c)); }

void main() {
    ivec4 rect;
    int level = bloomTileLevelAt(ivec2(gl_FragCoord.xy), rect);
    if (level == 0) {
        outBloom = vec4(0.0);
        return;
    }

    vec2 uv = (gl_FragCoord.xy - vec2(rect.xy)) / vec2(rect.zw);
    float lod = float(level - 1);
    // 1 段上のミップの 1 テクセル (この段の半テクセル)
    vec2 t = exp2(lod) * texelSize();

    vec4 a = fetchSource(uv + t * vec2(-2.0, 2.0), lod);
    vec4 b = fetchSource(uv + t * vec2(0.0, 2.0), lod);
    vec4 c = fetchSource(uv + t * vec2(2.0, 2.0), lod);
    vec4 d = fetchSource(uv + t * vec2(-2.0, 0.0), lod);
    vec4 e = fetchSource(uv, lod);
    vec4 f = fetchSource(uv + t * vec2(2.0, 0.0), lod);
    vec4 g = fetchSource(uv + t * vec2(-2.0, -2.0), lod);
    vec4 h = fetchSource(uv + t * vec2(0.0, -2.0), lod);
    vec4 i = fetchSource(uv + t * vec2(2.0, -2.0), lod);
    vec4 j = fetchSource(uv + t * vec2(-1.0, 1.0), lod);
    vec4 k = fetchSource(uv + t * vec2(1.0, 1.0), lod);
    vec4 l = fetchSource(uv + t * vec2(-1.0, -1.0), lod);
    vec4 m = fetchSource(uv + t * vec2(1.0, -1.0), lod);

    vec4 result;
    if (level == 1) {
        vec4 box0 = (j + k + l + m) * 0.25;
        vec4 box1 = (a + b + d + e) * 0.25;
        vec4 box2 = (b + c + e + f) * 0.25;
        vec4 box3 = (d + e + g + h) * 0.25;
        vec4 box4 = (e + f + h + i) * 0.25;
        float w0 = 0.5 * karisWeight(box0.rgb);
        float w1 = 0.125 * karisWeight(box1.rgb);
        float w2 = 0.125 * karisWeight(box2.rgb);
        float w3 = 0.125 * karisWeight(box3.rgb);
        float w4 = 0.125 * karisWeight(box4.rgb);
        result = (box0 * w0 + box1 * w1 + box2 * w2 + box3 * w3 + box4 * w4) / (w0 + w1 + w2 + w3 + w4);
    } else {
        result = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    outBloom = result;
}
