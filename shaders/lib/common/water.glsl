/*
 * 水面 (surface モジュール)
 * - 波: FFT で焼いた周期タイル (tools/gen_water_waves.py, Tessendorf 2001) を無理数比 (2.9 倍) で 5 層に重ねる
 *       テクスチャは対数波数の cos^2 窓の帯で、隣の層と足すと切れ目のないスペクトルになる。時間方向もループしていて、
 *       層ごとに周期を sqrt(タイルの大きさ) に比例させるので、どの層も深水の分散関係 (omega = sqrt(g k)) で動く
 *       層の重み (傾きの分散) は風速と吹送距離から決める: 平衡域の傾きの分散は波数の対数あたり一定 (Phillips) で、
 *       それより長い波はピーク (Pierson-Moskowitz / JONSWAP) で切る。全体は Cox-Munk (1954) の傾きの分散に合わせる
 *       波頭の尖りは水平変位の Jacobian で勾配を割って出す (チョッピネス)。画素より細かい層は粗さへ回す
 * - 海 / 湖 / 川 はカメラのバイオームで切り替える (湖・川は吹送距離が短く、波が短く低い)。傾いた流れの面は流れの向きへ流す
 * - 雨の波紋: セルごとの同心円 (2 層ずらし)
 * - 吸収 / 散乱: Jerlov の外洋タイプ IB 付近の係数 (1 ブロック = 1 m)
 * - コースティクス: 受け面側で水面の屈折光の面積比 (ヤコビアン) を有限差分で求める
 */
#ifndef COMMON_WATER_GLSL
#define COMMON_WATER_GLSL

//@include "/lib/common/water_waves.glsl"
//@include "/lib/common/water_glitter.glsl"
//@include "/lib/common/water_normal.glsl"

#endif
