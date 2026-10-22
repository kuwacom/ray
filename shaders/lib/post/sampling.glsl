/*
 * post モジュールのサンプリング補助 (双三次フィルタ・NaN 除去)
 */
#ifndef POST_SAMPLING_GLSL
#define POST_SAMPLING_GLSL

// 他のモジュールの出力に NaN / Inf が混ざると TAA 履歴やブルームで画面全体に広がるので入口で止める
vec3 sanitizeColor(vec3 c) {
    if (any(isnan(c)) || any(isinf(c))) return vec3(0.0);
    return max(c, 0.0);
}

/*
 * Catmull-Rom 双三次 (双線形 9 タップを 5 タップに省略, 角の 4 タップは寄与が小さいので省く)
 * TAA の履歴を再サンプルしても双線形のようにぼけない
 */
vec3 sampleCatmullRom(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 pos = uv * texSize;
    vec2 center = floor(pos - 0.5) + 0.5;
    vec2 f = pos - center;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;

    vec2 w0 = -0.5 * f3 + f2 - 0.5 * f;
    vec2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    vec2 w2 = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
    vec2 w3 = 0.5 * f3 - 0.5 * f2;

    vec2 w12 = w1 + w2;
    vec2 tc12 = (center + w2 / w12) / texSize;
    vec2 tc0 = (center - 1.0) / texSize;
    vec2 tc3 = (center + 2.0) / texSize;

    vec3 c = vec3(0.0);
    c += textureLod(tex, vec2(tc12.x, tc0.y), 0.0).rgb * (w12.x * w0.y);
    c += textureLod(tex, vec2(tc0.x, tc12.y), 0.0).rgb * (w0.x * w12.y);
    c += textureLod(tex, tc12, 0.0).rgb * (w12.x * w12.y);
    c += textureLod(tex, vec2(tc3.x, tc12.y), 0.0).rgb * (w3.x * w12.y);
    c += textureLod(tex, vec2(tc12.x, tc3.y), 0.0).rgb * (w12.x * w3.y);
    float wSum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(c / wSum, 0.0);
}

/*
 * 3 次 B スプライン (双線形 4 タップ)。リンギングが無く滑らかなのでブルームのアップサンプルに使う
 * rectMin / rectMax (UV) の外は読まない (タイル配置のバッファ用)
 */
vec4 sampleBSplineClamped4(sampler2D tex, vec2 uv, vec2 texSize, vec2 rectMin, vec2 rectMax) {
    vec2 pos = uv * texSize;
    vec2 center = floor(pos - 0.5) + 0.5;
    vec2 f = pos - center;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    vec2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 w2 = 1.0 - w0 - w1 - w3;

    vec2 s0 = w0 + w1;
    vec2 s1 = w2 + w3;
    vec2 t0 = (center - 1.0 + w1 / s0) / texSize;
    vec2 t1 = (center + 1.0 + w3 / s1) / texSize;
    t0 = clamp(t0, rectMin, rectMax);
    t1 = clamp(t1, rectMin, rectMax);

    return textureLod(tex, vec2(t0.x, t0.y), 0.0) * (s0.x * s0.y)
         + textureLod(tex, vec2(t1.x, t0.y), 0.0) * (s1.x * s0.y)
         + textureLod(tex, vec2(t0.x, t1.y), 0.0) * (s0.x * s1.y)
         + textureLod(tex, vec2(t1.x, t1.y), 0.0) * (s1.x * s1.y);
}

vec3 sampleBSplineClamped(sampler2D tex, vec2 uv, vec2 texSize, vec2 rectMin, vec2 rectMax) {
    return sampleBSplineClamped4(tex, uv, texSize, rectMin, rectMax).rgb;
}

#endif
