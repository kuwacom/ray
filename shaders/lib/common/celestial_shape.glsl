/*
 * 太陽と月の見かけの形 (丸い円盤 / バニラのテクスチャの四角)
 * 光源の大きさに依る処理 (雲影の面積の平均、レンズフレアの見え具合と形) はすべてこの形を使い、空に描く物と揃える
 */
#ifndef COMMON_CELESTIAL_SHAPE_GLSL
#define COMMON_CELESTIAL_SHAPE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"

// 太陽・月の円盤の見かけの半径 (rad)。実際 (0.0047) の 2 倍にして画面上で読める大きさにする
const float SUN_ANGULAR_RADIUS = 0.0093;
const float MOON_ANGULAR_RADIUS = 0.0093;
// 月の円盤の見かけの大きさ (MOON_ANGULAR_RADIUS に対する倍率)
const float MOON_DISK_SCALE = 2.5;
/*
 * バニラの太陽と月のテクスチャの明るい四角の半幅 (tan)。どちらも 32 x 32 の中央 8 x 8 が光り、周りは 1 割ほどの淡い光。
 * バニラは太陽を距離 100 に半幅 30、月を半幅 20 の板で描くので 30 / 100 x 8 / 32 と 20 / 100 x 8 / 32
 */
const float VANILLA_SUN_HALF_SIZE = 0.075;
const float VANILLA_MOON_HALF_SIZE = 0.05;

/*
 * 空に描く夜の月の円盤の倍率 (MOON_NIGHT_BRIGHTNESS に掛ける)。写真の月 (SUN_MOON_STYLE 2) は円盤の見かけの大きさで変える。
 * - 通常の画角 (半径 15 画素前後): 模様はほとんど解像されない。半月の写真の反射率は満月の半分以下で、AgX の肩も緩い
 *   (露出後の輝度 3.5 で表示 246) ので、4 倍だと灰色に見える。8 倍で芯を白く飛ばして明るい光にする
 * - 拡大した接写 (半径 36 画素以上): 暗い空は露出が大きく、4 倍でも凸月の明るい側が AgX の白を超えて模様が消える。3 倍で海とクレーターを残す
 */
#if SUN_MOON_STYLE == 2
const float MOON_DISC_NIGHT_GAIN_WIDE = 8.0;
const float MOON_DISC_NIGHT_GAIN_ZOOM = 3.0;
const vec2 MOON_DISC_ZOOM_PIXELS = vec2(18.0, 36.0);
float moonSkyDiscGain() {
    float pixels = MOON_ANGULAR_RADIUS * MOON_DISK_SCALE * 0.5 * viewHeight * gbufferProjection[1][1];
    return mix(MOON_DISC_NIGHT_GAIN_WIDE, MOON_DISC_NIGHT_GAIN_ZOOM, smoothstep(MOON_DISC_ZOOM_PIXELS.x, MOON_DISC_ZOOM_PIXELS.y, pixels));
}
#else
float moonSkyDiscGain() { return MOON_DISK_NIGHT_GAIN; }
#endif
float moonSkyDiscBoost(float sunY) { return moonDiscBoost(sunY, moonSkyDiscGain()); }

/*
 * 天球の極 (太陽の日周運動の回転軸, player 空間)
 * Iris は太陽を Ry(-90) Rz(sunPathRotation) Rx(角度) で回すので、回転軸は (0, sin a, cos a)
 */
vec3 celestialPole() {
    float a = radians(sunPathRotation);
    return vec3(0.0, sin(a), cos(a));
}

/*
 * 影を落とす天体 (昼は太陽、夜は月) の形。バニラの板は回転軸と、回転軸と光の向きの外積に沿う
 * size は丸なら半径、四角なら半幅 (tan)
 */
struct CelestialShape {
    vec3 dir;
    vec3 right;
    vec3 up;
    float size;
};

CelestialShape shadowLightShape() {
    CelestialShape s;
    s.dir = getShadowLightDir();
    s.right = normalize(cross(s.dir, celestialPole()));
    s.up = cross(s.right, s.dir);
    bool sun = dot(shadowLightPosition, sunPosition) > 0.0;
#if SUN_MOON_STYLE == 0
    s.size = sun ? VANILLA_SUN_HALF_SIZE : VANILLA_MOON_HALF_SIZE;
#else
    s.size = sun ? SUN_ANGULAR_RADIUS : MOON_ANGULAR_RADIUS * MOON_DISK_SCALE;
#endif
    return s;
}

// [0,1)^2 の点を、形の中の一様な点 (板の 2 軸の座標, tan) に写す
vec2 celestialShapePoint(CelestialShape s, vec2 xi) {
#if SUN_MOON_STYLE == 0
    return (xi * 2.0 - 1.0) * s.size;
#else
    float a = TAU * xi.y;
    return sqrt(xi.x) * s.size * vec2(cos(a), sin(a));
#endif
}

// 形の中の点 p (板の 2 軸の座標, tan) の向き (player 空間)
vec3 celestialShapeDir(CelestialShape s, vec2 p) { return normalize(s.dir + s.right * p.x + s.up * p.y); }

#endif
