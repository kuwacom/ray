/*
 * 色調整 (post モジュール): ホワイトバランス・コントラスト・彩度・CDL・Purkinje 効果
 * どれもトーンマップ前のシーン線形 (Rec.709) で掛ける。AgX がはみ出しを穏やかに畳むので、後段で掛けるよりクリップしにくい
 */
#ifndef POST_GRADING_GLSL
#define POST_GRADING_GLSL

// 線形 sRGB (D65) <-> XYZ
const mat3 RGB_TO_XYZ = mat3(
    0.4124564, 0.2126729, 0.0193339,
    0.3575761, 0.7151522, 0.1191920,
    0.1804375, 0.0721750, 0.9503041
);
const mat3 XYZ_TO_RGB = mat3(
    3.2404542, -0.9692660, 0.0556434,
    -1.5371385, 1.8760108, -0.2040259,
    -0.4985314, 0.0415560, 1.0572252
);
// Bradford の錐体応答 (色順応変換に使う)
const mat3 XYZ_TO_LMS = mat3(
    0.8951, -0.7502, 0.0389,
    0.2664, 1.7135, -0.0685,
    -0.1614, 0.0367, 1.0296
);
const mat3 LMS_TO_XYZ = mat3(
    0.9869929, 0.4323053, -0.0085287,
    -0.1470543, 0.5183603, 0.0400428,
    0.1599627, 0.0492912, 0.9684867
);

/*
 * ホワイトバランス (Bradford の von Kries 順応)
 * カメラと同じ規約: 設定値 = 想定する照明の色温度。低い値ほど暖色の照明を打ち消すので絵は青くなる
 */
vec3 applyWhiteBalance(vec3 c, float kelvin) {
    vec3 srcLms = XYZ_TO_LMS * (RGB_TO_XYZ * blackbody(kelvin));
    vec3 dstLms = XYZ_TO_LMS * (RGB_TO_XYZ * blackbody(6500.0));
    vec3 lms = XYZ_TO_LMS * (RGB_TO_XYZ * c);
    lms *= dstLms / max(srcLms, EPS);
    return max(XYZ_TO_RGB * (LMS_TO_XYZ * lms), 0.0);
}

// コントラストは log2 ドメインで中間グレーを軸に掛ける (露出を変えても効き方が同じ)
vec3 applyContrast(vec3 c, float contrast) {
    return EXPOSURE_KEY * pow(max(c, 0.0) / EXPOSURE_KEY, vec3(contrast));
}

vec3 applySaturation(vec3 c, float saturation) {
    float l = luminance(c);
    return max(l + saturation * (c - l), 0.0);
}

/*
 * Purkinje 効果: 暗所で桿体が主になり、青緑が相対的に明るく色が抜ける
 * 桿体輝度は Larson et al. 1997 の XYZ 近似、順応状態は自動露出の順応輝度 (シーン単位) から決める
 * 画面内の明るい部分 (光源の周り) は錐体が働くので弱める
 */
vec3 applyPurkinje(vec3 c, float adaptedLuminance, float exposure) {
    float k = 1.0 - smoothstep(log2(PURKINJE_LUM_LOW), log2(PURKINJE_LUM_HIGH), log2(max(adaptedLuminance, 1e-8)));
    k *= 1.0 - smoothstep(0.05, 0.6, luminance(c) * exposure);
    k *= PURKINJE_STRENGTH;
    if (k <= 0.0) return c;

    vec3 xyz = RGB_TO_XYZ * c;
    float scotopic = xyz.y * (1.33 * (1.0 + (xyz.y + xyz.z) / max(xyz.x, 1e-6)) - 1.68);
    scotopic = clamp(scotopic, 0.0, xyz.y * 4.0);
    // 桿体だけで見た時の青みがかった無彩色 (輝度 1 に正規化した色味)
    const vec3 nightTint = vec3(0.80, 0.95, 1.25) / 0.9395;
    return mix(c, scotopic * nightTint, k);
}

#endif
