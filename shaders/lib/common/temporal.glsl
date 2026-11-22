/*
 * 時間方向の蓄積の共通部: 再投影の有効判定、近傍の統計、履歴のクランプ
 * 混合率・クランプの幅・履歴を捨てる条件はパスごとに違うので、呼ぶ側が決める
 */
#ifndef COMMON_TEMPORAL_GLSL
#define COMMON_TEMPORAL_GLSL

//@include "/lib/common/uniforms.glsl"

// 再投影した UV が画面の中 (縁を含む)
bool reprojectionInside(vec2 prevUv) {
    return all(greaterThanEqual(prevUv, vec2(0.0))) && all(lessThanEqual(prevUv, vec2(1.0)));
}

// 重み w の 2 次モーメント m2 = Σ(weight x^2) と平均 mean から標準偏差を求める (w は重みの和)
vec3 momentSigma(vec3 m2, vec3 mean, float w) { return sqrt(max(m2 / w - mean * mean, 0.0)); }
vec4 momentSigma(vec4 m2, vec4 mean, float w) { return sqrt(max(m2 / w - mean * mean, 0.0)); }

// 近傍の min/max の箱を広げる幅。箱の幅に比例した expand と固定の pad の和 (箱が狭いとノイズで履歴が揺れる)
// 履歴は clamp(history, lo - margin, hi + margin) で収める
vec4 neighborBoxMargin(vec4 lo, vec4 hi, float expand, vec4 pad) { return (hi - lo) * expand + pad; }

/*
 * 視線 dir の点を、前フレームへ距離 1/invDistAssumed で戻した時の、本当の距離 1/invDistTrue の点との位置のずれ (画素/フレーム)
 * 回転の再投影は距離によらず正確なので、カメラの平行移動 (視線に垂直な分) だけが効く。雲のように距離が 1 つに決まらない履歴の信頼の目安
 * 距離は逆数で渡す (無限遠は 0)。|移動| が距離より十分小さい近似 (角度のずれ = 垂直な移動 x |1/D - 1/s|)
 */
float parallaxPx(vec3 dir, float invDistAssumed, float invDistTrue) {
    vec3 move = cameraPosition - previousCameraPosition;
    float perpendicular = length(move - dir * dot(move, dir));
    return 0.5 * viewHeight * gbufferProjection[1][1] * perpendicular * abs(invDistAssumed - invDistTrue);
}

/*
 * 位置のずれ eps (画素/フレーム) が毎フレーム続く時、履歴の平均のずれは eps (1 - w) / w。それを tolerance 画素に収める今フレームの重み
 */
float lagWeight(float eps, float tolerance) { return eps / (tolerance + eps); }

/*
 * Catmull-Rom 双三次 (5 タップ、rgba)。双線形の再サンプルは動くたびに分散 d (1 - d) (d = ずれの端数) のぼけを足し、
 * 履歴の重みが小さいほど溜まる。Catmull-Rom は核の分散がほぼ 0 で、ずれが 0 なら中心 1 タップと同じ値
 * 負のローブで出る行き過ぎは、呼ぶ側の近傍クランプで収める
 */
vec4 sampleCatmullRom4(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 pos = uv * texSize;
    vec2 center = floor(pos - 0.5) + 0.5;
    vec2 f = pos - center;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;

    vec2 w0 = -0.5 * f3 + f2 - 0.5 * f;
    vec2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    vec2 w2 = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
    vec2 w3 = 0.5 * f3 - 0.5 * f2;

    vec2 w12 = w1 + w2;
    vec2 tc12 = (center + w2 / w12) / texSize;
    vec2 tc0 = (center - 1.0) / texSize;
    vec2 tc3 = (center + 2.0) / texSize;

    vec4 c = textureLod(tex, vec2(tc12.x, tc0.y), 0.0) * (w12.x * w0.y)
           + textureLod(tex, vec2(tc0.x, tc12.y), 0.0) * (w0.x * w12.y)
           + textureLod(tex, tc12, 0.0) * (w12.x * w12.y)
           + textureLod(tex, vec2(tc3.x, tc12.y), 0.0) * (w3.x * w12.y)
           + textureLod(tex, vec2(tc12.x, tc3.y), 0.0) * (w12.x * w3.y);
    float wSum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(c / wSum, 0.0);
}
#endif
