/*
 * 全プログラムが最初に include する共通ヘッダ
 * 設定 -> uniform -> 数学 -> 座標 -> バッファ -> ID の順に読む (後ろほど前に依存)
 * モジュール固有の関数は各モジュールの lib ディレクトリへ
 */
#ifndef COMMON_COMMON_GLSL
#define COMMON_COMMON_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/jitter.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/buffers/ssbo.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"

// 露出 (post の composite25 が FrameData に書く)。誰でも読める
float getExposure() { return frameData.exposure > 0.0 ? frameData.exposure : 1.0; }

/*
 * 画面に直接見える発光テクスチャの輝度 (EMISSION_LUMINANCE の代わりに掛ける。GI の光源としては EMISSION_LUMINANCE のまま)
 * 固定の 4.0 だと暗所の露出 (x2-35) で AgX の白 (露出後 1.3 前後) を何段も超え、グロウストーンやたいまつの炎が
 * 色の無い白い板になった。露出の -0.45 乗で、昼 (露出 1) で 1.0、灯りの点いた室内 (露出 2) で 0.7 程度にする
 * 夜の屋外 (露出 30 前後) では露出後 7 程度の明るさが残り、灯りとして光って見える
 */
const float EMISSION_VISIBLE_LUMINANCE = 1.0;
const float EMISSION_EXPOSURE_ADAPT = 0.45;
float getVisibleEmissionLuminance() { return EMISSION_VISIBLE_LUMINANCE * pow(getExposure(), -EMISSION_EXPOSURE_ADAPT); }

#endif
