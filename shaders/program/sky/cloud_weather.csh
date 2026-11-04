/*
 * prepare2 (毎フレーム): 雲の天気図 (cloudWeatherImg, 512x512) と雲影マップ (cloudShadowImg, 512x512)
 *
 * 天気図はカメラ中心の窓 (参照空間で 1 テクセル 256 m, ±65 km) に非周期の手続きノイズを毎フレーム書く。
 * 雲影マップはワールドの雲底の面に貼る (高さテンプレートの写像は cloudShadowTransmittance の中で行う)
 * 気候 (日替わりの傾向・時刻の対流・雨・雷) を焼き込み、各チャンネルはその層の風で流す (cloud_weather.glsl の CloudClimate)
 *   r = 低層の被覆, g = 低層の雲種, b = 中層の被覆, a = 上層の被覆
 * 同じディスパッチで雲影マップが天気図を読むので隣のテクセルは前フレームの値が混ざるが、
 * 1 フレームの変化は風で 1 テクセルの数千分の 1 なので見た目に影響しない
 * カメラが雲の層の中にいる時の霧の濃さと光 (cloudInteriorWrite) と、雨の日の雲の向こうの空の置き換え (cloudRainVeil) も
 * 1 スレッドが求めて FrameData に書く
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで) と SSBO (lib/buffers。ほかのプログラムでは readonly)
#define IMG_CLOUD_SHADOW
#define IMG_CLOUD_WEATHER
#define SSBO_FRAME_DATA_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/sky/cloud_volume.glsl"
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
#include "/lib/buffers/frame_data.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
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
#include "/lib/sky/cloud_constants.glsl"
#include "/lib/sky/cloud_weather.glsl"
#include "/lib/sky/cloud_vanilla.glsl"
#include "/lib/sky/cloud_density.glsl"
#include "/lib/sky/cloud_lighting.glsl"
#include "/lib/sky/cloud_march.glsl"
#include "/lib/sky/cloud_volume.glsl"
// END GENERATED includes

layout(local_size_x = 16, local_size_y = 16) in;
const ivec3 workGroups = ivec3(32, 32, 1);

// 晴れ間と雲の多い地域の大きさ (m) と、その被覆の振れ幅
const float CLOUD_REGION_SIZE = 26000.0;
const float CLOUD_REGION_VARIATION = 0.75;
// 雷雨の時の嵐のセルの間の低層の雲種と被覆
// 0.3 / 0.78 では嵐の間が青空の見える晴れ間ばかりになり、雨なのに晴れの日の綿雲に見える。ほぼ覆って所々だけ切らす
const float CLOUD_THUNDER_GAP_TYPE = 0.25;
const float CLOUD_THUNDER_GAP_COVER = 0.88;
// 雲影の半影の半径 (m) と時間方向の混合率。雲の縁の密度の勾配と多重散乱で、実際の雲影の縁は数十 m かけてぼける
const float CLOUD_SHADOW_PENUMBRA = 45.0;
const float CLOUD_SHADOW_BLEND = 0.08;
const float CLOUD_SHADOW_RESET_DISTANCE = 64.0;

// 非周期の 2D 勾配ノイズ (天気図用)
vec2 weatherGradient(ivec2 cell, uint seed) {
    float a = hash3(uvec3(uvec2(cell), seed)).x * TAU;
    return vec2(cos(a), sin(a));
}

const float STORM_FREE_TYPE_MAX = 0.74;     // 嵐のセルの外の雲種の上限 (0.75 以上は積乱雲)
const float CB_REGIONAL_NEAR = 9000.0;    // m: 晴れた日の積乱雲を立てない範囲の端。CB_REGIONAL_FAR で全て立てる
const float CB_REGIONAL_FAR = 20000.0;
const float MID_REGION_SCALE = 1.3;       // 中層・上層の地域の大きさ (低層に対する倍率)
const float HIGH_REGION_SCALE = 1.8;
const float MID_VARIATION_SCALE = 1.2;    // 中層・上層の地域差の強さ (低層に対する倍率)
const float HIGH_VARIATION_SCALE = 1.3;
const float FBM_LACUNARITY = 2.03;
const float FBM_SHIFT = 17.1;

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
        p = ROTATE * p * FBM_LACUNARITY + FBM_SHIFT;
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
    float lowCover = c.lowCover + (region - 0.5) * variation * (1.0 - 0.6 * c.reshape);
    float lowType = c.lowType + (weatherFbm(pLow * 1.6 + vec2(31.7, -12.3), 3, 211u) - 0.5) * 0.4;
    // 嵐のセルの外は雄大雲まで (0.75 以上は積乱雲。対流の強い晴れの日に頭上へ積乱雲と雨脚が立った)
    lowType = min(lowType, STORM_FREE_TYPE_MAX);
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
    float far = smoothstep(CB_REGIONAL_NEAR, CB_REGIONAL_FAR, distance(world, cameraPosition.xz * CLOUD_KH));
    float stormCover = 0.4 * c.storm * CLOUD_CB_COVERAGE;
    float regional = linearStep(1.0 - stormCover, 1.0 - stormCover + 0.1, stormField) * step(1e-3, c.storm) * far;
    lowType = mix(lowType, 1.0, regional);
    lowCover = max(lowCover, regional * 1.2);
#else
    lowType = min(lowType, STORM_FREE_TYPE_MAX);
#endif

    vec2 pMid = (world - cloudWindMid()) / (regionSize * MID_REGION_SCALE);
    float midCover = c.midCover + (weatherFbm(pMid, 4, 401u) - 0.5) * MID_VARIATION_SCALE * variation * (1.0 - 0.5 * c.reshape);

    // 上層は形を別の水平の縮尺で読むので、天気図の座標をその縮尺に直して被覆を作る (風と群れが形とずれない)
    vec2 pHigh = (world * (CLOUD_KH_HIGH / CLOUD_KH) - cloudWindHigh()) / (regionSize * HIGH_REGION_SCALE);
    float highCover = c.highCover + (weatherFbm(pHigh, 4, 503u) - 0.5) * HIGH_VARIATION_SCALE * variation;

    return saturate(vec4(lowCover / CLOUD_COVER_RANGE, lowType, midCover / CLOUD_COVER_RANGE, highCover / CLOUD_COVER_RANGE));
}

#ifdef CLOUD_INTERIOR
/*
 * カメラの位置の雲の媒質 (fog_apply が雲の中の霧として掛ける)
 * skyParams[4] = (太陽の光, 濃さ), skyParams[5] = (空の光, 霧の消散係数 1/ブロック)。濃さが 0 なら雲の外
 * 縁で急に切り替わらないよう、周りの点 (中心・上下・水平の 2 つの輪。バニラの形の板は円盤) の平均の濃さから霧の濃さを作る。縁から輪の半径ほど中へ入るまで
 * 霧は滑らかに濃くなり、出るときも同じ距離で薄くなる。密度の場もカメラの動きも滑らかなので時間方向には均さない
 * (均すと雲を出た後も遠景が白いまま残る)
 */
