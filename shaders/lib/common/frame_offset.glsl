/*
 * 低解像度パスのフレームごとのジッター: ブロックの中の 1 ピクセルを巡回して計算し、デノイズ側がこのオフセットで
 * 低解像度テクセルが表すフル解像度のピクセルを復元する (GI・反射・光源・雲で同じ並びを使う)
 */
#ifndef COMMON_FRAME_OFFSET_GLSL
#define COMMON_FRAME_OFFSET_GLSL

// 2x2 ブロックの巡回順。対角を先に埋める順序にすると 2 フレームで 2x2 の偏りが消える
// 配列の宣言場所 (関数の中かグローバルか) でドライバの出すコードが変わるので、グローバルに置く surface/gi.glsl のために式のまま渡す
#define BAYER2_ORDER ivec2[4](ivec2(0, 0), ivec2(1, 1), ivec2(1, 0), ivec2(0, 1))

// i = 0..3 (範囲に収めるのは呼ぶ側)
ivec2 bayerOffset2(int i) {
    const ivec2 o[4] = BAYER2_ORDER;
    return o[i];
}

#endif
