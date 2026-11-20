/*
 * 花火の一時的な点光源 (light モジュール)
 * 光るパーティクル (バニラがライトマップ最大で描く自己発光の粒。花火の火花が大半) の平均の位置と色から点光源を 1 つ作る
 *   1. gbuffers_particles_translucent の頂点が 4 頂点に 1 回 fireworkAccAdd で位置と色を足す (画面内の粒だけ)
 *   2. 次のフレームの begin が updateFireworkLight で平均を取り、粒の数に応じた強さの光にして置く
 *   3. deferred30 が地面・壁の拡散 (evalFireworkIrradiance)、composite19 が空気と霧の内散乱 (evalFireworkGlow) を足す
 * 遮蔽はスカイライトで近似する (花火は空にあり、空の見える面ほど照らされる)。光源シャドウ・ビンには入れない
 * (到達距離が 100 ブロック近くあり、ビンに入れると数千のビンに登録されて全画素のトレースが 1 本増える)
 * 同時に上がった花火も 1 つの光にまとめる (色と位置は重みの平均)
 */
#ifndef LIGHT_FIREWORK_LIGHT_GLSL
#define LIGHT_FIREWORK_LIGHT_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/phase.glsl"
//@include "/lib/buffers/firework_light.glsl"

// 固定小数点の倍率。位置は多数の粒の平均なので 1/2 ブロックで足り、和が int に収まる粒の数を稼ぐ (約 13 万粒)
const float FIREWORK_ACC_POS_SCALE = 2.0;
const float FIREWORK_ACC_WEIGHT_SCALE = 32.0;
const float FIREWORK_ACC_COLOR_SCALE = 255.0;

// 光る粒の重みの和がこれより少ない時は光にしない (エンドロッドやトーテムの数粒、発光イカの粒を拾わない)
const float FIREWORK_LIGHT_MIN_SPARKS = 12.0;
// 小さな玉の花火 1 発 (火花と尾で約 150 粒) を強さ 1 とする。大きな玉や同時の打ち上げは頭打ちで最大 2 倍
const float FIREWORK_LIGHT_FULL_SPARKS = 150.0;
const float FIREWORK_LIGHT_GAIN_MAX = 2.0;
// 強さ 1 の放射強度。40 ブロック下の地面の照度が満月の月明かり (MOON_ILLUMINANCE) と同じくらい
const float FIREWORK_LIGHT_INTENSITY = 20.0 * PHYSICAL_BLOCKLIGHT;
// 火花が広がる球の半径 (ブロック)。真下の地面だけが点で強く照らされないように距離に足す
const float FIREWORK_LIGHT_RADIUS = 5.0;
// 粒の数の揺れ (バニラの点滅する花火) で光がちらつき過ぎないように均す時定数 (秒)
const float FIREWORK_LIGHT_SMOOTH_TIME = 0.06;
// これより暗くなったら光を消す (強さ 1 に対する割合)
const float FIREWORK_LIGHT_CUTOFF = 0.01;
// 地面を照らす面のスカイライトの範囲 (0-1)。屋根の下・洞窟は照らさない
const vec2 FIREWORK_LIGHT_SKYLIGHT = vec2(0.5, 0.95);
// 空気の散乱係数の下限 (1/ブロック)。晴れた夜は霧が薄く、火薬の煙に当たって色付いて光る暈をこの濃さで近似する
const float FIREWORK_SMOKE_SCATTER = 0.001;

#ifdef SSBO_FIREWORK_LIGHT_WRITE
// 光る粒 1 つ (4 頂点に 1 回呼ぶ)。weight: 粒の不透明度 (消えかけの火花ほど弱い)
void fireworkAccAdd(vec3 playerPos, vec3 linearColor, float weight) {
    int w = int(saturate(weight) * FIREWORK_ACC_WEIGHT_SCALE + 0.5);
    if (w == 0) return;
    ivec3 p = ivec3(round(playerPos * FIREWORK_ACC_POS_SCALE)) * w;
    ivec3 c = ivec3(saturate(linearColor) * FIREWORK_ACC_COLOR_SCALE + 0.5) * w;
    atomicAdd(fireworkLight.acc[0], 1);
    atomicAdd(fireworkLight.acc[1], w);
    atomicAdd(fireworkLight.acc[2], p.x);
    atomicAdd(fireworkLight.acc[3], p.y);
    atomicAdd(fireworkLight.acc[4], p.z);
    atomicAdd(fireworkLight.acc[5], c.x);
    atomicAdd(fireworkLight.acc[6], c.y);
    atomicAdd(fireworkLight.acc[7], c.z);
}

