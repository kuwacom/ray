/*
 * 物理カメラ (薄レンズ) のボケ半径と絞り形状 (post モジュール)
 * 焦点距離は FOV とセンサー高さから求めるので、望遠鏡やスプリントの FOV 変化でボケの量も物理的に変わる
 */
#ifndef POST_CAMERA_GLSL
#define POST_CAMERA_GLSL

// 焦点距離 (mm)。gbufferProjection[1][1] = 1 / tan(縦 FOV / 2)
float cameraFocalLength() {
    return 0.5 * DOF_SENSOR_HEIGHT * gbufferProjection[1][1];
}

/*
 * 絞り (入射瞳) の直径 (mm)
 * 0: ボケの量 (DOF_STRENGTH)。センサーに比例させて F 値を保つ (フルサイズでは従来どおり、FOV に依らず一定の径)
 * 1: レンズプリセットの開放 F 値, 2: 指定の F 値 (どちらも焦点距離 / F 値なので FOV で変わる)
 * 絞りの無いレンズ (Hologon の固定 F8) は設定に依らず開放 F 値
 */
float cameraApertureDiameter() {
#if defined LENS_FIXED_APERTURE
    return cameraFocalLength() / LP_F_OPEN;
#elif DOF_APERTURE_MODE == 1
    return cameraFocalLength() / LP_F_OPEN;
#elif DOF_APERTURE_MODE == 2
    return cameraFocalLength() / DOF_F_NUMBER;
#else
    return DOF_APERTURE_DIAMETER * DOF_STRENGTH * (DOF_SENSOR_HEIGHT / DOF_SENSOR_HEIGHT_FULL);
#endif
}

/*
 * ボケ半径の上限 (px)。遠景のボケ (画面比) は c / センサー高さ = A / (2 s tan(FOV/2)) で絞り径 A に比例するので、
 * A が既定の何倍かで上限を広げる。既定 (と、それより絞った設定) では FOV に依らず DOF_MAX_RADIUS のまま
 */
float dofMaxRadius() {
    float scale = cameraApertureDiameter() / DOF_APERTURE_REFERENCE;
    return DOF_MAX_RADIUS * clamp(scale, 1.0, DOF_MAX_RADIUS_SCALE) * viewHeight;
}

/*
 * 符号付きのボケ半径 (ピクセル)。負 = 焦点より手前 (前ボケ), 正 = 奥 (後ボケ)
 * 薄レンズ: c = A * f * (d - s) / (d * (s - f)) (センサー上の直径, mm)
 * dist / focus はブロック (= m)
 */
float circleOfConfusion(float dist, float focus) {
    float f = cameraFocalLength();
    float s = max(focus * 1000.0, f * 1.01);
    float d = max(dist * 1000.0, f * 1.01);
    float c = cameraApertureDiameter() * f * (d - s) / (d * (s - f));
    float radiusPx = 0.5 * c / DOF_SENSOR_HEIGHT * viewHeight;
    float maxRadius = dofMaxRadius();
    return clamp(radiusPx, -maxRadius, maxRadius);
}

/*
 * レンズの F 値。被写界深度の絞り径から出し、プリセットの開放 F 値より明るくはしない
 * フレアの形 (絞りの大きさ) と、開放で強まる収差の強さに使う
 */
float lensFNumber() {
    return clamp(cameraFocalLength() / max(cameraApertureDiameter(), 1e-3), LP_F_OPEN, LENS_F_MAX);
}

// 開放の度合い (DOF_STRENGTH 既定の F 値で 1)。開放ほど強くなる収差 (球面収差・軸上色収差) に掛ける
float lensApertureFactor() {
    return clamp(LENS_F_REFERENCE / lensFNumber(), 0.3, 1.6);
}

/*
 * 絞り羽根 N 枚の多角形の、角度 theta 方向の半径 (内接円 = cos(pi/N), 頂点 = 1)
 * 円板のサンプル点をこの比で縮めると多角形のボケになる。羽根の枚数と丸みはレンズプリセットで決まる
 */
float apertureShape(float theta) {
#if LENS_BLADES > 0
    const float blades = float(LENS_BLADES);
    const float segment = TAU / blades;
    float a = theta - DOF_BLADE_ROTATION;
    float local = a - segment * floor(a / segment + 0.5);
    float polygon = cos(PI / blades) / cos(local);
    return mix(polygon, 1.0, LP_BLADE_ROUNDNESS);
#else
    return 1.0;
#endif
}

#endif
