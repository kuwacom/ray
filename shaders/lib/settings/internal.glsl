#ifndef SETTINGS_INTERNAL_GLSL
#define SETTINGS_INTERNAL_GLSL

//@include "/lib/settings/light.glsl"
//@include "/lib/settings/surface.glsl"

// Iris の定数 (設定画面には出さない)
const float ambientOcclusionLevel = 1.0;
const float eyeBrightnessHalflife = 4.0;
const float centerDepthHalflife = 0.6;
// wetnessHalflife / drynessHalflife は書かない。Iris の wetness は使わず、濡れは rainWetness (shaders.properties) が設定 RAIN_WET_HALFLIFE / RAIN_DRY_HALFLIFE で平滑化する
// Iris 1.11 は drynessHalflife を濡れる側に代入するので、乾く側の半減期を const で変えられない
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

// 水に入った自分を、屈折した視線を自分の三角形に当てて描く (water_trace.fsh)。自分の三角形と水の屈折の両方が要る
#if defined ENTITY_TRI_OCCLUSION && defined LIGHT_PLAYER_OCCLUSION && WATER_REFRACTION >= 1
    #define WATER_SELF_REFRACTION 1
#endif

#endif
