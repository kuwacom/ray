/*
 * surface モジュール (太陽影 / GI / マテリアル / 水 / 反射) の公開ヘッダ
 * 他モジュールはこのファイルだけを include する
 * (screen_trace.glsl / lighting.glsl / ao.glsl は surface モジュールのパス専用。lighting.glsl は sky.glsl と light.glsl に依存する)
 */
#ifndef SURFACE_SURFACE_GLSL
#define SURFACE_SURFACE_GLSL

#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/surface/water.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"

#endif
