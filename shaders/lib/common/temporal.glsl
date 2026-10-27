/*
 * 時間方向の蓄積の共通部: 再投影の有効判定、近傍の統計、履歴のクランプ
 * 混合率・クランプの幅・履歴を捨てる条件はパスごとに違うので、呼ぶ側が決める
 */
#ifndef COMMON_TEMPORAL_GLSL
#define COMMON_TEMPORAL_GLSL

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

#endif
