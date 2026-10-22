/*
 * prepare2 (毎フレーム): 雲の天気図 (cloudWeatherImg, 512x512) と雲影マップ (cloudShadowImg, 512x512)
 *
 * 天気図はカメラ中心の窓 (参照空間で 1 テクセル 256 m, ±65 km) に非周期の手続きノイズを毎フレーム書く。
 * 雲影マップはワールドの雲底の面に貼る (高さテンプレートの写像は cloudShadowTransmittance の中で行う)
 * 気候 (日替わりの傾向・時刻の対流・雨・雷) を焼き込み、各チャンネルはその層の風で流す (cloud_volume.glsl の CloudClimate)
 *   r = 低層の被覆, g = 低層の雲種, b = 中層の被覆, a = 上層の被覆
 * 同じディスパッチで雲影マップが天気図を読むので隣のテクセルは前フレームの値が混ざるが、
 * 1 フレームの変化は風で 1 テクセルの数千分の 1 なので見た目に影響しない
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_CLOUD_SHADOW
#define IMG_CLOUD_WEATHER
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/sky/cloud_volume.glsl"

layout(local_size_x = 16, local_size_y = 16) in;
const ivec3 workGroups = ivec3(32, 32, 1);

// 晴れ間と雲の多い地域の大きさ (m) と、その被覆の振れ幅
const float CLOUD_REGION_SIZE = 26000.0;
const float CLOUD_REGION_VARIATION = 0.75;
// 雷雨の時の嵐のセルの間の低層の雲種と被覆
// 0.3 / 0.78 では実機で嵐の間が青空の見える晴れ間ばかりになり、雨なのに晴れの日の綿雲に見えた。ほぼ覆って所々だけ切らす
const float CLOUD_THUNDER_GAP_TYPE = 0.25;
const float CLOUD_THUNDER_GAP_COVER = 0.88;
// 雲影の半影の半径 (m) と時間方向の混合率。雲の縁の密度の勾配と多重散乱で、実際の雲影の縁は数十 m かけてぼける
const float CLOUD_SHADOW_PENUMBRA = 45.0;
const float CLOUD_SHADOW_BLEND = 0.08;
const float CLOUD_SHADOW_RESET_DISTANCE = 64.0;

/*------------------------------------------------------------------------------
  非周期の 2D 勾配ノイズ (天気図用)
------------------------------------------------------------------------------*/
vec2 weatherGradient(ivec2 cell, uint seed) {
    float a = hash3(uvec3(uvec2(cell), seed)).x * TAU;
    return vec2(cos(a), sin(a));
}

// およそ [-1,1]
float weatherNoise(vec2 p, uint seed) {
    ivec2 i = ivec2(floor(p));
    vec2 f = p - vec2(i);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n00 = dot(weatherGradient(i, seed), f);
    float n10 = dot(weatherGradient(i + ivec2(1, 0), seed), f - vec2(1.0, 0.0));
    float n01 = dot(weatherGradient(i + ivec2(0, 1), seed), f - vec2(0.0, 1.0));
    float n11 = dot(weatherGradient(i + ivec2(1, 1), seed), f - vec2(1.0, 1.0));
    return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y) * 1.414;
}

// [0,1] の fbm。オクターブごとに回して格子の向きをそろえない
float weatherFbm(vec2 p, int octaves, uint seed) {
    const mat2 ROTATE = mat2(0.8, 0.6, -0.6, 0.8);
    float sum = 0.0, amplitude = 0.5, total = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amplitude * weatherNoise(p, seed + uint(i) * 101u);
        total += amplitude;
        p = ROTATE * p * 2.03 + 17.1;
        amplitude *= 0.5;
    }
    return saturate(sum / total + 0.5);
}

/*
 * ワールド水平位置 world の天気図の値
 * 気候の基準値に地域差を足す。雨の日は全天を覆うので地域差を弱め、雷雨は湿った所に積乱雲を立てる
 */
