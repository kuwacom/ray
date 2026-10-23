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
 * GI のレイが空の光も運ぶ (SSGI / ボクセル RT, 空のあるディメンション)
 * 空へ抜けたレイが方向ごとの空の色を返し、deferred30 は空の環境光 (方向の無いスカイライト x AO の遮蔽) をこれで置き換える。
 * 以前は抜けたレイが 0 で、当たったレイの照り返しを空の光に足していたので、軒下・洞窟の入り口・森の中で空の光の向きが無く、
 * 照り返しも二重だった (FB #60)。RSM (GI_MODE=1) は可視性を見ないので、空の環境光はスカイライトと AO のまま
 */
#if (GI_MODE == 2 || GI_MODE == 3) && defined HAS_SKY
    #define GI_TRACES_SKY
#endif
/*
 * ボクセル RT の空へ抜けたレイに掛けるスカイライトの絞り。遮蔽はレイが見るので、スカイライトは
 * 届く距離 (VOXEL_GI_DISTANCE) より大きな洞窟の奥へ空の光が漏れるのを止めるだけに使う (スカイライト 0 で 0、5 段で 1)
 */
const float GI_SKY_GATE_LIGHTMAP = 0.35;
float giVoxelSkyGate(float skyLm) { return smoothstep(0.0, GI_SKY_GATE_LIGHTMAP, skyLm); }

// RSM は可視性を見ないので、スカイライトがこの範囲で 0 -> 1 になるように絞る (deferred10)。deferred30 が SH から引く地面の分も同じ絞り
const float RSM_SKYLIGHT_MIN = 0.1;
const float RSM_SKYLIGHT_MAX = 0.6;

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
