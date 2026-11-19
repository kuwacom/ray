/*
 * 露出の単位変換 (post モジュール)
 * 設定の EV は EV100 (反射光式 EV100 = log2(L * 100 / 12.5)) として扱う。L はシーン単位の輝度
 * FrameData.postParams[0]: x = 順応済みの計測 EV100, y = 今フレームの計測 EV100, z = 初期化済みマーカー, w = 適用 EV100
 * FrameData.postParams[1]: x = オートフォーカスの目標距離 (デバッグ用), y = 順応済みの暗い側の計測 EV100 (夜の持ち上げと灯りの割合用)
 * FrameData.postParams[2]: x = 平滑化済みのフレアの見え具合, y = 今フレーム
 * FrameData.postParams[3]: バニラの四角の見えている点の格子位置の重み付きモーメント (x, y, x^2, y^2。見え具合と同じ重みと平滑)
 * FrameData.postParams[4]: フレアのループの回数 (lib/post/lens_flare.glsl)。x = ゴースト, y = ゴーストの波長, z = 画面の光条の線, w = 画面のゴースト
 * FrameData.postParams[5]: 自動露出の順応済みの補助の値。x = ハイライト重点の上限の EV100, y = 評価測光の夜の白飛びを抑える EV100,
 *                         z = 灯りに照らされた所の割合, w = DR の補正で暗く撮った EV (final が戻す)
 * FrameData.postParams[6]: 古い方式の自動露出の状態。x = 絞りの EV100, y = 絞りの動く速さ, z = ゲイン (段), w = 検波した測光 EV100
 * FrameData.postParams[7]: シャッター速度の反映の状態 (composite21_a が書く)。x = このフレームを溜める重み, y = 今の露光で溜めた秒 (1 枚ずつ),
 *                         z = 溜め始めた時の画面の画素数, w = 印 (SHUTTER_FLAG_*)
 */
#ifndef POST_EXPOSURE_GLSL
#define POST_EXPOSURE_GLSL

//@include "/lib/common/uniforms.glsl"
//@include "/lib/post/post_constants.glsl"

const float EYE_BRIGHTNESS_MAX = 240.0; // eyeBrightness の最大値
// 窓のある部屋 (スカイライト 11 前後) は屋内、木の下・軒下 (14) は屋外として扱う範囲
// 下端 0.6 では窓のある部屋 (0.73) が 3 割屋外になり、屋内の暗さがほとんど効かなかった
const vec2 OUTDOOR_SKYLIGHT = vec2(0.75, 0.93);

// 目の位置が屋外か [0,1]。露出の夜の持ち上げと夜のブルームが共有する
float eyeOutdoor() {
    return smoothstep(OUTDOOR_SKYLIGHT.x, OUTDOOR_SKYLIGHT.y, float(eyeBrightnessSmooth.y) / EYE_BRIGHTNESS_MAX);
}

const float EXPOSURE_INIT_MARKER = 271.828;
// EV100 の基準の感度 (設定の EXPOSURE_ISO とは別)
const float EXPOSURE_ISO_REFERENCE = 100.0;

float luminanceToEv100(float l) { return log2(max(l, 1e-10) * EXPOSURE_ISO_REFERENCE / EXPOSURE_CALIBRATION); }
float ev100ToLuminance(float ev) { return exp2(ev) * EXPOSURE_CALIBRATION / EXPOSURE_ISO_REFERENCE; }

// 平均輝度 2^ev 相当の場面を中間グレーへ写す露出倍率
float ev100ToExposure(float ev) { return EXPOSURE_KEY / ev100ToLuminance(ev); }

// ヒストグラムのビン <-> log2 輝度 (ビン 0 は黒)
float histogramBinToLog(float bin) {
    return HISTOGRAM_LOG_MIN + (bin - 0.5) / HISTOGRAM_LAST_BIN * (HISTOGRAM_LOG_MAX - HISTOGRAM_LOG_MIN);
}

uint luminanceToHistogramBin(float l) {
    if (l < exp2(HISTOGRAM_LOG_MIN)) return 0u;
    float t = (log2(l) - HISTOGRAM_LOG_MIN) / (HISTOGRAM_LOG_MAX - HISTOGRAM_LOG_MIN);
    return uint(clamp(t * HISTOGRAM_LAST_BIN + 1.0, 1.0, HISTOGRAM_LAST_BIN));
}

#endif
