/*
 * composite23: ブルームの縮小タイル生成 (colortex0 のミップ -> colortex14 にタイル配置, lib/post/bloom.glsl)
 * 各レベルは 1 つ上のミップから Jimenez 2014 (COD: AW) の 13 タップで縮小する
 * ハードウェアのミップ (箱フィルタ) を直接使うよりエイリアスとちらつきが少ない
 * 最初の縮小の輝度の重み付け (Karis average) は使わない。元の colortex0 は TAA で時間方向に均した後なので 1 フレームだけの
 * ホタルはほとんど残らず (物陰から出た所や動いている間は一部残る)、重みを掛けると照り返しの小さな明るい点のすぐ周りの滲みだけが削れる
 * 閾値は掛けない (エネルギーを捨てない物理寄りのブルーム。強さは final の混合率で決まる)
 * post モジュール (lib/post)
 */
//@include "/lib/common/common.glsl"
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

const bool colortex0MipmapEnabled = true;
const bool colortex17MipmapEnabled = true;

in vec2 texcoord;

/* RENDERTARGETS: 14 */
layout(location = 0) out vec4 outBloom;

/*
 * rgb = ブルームの元の色、a = そのうち溶岩の発光の輝度 (final が溶岩の滲みを溶岩と同じ色を保つトーンマップに寄せる)
 * colortex0.a < 0 は溶岩の発光の割合 (composite19 -> TAA)。ミップは範囲の平均の割合になる
 */
vec4 fetchSource(vec2 uv, float lod) {
    vec2 p = clamp(uv, vec2(0.0), vec2(1.0));
    vec4 s = textureLod(colortex0, p, lod);
    vec3 c = sanitizeColor(s.rgb);
    float lava = clamp(-s.a, 0.0, 1.0);
#ifdef SPECULAR_SPARKLE
    // 光源ブロックの発光の輝度 (colortex17.a, TAA が書く) の、この範囲の明るさに占める割合だけ滲みの元を強める
    float glow = saturate(textureLod(colortex17, p, lod).a / max(luminance(c), 1e-6));
    c *= 1.0 + (EMISSION_BLOOM_GAIN - 1.0) * glow;
#endif
    return vec4(c * (1.0 + (LAVA_BLOOM_GAIN - 1.0) * lava), luminance(c) * LAVA_BLOOM_GAIN * lava);
}

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

    outBloom = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
}
