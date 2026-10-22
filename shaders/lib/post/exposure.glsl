/*
 * 露出の単位変換 (post モジュール)
 * 設定の EV は EV100 (反射光式 EV100 = log2(L * 100 / 12.5)) として扱う。L はシーン単位の輝度
 * FrameData.postParams[0]: x = 順応済みの計測 EV100, y = 今フレームの計測 EV100, z = 初期化済みマーカー, w = 適用 EV100
 * FrameData.postParams[1]: x = オートフォーカスの目標距離 (デバッグ用)
 */
#ifndef POST_EXPOSURE_GLSL
#define POST_EXPOSURE_GLSL

const float EXPOSURE_INIT_MARKER = 271.828;

float luminanceToEv100(float l) { return log2(max(l, 1e-10) * 100.0 / EXPOSURE_CALIBRATION); }
float ev100ToLuminance(float ev) { return exp2(ev) * EXPOSURE_CALIBRATION / 100.0; }

// 平均輝度 2^ev 相当の場面を中間グレーへ写す露出倍率
float ev100ToExposure(float ev) { return EXPOSURE_KEY / ev100ToLuminance(ev); }

// ヒストグラムのビン <-> log2 輝度 (ビン 0 は黒)
float histogramBinToLog(float bin) {
    return HISTOGRAM_LOG_MIN + (bin - 0.5) / 255.0 * (HISTOGRAM_LOG_MAX - HISTOGRAM_LOG_MIN);
}

uint luminanceToHistogramBin(float l) {
    if (l < exp2(HISTOGRAM_LOG_MIN)) return 0u;
    float t = (log2(l) - HISTOGRAM_LOG_MIN) / (HISTOGRAM_LOG_MAX - HISTOGRAM_LOG_MIN);
    return uint(clamp(t * 255.0 + 1.0, 1.0, 255.0));
}

#endif
