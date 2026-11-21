/*
 * composite21: モーションブラー (McGuire et al. 2012 "A Reconstruction Filter for Plausible Motion Blur")
 * 速度は getPreviousUv (カメラ移動 + colortex15 のエンティティ速度)
 * 論文のタイル最大速度パスの代わりに、周囲 8 方向の速度を疎に調べて近傍の最大速度を求める
 * (パスを増やさずに、止まった背景の上へ動く物体のブラーが滲み出す所まで再現する)
 * 手は速度 0 で前景扱いなので、ぼけず、周りへ滲みもしない
 * シャッター速度の反映 (SHUTTER) の時は、ぶれの長さをシャッター速度で決め、ぶれの後の色を画素ごとに溜めて長時間露光にする
 * (モーションブラーが OFF でも走る。溜める重みは composite21_a が書く)
 * post モジュール (lib/post)
 */
#define SSBO_SHUTTER_USE
//@include "/lib/common/common.glsl"
//@include "/lib/post/post_internal.glsl"
//@include "/lib/buffers/shutter.glsl"
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
#include "/lib/buffers/frame_data.glsl"
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
#include "/lib/buffers/shutter.glsl"
// END GENERATED includes

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

float maxBlurLength() { return MOTION_BLUR_MAX_LENGTH * viewHeight; }

#ifdef SHUTTER
/*
 * シャッター速度の反映: 1 フレームの移動量のうち、シャッターが開いている割合 (シャッター角 360 x t / フレームの長さ)
 * 1 フレームより長いシャッターは 360 度で止め、フレームを溜めて残りの時間を足す (溜めたフレームの間を埋め、速い物がとびとびの像にならない)
 */
float blurShutterScale() { return min(cameraShutterSpeed() / max(frameTime, SHUTTER_DT_MIN), 1.0); }
#else
float blurShutterScale() { return MOTION_BLUR_SHUTTER * MOTION_BLUR_STRENGTH; }
#endif

// ピクセル単位の露光中の移動量 (今 - 前)。長さは上限で切る
vec2 blurVelocity(vec2 uv, float depth) {
    vec2 v = (uv - postPreviousUv(uv, depth)) * viewSize() * blurShutterScale();
    float len = length(v);
    float maxLen = maxBlurLength();
    return len > maxLen ? v * (maxLen / len) : v;
}

float viewDistance(float depth) {
    return depth >= 1.0 ? far * 4.0 : linearizeDepth(fixHandDepth(depth));
}

// Y が X より手前なら 1 (柔らかい深度比較)
float inFront(float dY, float dX) { return saturate(1.0 - (dY - dX) / MOTION_BLUR_DEPTH_SOFTNESS); }

float cone(float dist, float speed) { return speed > 1e-3 ? saturate(1.0 - dist / speed) : 0.0; }
float cylinder(float dist, float speed) { return 1.0 - smoothstep(0.95 * speed, 1.05 * speed, dist); }

#ifdef SHUTTER
/*
 * 長時間露光: ぶれの後の色を、composite21_a が決めた重みで画素ごとの平均に溜め、溜めた絵を返す
 * 手は溜めずに今のフレームを出す (手の後ろは見えていた所の平均のまま)。溜め直しのフレームだけは手の色で埋め、0 (黒) から溜めない
 */
vec4 accumulateShutter(ivec2 texel, vec4 color, bool hand) {
    int width = int(viewWidth);
    int index = texel.y * width + texel.x;
    if (texel.x >= width || index >= width * int(viewHeight)) return color;
    vec4 state = frameData.postParams[SHUTTER_PARAM];
    uint flags = uint(state.w);
    vec4 accum = shutterAccum.accum[index];
    // a も有限に丸める。NaN は mix の重み 1 でも残り (NaN x 0 = NaN)、溜め直すまで溶岩の割合 (final) を壊す
    vec4 now = vec4(sanitizeColor(color.rgb), isnan(color.a) || isinf(color.a) ? 0.0 : color.a);
    if (!hand || (flags & SHUTTER_FLAG_RESET) != 0u) accum = mix(accum, now, state.x);
    shutterAccum.accum[index] = accum;
    #if SHUTTER_MODE == 1
    // 1 枚ずつ: 露光を終えたフレームで撮れた絵を移し、次の露光ができるまでそれを出す (最初の 1 枚までは途中経過)
    if ((flags & SHUTTER_FLAG_COMPLETE) != 0u) {
        // 撮れた絵も fp16 なので P を掛けて持つ。出す間に P が変わっても、撮れた時の P (composite21_a が置く) で戻す
        vec3 stored = hdrToStore(accum.rgb);
        shutterShown.shown[index] = uvec2(packHalf2x16(stored.rg), packHalf2x16(vec2(stored.b, accum.a)));
    } else if ((flags & SHUTTER_FLAG_SHOWN) != 0u) {
        uvec2 shown = shutterShown.shown[index];
        accum = vec4(unpackHalf2x16(shown.x), unpackHalf2x16(shown.y));
        accum.rgb = hdrFromStoreShutter(accum.rgb);
    }
    #endif
    return hand ? color : accum;
}
#endif