const int CLOUD_INTERIOR_RING_TAPS = 8;           // 輪 1 つの点の数
const int CLOUD_INTERIOR_TAPS = 3 + 2 * CLOUD_INTERIOR_RING_TAPS; // 中心 + 上下 + 2 つの輪
const vec2 CLOUD_INTERIOR_RING_RADIUS = vec2(4.0, 12.0); // ブロック (水平。遠い輪の半径が霧の立ち上がる幅の目安)
const float CLOUD_INTERIOR_RADIUS_Y = 3.0;        // ブロック (鉛直)
const vec2 CLOUD_INTERIOR_ENTER = vec2(0.05, 0.35); // この平均の濃さの間で霧を立ち上げる (縁の外の薄いもやでは霧にしない。体積雲の中の平均は 0.4 前後)
// バニラの形の板は半径 SLAB_RADIUS の円盤の平均の濃さで立ち上げる。縁の外 4 ブロックでは円盤の 2 割しか板に掛からず霧は 0、
// 縁を 8 ブロック越えると円盤が全部板の中に入って最大になる。壁が見えている間は霧が薄く、縁を越えるあたりから濃くなる
const float CLOUD_INTERIOR_SLAB_RADIUS = 8.0;     // ブロック
const int CLOUD_INTERIOR_SLAB_TAPS = 48;          // 円盤の点の数 (1 点が縁をまたぐ段差が霧の濃さに出ない数)
const vec2 CLOUD_INTERIOR_SLAB_ENTER = vec2(0.2, 0.98);
const float CLOUD_INTERIOR_SLAB_FACE = 3.0;       // ブロック: 頭・底の面からこの深さまで霧を立ち上げる
const float CLOUD_INTERIOR_MID_SHARE = 0.5;       // 中層の雲は薄いので低層より霧を弱める
const float CLOUD_INTERIOR_MIN_SHARE = 0.5;       // 雲のマーチが濃くても、霧は視程の消散係数のこの割合を下限にする (遠くで空と地形の雲の色の差を残さない)
const float CLOUD_INTERIOR_SATURATION = 0.3;      // 空の光の彩度の残し方 (雲の中は何度も散乱して色が抜ける。空の青のままだと青い霧に見える)
const float CLOUD_INTERIOR_LIGHT_DITHER = 0.5;    // 光方向のマーチの開始位置 (揺らさず 1 本で代表させる)

