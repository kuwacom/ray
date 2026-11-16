/*
 * アナログのプリセット (post モジュール): ANALOG_PRESET から詳細の値 AP_* を決める
 * AP_* は ANALOG_C_* と 1 対 1 (名前は ANALOG_C_ を AP_ に替えたもの)。列は使う段で足す
 * 値付きの #define にする (設定の値から作る定数。使った所にだけ残り、値付きなので Iris のブール設定に拾われない)。
 * 整数の選択は #if で分け、小数は本文の if で比べる
 * 番号: 0 = カスタム (最後の #else)、1〜6 = 下の機材。新しいプリセットは後ろに足し、既存の番号は変えない (ユーザーの保存値を保つ)
 * 中身は ANALOG の時だけ入れる (ANALOG OFF の本文に定数を残さない)
 */
#ifndef POST_ANALOG_PRESETS_GLSL
#define POST_ANALOG_PRESETS_GLSL

//@include "/lib/settings.glsl"

#ifdef ANALOG
#if ANALOG_PRESET == 1
// 標準の MiniDV (60 Hz 系の DV)。民生の素子の典型値
#define AP_SMEAR_RATIO 0.01
#define AP_SMEAR_TINT_MODE 1
#elif ANALOG_PRESET == 2
// 安いコンパクトのビデオ (小さい素子)
#define AP_SMEAR_RATIO 0.03
#define AP_SMEAR_TINT_MODE 1
#elif ANALOG_PRESET == 3
// 暗い所の自動ゲイン
#define AP_SMEAR_RATIO 0.01
#define AP_SMEAR_TINT_MODE 1
#elif ANALOG_PRESET == 4
// 古い Digital8 (見た目の演出としてスミアを強める)
#define AP_SMEAR_RATIO 0.1
#define AP_SMEAR_TINT_MODE 1
#elif ANALOG_PRESET == 5
// HDV 1080i (3CCD の HDV 機)
#define AP_SMEAR_RATIO 0.003
#define AP_SMEAR_TINT_MODE 1
#elif ANALOG_PRESET == 6
// PAL の MiniDV (50 Hz 系の DV)。形式のほかは 1 と同じ
#define AP_SMEAR_RATIO 0.01
#define AP_SMEAR_TINT_MODE 1
#else
// カスタム (ANALOG_PRESET 0): 詳細設定 (ANALOG_C_*) をそのまま使う
#define AP_SMEAR_RATIO ANALOG_C_SMEAR_RATIO
#define AP_SMEAR_TINT_MODE ANALOG_C_SMEAR_TINT_MODE
#endif
#endif

#endif
