/*
 * 全プログラムが最初に include する核: 設定・ディメンション・定数・uniform・sampler・数学・シェーディングの型
 * SSBO (lib/buffers/<アクセサ名>.glsl) と image (lib/buffers/images.glsl) は使うファイルが自分で include する。
 * 宣言しないプログラムが減るほどリンクが速く、SSBO は書かないプログラムで readonly になる
 * 座標変換・色・ノイズ・ID などは、使うファイルが自分で include する
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
#include "/lib/common/shading_types.glsl"

#endif