// i 番目の点のカメラからのずれ (ワールド, ブロック)
vec3 cloudInteriorTap(int i) {
    if (i == 0) return vec3(0.0);
    if (i < 3) return vec3(0.0, (i == 1 ? 1.0 : -1.0) * CLOUD_INTERIOR_RADIUS_Y, 0.0);
    int ring = (i - 3) / CLOUD_INTERIOR_RING_TAPS;
    // 輪ごとに半歩ずらして、軸に沿った縁だけに偏らないようにする
    float angle = (float(i - 3 - ring * CLOUD_INTERIOR_RING_TAPS) + 0.5 * float(ring)) * (TAU / float(CLOUD_INTERIOR_RING_TAPS));
    return vec3(cos(angle), 0.0, sin(angle)) * CLOUD_INTERIOR_RING_RADIUS[ring];
}

#ifdef CLOUD_VANILLA_SHAPE
// カメラがいる段 (下段・中段)。上段は薄いので霧を掛けない
VanillaTier cloudInteriorTier() {
    VanillaTier mid = vanillaTier(1);
    bool inMid = CLOUD_VANILLA_TIER_COUNT >= 1 && cameraPosition.y > mid.bottom && cameraPosition.y < mid.bottom + mid.envelope;
    return vanillaTier(inMid ? 1 : 0);
}
#endif

/*
 * カメラからのずれ offset の点の雲の濃さ [0,1] (体積の層。バニラの形の板の濃さは霧には入れず、マーチの消散係数にだけ足す)
 * cloudHeight: 低層の雲の中の高さ、marchExtinction: 雲のマーチがその点に持つ消散係数 (1/ブロック)
 */
float cloudInteriorDensity(CloudContext ctx, vec3 offset, out float cloudHeight, out float marchExtinction) {
    float y = cameraPosition.y + offset.y;
    #ifdef CLOUD_VANILLA_SHAPE
    // 写実の層は描かない。バニラの形の濃さは霧には入れず、マーチの消散係数にだけ足す
    cloudHeight = 0.5;
    VanillaTier tier = cloudInteriorTier();
    marchExtinction = vanillaCloudDensity(tier, vanillaCloudOrigin(tier) + offset.xz, y) * cloudRainDensityScale(ctx) * VANILLA_CLOUD_SIGMA * tier.sigma * VANILLA_CLOUD_KREF;
    return 0.0;
    #else
    vec2 rel = offset.xz * CLOUD_KH;
    float altitude = cloudRefAltitude(y);
    vec4 map = cloudMapFetch(rel);
    float low = cloudLowDensity(ctx, cloudLowColumn(map), rel, altitude, 0.0, false, cloudHeight);
    float rho = low;
    marchExtinction = low * CLOUD_LOW_SIGMA * CLOUD_KH;
    #ifdef CLOUD_MID_LAYER
    float mid = cloudMidDensity(ctx, map.b * CLOUD_COVER_RANGE, rel, altitude, false);
    rho = max(rho, mid * CLOUD_INTERIOR_MID_SHARE);
    marchExtinction += mid * CLOUD_MID_SIGMA * CLOUD_KH;
    #endif
    return saturate(rho);
    #endif
}

