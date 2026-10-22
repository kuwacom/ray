#include "/lib/common/common.glsl"

in vec4 glcolor;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 outColor;

/*
 * バニラの稲妻は色 (0.45, 0.45, 0.5) x 不透明度 0.3 の帯を太さ違いで 4 枚重ねて加算する
 * 明るさは露出後の値で決める: 固定の輝度だと夜の露出 (暗い場面で大きく持ち上げる) で何十倍にもなり、
 * 面積の大きい稲妻のブルームが画面の半分を白く霞ませた。露出後で芯がわずかに白飛びし、
 * 外側の 1 枚が淡い青白い光になる程度にして、昼の雷雨でも夜でも同じ見え方にする
 */
const float LIGHTNING_EXPOSED_LUMINANCE = 3.5; // 不透明度 1 あたりの露出後の輝度 (芯は 4 枚 x 0.3 で約 4)

void main() {
    // 頂点色の明るさ (稲妻は暗い灰) は捨てて色味だけ使い、不透明度を重なりの強さにする
    // ドラゴンの光線は白から紫へ色と不透明度が変わるので、同じ式でそのまま描ける
    vec3 hue = srgbToLinear(glcolor.rgb / max(maxOf(glcolor.rgb), 1e-3));
    // colortex4 へは shaders.properties の加算ブレンドで足し、a (覆いの強さ) は変えない
    outColor = vec4(hue * (LIGHTNING_EXPOSED_LUMINANCE * glcolor.a / getExposure()), 0.0);
}
