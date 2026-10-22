#ifndef COMMON_CONSTANTS_GLSL
#define COMMON_CONSTANTS_GLSL

const float PI = 3.14159265358979;
const float TAU = 6.28318530717959;
const float HALF_PI = 1.57079632679490;
const float RCP_PI = 0.318309886183791;
const float GOLDEN_ANGLE = 2.39996322972865;
const float EPS = 1e-5;

/*
 * 放射量の基準 (全モジュール共通のスケール)
 * シーンは線形 HDR。値は物理単位ではなく、自動露出 (post モジュール) が吸収する前提の相対値
 * 各モジュールはこの定数を掛けて出力し、勝手に別スケールを作らない
 */
const float SUN_ILLUMINANCE = 6.0;        // 正午の太陽直達照度 (大気透過前)
const float MOON_ILLUMINANCE = 0.012;     // 満月の直達照度
const float SKY_ILLUMINANCE = 1.0;        // 空の拡散照度の基準
const float BLOCKLIGHT_ILLUMINANCE = 2.5; // 光源レベル 15 の光源から 1 ブロック離れた面の照度
const float EMISSION_LUMINANCE = 4.0;     // 発光テクスチャ (emission=1) の輝度
const float MIN_AMBIENT = 0.004;          // 洞窟の最低限の可視光 (真っ暗を避ける)
const float NIGHT_VISION_AMBIENT = 0.6;

// 深度がこれ未満なら手持ちアイテム (Iris は手を near 寄りの深度で描く)
const float HAND_DEPTH_THRESHOLD = 0.56;

#endif
