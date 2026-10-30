/*
 * composite12-14: 画面空間の光芒のぼかし (lib/sky/godrays.glsl)。3 パスを同じ本体にマクロで分ける
 *   composite12 (GODRAYS_PASS_0): 空のマスクをタップごとに求め、最短のスパンでぼかす
 *   composite13 (GODRAYS_PASS_1): 中のスパン
 *   composite14 (GODRAYS_PASS_2): 全長のスパン
 * 小さいスパンを先にして、深度のマス目 (低解像度の折り返し) をならしてから長く伸ばす。
 * 3 つの箱 (幅 L/N^2・L/N・L、それぞれ N タップ) を順に畳み込むと、全長 L を間隔 L/N^3 でなぞったのと同じになる
 * 低解像度のバッファ (colortex16) に書くので、texcoord は 0..1 のまま画面の UV として使える
 * sky モジュール (lib/sky)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/sky/godrays.glsl"
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
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/godrays.glsl"
// END GENERATED includes

in vec2 texcoord;

/* RENDERTARGETS: 16 */
layout(location = 0) out float outRays;

#if defined GODRAYS_PASS_0
    const float GODRAYS_SPAN = 1.0 / float(GODRAYS_SAMPLES * GODRAYS_SAMPLES);
    const int GODRAYS_NOISE_CHANNEL = 0;
#elif defined GODRAYS_PASS_1
    const float GODRAYS_SPAN = 1.0 / float(GODRAYS_SAMPLES);
    const int GODRAYS_NOISE_CHANNEL = 1;
#else
    const float GODRAYS_SPAN = 1.0;
    const int GODRAYS_NOISE_CHANNEL = 2;
#endif

void main() {
    vec2 lightUv;
    float outside;
    // 画面全体で同じ条件 (分岐は揃う)
    if (!godraysLightUv(lightUv, outside)) { outRays = 0.0; return; }
    vec3 lightView = normalize(shadowLightPosition);
    float span = GODRAYS_LENGTH * GODRAYS_SPAN;
    vec2 delta = (lightUv - texcoord) * span;
    // パスごとにノイズのチャンネルを変え、TAA で平均する
    float jitter = blueNoise(ivec2(gl_FragCoord.xy), frameCounter)[GODRAYS_NOISE_CHANNEL];
    float sum = 0.0;
    float weightSum = 0.0;
    for (int k = 0; k < GODRAYS_SAMPLES; k++) {
        float t = (float(k) + jitter) / float(GODRAYS_SAMPLES);
        // 指数の減衰は位置の和の指数なので、パスごとに掛けても全体の減衰と一致する
        float w = exp(-GODRAYS_DECAY * t * span);
        vec2 uv = texcoord + delta * t;
#if defined GODRAYS_PASS_0
        sum += evalGodraysSource(uv, lightView) * w;
#else
        sum += fetchGodrays(uv) * w;
#endif
        weightSum += w;
    }
    outRays = sum / weightSum;
}
