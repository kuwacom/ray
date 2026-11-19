/*
 * composite21_a (compute): シャッター速度の反映 (SHUTTER) の長時間露光の状態を、フレームに 1 回だけ進める
 * 同じパスの composite21 (fragment) より先に走り、Iris がその間にバリアを入れる。composite21 は書いた重みと印で画素ごとに溜める
 * 指数の平均。重み a = 2 dt / (t + dt) は、t 秒の箱の平均と平均の古さがそろう値 (t / dt フレームの単純移動平均と同じ)。
 *   1 フレームより短いシャッターでは 1 (溜めない)
 * post モジュール (lib/post)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/post/post_constants.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/common/uniforms.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/post/post_constants.glsl"
// END GENERATED includes

layout(local_size_x = 1, local_size_y = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
    float t = optShutterSpeed;
    float dt = clamp(frameTime, SHUTTER_DT_MIN, SHUTTER_DT_MAX);
    vec4 state = frameData.postParams[SHUTTER_PARAM];
    // 再読み込み (FrameData も 0) と画面の大きさの変更 (Iris が SSBO 7 / 8 を 0 で作り直す) では溜め直す
    float pixels = float(int(viewWidth) * int(viewHeight));
    bool reset = state.z != pixels;
    uint flags = reset ? SHUTTER_FLAG_RESET : 0u;
    float weight = reset ? 1.0 : min(2.0 * dt / (t + dt), 1.0);
    frameData.postParams[SHUTTER_PARAM] = vec4(weight, 0.0, pixels, float(flags));
}
