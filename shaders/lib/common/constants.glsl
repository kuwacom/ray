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
/*
 * 夜の月の放射の倍率 (見た目の調整)。物理的な放射のままだと、鏡像が空の月より桁違いに明るい白い塊になり、
 * フレアも小さな円盤から昼の太陽並みに伸びるので、鏡像の上限・地球照・フレアの基準はこの値にする。
 * 昼の月は青空と同じくらいの明るさで淡く見えるのが正しいので 1 にする
 */
const float MOON_NIGHT_BRIGHTNESS = 0.004;
/*
 * 空に描く夜の円盤だけの倍率 (MOON_NIGHT_BRIGHTNESS に掛ける)。AgX の肩は緩く、基準のままだと円盤は灰色 (Y 180 前後) で、
 * 8 倍で芯が Y 245 に届き、16 倍で白飛びする。それ以上は縁にブルームの輝きが乗る (周りの暈は大気の散乱が決めるので変わらない)。
 * 鏡像の上限・フレアの強さ・地面の月光には掛けない
 */
const float MOON_DISK_NIGHT_GAIN = 32.0;

// 昼の度合い (太陽の高さ sunY で 0 = 夜 .. 1 = 昼)。月の放射の昼夜の切り替え
float moonDayMix(float sunY) { return smoothstep(-0.1, 0.1, sunY); }
// 空に描く月の円盤の放射が、鏡像・フレアの基準 (MOON_NIGHT_BRIGHTNESS) の何倍か。昼は 1
float moonDiscBoost(float sunY) {
    float day = moonDayMix(sunY);
    return mix(MOON_NIGHT_BRIGHTNESS * MOON_DISK_NIGHT_GAIN, 1.0, day) / mix(MOON_NIGHT_BRIGHTNESS, 1.0, day);
}
const float SKY_ILLUMINANCE = 1.0;        // 空の拡散照度の基準
const float BLOCKLIGHT_ILLUMINANCE = 2.5; // 光源レベル 15 の光源から 1 ブロック離れた面の照度
const float EMISSION_LUMINANCE = 4.0;     // 発光テクスチャ (emission=1) の輝度
const float MIN_AMBIENT = 0.004;          // 洞窟の最低限の可視光 (真っ暗を避ける)
const float NIGHT_VISION_AMBIENT = 0.6;
const float LIGHT_LEVEL_MAX = 15.0;       // バニラの光源レベルの最大値

// ライトマップ座標を [0,1] に直す: (x - 1/32) * 32 / 30 で、1/32 が 0、31/32 が 1
const float LIGHTMAP_TEXELS = 32.0;
const float LIGHTMAP_RANGE = 30.0;

// 深度がこれ未満なら手持ちアイテム (Iris は手を near 寄りの深度で描く)
const float HAND_DEPTH_THRESHOLD = 0.56;

#endif