// 前フレームに溜めた粒から今フレームの光を決め、蓄積を空にする (begin の 1 スレッドだけが呼ぶ)
void updateFireworkLight() {
    vec3 prevIntensity = fireworkLight.intensity.rgb;
    // 前フレームの player 空間 -> 今フレーム
    vec3 shift = previousCameraPosition - cameraPosition;
    vec3 pos = fireworkLight.posRadius.xyz + shift;
    vec3 target = vec3(0.0);
    float wq = float(fireworkLight.acc[1]);
    float sparks = wq / FIREWORK_ACC_WEIGHT_SCALE;
    if (sparks > 0.0) {
        vec3 p = vec3(fireworkLight.acc[2], fireworkLight.acc[3], fireworkLight.acc[4]) / (wq * FIREWORK_ACC_POS_SCALE) + shift;
        vec3 c = vec3(fireworkLight.acc[5], fireworkLight.acc[6], fireworkLight.acc[7]) / (wq * FIREWORK_ACC_COLOR_SCALE);
        float k = sparks / FIREWORK_LIGHT_FULL_SPARKS;
        float amount = smoothstep(FIREWORK_LIGHT_MIN_SPARKS, FIREWORK_LIGHT_MIN_SPARKS * 2.0, sparks) * k / (1.0 + k / FIREWORK_LIGHT_GAIN_MAX);
        target = c / max(maxOf(c), 1e-3) * (amount * FIREWORK_LIGHT_INTENSITY * FIREWORK_LIGHT_STRENGTH);
        // 光っていなかった時は新しい位置へ飛ぶ。光っている間は位置も均す (別の花火が加わった時に光が跳ばない)
        pos = fireworkLight.posRadius.w > 0.0 ? mix(pos, p, 0.5) : p;
    }
    float blend = 1.0 - exp(-frameTime / FIREWORK_LIGHT_SMOOTH_TIME);
    vec3 intensity = mix(prevIntensity, target, blend);
    bool lit = maxOf(intensity) > FIREWORK_LIGHT_CUTOFF * FIREWORK_LIGHT_INTENSITY * FIREWORK_LIGHT_STRENGTH;
    fireworkLight.posRadius = vec4(pos, lit ? FIREWORK_LIGHT_RADIUS : 0.0);
    fireworkLight.intensity = vec4(lit ? intensity : vec3(0.0), 0.0);
    for (int i = 0; i < FIREWORK_ACC_COUNT; i++) fireworkLight.acc[i] = 0;
}
#endif

bool hasFireworkLight() { return fireworkLight.posRadius.w > 0.0; }

// 面の照度 (拡散に足す)。skylight: ライトマップのスカイライト (0-1)
vec3 evalFireworkIrradiance(vec3 playerPos, vec3 normal, float skylight) {
    vec3 toLight = fireworkLight.posRadius.xyz - playerPos;
    float d2 = dot(toLight, toLight);
    float NdotL = saturate(dot(normal, toLight * inversesqrt(max(d2, 1e-4))));
    float r = fireworkLight.posRadius.w;
    float sky = smoothstep(FIREWORK_LIGHT_SKYLIGHT.x, FIREWORK_LIGHT_SKYLIGHT.y, skylight);
    return fireworkLight.intensity.rgb * (NdotL * sky / (d2 + r * r));
}

/*
 * 視線 (dir, 長さ dist) に沿った内散乱。手持ち光源の暈 (composite19 の handLightGlow) と同じ逆二乗の解析積分で、
 * 火花の球の半径を距離に足して光源のすぐ近くで発散させない。scatterCoeff: カメラの位置の霧の散乱係数
 */
vec3 evalFireworkGlow(vec3 dir, float dist, vec3 scatterCoeff) {
    vec3 lightPos = fireworkLight.posRadius.xyz;
    float r = fireworkLight.posRadius.w;
    float t0 = dot(lightPos, dir);
    float h2 = max(dot(lightPos, lightPos) - t0 * t0, 0.0);
    float a = sqrt(h2 + r * r);
    float along = (atan((dist - t0) / a) - atan(-t0 / a)) / a;
    return fireworkLight.intensity.rgb * max(scatterCoeff, vec3(FIREWORK_SMOKE_SCATTER)) * (along * PHASE_ISOTROPIC);
}

#endif
