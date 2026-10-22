/*
 * GI / AO の参照口 (surface モジュール)
 */
#ifndef SURFACE_GI_GLSL
#define SURFACE_GI_GLSL

/*
 * deferred11 のデノイズ済み結果 (colortex8)
 * rgb = 間接光の照度 (空・ブロックライトの拡散に加算), a = AO (空の照度に掛ける)
 */
vec4 getIndirectLight(ivec2 texel) {
#if GI_MODE > 0 || AO_MODE > 0
    return texelFetch(colortex8, texel, 0);
#else
    return vec4(0.0, 0.0, 0.0, 1.0);
#endif
}

/*
 * バニラのスカイライト [0,1] -> 空の照度に掛ける可視率
 * バニラは 1 段 = 1/15 の線形だが、実際の空の見え方は開口部から離れると急に落ちる。
 * 3 乗寄りの曲線で洞窟の奥を暗くしつつ、開口部付近 (0.8 以上) はほぼ 1 に保つ
 */
float skylightCurve(float lm) {
#ifndef HAS_SKYLIGHT
    // ネザー・エンドはスカイライトが常に 0 なので、掛けると環境光 (prepare の一様な SH) が全部消えて真っ黒になる
    // バニラのディメンションの環境光と同じく、場所によらず一様に当てる
    return 1.0;
#else
    float x = saturate(lm);
    return x * x * (0.25 + 0.75 * x);
#endif
}

/*
 * 低解像度パス (GI_RES / 反射) のジッター: 2x2 ブロックの中の 1 ピクセルを 4 フレームで巡回する
 * デノイズ側はこのオフセットで低解像度テクセルが表すフル解像度のピクセルを復元する
 */
// 対角を先に埋める順序にすると 2 フレームで 2x2 の偏りが消える
const ivec2 LOW_RES_OFFSETS[4] = ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1));

ivec2 lowResOffset(int frame) { return LOW_RES_OFFSETS[frame & 3]; }

#endif
