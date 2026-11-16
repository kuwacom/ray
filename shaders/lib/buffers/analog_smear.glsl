/*
 * SSBO binding 6: CCD の縦スミアの列の平均 (post, lib/post/analog.glsl)
 * composite26 (program/post/analog_smear.csh) が colortex0 (線形 HDR、露出前、DoF・MB の後) の列ごとの平均を書き、final が読む
 * 確保: 131072 バイト (shaders.properties の bufferObject.6。ANALOG と ANALOG_SMEAR の時だけ)
 * 宣言は opt-in: 読むプログラムは include の前に SSBO_ANALOG_SMEAR_USE を、書くプログラム (composite26) は加えて SSBO_ANALOG_SMEAR_WRITE を定義する
 * 設定は defined だけを見て値を本文に残さない。ANALOG が OFF なら宣言ごと入らず、final の本文が今と同じになる
 */
#ifndef BUFFERS_ANALOG_SMEAR_GLSL
#define BUFFERS_ANALOG_SMEAR_GLSL

//@include "/lib/settings.glsl"

#if defined SSBO_ANALOG_SMEAR_USE && defined ANALOG && defined ANALOG_SMEAR

#ifdef SSBO_ANALOG_SMEAR_WRITE
    #define SSBO_ANALOG_SMEAR_ACCESS
#else
    #define SSBO_ANALOG_SMEAR_ACCESS readonly
#endif

// 列の数の上限 (8K の幅 7680 まで)。composite26 の workGroups.x x local_size_x と同じ
const int ANALOG_SMEAR_COLUMNS_ALLOC = 8192;

layout(std430, binding = 6) SSBO_ANALOG_SMEAR_ACCESS buffer AnalogSmearBuffer {
    vec4 columns[];  // rgb = 列の平均 (線形、露出前), a = 予備。要素数: ANALOG_SMEAR_COLUMNS_ALLOC
} analogSmear;

#endif

#endif
