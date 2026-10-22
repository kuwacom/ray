/*
 * prepare (毎フレーム): 太陽・月の直達照度と空の SH を FrameData に書く
 * シーン全体 (地形・雲・フォグ) が同じ光の色を使うための唯一の計算場所
 * 照度は透過率 LUT (ATMOSPHERE_MODE=0 は解析近似) で大気を通した値。空の SH は前フレームの SkyView LUT から
 * (prepare1 がこの後で今フレームの LUT を作るため 1 フレーム遅れるが、空の変化は遅いので問題にならない)
 *
 * skyParams の使い方 (sky モジュールの自由領域)
 *   [0] rgb = 雲の高度での光源照度, a = +1 なら光源は太陽 / -1 なら月
 *   [1] x = 前フレームの worldTime, y = 履歴が有効な連続フレーム数 (0 = 時刻が飛んだのでリセット), zw = 予備
 * sky モジュール (lib/sky)
 */
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"

layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

const int SH_SAMPLES = 128;
// 地面 (草地・土) の平均アルベド。空の SH の下半球に使う
const float SH_GROUND_ALBEDO = 0.2;
/*
 * 空の環境光の彩度。LUT の空をそのまま積分した照度は R/B = 0.25 (晴れの正午) と、
 * 実測の日陰の色 (7000-10000K, R/B 0.6 前後) よりずっと青く、日陰の雪が青灰色、室内の木材がオリーブ色に転んだ
 * 周囲の地形・植生の照り返しとカメラの WB が打ち消す分として半分に落とす (空そのものの描画は変えない)
 * getSkyRadiance が見た目用に彩度を SKY_COLOR_SATURATION (1.25) 倍しているので、ここは 0.3 で LUT 比 0.375 になる
 * (0.4 では noon の日陰の雪がまだ青灰色だった)
 */
const float SH_SKY_SATURATION = 0.3;
/*
 * 空の環境光の強さ。LUT は雲の無い空なので、白く明るい雲・遠景の照り返しの分が入っておらず、
 * 晴れの正午で空/太陽の照度比が 0.09 (実測の晴天は 0.12-0.2) と日陰が暗く、日陰の雪・草がくすんだ
 */
const float SH_SKY_GAIN = 1.7;
// 雨の日の直達光の減衰 (雨雲が雲影マップで覆いきれない分)
const float RAIN_DIRECT_DIMMING = 0.6;
// worldTime がこれ以上飛んだら時間方向の履歴を捨てる (/time set 等)
const int WORLD_TIME_JUMP = 40;

