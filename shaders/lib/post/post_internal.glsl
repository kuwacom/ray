/*
 * post モジュールのプログラム (composite20-25, final) だけが include する内部ヘッダ
 * 他のモジュールは post.glsl (速度・トーンマップ) だけを使う
 */
#ifndef POST_POST_INTERNAL_GLSL
#define POST_POST_INTERNAL_GLSL

#include "/lib/post/post.glsl"
#include "/lib/post/post_constants.glsl"
#include "/lib/post/lens_presets.glsl"
#include "/lib/post/sampling.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/post/camera.glsl"
#include "/lib/post/grading.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/lens.glsl"

#endif