#ifdef CLOUD_VANILLA_SHAPE
/*
 * バニラの形の板 (カメラがいる段) の、カメラの周りの半径 CLOUD_INTERIOR_SLAB_RADIUS の円盤での平均の濃さ [0,1]
 * 縁からどれだけ中にいるかを滑らかに表す。点が多いので、1 点が縁をまたぐ段差が霧の濃さに出ない (板の濃さは軽いので点を増やせる)
 */
float cloudInteriorSlabCover(VanillaTier tier) {
    vec2 origin = vanillaCloudOrigin(tier);
    float sum = 0.0;
    for (int i = 0; i < CLOUD_INTERIOR_SLAB_TAPS; i++) {
        float r = CLOUD_INTERIOR_SLAB_RADIUS * sqrt((float(i) + 0.5) / float(CLOUD_INTERIOR_SLAB_TAPS));
        float a = float(i) * GOLDEN_ANGLE;
        sum += vanillaCloudDensity(tier, origin + r * vec2(cos(a), sin(a)), cameraPosition.y);
    }
    return sum / float(CLOUD_INTERIOR_SLAB_TAPS);
}
#endif

void cloudInteriorWrite(CloudContext ctx) {
    float rho = 0.0;
    float extinction = 0.0;
    float cloudHeight = 0.5;
    for (int i = 0; i < CLOUD_INTERIOR_TAPS; i++) {
        float height, tapExtinction;
        rho += cloudInteriorDensity(ctx, cloudInteriorTap(i), height, tapExtinction);
        extinction += tapExtinction;
        if (i == 0) cloudHeight = height;
    }
    rho /= float(CLOUD_INTERIOR_TAPS);
    // 雲のマーチがすでに持つ消散を差し引いて、マーチと霧の合計が設定の視程になるようにする (薄い雲だけ霧が足す)
    float fogExtinction = max(CLOUD_INTERIOR_EXTINCTION - extinction / float(CLOUD_INTERIOR_TAPS), CLOUD_INTERIOR_EXTINCTION * CLOUD_INTERIOR_MIN_SHARE);
    // 縁の立ち上がりを緩くするため 2 乗する (濃さが小さくても遠景を白く閉じてしまうので、縁ではまず手前だけが霞むように)
    rho = sqr(smoothstep(CLOUD_INTERIOR_ENTER.x, CLOUD_INTERIOR_ENTER.y, rho));
    #ifdef CLOUD_VANILLA_SHAPE
    // 柱の頭と底から CLOUD_INTERIOR_SLAB_FACE ブロックまで霧を立ち上げる (柱の外へ出る縁もなめらかにする)。柱の外のマスは頭が 0 なので、円盤の濃さだけで決める
    VanillaTier tier = cloudInteriorTier();
    vec2 column = vanillaCloudColumn(tier, vanillaCloudCellOf(tier, vanillaCloudOrigin(tier)));
    float camH = cameraPosition.y - tier.bottom;
    vec2 span = vanillaCloudSpan(column, camH);
    float faceDepth = min(camH - span.x, span.y - camH);
    float faceFade = column.x > 0.0 ? smoothstep(0.0, CLOUD_INTERIOR_SLAB_FACE, max(faceDepth, 0.0)) : 1.0;
    // 霧は視線の全長に掛かるので、縁の外のわずかな濃さでも遠景が曇る。2 乗にして縁の手前はごく薄く、縁を越えるあたりから濃くする
    rho = max(rho, sqr(smoothstep(CLOUD_INTERIOR_SLAB_ENTER.x, CLOUD_INTERIOR_SLAB_ENTER.y, cloudInteriorSlabCover(tier))) * faceFade);
    #endif

    vec3 sun = vec3(0.0);
    vec3 ambient = vec3(0.0);
    if (rho > 0.0) {
        // 雲のマーチと同じ光 (cloudInscatter) を、カメラの位置 1 点で求める。光源の光は横から見た値で、向きによる差は fog_apply が掛ける
        float y = cameraPosition.y;
        CloudLighting l = cloudLightingSetup(vec3(0.0, 1.0, 0.0), ctx.rainLight);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH, slope);
        float odNear = 0.0;
        float odLight = 0.0;
        float odSky = 0.0;
        float groundVisibility = 1.0;
        #ifdef CLOUD_VANILLA_SHAPE
        // 写実の層は描かない。バニラの形の柱の中の光だけ
        float slabWeight = cloudRainDensityScale(ctx);
        vec2 q = vanillaCloudOrigin(tier);
        odLight = vanillaCloudLightOD(tier, q, y, l.lightDir) * slabWeight;
        odSky = vanillaCloudSkyOD(tier, q, y) * slabWeight;
        l = cloudVanillaLighting(l);
        float slabHeight = (y - tier.bottom) / tier.baseDepth;
        if (slabHeight > 0.0 && y < tier.bottom + tier.envelope) {
            cloudHeight = saturate(slabHeight);
            groundVisibility = sqr(1.0 - cloudHeight);
        }
        #else
        vec4 map = cloudMapFetch(vec2(0.0));
        odLight = cloudLowLightOD(ctx, cloudLowColumn(map), vec2(0.0), altitude, lightDir, CLOUD_INTERIOR_LIGHT_DITHER, odNear);
        odSky = cloudLowSkyOD(ctx, cloudLowColumn(map), vec2(0.0), altitude);
        groundVisibility = sqr(1.0 - saturate((altitude - CLOUD_R_BASE) / CLOUD_R_DEPTH));
        #ifdef CLOUD_MID_LAYER
        odLight += cloudMidLightOD(ctx, map.b * CLOUD_COVER_RANGE, vec2(0.0), altitude, lightDir, CLOUD_INTERIOR_LIGHT_DITHER);
        #endif
        #endif
        float sigma = extinction / (float(CLOUD_INTERIOR_TAPS) * CLOUD_KH);
        float upperT = cloudUpperTransmittance(ctx, vec2(0.0), altitude, lightDir);
        // 光源の光だけ、空と地面の光だけを別々に求める (向きによる差を光源の光だけに掛けるため)
        CloudLighting sunOnly = l;
        sunOnly.cosTheta = 0.0;
        sunOnly.skyRadiance = vec3(0.0);
        sunOnly.groundRadiance = vec3(0.0);
        CloudLighting skyOnly = l;
        skyOnly.lightIrradiance = vec3(0.0);
        sun = cloudInscatter(sunOnly, sigma, odLight, odNear, odSky, groundVisibility, upperT, cloudHeight) * CLOUD_ALBEDO;
        ambient = cloudInscatter(skyOnly, sigma, odLight, odNear, odSky, groundVisibility, upperT, cloudHeight) * CLOUD_ALBEDO;
        ambient = mix(vec3(luminance(ambient)), ambient, CLOUD_INTERIOR_SATURATION);
        #ifdef CLOUD_VANILLA_SHAPE
        // 夜の中段は雲のマーチと同じく暗くする (霧だけ明るく浮かない)
        float nightGain = mix(1.0, VANILLA_TIER_NIGHT_GAIN, tier.index == 0 ? 0.0 : cloudVanillaNight());
        sun *= nightGain;
        ambient *= nightGain;
        #endif
    }
    frameData.skyParams[4] = vec4(sun, rho);
    frameData.skyParams[5] = vec4(ambient, fogExtinction);
}
#endif

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    CloudClimate climate = cloudClimate();

