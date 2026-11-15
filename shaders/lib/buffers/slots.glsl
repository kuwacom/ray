/*
 * colortex と画面相対の image の論理名 (時間で分け合う枠と、番号を移す枠だけ)
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
//@include "/lib/buffers/images.glsl"

#define TEX_TRANSLUCENT   colortex4   // gbuffers -> composite2
#define TEX_GI            TEX_GI_HIST // deferred11 -> composite2 / final (今フレームの出力と次フレームの履歴は同じ値。final は DEBUG_VIEW=6)
#define TEX_GI_HIST       colortex9   // deferred11 (永続) -> deferred10 / composite
#define TEX_CLOUD_LOW     colortex14  // deferred20 -> deferred21
#define TEX_BLOOM         colortex14  // composite23 -> final
#define TEX_GODRAYS       colortex4   // composite12 -> composite19 (左上 1/GODRAYS_RES、scale.composite12-14)
#define TEX_SPARKLE_HIST  colortex8   // composite20 (永続) -> final
#define TEX_WATER_REFR    colortex14  // composite1 -> composite2
#define TEX_GI_AUX        colortex10  // deferred11 (永続)
#define TEX_WATER_MIRROR  giRawSampler          // composite1 -> composite2 (image は TEX_GI_RAW と共用)
#define TEX_WATER_SUNVIS  blockLightRawSampler  // composite1 -> composite2 (image は TEX_BLOCKLIGHT_RAW と共用)
#define TEX_GI_RAW        giRawSampler          // deferred10 -> deferred11
#define TEX_BLOCKLIGHT_RAW blockLightRawSampler // deferred1 -> deferred2

/*
 * 上の image の書き側の名前。宣言の opt-in は今までどおり IMG_GI_RAW / IMG_BLOCKLIGHT_RAW (lib/buffers/images.glsl) で、
 * IMG_* はその印の名前なので書き側は STORE_* にする
 * 水の 2 つは composite1 の fragment が imageStore で書き、composite2 が sampler で読む。間のバリアは
 * composite2_a (program/surface/water_barrier.csh、空の compute) の後に Iris が出す glMemoryBarrier
 * deferred の側は毎フレーム、読む範囲 (左上 1/RES) を全部書き直してから読むので、水の値は次のフレームに残らない
 */
#define STORE_WATER_MIRROR   giRawImg
#define STORE_WATER_SUNVIS   blockLightRawImg
#define STORE_GI_RAW         giRawImg
#define STORE_BLOCKLIGHT_RAW blockLightRawImg

#endif
