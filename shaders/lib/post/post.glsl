/*
 * post モジュール (TAA / DoF / ブルーム / 露出 / トーンマップ / 最終合成) の公開ヘッダ
 * 他モジュールが使うのは encodeVelocity / encodeHandVelocity / getPreviousUv / tonemap のみ
 * post モジュール自身のプログラムは内部ヘッダ lib/post/post_internal.glsl を include する
 */
#ifndef POST_POST_GLSL
#define POST_POST_GLSL

#include "/lib/post/velocity.glsl"
#include "/lib/post/tonemap.glsl"

#endif
