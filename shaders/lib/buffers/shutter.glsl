/*
 * SSBO binding 7 / 8: シャッター速度の反映 (SHUTTER) の長時間露光 (post, program/post/motion_blur.fsh)
 * composite21 がモーションブラーの後の colortex0 (線形 HDR、露出前) を画素ごとに溜め、溜めた絵を colortex0 に書き戻す
 * 確保は画面比 (shaders.properties の bufferObject.7 = 16 true 1.0 1.0、bufferObject.8 = 8 true 1.0 1.0)。
 * Iris は画面の大きさが変わると作り直して 0 で埋めるので、状態 (FrameData.postParams[7]) も画素数が変わったら溜め直す
 * 宣言は opt-in: 使うプログラム (composite21) は include の前に SSBO_SHUTTER_USE を定義する。SHUTTER が OFF なら宣言ごと入らない
 * 添字は y x int(viewWidth) + x
 */
#ifndef BUFFERS_SHUTTER_GLSL
#define BUFFERS_SHUTTER_GLSL

//@include "/lib/settings.glsl"

#if defined SSBO_SHUTTER_USE && defined SHUTTER

/*
 * 溜めた平均は fp32 で持つ。連続の溜め方の 1 フレームの重みは 60 fps・2 秒で約 1/60 で、fp16 (相対の刻み約 1/2000) では
 * 平均と新しい値の差が平均の数 % より小さいと足しても変わらず、暗い側に縞と偏りが残る
 */
layout(std430, binding = 7) buffer ShutterAccumBuffer {
    vec4 accum[];  // rgb = 溜めた平均の色 (線形、露出前), a = colortex0.a の平均 (正 = 鏡面の白飛び分の割合、負 = 溶岩の発光の割合)。要素数: 画面の画素数
} shutterAccum;

#if SHUTTER_MODE == 1
// 1 枚ずつ: 撮り終えた露光の絵 (表示だけなので fp16)
layout(std430, binding = 8) buffer ShutterShownBuffer {
    uvec2 shown[];  // packHalf2x16 の (r, g), (b, a)。要素数: 画面の画素数
} shutterShown;
#endif

#endif

#endif
