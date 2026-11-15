/*
 * colortex の論理名 (時間で分け合う枠と、番号を移す枠だけ)
 * 本体はここに名前のある枠を colortexN で直接読まず、論理名で読む。番号を変えるときはこの表と RENDERTARGETS の数字を一緒に直す
 * 名前の無い枠 (G バッファなど) は colortexN のまま使う
 *
 * 1 行に 1 つ、`#define TEX_<名前> <sampler> // <最初のパス> -> <最後のパス>` の形で書く (tools/check_slots.py が読む)
 * - パスは Iris のプログラム名 (gbuffers は G バッファの描画全体)。`/` で並べたときは最も後のものまで
 * - (永続) は前フレームの値を読む枠で、1 フレームの全体を占める
 * - 他の括弧の中は説明で、検査は読まない
 * - 値に別の TEX_* を書くと同じ中身の別名になり、区間の重なりを問わない
 */
#ifndef BUFFERS_SLOTS_GLSL
#define BUFFERS_SLOTS_GLSL

//@include "/lib/common/samplers.glsl"

#define TEX_TRANSLUCENT   colortex4   // gbuffers -> composite2
#define TEX_GI            colortex8   // deferred11 -> composite2 / final (final は DEBUG_VIEW=6)
#define TEX_GI_HIST       colortex9   // deferred11 (永続) -> deferred10 / composite
#define TEX_CLOUD_LOW     colortex14  // deferred20 -> deferred21
#define TEX_BLOOM         colortex14  // composite23 -> final
#define TEX_GODRAYS       colortex16  // composite12 -> composite19 (size.buffer.colortex16 の低解像度)
#define TEX_SPARKLE_HIST  colortex17  // composite20 (永続) -> final
#define TEX_WATER_REFR    colortex18  // composite1 -> composite2
#define TEX_GI_AUX        colortex19  // deferred11 (永続)
#define TEX_WATER_MIRROR  colortex20  // composite1 -> composite2
#define TEX_WATER_SUNVIS  colortex21  // composite1 -> composite2

#endif
