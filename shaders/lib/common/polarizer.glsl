/*
 * レンズの前の円偏光 (C-PL) フィルターが通す光の比 (sky の空と surface の鏡面が使う)
 * 光を偏光度 p と電場の向き e (視線に垂直) で表す。偏光した分はマリュスの法則 cos^2、残りは 1/2 通るので、
 * 理想の偏光子が非偏光の光を通す 1/2 を 1 とした比は (1 - p) + 2 p cos^2(φ) = 1 + p cos 2φ (φ = 透過軸と e の角)
 * 画全体の減光 (理想の 1 段、カメラのモードは吸収を含めて 1.5 段) は露出 (composite25、CAMERA_FILTER_STOPS) が掛けるので、比が最大 2 でも OFF より明るくならない (ゲーム向けのオートは画全体の段を測光が打ち消すので掛けない)
 * 透過軸は画面に固定した向きを視線に垂直な面へ写すので、画面の端ほど e との角が変わり、広角の空にむらが出る (実機と同じ)
 */
#ifndef COMMON_POLARIZER_GLSL
#define COMMON_POLARIZER_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"

#ifdef CAMERA_PL
/*
 * 晴れた空の太陽から 90° の帯の偏光度。Rayleigh sky model の晴れた空の現実の最大 (約 0.8) より少し下にした (調整値)
 * 太陽の近く・反対側は sin^2 / (1 + cos^2) で 0 に下がる
 */
const float POLARIZER_SKY_MAX = 0.75;
// 曇り・雨の空で偏光度を下げる割合 (曇りの空の偏光度は晴れより大きく下がる。調整値)
const float POLARIZER_SKY_OVERCAST = 0.8;
// 太陽の高さ (sin) がこの間で、空の偏光の模様を月から太陽へ移す (地平線のすぐ下の薄明は太陽の模様が残る。境で模様が跳ばないよう混ぜる)
const vec2 POLARIZER_SUN_Y = vec2(-0.15, -0.05);

// 透過軸 (player 空間)。視線 v に垂直な面へ写したもので、長さは 1 でない
vec3 polarizerAxis(vec3 v) {
    float a = radians(optCameraPlRotation);
    vec3 axis = viewToPlayerDir(vec3(sin(a), cos(a), 0.0));
    return axis - v * dot(axis, v);
}

// 偏光度 p、電場の向き e (v に垂直、長さは問わない) の光が通る比。視線が透過軸と平行な時と e が 0 の時は 1
float polarizerTransmission(vec3 v, vec3 e, float p) {
    vec3 a = polarizerAxis(v);
    float len2 = dot(a, a) * dot(e, e);
    if (!(len2 > 1e-12)) return 1.0;
    return 1.0 + p * (2.0 * sqr(dot(a, e)) / len2 - 1.0);
}

/*
 * 誘電体の反射の偏光度 (Rs - Rp) / (Rs + Rp)。eta = 透過側 / 入射側 (fresnelDielectric と同じ)。全反射は偏光しない
 * g = eta cos(屈折角) として Rs = ((c - g) / (c + g))^2、Rp = ((eta^2 c - g) / (eta^2 c + g))^2。水は 53°、ガラスは 56° (ブルースター角) で 1
 */
float polarizerFresnelDegree(float cosI, float eta) {
    float c = saturate(cosI);
    float g2 = eta * eta - 1.0 + c * c;
    if (g2 <= 0.0) return 0.0;
    float g = sqrt(g2);
    float rs = sqr((c - g) / (c + g));
    float e2c = eta * eta * c;
    float rp = sqr((e2c - g) / (e2c + g));
    return (rs - rp) / max(rs + rp, 1e-8);
}

// F0 から空気側の屈折率比 (n = (1 + sqrt(F0)) / (1 - sqrt(F0)))
float polarizerF0ToEta(float f0) {
    float s = sqrt(clamp(f0, 0.0, 0.9));
    return (1.0 + s) / (1.0 - s);
}

// 法線 n の面の映り込み (視線 v)。反射光は入射面に垂直 (s) に偏光する
float polarizerReflection(vec3 v, vec3 n, float eta) {
    return polarizerTransmission(v, cross(v, n), polarizerFresnelDegree(dot(v, n), eta));
}

// 光源 l の照り返し。照り返すマイクロ面の法線は半ベクトルで、入射面は v と l を含む
float polarizerSpecular(vec3 v, vec3 l, float eta) {
    vec3 h = v + l;
    float hh = dot(h, h);
    if (!(hh > 1e-8)) return 1.0;
    return polarizerTransmission(v, cross(v, l), polarizerFresnelDegree(dot(v, h) * inversesqrt(hh), eta));
}

// 空の散乱光 (視線 dir、光源 light)。偏光度は Rayleigh sky model、e は散乱面 (視線と光源) に垂直
float polarizerSky(vec3 dir, vec3 light, float overcast) {
    float c2 = sqr(dot(dir, light));
    float p = POLARIZER_SKY_MAX * (1.0 - c2) / (1.0 + c2) * (1.0 - POLARIZER_SKY_OVERCAST * overcast);
    return polarizerTransmission(dir, cross(dir, light), p);
}
#endif

#endif
