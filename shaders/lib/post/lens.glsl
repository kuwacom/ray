/*
 * レンズ光学系のエフェクト (post モジュール)
 * - フレア: ゴースト (レンズ設計の近軸光線追跡の表から, lens_ghosts.glsl)・スターバースト (絞りの回折, 事前ベイク)・
 *   ハロー・ベーリンググレア・汚れ・アナモルフィックの横ストリーク
 * - 収差: 歪曲 (Brown-Conrady)・魚眼の再投影・倍率色収差 (波長サンプリング)・口径食と周辺減光 (処方の表)
 * - グレイン
 * 座標: 「tan 座標」= 焦点距離 1 のセンサー上の位置 (画面中心 0, 縦は ±tan(FOV/2), 横は縦横比倍)
 */
#ifndef POST_LENS_GLSL
#define POST_LENS_GLSL

//@include "/lib/post/lens_optics.glsl"
//@include "/lib/post/lens_flare.glsl"

#endif
