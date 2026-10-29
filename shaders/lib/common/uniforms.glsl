/*
 * Iris 組み込み uniform の宣言 (全プログラム共通)
 * 未使用の uniform はドライバが除去するので、プログラムごとに選ばず全部宣言する
 */
#ifndef COMMON_UNIFORMS_GLSL
#define COMMON_UNIFORMS_GLSL

// カメラ
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform vec3 cameraPositionFract;
uniform ivec3 cameraPositionInt;
uniform vec3 previousCameraPositionFract;
uniform ivec3 previousCameraPositionInt;
uniform vec3 eyePosition;
uniform vec3 relativeEyePosition;
uniform vec3 playerBodyVector;
uniform vec3 playerLookVector;
uniform vec3 upPosition;
uniform ivec2 eyeBrightness;
uniform ivec2 eyeBrightnessSmooth;
uniform float eyeAltitude;
uniform float centerDepthSmooth;
uniform bool firstPersonCamera;

// 行列
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;

// 描画状態
uniform float near;
uniform float far;
uniform float alphaTestRef;
uniform vec4 entityColor;
uniform ivec2 atlasSize;
uniform int renderStage;
uniform vec3 fogColor;
uniform vec3 skyColor;
uniform float fogDensity;
uniform float fogStart;
uniform float fogEnd;
// ネザーのバイオームの重み (shaders.properties のカスタム uniform, 5 秒で切り替わる)。荒地は残り
uniform float netherSoulValley;
uniform float netherCrimson;
uniform float netherWarped;
uniform float netherBasalt;
// 描画距離の外の地面の種類 (カメラのいるバイオーム。shaders.properties のカスタム uniform, 8 秒で切り替わる)
uniform float distantSnow;
uniform float distantSand;
uniform float distantOcean;
// フォグの湿ったバイオーム (shaders.properties のカスタム uniform, 8 秒で切り替わる)
uniform float fogSwamp;
uniform float fogJungle;

// ID
uniform int entityId;
uniform int blockEntityId;
uniform int currentRenderedItemId;
uniform int currentSelectedBlockId;
uniform vec3 currentSelectedBlockPos;
uniform int heldItemId;
uniform int heldItemId2;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

// プレイヤー状態
uniform int isEyeInWater;
uniform bool isSpectator;
uniform bool isRightHanded;
uniform float blindness;
uniform float darknessFactor;
uniform float darknessLightFactor;
uniform float nightVision;
uniform float playerMood;
uniform bool is_burning;
uniform bool hideGUI;

// システム
uniform float viewWidth;
uniform float viewHeight;
uniform float aspectRatio;
uniform float screenBrightness;
uniform int frameCounter;
uniform float frameTime;
uniform float frameTimeCounter;

// ワールド
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform float sunAngle;
uniform float shadowAngle;
uniform int moonPhase;
uniform float rainStrength;
uniform float rainWetness; // 雨の濡れ (shaders.properties のカスタム uniform。Iris の wetness は乾く側の半減期を変えられないので使わない)
uniform float thunderStrength;
uniform vec4 lightningBoltPosition;
uniform int worldTime;
uniform int worldDay;
uniform float cloudHeight; // バニラの雲の下面の基準の y (雲の無いディメンションは NaN)
uniform float cloudTime;   // バニラの雲の x 方向のずれ (ブロック。ゲームの時刻から作られ、時間を止めると止まる)
uniform bool hasSkylight;
uniform bool hasCeiling;
uniform int bedrockLevel;
uniform int heightLimit;

// バイオーム
uniform int biome_precipitation;
uniform float temperature;
uniform float rainfall;

#endif