vec4 cloudWeatherTexel(vec2 world, CloudClimate c) {
    float regionSize = CLOUD_REGION_SIZE * CLOUD_SCALE_FACTOR;
    // 被覆の設定を 0 にした時に地域差だけで雲が湧かないように
    float variation = CLOUD_REGION_VARIATION * min(CLOUD_COVERAGE, 1.0);

    vec2 pLow = (world - cloudWindLow()) / regionSize;
    float region = weatherFbm(pLow, 4, 101u);
    float lowCover = c.lowCover + (region - 0.5) * variation * (1.0 - 0.6 * c.rain);
    float lowType = c.lowType + (weatherFbm(pLow * 1.6 + vec2(31.7, -12.3), 3, 211u) - 0.5) * 0.4;
    // 嵐のセルの外は雄大雲まで (0.75 以上は積乱雲。対流の強い晴れの日に頭上へ積乱雲と雨脚が立った)
    lowType = min(lowType, 0.74);
    // 嵐のセル (5-10 km)。雲種 0.75-1 が積乱雲で、1 が嵐の中心 (塔の太さ・オーバーシュート・降水の柱は中心ほど強い)
    float stormField = weatherFbm(pLow * 3.0 + vec2(-5.3, 8.9), 3, 307u);
    float stormStart = 1.0 - 0.45 * CLOUD_CB_COVERAGE;
    float storm = linearStep(stormStart, stormStart + 0.3, stormField);
    // 嵐のセルの間は雄大雲・層積雲の切れ切れの雲にする。一面の乱層雲 (被覆 1.05) にすると全天が一様な灰色の天井になり、
    // 積乱雲の塔とかなとこが下から一切見えなかった
    lowType = mix(lowType, mix(CLOUD_THUNDER_GAP_TYPE, 1.0, storm), c.thunder);
    lowCover = mix(lowCover, mix(CLOUD_THUNDER_GAP_COVER, 1.3, storm), c.thunder);
#ifdef CLOUD_CB
    // 晴れた日の午後の積乱雲 (熱帯など): c.storm を嵐のセルの被覆として、場の値の高い所から順に立てる。
    // 遠くにだけ立てる (頭上に急に塔が立って雨脚が降りないように)
    float far = smoothstep(9000.0, 20000.0, distance(world, cameraPosition.xz * CLOUD_KH));
    float stormCover = 0.4 * c.storm * CLOUD_CB_COVERAGE;
    float regional = linearStep(1.0 - stormCover, 1.0 - stormCover + 0.1, stormField) * step(1e-3, c.storm) * far;
    lowType = mix(lowType, 1.0, regional);
    lowCover = max(lowCover, regional * 1.2);
#else
    lowType = min(lowType, 0.74);
#endif

    vec2 pMid = (world - cloudWindMid()) / (regionSize * 1.3);
    float midCover = c.midCover + (weatherFbm(pMid, 4, 401u) - 0.5) * 1.2 * variation * (1.0 - 0.5 * c.rain);

    // 上層は形を別の水平の縮尺で読むので、天気図の座標をその縮尺に直して被覆を作る (風と群れが形とずれない)
    vec2 pHigh = (world * (CLOUD_KH_HIGH / CLOUD_KH) - cloudWindHigh()) / (regionSize * 1.8);
    float highCover = c.highCover + (weatherFbm(pHigh, 4, 503u) - 0.5) * 1.3 * variation;

    return saturate(vec4(lowCover / CLOUD_COVER_RANGE, lowType, midCover / CLOUD_COVER_RANGE, highCover / CLOUD_COVER_RANGE));
}

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    CloudClimate climate = cloudClimate();

    vec2 world = cloudMapCenter() + (vec2(texel) + 0.5 - CLOUD_MAP_RES * 0.5) * CLOUD_MAP_TEXEL;
    imageStore(cloudWeatherImg, texel, cloudWeatherTexel(world, climate));

#ifdef CLOUD_SHADOWS
    CloudContext ctx = cloudContextSetup(climate);
    vec3 lightDir = getShadowLightDir();
    vec2 origin = cloudShadowMapOrigin(lightDir);
    vec2 rel = (origin - cameraPosition.xz) + ((vec2(texel) + 0.5) / CLOUD_SHADOW_RES - 0.5) * CLOUD_SHADOW_EXTENT;
    // 半影: 円盤の中でずらした位置の透過率をフレームごとに積み重ね、ぼかした雲影にする (iterationT はガウシアン 2 パス)。
    // 1 テクセルずつの読み書きなので同じディスパッチ内で競合せず、別パスも要らない。
    // 原点がテクセル単位で動いた分は再投影しないが、混合率 CLOUD_SHADOW_BLEND では 1 テクセル (12 m) の遅れがすぐ消える
    vec2 r2 = fract(float(frameCounter % 256) * vec2(0.7548777, 0.5698403) + interleavedGradientNoise(vec2(texel), 0));
    vec2 jitter = sqrt(r2.x) * vec2(cos(TAU * r2.y), sin(TAU * r2.y)) * (CLOUD_SHADOW_PENUMBRA / CLOUD_KH);
    float dither = interleavedGradientNoise(vec2(texel), frameCounter);
    float current = cloudShadowTransmittance(ctx, rel + jitter, lightDir, dither);
    float history = imageLoad(cloudShadowImg, texel).r;
    // 履歴の無効: 再読み込み・時刻の飛び (prepare の履歴フレーム数) とテレポート
    bool reset = frameData.skyParams[1].y < 1.5 || distance(cameraPosition, previousCameraPosition) > CLOUD_SHADOW_RESET_DISTANCE || isnan(history) || isinf(history);
    float shadow = reset ? current : mix(history, current, CLOUD_SHADOW_BLEND);
    imageStore(cloudShadowImg, texel, vec4(saturate(shadow), 0.0, 0.0, 1.0));
#endif
}