void main() {
    // 時間方向の履歴の有効性 (雲・VL の蓄積が古い時刻の絵を引きずらないように)
    float prevTime = frameData.skyParams[1].x;
    float historyFrames = frameData.skyParams[1].y;
    int dt = worldTime - int(prevTime);
    bool timeJump = abs(dt) > WORLD_TIME_JUMP && abs(dt) < 24000 - WORLD_TIME_JUMP;
    historyFrames = timeJump ? 0.0 : min(historyFrames + 1.0, 65535.0);
    frameData.skyParams[1] = vec4(float(worldTime), historyFrames, 0.0, 0.0);

#ifdef HAS_SKY
    vec3 sunDir = getSunDir();
    vec3 moonDir = getMoonDir();
    float r = atmoViewerRadius();
    float weather = 1.0 - RAIN_DIRECT_DIMMING * rainStrength;

    vec3 sun = getSunIlluminanceTOA() * atmoTransmittanceToLight(r, sunDir.y) * weather;
    vec3 moon = getMoonIlluminanceTOA() * atmoTransmittanceToLight(r, moonDir.y) * weather;

    frameData.sunIrradiance = vec4(sun, sunDir.y);
    frameData.moonIrradiance = vec4(moon, moonDir.y);
    bool sunIsShadowLight = dot(getShadowLightDir(), sunDir) > 0.0;
    frameData.shadowLightIrradiance = vec4(sunIsShadowLight ? sun : moon, sunIsShadowLight ? 1.0 : 0.0);

    // 雲の高度での光源。地上が日没後でも雲の上はまだ照らされる (夕焼け雲)
    #if CLOUDS == 3
        // 雲の光は参照空間 (現実の寸法) で計算するので、高さテンプレートのワールド値ではなく参照高度を使う
        float cloudAltitude = CLOUD_R_BASE + 0.35 * CLOUD_R_DEPTH;
    #else
        float cloudAltitude = CLOUD2D_ALTITUDE + 0.5 * CLOUD2D_THICKNESS;
    #endif
    float rCloud = ATMO_GROUND_RADIUS + max(cloudAltitude - SKY_SEA_LEVEL, 0.0) * 1e-3;
    vec3 sunAtCloud = getSunIlluminanceTOA() * atmoTransmittanceToLight(rCloud, sunDir.y);
    vec3 moonAtCloud = getMoonIlluminanceTOA() * atmoTransmittanceToLight(rCloud, moonDir.y);
    bool cloudLitBySun = luminance(sunAtCloud) > luminance(moonAtCloud);
    frameData.skyParams[0] = vec4(cloudLitBySun ? sunAtCloud : moonAtCloud, cloudLitBySun ? 1.0 : -1.0);

    // 空の放射を SH L2 へ射影 (フィボナッチ球の一様サンプル)。下半球は地面の照り返し
    vec3 groundIrradiance = (sun * max(sunDir.y, 0.0) + moon * max(moonDir.y, 0.0) + shEvalIrradiance(vec3(0.0, 1.0, 0.0))) * SH_GROUND_ALBEDO;
    vec3 groundRadiance = groundIrradiance * RCP_PI;
    vec3 sh[9];
    for (int i = 0; i < 9; i++) sh[i] = vec3(0.0);
    for (int i = 0; i < SH_SAMPLES; i++) {
        float z = 1.0 - 2.0 * (float(i) + 0.5) / float(SH_SAMPLES);
        float rr = sqrt(max(1.0 - z * z, 0.0));
        float phi = float(i) * GOLDEN_ANGLE;
        vec3 dir = vec3(rr * cos(phi), z, rr * sin(phi));
        vec3 radiance = dir.y < 0.0 ? mix(getSkyRadiance(dir), groundRadiance, smoothstep(0.0, 0.1, -dir.y)) : getSkyRadiance(dir);
        float b[9];
        shBasis(dir, b);
        for (int k = 0; k < 9; k++) sh[k] += radiance * b[k];
    }
    for (int k = 0; k < 9; k++) {
        // 輝度を保ったまま彩度だけ落とす (SH は線形なので係数ごとに掛けてよい)
        vec3 c = sh[k] * (4.0 * PI / float(SH_SAMPLES) * SH_SKY_GAIN);
        frameData.skySH[k] = vec4(mix(vec3(luminance(c)), c, SH_SKY_SATURATION), 0.0);
        sh[k] = c;
    }
    // 雲が受ける真上からの空の照度は彩度を落とさない。灰色にすると夕方の雲の陰が
    // 空の青紫にならず、残った橙の太陽光で茶色く濁る
    vec3 cloudSkyUp = sh[0] * (0.282095 * 3.141593) + sh[1] * (0.488603 * 2.094395)
                    - (sh[6] * 0.315392 + sh[8] * 0.546274) * 0.785398;
    frameData.skyParams[2] = vec4(max(cloudSkyUp, 0.0), 0.0);
#else
    frameData.sunIrradiance = vec4(0.0);
    frameData.moonIrradiance = vec4(0.0);
    frameData.skyParams[0] = vec4(0.0);
    frameData.skyParams[2] = vec4(0.0);
    #ifdef WORLD_END
        // エンドは影マップがあるので、淡い紫の平行光で立体感を出す
        frameData.shadowLightIrradiance = vec4(END_LIGHT_IRRADIANCE, 0.0);
        vec3 ambient = END_AMBIENT_IRRADIANCE;
        // 一様な環境光だと影の中の上面と側面が同じ明るさで地形が平板になる。
        // 空 (上) から多く、虚空 (下) から少なく入る L1 の勾配: 上向き x END_AMBIENT_UP, 下向き x END_AMBIENT_DOWN
        frameData.skySH[1] = vec4(ambient * (0.5 * (END_AMBIENT_UP - END_AMBIENT_DOWN)) / (0.488603 * 2.094395), 0.0);
        ambient *= 0.5 * (END_AMBIENT_UP + END_AMBIENT_DOWN);
    #else
        frameData.shadowLightIrradiance = vec4(0.0);
        // ネザーはバイオームごとの色の一様な環境光にする
        // fogColor そのままだと真紅の森などは赤一色の光になり、地面のテクスチャの色が読めない
        vec3 ambient = getNetherPalette().ambient;
    #endif
    frameData.skySH[0] = vec4(ambient / 0.282095 / PI, 0.0);
    for (int k = 2; k < 9; k++) frameData.skySH[k] = vec4(0.0);
    #ifndef WORLD_END
        frameData.skySH[1] = vec4(0.0);
    #endif
#endif
}
