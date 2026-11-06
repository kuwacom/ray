/*
 * prepare (毎フレーム): 太陽・月の直達照度と空の SH を FrameData に書く
 * シーン全体 (地形・雲・フォグ) が同じ光の色を使うための唯一の計算場所
 * 照度は透過率 LUT (ATMOSPHERE_MODE=0 は解析近似) で大気を通した値。空の SH は前フレームの SkyView LUT から
 * (prepare1 がこの後で今フレームの LUT を作るため 1 フレーム遅れるが、空の変化は遅いので問題にならない)
 *
 * skyParams の使い方 (sky モジュールの自由領域)
 *   [0] rgb = 雲の高度での光源照度, a = +1 なら光源は太陽 / -1 なら月
 *   [1] x = 前フレームの worldTime, y = 履歴が有効な連続フレーム数 (0 = 時刻が飛んだのでリセット), zw = 予備
 *   [3] x = 目の位置の太陽の見え方 (今フレーム), y = 目の周り 3 ブロックの平均 (平滑化済み), z = 太陽が影マップの範囲より遠い地形に隠れている割合
 *       (post の composite25 が書く。ここでは触らない), w = 予備
 *   [4] = (カメラの位置の雲の中の太陽の光, 雲の濃さ), [5] = (雲の中の空の光, 霧の消散係数) (prepare2 の cloud_weather.csh が書く。ここでは触らない)
 *   [6] = (雨の日の雲の向こうの空を置き換える灰色の放射輝度, 置き換える割合) (prepare2 の cloud_weather.csh が書く。反射の空が使う)
 * surfaceParams[0..2] は開けた水面の海の状態 (lib/common/water_waves.glsl の waterSeaStoreOpen)、[3] は水面のきらめきの寿命に使うフレームの長さ
 * (lib/common/water_glitter.glsl の waterGlintFrameStore)
 * sky モジュール (lib/sky)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/shadow_space.glsl"
//@include "/lib/common/shadow_volume.glsl"
//@include "/lib/common/water_waves.glsl"
//@include "/lib/common/water_glitter.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/sky.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glitter.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
// END GENERATED includes

layout(local_size_x = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

const int SH_SAMPLES = 128;
/*
 * SH の下半球は地面 (草地・土) の平均の反射率 SH_GROUND_ALBEDO の照り返し (lib/sky/sky_color.glsl)
 * 以下の SH_SKY_SATURATION / SH_SKY_GAIN も GI のある時に受け取り側が地面の分を引くので sky_color.glsl に置く (shSkyGrade)
 *
 * 空の環境光の彩度。LUT の空をそのまま積分した照度は R/B = 0.25 (晴れの正午) と、
 * 実測の日陰の色 (7000-10000K, R/B 0.6 前後) よりずっと青く、日陰の雪が青灰色、室内の木材がオリーブ色に転んだ
 * 周囲の地形・植生の照り返しとカメラの WB が打ち消す分として半分に落とす (空そのものの描画は変えない)
 * getSkyRadiance が見た目用に彩度を SKY_COLOR_SATURATION (1.25) 倍しているので、ここは 0.3 で LUT 比 0.375 になる
 * (0.4 では正午の日陰の雪がまだ青灰色)
 * 設定 SKY_AMBIENT_SATURATION の既定は 0.5 (0.3 では日陰に色があると分からない)。GI が地面の照り返しを実際の色で足し、
 * SH の灰色の地面で日陰が灰色に寄らない分もある。森の日陰の雪の B/R は 0.3 で 1.26、0.5 で 1.49、0.65 で 1.67 (表示後)。室内の木は変わらない
 */
/*
 * 空の環境光の強さ。LUT は雲の無い空なので、白く明るい雲・遠景の照り返しの分が入っておらず、
 * 晴れの正午で空/太陽の照度比が 0.09 (実測の晴天は 0.12-0.2) と日陰が暗く、日陰の雪・草がくすんだ
 */
// 雨の日の直達光の減衰 (雨雲が雲影マップで覆いきれない分)
const float RAIN_DIRECT_DIMMING = 0.6;
// worldTime がこれ以上飛んだら時間方向の履歴を捨てる (/time set 等)
const int WORLD_TIME_JUMP = 40;
// 目の位置の太陽の見え方 (影マップ)。画面の外の太陽や、影マップより遠い霧の遮る物が分からない所の手がかりにする
const int EYE_SUN_TAPS = 16;
// 光源側へずらす距離 (ブロック)。自分の頭の影 (shadowPlayer) を拾わない
const float EYE_SUN_OFFSET = 1.0;
// フレア用: 光に垂直な円盤の半径 (ブロック)
const float EYE_SUN_RADIUS = 0.5;
// 霧用: 広く平均して、柵や細い木の影で光芒が点滅しないようにする。縦は狭く
// (低い太陽で縦にも広げると円盤の下側が足元の地面に埋まり、開けた所でも見え方が下がる)
const float EYE_SUN_AREA_RADIUS = 3.0;
const float EYE_SUN_AREA_HEIGHT = 1.0;
// 深度の余裕 (ブロック)
const float EYE_SUN_BIAS = 0.1;
// 霧用の平滑化 (1/秒)
const float EYE_SUN_SPEED = 4.0;
// カメラがこれ以上飛んだら平滑化の履歴を捨てる (ブロック)
const float EYE_SUN_RESET_DISTANCE = 16.0;

