#ifndef SETTINGS_INTERNAL_GLSL
#define SETTINGS_INTERNAL_GLSL

//@include "/lib/settings/light.glsl"
//@include "/lib/settings/surface.glsl"
//@include "/lib/settings/post.glsl"

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
    #undef CHARGED_CREEPER_LIGHT
#endif

// 手持ち光源が OFF ならレイ・影も無効
#ifndef HAND_LIGHT
    #undef HAND_LIGHT_RAYS
    #undef HAND_LIGHT_SS_SHADOWS
#endif

// ANALOG はアナログの段の総スイッチ。外れていれば効果ごとのスイッチも全部無効にする
#ifndef ANALOG
    #undef ANALOG_SMEAR
    #undef ANALOG_CHROMA
    #undef ANALOG_RESOLUTION
    #undef ANALOG_SHARPEN
    #undef ANALOG_INTERLACE
    #undef ANALOG_NOISE
    #undef ANALOG_BLOCK
    #undef ANALOG_MOSQUITO
    #undef ANALOG_DROPOUT
    #undef ANALOG_KNEE
    #undef ANALOG_BLOOMING
#endif

// ANALOG_NOISE はセンサーのノイズ 5 種 (ショット・暗部・色・固定パターン・ホットピクセル) の総スイッチ
#ifndef ANALOG_NOISE
    #undef ANALOG_SHOT_NOISE
    #undef ANALOG_DARK_NOISE
    #undef ANALOG_CHROMA_NOISE
    #undef ANALOG_FPN
    #undef ANALOG_HOT_PIXELS
#endif

// 三角形方式のエンティティ遮蔽 (lib/light/entity_tri.glsl)。遮蔽が両方 OFF なら三角形も書かない
// 値付きにして Iris のブール設定として拾われないようにする
#if LIGHT_OCCLUSION_MODE == 1 && (defined LIGHT_ENTITY_OCCLUSION || defined LIGHT_PLAYER_OCCLUSION)
    #define ENTITY_TRI_OCCLUSION 1
#endif

// 画面に映る GI の当たりの直接光を deferred2 の結果から引く (lib/surface/lighting.glsl)。光源の影 (deferred2) と、当たりで光源を数える GI の方式が要る
#if defined GI_HIT_REUSE && defined LIGHT_SHADOWS && GI_MODE >= 2
    #define GI_HIT_DIRECT_REUSE 1
#endif

// 光源の明るさを現実の比にする (lib/common/constants.glsl)。カメラの露出 (3 = M、4〜6 = P・A・S) の時だけ効かせる
#if EXPOSURE_MODE >= 3 && defined EXPOSURE_PHYSICAL_LIGHT
    #define PHYSICAL_LIGHT_ACTIVE 1
#endif

/*
 * HDR のバッファを露出に近い倍率を掛けて持つ (lib/common/pre_exposure.glsl)。現実の光の比は暗い所を fp16 の非正規化数まで下げ、
 * 高い感度・長い SS で持ち上げると刻みが段になるので、その時だけ効かせる
 */
#ifdef PHYSICAL_LIGHT_ACTIVE
    #define PRE_EXPOSURE_ACTIVE 1
#endif

// 水に入った自分を、屈折した視線を自分の三角形に当てて描く (water_trace.fsh)。自分の三角形と水の屈折の両方が要る
#if defined ENTITY_TRI_OCCLUSION && defined LIGHT_PLAYER_OCCLUSION && WATER_REFRACTION >= 1
    #define WATER_SELF_REFRACTION 1
#endif

#endif
