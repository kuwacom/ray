/*
 * HDR のバッファの pre-exposure (Lagarde & de Rousiers 2014 の Frostbite と同じ考え)
 * シーンの値は絶対の単位のまま計算し、fp16 のバッファに書く時だけ倍率 P を掛け、読む時に割って戻す
 * 現実の光の比 (PRE_EXPOSURE_ACTIVE) では夜の地面が 1e-6 前後、新月の最低限の光が 1e-7 前後で、fp16 の正規化数の下限 (6.1e-5) を
 * 下回り、非正規化数の刻み (6e-8) に露出 (夜 1 万〜新月の高感度 100 万倍) を掛けた段が画面に出た
 * P は前のフレームの露出の 2 の冪 (掛けても割っても丸めが出ない) で、1 フレームの中では変えない (begin が決める)。
 * 前のフレームに書いた履歴は、その時の P (preExposurePrev) で戻すので、P が変わっても履歴の明るさはずれない
 * OFF では恒等 (main と同じ機械語)
 * 守ること: 対象のバッファ (docs/architecture.md の colortex と image の表で「P 倍」と書いたもの) を読む・書く所は必ずこの関数を通す。
 * 書くパスより前に読む (前のフレームの値) なら hdrFromStorePrev。通し忘れると P (夜は数千倍) だけ明るさが狂う。
 * 読みの通し忘れは tools/check_slots.py (validate_shaders.py の静的チェック) が見つける。書きは見ないので、新しい書き手は ON の夜で確かめる
 */
#ifndef COMMON_PRE_EXPOSURE_GLSL
#define COMMON_PRE_EXPOSURE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/buffers/frame_data.glsl"

// FrameData.postParams の P を置く場所。x = 今のフレームの P, y = 前のフレームの P, z = シャッター速度の反映の撮れた絵の P
const int PRE_EXPOSURE_PARAM = 11;

#ifdef PRE_EXPOSURE_ACTIVE
/*
 * 露出に対して P を何段下げるか。P = 露出なら画面の白が 1 前後で、上は fp16 の上限まで 16 段あるが、
 * 太陽の円盤 (約 2 万) と鏡面の上限 (32768) が昼の露出 (約 0.5) で白の 1 万倍を超えるので、4 段の余裕を残す
 * (floor で P は露出の 1/32〜1/16)。下は画面の白の約 2^-10 まで正規化数 (刻み 0.1 %)、8bit の最も暗い段 (白の約 2^-12) でも刻みは 1 % 未満
 */
const float PRE_EXPOSURE_HEADROOM_STOPS = 4.0;
// P の範囲 (段)。下は 1 (昼は main と同じ値で持つ)、上は新月の高感度 (露出 4e7 = 2^25) まで
const float PRE_EXPOSURE_MAX_STOPS = 22.0;
// 書く値の上限。fp16 の最大 65504 を超えると無限大になり、TAA が 0 に置き換えて消える
const float PRE_EXPOSED_MAX = 60000.0;

float preExposure() { return frameData.postParams[PRE_EXPOSURE_PARAM].x; }
float preExposurePrev() { return frameData.postParams[PRE_EXPOSURE_PARAM].y; }

// begin が前のフレームの露出から決める
float choosePreExposure(float exposure) {
    float stops = exposure > 0.0 ? floor(log2(exposure)) - PRE_EXPOSURE_HEADROOM_STOPS : 0.0;
    return exp2(clamp(stops, 0.0, PRE_EXPOSURE_MAX_STOPS));
}

vec3 hdrToStore(vec3 c) { return min(c * preExposure(), vec3(PRE_EXPOSED_MAX)); }
vec3 hdrFromStore(vec3 c) { return c * (1.0 / preExposure()); }
vec3 hdrFromStorePrev(vec3 c) { return c * (1.0 / preExposurePrev()); }
// シャッター速度の反映 (1 枚ずつ) の撮れた絵。撮れたフレームの P (z、composite21_a が置く) で戻す
vec3 hdrFromStoreShutter(vec3 c) { return c * (1.0 / frameData.postParams[PRE_EXPOSURE_PARAM].z); }
#else
float preExposure() { return 1.0; }
vec3 hdrToStore(vec3 c) { return c; }
vec3 hdrFromStore(vec3 c) { return c; }
vec3 hdrFromStorePrev(vec3 c) { return c; }
vec3 hdrFromStoreShutter(vec3 c) { return c; }
#endif
// alpha は割合・透過率・距離なので掛けない
vec4 hdrToStore(vec4 c) { return vec4(hdrToStore(c.rgb), c.a); }
vec4 hdrFromStore(vec4 c) { return vec4(hdrFromStore(c.rgb), c.a); }
vec4 hdrFromStorePrev(vec4 c) { return vec4(hdrFromStorePrev(c.rgb), c.a); }

#endif