#ifdef HAS_SKY
// 目から光源側へ EYE_SUN_OFFSET の点の周り (光に垂直な、横 radius 縦 height の楕円) が、影マップで光に見えている割合
float eyeSunVisibility(float radius, float height) {
    vec3 L = getShadowLightDir();
    // 横軸は水平 (光がほぼ真上なら適当な軸)
    vec3 right = abs(L.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : normalize(cross(vec3(0.0, 1.0, 0.0), L));
    vec3 up = cross(L, right);
    float sum = 0.0;
    for (int i = 0; i < EYE_SUN_TAPS; i++) {
        vec2 d = vogelDisk(i, EYE_SUN_TAPS, 0.0) * vec2(radius, height);
        vec3 p = L * EYE_SUN_OFFSET + right * d.x + up * d.y;
        vec3 s = playerToShadowScreen(p);
        // 影マップの範囲外は遮る物が分からないので見えるとする
        if (any(lessThan(s, vec3(0.0))) || any(greaterThan(s, vec3(1.0)))) {
            sum += 1.0;
        } else {
            sum += step(s.z - EYE_SUN_BIAS * shadowDepthPerBlock(), texture(shadowtex1, s.xy).r);
        }
    }
    return sum / float(EYE_SUN_TAPS);
}
#endif

void main() {
    // 時間方向の履歴の有効性 (雲・VL の蓄積が古い時刻の絵を引きずらないように)
    float prevTime = frameData.skyParams[1].x;
    float historyFrames = frameData.skyParams[1].y;
    int dt = worldTime - int(prevTime);
    bool timeJump = abs(dt) > WORLD_TIME_JUMP && abs(dt) < 24000 - WORLD_TIME_JUMP;
    historyFrames = timeJump ? 0.0 : min(historyFrames + 1.0, 65535.0);
    frameData.skyParams[1] = vec4(float(worldTime), historyFrames, 0.0, 0.0);
    waterSeaStoreOpen();
#ifdef WATER_GLITTER
    waterGlintFrameStore();
#endif

#ifdef HAS_SKY
    vec3 sunDir = getSunDir();
    vec3 moonDir = getMoonDir();
    float r = atmoViewerRadius();
    float weather = 1.0 - RAIN_DIRECT_DIMMING * rainStrength;

    vec3 sun = getSunIlluminanceTOA() * atmoTransmittanceToLight(r, sunDir.y) * weather;
    if (LK_SUN_WARMTH > 0.0) sun *= lookSunTint();
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
    // frameData の太陽・月は上で書いたので skyGroundIrradianceRaw は今フレームの値を読む
    vec3 groundIrradiance = skyGroundIrradianceRaw();
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
        vec3 c = sh[k] * (4.0 * PI / float(SH_SAMPLES));
        frameData.skySH[k] = vec4(shSkyGrade(c), 0.0);
        sh[k] = c * SH_SKY_GAIN_BASE;
    }
    // 雲が受ける真上からの空の照度は彩度を落とさない。灰色にすると夕方の雲の陰が
    // 空の青紫にならず、残った橙の太陽光で茶色く濁る
    vec3 cloudSkyUp = sh[0] * (SH_Y0 * SH_COS_A0) + sh[1] * (SH_Y1 * SH_COS_A1)
                    - (sh[6] * SH_Y2_ZZ + sh[8] * SH_Y2_XX_YY) * SH_COS_A2;
    frameData.skyParams[2] = vec4(max(cloudSkyUp, 0.0), 0.0);

    float eyeNow = eyeSunVisibility(EYE_SUN_RADIUS, EYE_SUN_RADIUS);
    float eyeArea = eyeSunVisibility(EYE_SUN_AREA_RADIUS, EYE_SUN_AREA_HEIGHT);
    float eyePrev = frameData.skyParams[3].y;
    bool eyeReset = historyFrames < 1.5 || isnan(eyePrev) || isinf(eyePrev) || distance(cameraPosition, previousCameraPosition) > EYE_SUN_RESET_DISTANCE;
    float eyeSmooth = eyeReset ? eyeArea : mix(eyePrev, eyeArea, 1.0 - exp(-EYE_SUN_SPEED * clamp(frameTime, 0.0, 0.5)));
    frameData.skyParams[3].xy = vec2(eyeNow, eyeSmooth);
#else
    frameData.sunIrradiance = vec4(0.0);
    frameData.moonIrradiance = vec4(0.0);
    frameData.skyParams[0] = vec4(0.0);
    frameData.skyParams[2] = vec4(0.0);
    frameData.skyParams[3].xy = vec2(1.0);
    #ifdef WORLD_END
        // エンドは影マップがあるので、淡い紫の平行光で立体感を出す
        frameData.shadowLightIrradiance = vec4(END_LIGHT_IRRADIANCE, 0.0);
        vec3 ambient = END_AMBIENT_IRRADIANCE;
        // 一様な環境光だと影の中の上面と側面が同じ明るさで地形が平板になる。
        // 空 (上) から多く、虚空 (下) から少なく入る L1 の勾配: 上向き x END_AMBIENT_UP, 下向き x END_AMBIENT_DOWN
        frameData.skySH[1] = vec4(ambient * (0.5 * (END_AMBIENT_UP - END_AMBIENT_DOWN)) / (SH_Y1 * SH_COS_A1), 0.0);
        ambient *= 0.5 * (END_AMBIENT_UP + END_AMBIENT_DOWN);
    #else
        frameData.shadowLightIrradiance = vec4(0.0);
        // ネザーはバイオームごとの色の一様な環境光にする
        // fogColor そのままだと真紅の森などは赤一色の光になり、地面のテクスチャの色が読めない
        vec3 ambient = getNetherPalette().ambient;
    #endif
    frameData.skySH[0] = vec4(ambient / SH_Y0 / PI, 0.0);
    for (int k = 2; k < 9; k++) frameData.skySH[k] = vec4(0.0);
    #ifndef WORLD_END
        frameData.skySH[1] = vec4(0.0);
    #endif
#endif
}