// 出力を書く。シャッター速度の反映の時は溜めた絵にする
#ifdef SHUTTER
#define WRITE_OUTPUT(color, hand) outColor = hdrToStore(accumulateShutter(texel, color, hand))
#else
#define WRITE_OUTPUT(color, hand) outColor = hdrToStore(color)
#endif

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec4 centerRaw = hdrFromStore(texelFetch(colortex0, texel, 0));
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    // 歪曲・魚眼を TAA で組み立てた時は colortex0 が出力の座標なので、深度は元画像の位置で読む (lib/post/lens.glsl)
    float depthX = texelFetch(depthtex0, LENS_WARP_TAA ? postSourceTexel(uv) : texel, 0).r;

    if (isHandDepth(depthX)) {
        WRITE_OUTPUT(centerRaw, true);
        return;
    }

    vec2 vX = blurVelocity(uv, depthX);
    float speedX = length(vX);

    // 近傍の最大速度 (論文の NeighborMax の近似)
    vec2 vN = vX;
    float speedN = speedX;
    float reach = maxBlurLength() * 0.5;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * (TAU / 8.0);
        vec2 p = uv + vec2(cos(a), sin(a)) * reach * texelSize();
        if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) continue;
        float d = texelFetch(depthtex0, postSourceTexel(p), 0).r;
        if (isHandDepth(d)) continue;
        vec2 v = blurVelocity(p, d);
        float s = length(v);
        if (s > speedN) {
            vN = v;
            speedN = s;
        }
    }

    if (speedN < 0.5) {
        WRITE_OUTPUT(centerRaw, false);
        return;
    }

    float distX = viewDistance(depthX);
    float jitter = interleavedGradientNoise(gl_FragCoord.xy, frameCounter) - 0.5;

    vec3 sum = sanitizeColor(centerRaw.rgb) / max(speedX, 1.0);
    float wSum = 1.0 / max(speedX, 1.0);
    for (int i = 0; i < MOTION_BLUR_SAMPLES; i++) {
        // シャッターの中央を基準に前後へ対称に (-1 .. 1)。ディザでサンプルの縞を消す
        float t = mix(-1.0, 1.0, (float(i) + jitter + 1.0) / float(MOTION_BLUR_SAMPLES + 1));
        vec2 offsetPx = vN * (0.5 * t);
        vec2 uvY = uv + offsetPx * texelSize();
        if (any(lessThan(uvY, vec2(0.0))) || any(greaterThan(uvY, vec2(1.0)))) continue;

        float depthY = texelFetch(depthtex0, postSourceTexel(uvY), 0).r;
        bool handY = isHandDepth(depthY);
        float speedY = handY ? 0.0 : length(blurVelocity(uvY, depthY));
        float distY = viewDistance(depthY);
        float dist = length(offsetPx);

        float f = inFront(distY, distX);
        float b = inFront(distX, distY);
        float w = f * cone(dist, speedY)
                + b * cone(dist, speedX)
                + cylinder(dist, speedY) * cylinder(dist, speedX) * 2.0;
        if (handY) w = 0.0;

        sum += sanitizeColor(hdrFromStore(textureLod(colortex0, uvY, 0.0).rgb)) * w;
        wSum += w;
    }

    WRITE_OUTPUT(vec4(sum / wSum, centerRaw.a), false);
}
