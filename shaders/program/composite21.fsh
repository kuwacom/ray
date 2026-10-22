/*
 * composite21: モーションブラー (McGuire et al. 2012 "A Reconstruction Filter for Plausible Motion Blur")
 * 速度は getPreviousUv (カメラ移動 + colortex15 のエンティティ速度)
 * 論文のタイル最大速度パスの代わりに、周囲 8 方向の速度を疎に調べて近傍の最大速度を求める
 * (パスを増やさずに、止まった背景の上へ動く物体のブラーが滲み出す所まで再現する)
 * 手は速度 0 で前景扱いなので、ぼけず、周りへ滲みもしない
 * post モジュール (lib/post)
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

float maxBlurLength() { return MOTION_BLUR_MAX_LENGTH * viewHeight; }

// ピクセル単位の露光中の移動量 (今 - 前)。長さは上限で切る
vec2 blurVelocity(vec2 uv, float depth) {
    vec2 v = (uv - getPreviousUv(uv, depth)) * viewSize() * (MOTION_BLUR_SHUTTER * MOTION_BLUR_STRENGTH);
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

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec4 centerRaw = texelFetch(colortex0, texel, 0);
    vec2 uv = (vec2(texel) + 0.5) * texelSize();
    float depthX = texelFetch(depthtex0, texel, 0).r;

    if (isHandDepth(depthX)) {
        outColor = centerRaw;
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
        float d = texelFetch(depthtex0, ivec2(p * viewSize()), 0).r;
        if (isHandDepth(d)) continue;
        vec2 v = blurVelocity(p, d);
        float s = length(v);
        if (s > speedN) {
            vN = v;
            speedN = s;
        }
    }

    if (speedN < 0.5) {
        outColor = centerRaw;
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

        float depthY = texelFetch(depthtex0, ivec2(uvY * viewSize()), 0).r;
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

        sum += sanitizeColor(textureLod(colortex0, uvY, 0.0).rgb) * w;
        wSum += w;
    }

    outColor = vec4(sum / wSum, centerRaw.a);
}
