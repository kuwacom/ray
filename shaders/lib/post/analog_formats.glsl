/*
 * アナログの記録の形式の表 (post モジュール): AP_FORMAT_MODE (プリセットか ANALOG_C_FORMAT_MODE) から AF_* を決める
 * 横の輝度の画素 AF_SAMPLES を画面の幅に、走査線 AF_LINES を画面の高さに当てる (16:9 のワイド DV と同じ扱いで、画面の解像度によらず同じ見た目)
 * 列は使う段で足す。値付きの #define にして #if で分けられるようにする (値付きなので Iris のブール設定に拾われない)
 * 中身は ANALOG の時だけ入れる (ANALOG OFF の本文に定数を残さない)
 */
#ifndef POST_ANALOG_FORMATS_GLSL
#define POST_ANALOG_FORMATS_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/post/analog_presets.glsl"

#ifdef ANALOG
#if AP_FORMAT_MODE == 1
// PAL DV (50 Hz 系): 720x576、色差は 4:2:0
#define AF_SAMPLES 720
#define AF_LINES 576
#define AF_CHROMA_X 2
#define AF_CHROMA_Y 2
#define AF_YCC_709 0
#elif AP_FORMAT_MODE == 2
// HDV 1080i: 1440x1080、色差は 4:2:0、HD なので BT.709 の係数
#define AF_SAMPLES 1440
#define AF_LINES 1080
#define AF_CHROMA_X 2
#define AF_CHROMA_Y 2
#define AF_YCC_709 1
#else
// NTSC DV (60 Hz 系): 720x480、色差は 4:1:1 (横 1/4、縦はそのまま)。SD なので BT.601 の係数
#define AF_SAMPLES 720
#define AF_LINES 480
#define AF_CHROMA_X 4
#define AF_CHROMA_Y 1
#define AF_YCC_709 0
#endif
#endif

#endif
