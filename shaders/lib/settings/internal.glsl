#ifndef SETTINGS_INTERNAL_GLSL
#define SETTINGS_INTERNAL_GLSL

#include "/lib/settings/light.glsl"

// Iris の定数 (設定画面には出さない)
const float ambientOcclusionLevel = 1.0;
const float eyeBrightnessHalflife = 4.0;
const float centerDepthHalflife = 0.6;
// 濡れの半減期 (Iris は 0.1 秒単位)。300 (30 秒) では雨が 1 分降っても水たまりがほとんど出ないので短くする
// 濡れは 10 秒で半分 (1 分でほぼ全面)、乾きは 30 秒で半分 (雨上がりもしばらく濡れて雲が残る)
const float wetnessHalflife = 100.0;
const float drynessHalflife = 300.0;
const int noiseTextureResolution = 256;

// reversed shadow culling の非カリング半径。ボクセル体積の水平半径に合わせる
// shadowDistance がこれより小さいとボクセル化範囲が欠けるので、プロファイルでは常に shadowDistance >= voxelDistance にしている
#if VOXEL_VOLUME == 0
    const float voxelDistance = 64.0;
#elif VOXEL_VOLUME == 1
    const float voxelDistance = 96.0;
#elif VOXEL_VOLUME == 2
    const float voxelDistance = 128.0;
#else
    const float voxelDistance = 192.0;
#endif

// 設定から導出される値 (ここだけで定義し、各モジュールはこれを参照する)
#if VOXEL_VOLUME == 0
    #define VOXEL_SIZE_X 128
    #define VOXEL_SIZE_Y 64
    #define VOXEL_SIZE_Z 128
#elif VOXEL_VOLUME == 1
    #define VOXEL_SIZE_X 192
    #define VOXEL_SIZE_Y 96
    #define VOXEL_SIZE_Z 192
#elif VOXEL_VOLUME == 2
    #define VOXEL_SIZE_X 256
    #define VOXEL_SIZE_Y 128
    #define VOXEL_SIZE_Z 256
#else
    #define VOXEL_SIZE_X 384
    #define VOXEL_SIZE_Y 128
    #define VOXEL_SIZE_Z 384
#endif

// ENTITY_LIGHTS は個別スイッチの総スイッチ。外れていれば個別スイッチも全部無効にする
#ifndef ENTITY_LIGHTS
    #undef ITEM_LIGHTS
    #undef PROJECTILE_LIGHTS
    #undef BURNING_ENTITY_LIGHTS
    #undef GLOWING_ENTITY_LIGHTS
#endif

// 手持ち光源が OFF ならレイ・影も無効
#ifndef HAND_LIGHT
    #undef HAND_LIGHT_RAYS
    #undef HAND_LIGHT_SS_SHADOWS
#endif

// 三角形方式のエンティティ遮蔽 (lib/light/entity_tri.glsl)。遮蔽が両方 OFF なら三角形も書かない
// 値付きにして Iris のブール設定として拾われないようにする
#if LIGHT_OCCLUSION_MODE == 1 && (defined LIGHT_ENTITY_OCCLUSION || defined LIGHT_PLAYER_OCCLUSION)
    #define ENTITY_TRI_OCCLUSION 1
#endif

#endif
