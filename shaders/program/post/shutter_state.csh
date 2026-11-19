/*
 * composite21_a (compute): シャッター速度の反映 (SHUTTER) の長時間露光の状態を、フレームに 1 回だけ進める
 * 同じパスの composite21 (fragment) より先に走り、Iris がその間にバリアを入れる。composite21 は書いた重みと印で画素ごとに溜める
 * - 連続 (SHUTTER_MODE 0): 指数の平均。重み a = 2 dt / (t + dt) は、t 秒の箱の平均と平均の古さがそろう値 (t / dt フレームの単純移動平均と同じ)。
 *   1 フレームより短いシャッターでは 1 (溜めない)
 * - 1 枚ずつ (SHUTTER_MODE 1): 露光の始まりから時間の重みの逐次平均。溜めた秒が t に届いたフレームで露光を終え、次のフレームから溜め直す
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
#include "/lib/common/constants.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/post/post_constants.glsl"
// END GENERATED includes

layout(local_size_x = 1, local_size_y = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
    float t = optShutterSpeed;
    float dt = clamp(frameTime, SHUTTER_DT_MIN, SHUTTER_DT_MAX);
    vec4 state = frameData.postParams[SHUTTER_PARAM];
    /*
     * 再読み込み (FrameData も 0) と画面の大きさの変更 (Iris が SSBO 7 / 8 を 0 で作り直す) では溜め直す
     * 画素数が同じまま縦横が変わる時 (1920x1080 -> 1080x1920) も溜め直すよう、幅と高さを別々に比べる
     */
    float width = float(int(viewWidth));
    float height = float(int(viewHeight));
    bool reset = state.z != width || floor(state.w / SHUTTER_FLAG_RANGE) != height;
    uint flags = reset ? SHUTTER_FLAG_RESET : 0u;
#if SHUTTER_MODE == 1
    float exposed = reset ? 0.0 : state.y;
    if (!reset && (uint(state.w) & SHUTTER_FLAG_SHOWN) != 0u) flags |= SHUTTER_FLAG_SHOWN;
    float weight = dt / (exposed + dt);
    exposed += dt;
    // 最後のフレームのはみ出しは捨てる (誤差は 1 フレーム / t 以下)
    if (exposed >= t) {
        flags |= SHUTTER_FLAG_COMPLETE | SHUTTER_FLAG_SHOWN;
        exposed = 0.0;
    }
    frameData.postParams[SHUTTER_PARAM] = vec4(weight, exposed, width, float(flags) + SHUTTER_FLAG_RANGE * height);
#else
    float weight = reset ? 1.0 : min(2.0 * dt / (t + dt), 1.0);
    frameData.postParams[SHUTTER_PARAM] = vec4(weight, 0.0, width, float(flags) + SHUTTER_FLAG_RANGE * height);
#endif
}
