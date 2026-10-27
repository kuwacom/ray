/*
 * フォグの高さテンプレート (FOG_HEIGHT_PRESET, sky モジュール。fog.glsl が clouds.glsl の後に読む)
 * 番号は雲の CLOUD_HEIGHT_PRESET と同じ並びで、4 は雲のテンプレートに合わせる
 * 値はワールドの y。もや (混合層) の上端は雲底の 3/4 で雲とそろう。地表の霧ほど縮めない (薄い層は最小の厚みを持つ)
 *   FOG_T_SEA:         基準の海面
 *   FOG_T_HAZE_TOP:    昼のもやの上端 (混合層の上端)。朝と夜は低くなる
 *   FOG_T_HAZE_SOFT:   もやの上端の柔らかさ (ロジスティックの幅)
 *   FOG_T_HAZE_FREE:   もやの上の薄い残りの減衰長
 *   FOG_T_LAYER_BASE / FOG_T_LAYER_TOP: 中くらいの高さの霧の層
 *   FOG_T_GROUND_TOP / FOG_T_GROUND_SOFT: 地表の霧 (放射霧・谷霧) の上端
 *   FOG_T_LIGHT_SCALE: 1 ブロックが現実の何 m か (空中遠近のエアロゾルが高さで減る速さ)
 */
#ifndef SKY_FOG_TEMPLATE_GLSL
#define SKY_FOG_TEMPLATE_GLSL

#include "/lib/settings.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/clouds.glsl"

#if FOG_HEIGHT_PRESET == 4
    #if CLOUD_HEIGHT_PRESET == 3
        #define FOG_T_FROM_CLOUDS
    #else
        #define FOG_T_INDEX CLOUD_HEIGHT_PRESET
    #endif
#elif FOG_HEIGHT_PRESET == 3
    #define FOG_T_CUSTOM
#else
    #define FOG_T_INDEX FOG_HEIGHT_PRESET
#endif

#if defined FOG_T_CUSTOM
    // カスタム: スライダーの値。もやの上端の 0 は雲底の 3/4、柔らかさと残りは厚みから
    const float FOG_T_SEA = float(FOG_C_SEA_LEVEL);
    const float FOG_T_HAZE_TOP = FOG_C_HAZE_TOP > 0.0 ? FOG_C_HAZE_TOP : FOG_T_SEA + 0.75 * max(CLOUD_BASE - FOG_T_SEA, 16.0);
    const float FOG_T_HAZE_SOFT = max((FOG_T_HAZE_TOP - FOG_T_SEA) / 6.5, 3.0);
    const float FOG_T_HAZE_FREE = 5.0 * max(FOG_T_HAZE_TOP - FOG_T_SEA, 16.0);
    const float FOG_T_LAYER_BASE = FOG_C_LAYER_BASE;
    const float FOG_T_LAYER_TOP = FOG_C_LAYER_BASE + FOG_C_LAYER_THICKNESS;
    const float FOG_T_GROUND_TOP = float(FOG_MIST_ALTITUDE);
    const float FOG_T_GROUND_SOFT = max((FOG_T_GROUND_TOP - FOG_T_SEA) / 4.0, 3.0);
    // 混合層の厚み (現実の昼 約 1.1 km) がもやの厚みになる縮尺
    const float FOG_T_LIGHT_SCALE = 1078.0 / max(FOG_T_HAZE_TOP - FOG_T_SEA, 16.0);
#elif defined FOG_T_FROM_CLOUDS
    // 雲のカスタムの高さに合わせる: 雲の水平の縮尺 (参照 m / ブロック) で現実の寸法を縮め、薄い層には最小の厚みを残す
    const float FOG_T_SEA = SKY_SEA_LEVEL;
    const float FOG_T_HAZE_TOP = FOG_T_SEA + 0.75 * max(CLOUD_BASE - FOG_T_SEA, 16.0);
    const float FOG_T_HAZE_SOFT = max(150.0 / CLOUD_KH, 3.0);
    const float FOG_T_HAZE_FREE = max(8000.0 / CLOUD_KH, 400.0);
    const float FOG_T_LAYER_BASE = FOG_T_SEA + max(97.0 / CLOUD_KH, 7.0);
    const float FOG_T_LAYER_TOP = FOG_T_LAYER_BASE + max(340.0 / CLOUD_KH, 35.0);
    const float FOG_T_GROUND_TOP = FOG_T_SEA + max(30.0 / CLOUD_KH, 8.0);
    const float FOG_T_GROUND_SOFT = max(10.0 / CLOUD_KH, 4.0);
    const float FOG_T_LIGHT_SCALE = CLOUD_KH;
#elif FOG_T_INDEX == 0
    // バニラ (-64..320): もや y 63-143 (雲底 y 170 の 3/4)、霧の層 y 70-105、地表の霧は海面から 8 ブロック
    const float FOG_T_SEA = 63.0;
    const float FOG_T_HAZE_TOP = 143.0;
    const float FOG_T_HAZE_SOFT = 12.0;
    const float FOG_T_HAZE_FREE = 400.0;
    const float FOG_T_LAYER_BASE = 70.0;
    const float FOG_T_LAYER_TOP = 105.0;
    const float FOG_T_GROUND_TOP = 71.0;
    const float FOG_T_GROUND_SOFT = 4.0;
    const float FOG_T_LIGHT_SCALE = 14.0;
#elif FOG_T_INDEX == 1
    // 高さ拡張 (頂 2000 前後): 雲底 y 520 に合わせる
    const float FOG_T_SEA = 63.0;
    const float FOG_T_HAZE_TOP = 406.0;
    const float FOG_T_HAZE_SOFT = 40.0;
    const float FOG_T_HAZE_FREE = 1500.0;
    const float FOG_T_LAYER_BASE = 90.0;
    const float FOG_T_LAYER_TOP = 200.0;
    const float FOG_T_GROUND_TOP = 78.0;
    const float FOG_T_GROUND_SOFT = 6.0;
    const float FOG_T_LIGHT_SCALE = 3.3;
#else
    // 実寸 (1 ブロック = 1 m): 混合層 1.1 km、霧の層 100-440 m、放射霧 30 m
    const float FOG_T_SEA = 63.0;
    const float FOG_T_HAZE_TOP = 1141.0;
    const float FOG_T_HAZE_SOFT = 150.0;
    const float FOG_T_HAZE_FREE = 8000.0;
    const float FOG_T_LAYER_BASE = 160.0;
    const float FOG_T_LAYER_TOP = 500.0;
    const float FOG_T_GROUND_TOP = 93.0;
    const float FOG_T_GROUND_SOFT = 10.0;
    const float FOG_T_LIGHT_SCALE = 1.0;
#endif

// 層の柔らかさ (霧の層の上下の面)
const float FOG_T_LAYER_SOFT = max((FOG_T_LAYER_TOP - FOG_T_LAYER_BASE) / 7.0, 2.0);

#endif
