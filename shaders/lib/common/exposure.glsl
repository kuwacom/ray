#ifndef COMMON_EXPOSURE_GLSL
#define COMMON_EXPOSURE_GLSL

#include "/lib/buffers/frame_data.glsl"

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
