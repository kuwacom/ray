/*
 * sky モジュール (空 / 大気 / 雲 / フォグ / VL) の公開ヘッダ
 * 他モジュールはこのファイルだけを include する
 * (cloud_volume.glsl と volumetrics.glsl は sky のパス専用。後者は light / surface の関数を使うので light.glsl / surface.glsl の後に読む)
 */
#ifndef SKY_SKY_GLSL
#define SKY_SKY_GLSL

#include "/lib/sky/sh.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/fog.glsl"

#endif