#ifdef CLOUD_VANILLA_SHAPE
    // 天気図は使わない。同じ image に、バニラの形の柱の表を書く (1 スレッド = 1 マス)
    imageStore(cloudWeatherImg, texel, vanillaCloudTableTexel(texel));
#else
    vec2 world = cloudMapCenter() + (vec2(texel) + 0.5 - CLOUD_MAP_RES * 0.5) * CLOUD_MAP_TEXEL;
    imageStore(cloudWeatherImg, texel, cloudWeatherTexel(world, climate));
#endif

    CloudContext ctx = cloudContextSetup(climate);
#if defined CLOUD_RAIN_KEEPS_SHAPE && defined HAS_SKY
    // 雨の日の雲の向こうの空の置き換え。水面などの反射の空を、雲のバッファの空と同じ灰色にそろえるために書く
    if (texel == ivec2(0)) frameData.skyParams[6] = cloudRainVeil(ctx, cloudLightingSetup(vec3(0.0, 1.0, 0.0), ctx.rainLight));
#endif
#ifdef CLOUD_INTERIOR
    // 1 スレッドだけが書く。ほかのスレッドは天気図と雲影マップを作る
    if (texel == ivec2(0)) cloudInteriorWrite(ctx);
#endif
#ifdef CLOUD_SHADOWS
    vec3 lightDir = getShadowLightDir();
    // このテクセルが持つ面上のテクセル番号 (窓の中のどれか 1 つ。前フレームの窓と同じ番号なら履歴がそのまま使える)
    const int SHADOW_RES = int(CLOUD_SHADOW_RES);
    ivec2 windowLow = ivec2(round(cloudShadowMapOrigin(cameraPosition, lightDir) / CLOUD_SHADOW_TEXEL)) - SHADOW_RES / 2;
    ivec2 windowLowPrev = ivec2(round(cloudShadowMapOrigin(previousCameraPosition, lightDir) / CLOUD_SHADOW_TEXEL)) - SHADOW_RES / 2;
    ivec2 plane = windowLow + ((texel - windowLow) & (SHADOW_RES - 1));
    ivec2 planePrev = windowLowPrev + ((texel - windowLowPrev) & (SHADOW_RES - 1));
    vec2 rel = (vec2(plane) + 0.5) * CLOUD_SHADOW_TEXEL - cameraPosition.xz;
    // 半影: 円盤の中でずらした位置の透過率をフレームごとに積み重ね、ぼかした雲影にする (iterationT はガウシアン 2 パス)。
    // 1 テクセルずつの読み書きなので同じディスパッチ内で競合せず、別パスも要らない。
    // 面に固定した環状のタイルなので、カメラが動いても履歴は同じ点のまま。窓の端で新しく窓に入ったテクセルだけ履歴を捨てる
    vec2 r2 = fract(float(frameCounter % 256) * vec2(0.7548777, 0.5698403) + interleavedGradientNoise(vec2(texel), 0));
    vec2 jitter = sqrt(r2.x) * vec2(cos(TAU * r2.y), sin(TAU * r2.y)) * (CLOUD_SHADOW_PENUMBRA / CLOUD_KH);
    float dither = interleavedGradientNoise(vec2(texel), frameCounter);
    float current = cloudShadowTransmittance(ctx, rel + jitter, lightDir, dither);
    float history = imageLoad(cloudShadowImg, texel).r;
    // 履歴の無効: 再読み込み・時刻の飛び (prepare の履歴フレーム数) とテレポート
    bool reset = frameData.skyParams[1].y < 1.5 || distance(cameraPosition, previousCameraPosition) > CLOUD_SHADOW_RESET_DISTANCE || any(notEqual(plane, planePrev)) || isnan(history) || isinf(history);
    float shadow = reset ? current : mix(history, current, CLOUD_SHADOW_BLEND);
    imageStore(cloudShadowImg, texel, vec4(saturate(shadow), 0.0, 0.0, 1.0));
#endif
}
