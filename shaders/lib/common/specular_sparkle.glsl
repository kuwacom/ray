/*
 * 鏡面の白飛び分 (露出後に白を超えた分)
 * TAA (composite20) は露出込みの c / (1 + L) で混ぜるので、波で毎フレーム動く照り返しや画素より小さい照り返しは
 * HDR のエネルギーを失い、ブルーム・光条・ゴーストに届かない。白を超えた分だけを colortex0.a = 1 + 割合で渡し、
 * TAA の中の線形の短い履歴で時間方向に積分してから足させる (白より下は TAA でアンチエイリアスする)
 * 表示は白を超えるとほぼ白なので、迂回しても輪郭は変わらず、エネルギーだけがポストへ届く
 */
#ifndef COMMON_SPECULAR_SPARKLE_GLSL
#define COMMON_SPECULAR_SPARKLE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"

const float SPARKLE_WHITE = 2.0;  // 露出後の輝度。AgX の肩の中 (上限 7) で、ここから上はほぼ白
const float SPARKLE_KNEE = 1.0;   // 柔らかく切り替える幅 (境目に輪郭を出さない)

// 輝度 l (露出後) のうち threshold を超えた分。ソフトニーで境目をなめらかにつなぐ
float highlightOver(float l, float threshold, float knee) {
    float x = clamp(l - threshold + knee, 0.0, 2.0 * knee);
    return max(l - threshold, x * x / (4.0 * knee));
}

// spec: 鏡面の放射輝度 (露出前), exposure: 露出。戻り値は spec のうち白を超えた分 (露出前)
vec3 sparkleExcess(vec3 spec, float exposure) {
#ifdef SPECULAR_SPARKLE
    float l = luminance(spec) * exposure;
    return spec * (highlightOver(l, SPARKLE_WHITE, SPARKLE_KNEE) / max(l, 1e-6));
#else
    return vec3(0.0);
#endif
}

#endif
