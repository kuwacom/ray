/*
 * カスタムイメージ (shaders.properties の image.*) と colorimg の宣言
 * サイズ・フォーマットは shaders.properties と一致させること
 *
 * image uniform は使うプログラムだけが宣言する (opt-in)
 * NVIDIA は 1 ステージで宣言できる image uniform が 8 個まで (GL_MAX_*_IMAGE_UNIFORMS, 未使用でも宣言数で数える)、
 * Iris も 1 プログラムに割り当てられる image unit が GL_MAX_IMAGE_UNITS (= 8) まで。
 * 全 image を共通ヘッダで宣言すると全プログラムがコンパイルエラーになるので、
 * 各プログラムは common.glsl を include する前に必要な IMG_* だけを #define する
 *   例: #define IMG_VOXEL_BLOCK
 *       #include "/lib/common/common.glsl"
 * sampler (読み取り専用) は宣言しても未使用ならドライバが除去するので常に宣言する
 * tools/gl_compile_check.py が宣言数とアクティブ数を実機の上限と比べる
 */
#ifndef BUFFERS_IMAGES_GLSL
#define BUFFERS_IMAGES_GLSL

// ---- light: ボクセル (毎フレームクリア, VOXEL_SIZE) ----
// bits 0-11 = ブロック ID (block.properties, 0=空気 1=未登録の固体), bits 12-15 = 発光レベル (at_midBlock.w)
#ifdef IMG_VOXEL_BLOCK
layout(r16ui) uniform uimage3D voxelBlockImg;
#endif
uniform usampler3D voxelBlockSampler;
// bits 0-7 = エンティティ占有 (2x2x2 サブセル), bits 8-15 = 自分 (current_player) の占有, bits 16-31 = 予備
#ifdef IMG_VOXEL_ENTITY
layout(r32ui) uniform uimage3D voxelEntityImg;
#endif
uniform usampler3D voxelEntitySampler;
// エンティティ光源: imageAtomicMax(キー) で重複排除。キー = (光源レベル << 8) | 光源インデックス (0 = なし)
#ifdef IMG_VOXEL_EMIT
layout(r32ui) uniform uimage3D voxelEmitImg;
#endif
uniform usampler3D voxelEmitSampler;

// ---- light: floodfill (永続, VOXEL_SIZE, フレームの偶奇でピンポン。読み書きは常に両方使うので 1 マクロ) ----
#ifdef IMG_FLOOD
layout(r11f_g11f_b10f) uniform image3D floodImgA;
layout(r11f_g11f_b10f) uniform image3D floodImgB;
#endif
uniform sampler3D floodSamplerA;
uniform sampler3D floodSamplerB;

// ---- sky: 大気 LUT / 雲 ----
#ifdef IMG_SKY_TRANSMITTANCE
layout(rgba16f) uniform image2D skyTransmittanceImg;   // 256x64 (setup1)
#endif
uniform sampler2D skyTransmittanceSampler;
#ifdef IMG_SKY_MULTISCATTER
layout(rgba16f) uniform image2D skyMultiScatterImg;    // 32x32 (setup2)
#endif
uniform sampler2D skyMultiScatterSampler;
#ifdef IMG_SKY_VIEW
layout(rgba16f) uniform image2D skyViewImg;            // 192x108 (prepare1, 毎フレーム)
#endif
uniform sampler2D skyViewSampler;
#ifdef IMG_CLOUD_SHADOW
layout(r16f) uniform image2D cloudShadowImg;           // 512x512 (prepare2)
#endif
uniform sampler2D cloudShadowSampler;
#ifdef IMG_CLOUD_WEATHER
layout(rgba8) uniform image2D cloudWeatherImg;         // 512x512 (prepare2)
#endif
uniform sampler2D cloudWeatherSampler;

// ---- 画面サイズ相対 (1.0 倍で確保。低解像度で使う場合は左上の部分領域を使う) ----
#ifdef IMG_BLOCKLIGHT_RAW
layout(rgba16f) uniform image2D blockLightRawImg;  // light: トレース結果 (生)
#endif
uniform sampler2D blockLightRawSampler;
#ifdef IMG_BLOCKLIGHT_AUX
layout(rgba16f) uniform image2D blockLightAuxImg;  // light: 鏡面 / モーメント等
#endif
uniform sampler2D blockLightAuxSampler;
#ifdef IMG_GI_RAW
layout(rgba16f) uniform image2D giRawImg;          // surface: GI / AO の生値
#endif
uniform sampler2D giRawSampler;
#ifdef IMG_REFLECTION
layout(rgba16f) uniform image2D reflectionImg;     // surface: 反射
#endif
uniform sampler2D reflectionSampler;
#ifdef IMG_FOG_HISTORY
layout(rgba16f) uniform image2D fogHistoryImg;     // sky: VL の時間蓄積
#endif
uniform sampler2D fogHistorySampler;
// 全モジュール: デバッグ表示 (DEBUG_VIEW=12 で final が表示, 毎フレームクリア)。書くプログラムで IMG_DEBUG を定義する
#ifdef IMG_DEBUG
layout(rgba16f) uniform image2D debugImg;
#endif
uniform sampler2D debugSampler;

// ---- colortex を compute から書くための image (フォーマットは formats.glsl と一致) ----
#ifdef IMG_COLORIMG0
layout(rgba16f) uniform image2D colorimg0;
#endif
#ifdef IMG_COLORIMG6
layout(rgba16f) uniform image2D colorimg6;
#endif
#ifdef IMG_COLORIMG8
layout(rgba16f) uniform image2D colorimg8;
#endif
#ifdef IMG_COLORIMG10
layout(rgba16f) uniform image2D colorimg10;
#endif
#ifdef IMG_COLORIMG12
layout(rgba16f) uniform image2D colorimg12;
#endif
#ifdef IMG_COLORIMG14
layout(rgba16f) uniform image2D colorimg14;
#endif

#endif
