/*
 * アナログ領域 (2000 年代の民生 CCD ビデオカメラの画、post モジュール)
 * 中身は ANALOG の時だけ入れる (ANALOG OFF の final の本文を今と同じにする)
 */
#ifndef POST_ANALOG_GLSL
#define POST_ANALOG_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/buffers/analog_smear.glsl"
//@include "/lib/post/analog_presets.glsl"

#if defined ANALOG && defined ANALOG_SMEAR && defined SSBO_ANALOG_SMEAR_USE
/*
 * ### applyAnalogSmear
 * CCD の縦スミア。インターライン転送 CCD では明るい光が垂直転送レジスタへ漏れ、読み出しの転送の間に足され続けて列全体の筋になる
 * スミア比 (転送時間 / 蓄積時間) は列が一様に照らされた時の比なので、列の平均にそのまま掛ける。
 * 線形なのでしきい値も減衰も持たない (一様な画面は小さな一様の底上げで、明るい光の列だけが筋に見える)
 *
 * @param hdr - 露出前の線形の色
 * @param column - colortex0 の列 (composite26 が平均を取った座標)
 * @returns 筋を足した色
 */
vec3 applyAnalogSmear(vec3 hdr, int column) {
    vec3 mean = analogSmear.columns[clamp(column, 0, ANALOG_SMEAR_COLUMNS_ALLOC - 1)].rgb;
#if AP_SMEAR_TINT_MODE == 0
    vec3 streak = mean;
#else
    // 漏れた電荷は列のどの色の画素の読み出しにも同じだけ足されるので、筋は白い (列の平均の輝度)
    vec3 streak = vec3(luminance(mean));
#endif
    // AP_SMEAR_RATIO は % なので比に直す
    return hdr + streak * (AP_SMEAR_RATIO / 100.0);
}
#endif

#endif
