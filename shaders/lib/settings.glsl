/*
 * Ray 設定の入口 (設定は lib/settings/ に lib のモジュールごとのファイルで書く)
 *
 * - 素の #define 値は HIGH プロファイルと同一 (既定値が既定のプロファイル「高」と食い違わないように)
 * - プロファイル (LOW 〜 EXTREME の 9 段階) は shaders.properties で定義
 * - 数値の値リストは "// [..]" の書式で Iris の設定画面に出る
 */
#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL

#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"

#define RAY_VERSION 1 // [1] 画面には lang の value.RAY_VERSION.1 (v0.1.0-alpha)

#endif // SETTINGS_GLSL
