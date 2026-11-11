/*
 * 空・太陽・月 (sky モジュール)
 * 他モジュールに公開する関数のシグネチャは固定
 * 空の放射は SkyView LUT (prepare1, Hillaire 2020) から、ATMOSPHERE_MODE=0 では解析近似から
 */
#ifndef SKY_SKY_COLOR_GLSL
#define SKY_SKY_COLOR_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/celestial_shape.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/dimension.glsl"
//@include "/lib/common/look_presets.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/images.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/atmosphere.glsl"
//@include "/lib/sky/celestial.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/sh.glsl"

// 月光の色。物理的には太陽光とほぼ同じだが、夜の視覚 (プルキンエ効果) に寄せて青に振る
const vec3 MOON_TINT = vec3(0.72, 0.84, 1.0);
/*
 * 月の照り返しの満ち欠けの曲線の冪。球のランバート体の位相関数のままだと半月で満月の 0.32 だが、
 * 実際の月は表土の後方散乱 (衝効果) で半月は満月の 1 割前後まで落ちる。差を出しつつ半月で真っ暗にしない間を取る
 */
const float MOON_PHASE_EXPONENT = 1.5;
// 曇天 (雨) で空が灰色に寄る量と暗くなる量
const float SKY_OVERCAST_DESATURATE = 0.85;
const float SKY_OVERCAST_DARKEN = 0.55;
// 雨雲の層より上から見る空に残す曇天の割合 (雲の上の空は普通の空で、少しだけ暗い)
const float SKY_OVERCAST_ABOVE_DECK = 0.2;
// 月も無い夜の空の下限 (大気光・星明かり)
const vec3 SKY_NIGHT_FLOOR = vec3(0.55, 0.75, 1.0) * 3e-5;
/*
 * 空の色の彩度 (LUT の値に掛ける見た目の調整)
 * そのままだと AgX を通した昼の天頂が灰青、夕方の太陽まわりが白っぽい桃色に寄った
 * iterationT も大気の色を錐体空間の行列で盛っている。環境光 (SH) 側は prepare.csh で別に彩度を落とす
 */
const float SKY_COLOR_SATURATION = 1.25 * LK_SKY_SAT;
// 描画距離の外の地面 (skyBelowHorizon)
const vec3 SKY_DISTANT_GROUND_ALBEDO = vec3(0.16, 0.18, 0.14); // 草地・森・岩の平均
// 雪原・砂漠では外の地面も明るい。草地の色のままだと、高所から見た夕方の雪原の描画距離の外が暗い灰色の壁に見えた
const vec3 SKY_DISTANT_SNOW_ALBEDO = vec3(0.55, 0.58, 0.62);  // 雪と針葉樹の混ざり
const vec3 SKY_DISTANT_SAND_ALBEDO = vec3(0.42, 0.34, 0.24);
// 海の外は地平線近くの空を映す水面 (かすめ角のフレネル)
const float SKY_DISTANT_OCEAN_REFLECTANCE = 0.8;
/*
 * 虚空の明るさの上限: 太陽から SKY_VOID_SUN_COS_FAR の角度より離れた方位では地平線の空の SKY_VOID_MAX_GAIN 倍まで、
 * 太陽に近づくにつれて SKY_VOID_MAX_GAIN_SUN 倍までなめらかに緩める。4 倍から 20-30 度で 1.05 倍へ切り替えていた時は、
 * 日没後に太陽の下の虚空が縦の縁のある赤い四角に見えた
 */
const float SKY_VOID_MAX_GAIN = 1.05;
const float SKY_VOID_MAX_GAIN_SUN = 1.6;
const float SKY_VOID_SUN_COS_NEAR = 0.9986; // 3 度
const float SKY_VOID_SUN_COS_FAR = 0.866;   // 30 度
const float SKY_DISTANT_GROUND_OVERCAST = 0.85; // 雨雲で直達光が減る割合
// 描画距離を 1 として、地面までの距離がこれだけ描画距離を超えるごとに、地面の色が空の色へ溶ける割合 (1 - 1/e) が増える
const float SKY_VOID_AERIAL_LENGTH = 1.0;
const float SKY_VOID_AERIAL_LOW_SUN_KEEP = 0.5; // 太陽が低い時に、地平線の色のまま残す割合
const float SKY_DISTANT_GROUND_MIN_HEIGHT = 8.0; // 海面より低い視点でも地面までの距離を 0 にしない
const float SKY_HORIZON_SAMPLE_MU = 0.004;    // 地平線の色を読む高さ (地平線の真上の LUT の継ぎ目を避ける)
const float SKY_SHADOWED_HAZE_MU = 0.15;      // 朝夕の地表のもやの色を読む高さ
const float SKY_SHADOWED_HAZE = 0.7;          // 朝夕に地表のもやの色をその高さの空へ寄せる割合
const float SKY_SHADOWED_HAZE_FADE_MU = 0.03; // 地平線からこの深さまでで上の空の色へ寄せ始める

// ネザー・エンドの環境
/*
 * ネザーの環境光と霧の色 (バイオームごと)
 * fogColor からは作らない。真紅の森の fogColor は純粋な赤 (sRGB 51,3,3) で、彩度を落としても環境光が赤一色になり
 * 地面のテクスチャの色が読めない。明るさもバイオームで 40 倍違う (歪んだ森 0.003, 玄武岩 0.12)。
 * 環境光は控えめな色味 (溶岩・菌糸の照り返しの暖色 / 魂の炎の寒色)、霧は煤や灰の色として地形と同程度の明るさにする
 * ambient: 環境光の色 (輝度 1 に正規化して使う) と明るさ, fog: 霧の散乱アルベドの色, density: 霧の濃さの倍率
 */
const float NETHER_AMBIENT_IRRADIANCE = 0.09;  // 荒地の環境光の照度
struct NetherPalette {
    vec3 ambient;   // 一様な環境光の照度
    vec3 fogAlbedo; // 霧の散乱アルベド (内散乱 = アルベド x 環境光の放射)
    float density;  // 霧の消散係数の倍率
};
NetherPalette netherBiome(vec3 ambientTint, float ambientLevel, vec3 fogTint, float fogLevel, float density) {
    NetherPalette p;
    p.ambient = ambientTint / max(luminance(ambientTint), 1e-4) * ambientLevel;
    p.fogAlbedo = fogTint / max(luminance(fogTint), 1e-4) * fogLevel;
    p.density = density;
    return p;
}
NetherPalette getNetherPalette() {
    float wSoul = saturate(netherSoulValley), wCrimson = saturate(netherCrimson);
    float wWarped = saturate(netherWarped), wBasalt = saturate(netherBasalt);
    float wWastes = saturate(1.0 - wSoul - wCrimson - wWarped - wBasalt);
    float wSum = max(wWastes + wSoul + wCrimson + wWarped + wBasalt, 1e-3);
    NetherPalette b[5] = NetherPalette[5](
        netherBiome(vec3(1.00, 0.55, 0.36), 1.00, vec3(1.00, 0.36, 0.20), 0.12, 1.0), // 荒地: 溶岩の橙
        netherBiome(vec3(0.62, 0.80, 1.00), 0.75, vec3(0.38, 0.62, 0.70), 0.15, 1.1), // ソウルサンドバレー: 魂の炎の青緑
        // 霧 (1.0, 0.30, 0.22) と暖色の環境光では、赤い地面・崖・遠景が赤一色になる (R/B 7.9)
        // 地面の赤はテクスチャに任せ、環境光は中性寄り、霧は煤の暗い赤茶にする
        netherBiome(vec3(1.00, 0.88, 0.80), 0.95, vec3(1.00, 0.55, 0.45), 0.10, 1.0), // 真紅の森: 赤い胞子
        netherBiome(vec3(0.72, 0.86, 1.00), 0.80, vec3(0.42, 0.62, 0.72), 0.14, 0.8), // 歪んだ森: 青緑の胞子
        netherBiome(vec3(1.00, 0.86, 0.76), 1.30, vec3(0.82, 0.78, 0.80), 0.25, 1.6)  // 玄武岩の三角州: 灰
    );
    float w[5] = float[5](wWastes, wSoul, wCrimson, wWarped, wBasalt);
    NetherPalette p;
    p.ambient = vec3(0.0); p.fogAlbedo = vec3(0.0); p.density = 0.0;
    for (int i = 0; i < 5; i++) {
        p.ambient += b[i].ambient * w[i];
        p.fogAlbedo += b[i].fogAlbedo * w[i];
        p.density += b[i].density * w[i];
    }
    p.ambient *= NETHER_AMBIENT_IRRADIANCE / wSum;
    p.fogAlbedo /= wSum;
    p.density /= wSum;
    return p;
}
// ネザーの霧が無限に続いた時の放射 (虚空・霧の内散乱の飽和値)
vec3 getNetherFogRadiance() {
    NetherPalette p = getNetherPalette();
    return p.fogAlbedo * p.ambient * RCP_PI;
}
// エンドの平行光と環境光。0.30 / 0.10 (比 3) では影の中も外も明るさの差が小さく、地形が平たく見えた
const vec3 END_LIGHT_IRRADIANCE = vec3(0.30, 0.26, 0.40) * 2.0;
const vec3 END_AMBIENT_IRRADIANCE = vec3(0.10, 0.08, 0.15) * 0.6;
const float END_AMBIENT_UP = 1.6;   // 上向きの面の環境光の倍率
const float END_AMBIENT_DOWN = 0.2; // 下向きの面 (虚空側)

// 大気上端での太陽照度
vec3 getSunIlluminanceTOA() { return vec3(SUN_ILLUMINANCE * SUN_BRIGHTNESS); }

/*
 * ルックの日向の色 (LK_SUN_WARMTH)。地表に届く太陽の直達光だけを暖色に寄せる (輝度は保つ)
 * 日陰の空の光の青との色の割れを出す見た目の値 (写真で白の基準を日向より高い色温度に置いた時の写り方)。空・雲・太陽の円盤の色は変えない
 */
const float LOOK_SUN_WARM_KELVIN = 5000.0;
vec3 lookSunTint() {
    vec3 t = mix(vec3(1.0), blackbody(LOOK_SUN_WARM_KELVIN) / blackbody(6500.0), LK_SUN_WARMTH);
    return t / luminance(t);
}

// 月の照り返しが満ち欠けでどれだけ減るか (満月 = 1、新月 = 0)
// 新月の夜の明るさは向きのない空の底 (SKY_NIGHT_FLOOR・大気光・星) と MIN_AMBIENT が受け持つ。
// ここに下限を残すと、新月でも月の方向から平行光が来て、影・光芒・フレアが出る
float moonPhaseFactor() {
    // 位相角は満ちる側で PI を超えるので、明るさは 2PI - a に折り返して欠ける側と対称にする
    float raw = moonPhaseAngle();
    float a = min(raw, 2.0 * PI - raw);
    float lambert = ((PI - a) * cos(a) + sin(a)) * RCP_PI;
    return pow(saturate(lambert), MOON_PHASE_EXPONENT);
}

vec3 getMoonIlluminanceFull() { return MOON_ILLUMINANCE * MOON_BRIGHTNESS * MOON_TINT; }
vec3 getMoonIlluminanceTOA() { return getMoonIlluminanceFull() * moonPhaseFactor(); }

// 地表での太陽直達照度 (大気透過込み)。prepare が FrameData に書いた値
vec3 getSunIrradiance() { return frameData.sunIrradiance.rgb; }
vec3 getMoonIrradiance() { return frameData.moonIrradiance.rgb; }

// 影を落とす天体 (昼 = 太陽, 夜 = 月) の光。太陽影 (C) と VL (B) はこれを使う
LightSample getCelestialLight() {
    LightSample s;
    s.direction = getShadowLightDir();
    s.irradiance = frameData.shadowLightIrradiance.rgb;
    s.angularSize = frameData.shadowLightIrradiance.a > 0.5 ? SUN_ANGULAR_RADIUS : MOON_ANGULAR_RADIUS;
    return s;
}

/*
 * 天体の鏡面に掛ける円盤の放射輝度の倍率 (specularDiscCap の discScale)。太陽は 1
 * 夜の月は空に描く円盤 (MOON_DISK_SCALE 倍の大きさで MOON_NIGHT_BRIGHTNESS x MOON_DISK_NIGHT_GAIN 倍) を基準にし、鏡像は空の月より明るくならない
 * (照度どおりの鏡像は空の月の約 50 倍 x フレネルになり、水面に月より明るい白い塊が出る)。月の円盤には周縁減光が無いので、
 * 太陽用の中心の倍率 (SPECULAR_DISC_PEAK) を割って戻す
 * 鏡面のローブの広がりと粗い面が受ける光は照度のまま (拡散と同じ光) で、上限だけ見えている円盤に合わせる
 * 強さの設定 (celestialSpecularStrength、呼び出し側が掛ける) は、粗い面の照り返しだけを明るくし、水たまりのような鏡に近い面の
 * 鏡像は見えている円盤より明るくしない。上限を 1 より大きい強さで割っておく (太陽も月も同じ。強さ 1 で円盤の鏡像どおり)
 */
// 影を落とす天体の鏡面の強さの設定 (昼は太陽、夜は月。エンドの光も月の側)
float celestialSpecularStrength() {
    return frameData.shadowLightIrradiance.a > 0.5 ? SPECULAR_SUN_STRENGTH : SPECULAR_MOON_STRENGTH;
}

float celestialDiscScale() {
    float disc = 1.0;
#ifdef HAS_SKY
    if (frameData.shadowLightIrradiance.a <= 0.5)
        disc = mix(MOON_NIGHT_BRIGHTNESS * MOON_DISK_NIGHT_GAIN, 1.0, moonDayMix(getSunDir().y)) / (sqr(MOON_DISK_SCALE) * SPECULAR_DISC_PEAK);
#endif
    return disc / max(celestialSpecularStrength(), 1.0);
}

// 法線 n の面が空から受ける拡散照度 (遮蔽なし。AO・スカイライトは受け取り側が掛ける)
vec3 getSkyIrradiance(vec3 n) { return shEvalIrradiance(n); }

/*
 * 空の SH の下半球 (地面の照り返し)。prepare が平らで一様な灰色の地面 (反射率 SH_GROUND_ALBEDO) として SH に入れている
 * 一様な下半球からの照度は L1 までで表せて、法線 n の面では E (1 - n.y) / 2 (L2 の係数は 0)
 * GI (RSM / SSGI / ボクセル RT) は近くの地面の照り返しを実際の色で足すので、受け取り側でこの分を SH から引く。
 * 引かないと二重に数えたうえ、反射率 0.2 x SH_SKY_GAIN = 0.34 の灰色が草の照り返し (草の上面の反射率は輝度 0.13) を埋めて、
 * 草地に立つ白い柱の側面の照度の 5 割近くがこの灰色になり、緑が乗らない
 */
const float SH_GROUND_ALBEDO = 0.2;
// 輝度を保ったまま SH の彩度を落とす割合と、SH 全体の強さ (理由は prepare.csh)
const float SH_SKY_SATURATION = LOOK_SKY_AMBIENT_SATURATION;
const float SH_SKY_GAIN_BASE = 1.7;
/*
 * ルックの空の環境光の強さ (LK_SKY_AMBIENT) は SH 全体に掛ける (日陰・GI のレイが運ぶ空の光・水・半透明が揃って変わる)
 * 空そのものの描画は変えないので、SH を空の明るさとして使う所 (霧の内散乱・粗い反射の空・フレアの可視判定) は
 * SH_LOOK_UNDO を掛けて戻す。雲の陰の空の光は prepare が SH_SKY_GAIN_BASE で別に作る
 */
const float SH_SKY_GAIN = SH_SKY_GAIN_BASE * LK_SKY_AMBIENT;
const float SH_LOOK_UNDO = 1.0 / LK_SKY_AMBIENT;

vec3 shSkyGrade(vec3 c) {
    c *= SH_SKY_GAIN;
    return mix(vec3(luminance(c)), c, SH_SKY_SATURATION);
}

// 地面が受ける光 (太陽・月の直達 + 真上の空) x 反射率。prepare は SH を作る前、ここの shEvalIrradiance は前フレームの SH
vec3 skyGroundIrradianceRaw() {
#ifdef HAS_SKY
    return (getSunIrradiance() * max(getSunDir().y, 0.0) + getMoonIrradiance() * max(getMoonDir().y, 0.0)
          + shEvalIrradiance(vec3(0.0, 1.0, 0.0))) * SH_GROUND_ALBEDO;
#else
    return vec3(0.0);
#endif
}

// 法線 n の面が SH の下半球から受ける照度 (SH の彩度・強さの調整込み)
vec3 getSkyGroundIrradiance(vec3 n) { return shSkyGrade(skyGroundIrradianceRaw()) * (0.5 - 0.5 * n.y); }

// 洞窟の度合い (0 = 屋外, 1 に近いほど空が見えない)。目の位置のスカイライトから (Kappa / Nostalgia と同じ考え方)
float getCaveFactor() {
#ifdef HAS_SKYLIGHT
    return 1.0 - smoothstep(0.05, 0.6, float(eyeBrightnessSmooth.y) / 240.0);
#else
    return 0.0;
#endif
}

/*
 * 太陽の方向の遠い霧の光り方を、目の周りの太陽の見え方 (prepare が影マップから求める) で抑える割合。影マップの範囲より遠い区間用
 * 屋外 (スカイライト 9 以上) と画面空間の判定だけでは、山の陰や洞窟の口でも遠い霧が太陽の色で光る
 * 太陽から外れた方向 (cos -0.17 = 100 度より外) は抑えず、遠景のもやを残す
 */
const float FAR_SUN_SHADE_COS_OFF = -0.17;
const float FAR_SUN_SHADE_COS_ON = 0.5;
// 目の周りの見え方がこの範囲で 1 -> 0 に落ちる。柱・柵・細い木で一部が遮られただけでは抑えず、半分以上が遮られた時に効かせる
const float FAR_SUN_SHADE_VISIBLE_MIN = 0.1;
const float FAR_SUN_SHADE_VISIBLE_FULL = 0.7;
float farSunToward(vec3 dir) {
    return smoothstep(FAR_SUN_SHADE_COS_OFF, FAR_SUN_SHADE_COS_ON, dot(dir, getShadowLightDir()));
}

float farSunShade(vec3 dir) {
    float visible = smoothstep(FAR_SUN_SHADE_VISIBLE_MIN, FAR_SUN_SHADE_VISIBLE_FULL, frameData.skyParams[3].y);
    return mix(1.0, visible, farSunToward(dir));
}

/*
 * 太陽が画面の中で、影マップの範囲より遠い地形に隠れている割合 (composite25 が太陽の円盤の深度から求める) で、太陽の方向の霧の光を抑える
 * 画面空間の光芒 (VL_FAR) が無い構成の手当て。山の裏・遠い壁の裏で、影マップに写らない遮蔽物による貫通を抑える
 * 範囲内の遮蔽 (木・近い崖) は影マップが見るので含めない。太陽が画面の外にある時は分からないので抑えない
 */
float farSunHiddenShade(vec3 dir) {
    return mix(1.0, 1.0 - frameData.skyParams[3].z, farSunToward(dir));
}

// 雨で曇った空へ寄せる (雲の無い LUT を灰色の曇天に近づける)
float skyOvercast() { return rainStrength * mix(SKY_OVERCAST_ABOVE_DECK, 1.0, cloudRainBelowDeck()); }

vec3 skyApplyOvercast(vec3 radiance) {
    float overcast = skyOvercast();
    vec3 grey = vec3(luminance(radiance));
    radiance = mix(radiance, grey, overcast * SKY_OVERCAST_DESATURATE);
    return radiance * mix(1.0, SKY_OVERCAST_DARKEN, overcast);
}

vec2 skySafeNormalize(vec2 v) {
    float l = length(v);
    return l > 1e-5 ? v / l : vec2(1.0, 0.0);
}

/*
 * 方向 dir の空の放射 (太陽円盤・星なし)。反射・フォグの色にも使う
 * 地平線より下は地平線の色を返す (遠景の地形が溶ける先と、反射の下半分を地平線色で一致させるため)
 */
vec3 getSkyRadiance(vec3 dir) {
#if defined HAS_SKY
    vec3 sunDir = getSunDir();
    #if ATMOSPHERE_MODE == 1
        float cosAzimuth = dot(skySafeNormalize(dir.xz), skySafeNormalize(sunDir.xz));
        vec3 radiance = texture(skyViewSampler, atmoSkyViewUv(atmoViewerRadius(), dir.y, cosAzimuth)).rgb;
    #else
        vec3 d = normalize(vec3(dir.x, max(dir.y, 0.0), dir.z));
        vec3 radiance = atmoAnalyticSkyForLight(d, sunDir) * getSunIlluminanceTOA() + atmoAnalyticSkyForLight(d, -sunDir) * getMoonIlluminanceTOA();
    #endif
    radiance = max(mix(vec3(luminance(radiance)), radiance, SKY_COLOR_SATURATION), 0.0);
    return (skyApplyOvercast(radiance) + SKY_NIGHT_FLOOR) * SKY_BRIGHTNESS;
#elif defined WORLD_END
    return END_SKY_COLOR * SKY_BRIGHTNESS;
#else
    return getNetherFogRadiance();
#endif
}

/*
 * 地平線より下 (描画距離の外の虚空) の色: 描画距離の外まで地面が続くとみなし、視線が地面に当たる距離ぶんの空中遠近で地平線の空の色に溶かす
 * 地平線のすぐ下は描画距離の外の遠景がもやに溶けた色なので、地平線の色のまま残す
 * 0.25 で 0.4 倍まで落としていた時は、高所から見ると描画距離の端と地平線の間が灰色 (夕方は茶色) の平らな帯になった。
 * LUT の地平線より下の値 (地面までの大気の内散乱) のままでも、夕方は赤茶色の一様な面になる。
 * 地面までの距離で地面の色から地平線の色へ移るので、遠くほど霞む奥行きのある遠景になり、朝夕は暗い地面が地平線の照りへ溶ける
 * 描画距離端のフォグ (getBorderFogColor) も同じ色を使い、地形が溶ける色と虚空の色を揃える
 */
// fog.glsl
vec3 fogVoidTransmittance(vec3 dir, float groundDist);
vec3 fogAirSkyDir(vec3 dir, float mu);
float fogRenderDistance();
vec3 skyBelowHorizon(vec3 dir, vec3 sky) {
#if defined HAS_SKY
    float horizonMu = atmoHorizonMu(atmoViewerRadius());
    float below = horizonMu - dir.y;
    if (below <= 0.0) return sky;
    // 地平線の少し上の空の色。方位は太陽との角度が視線と同じになる所 (太陽の真下の虚空が太陽の横の輝きで光る柱にならないように)
    vec3 horizon = getSkyRadiance(fogAirSkyDir(dir, horizonMu + SKY_HORIZON_SAMPLE_MU));
    // 朝夕は地表近くのもやが地球の影に入り、直射の照りではなく空の光で光る。地平線の照りの色のままだと赤茶色の面になるので、
    // 太陽が低いほど少し上の空 (同じ方位) の色に寄せる
    float lowSun = 1.0 - smoothstep(0.02, 0.15, getSunDir().y);
    // 地平線のすぐ下 (海面近くから見た描画距離の外の数ピクセル) は照りの色のまま残す。ここを上の空の紫灰色にすると、
    // 夕方の海で水面の端と地平線の間に灰色の線が出た
    float shadowedHaze = SKY_SHADOWED_HAZE * lowSun * smoothstep(0.0, SKY_SHADOWED_HAZE_FADE_MU, below);
    horizon = mix(horizon, getSkyRadiance(fogAirSkyDir(dir, SKY_SHADOWED_HAZE_MU)), shadowedHaze);
    float height = max(cameraPosition.y - SKY_SEA_LEVEL, SKY_DISTANT_GROUND_MIN_HEIGHT);
    float dist = height / max(below, 1e-4);
    // 描画距離の中の地形と同じフォグの式で、仮想の地面まで積む (描画距離の端で地形と継ぎ目が出ない)
    vec3 transmittance = fogVoidTransmittance(dir, dist);
    vec3 irradiance = getSunIrradiance() * max(getSunDir().y, 0.0) * (1.0 - SKY_DISTANT_GROUND_OVERCAST * rainStrength)
                    + getMoonIrradiance() * max(getMoonDir().y, 0.0) + getSkyIrradiance(vec3(0.0, 1.0, 0.0));
    vec3 albedo = mix(SKY_DISTANT_GROUND_ALBEDO, SKY_DISTANT_SNOW_ALBEDO, saturate(distantSnow));
    albedo = mix(albedo, SKY_DISTANT_SAND_ALBEDO, saturate(distantSand));
    vec3 ground = irradiance * (albedo * RCP_PI);
    // 海: 同じ方位で地平線から同じ角度だけ上の空を映す
    vec3 mirrored = getSkyRadiance(vec3(dir.x, horizonMu + below, dir.z));
    vec3 sea = mirrored * SKY_DISTANT_OCEAN_REFLECTANCE;
    ground = mix(ground, sea, saturate(distantOcean));
    vec3 result = mix(horizon, ground, transmittance);
    // 描画距離から遠い地面ほど、地面の色 (雪原は白い) を捨てて、見下ろした角度の上の空の青へ溶かす。
    // 描画距離の端 (dist = 描画距離) では 0 なので、端で止まる地形との継ぎ目は出ない。地平線のすぐ下 (below が小さい) は
    // 地平線の色とほぼ同じ空なので、地上から見た見た目は変わらず、高所から見下ろす角度ほど青くなる
    float renderDistance = fogRenderDistance();
    float toAerial = 1.0 - exp(-max(dist - renderDistance, 0.0) / (SKY_VOID_AERIAL_LENGTH * renderDistance));
    // 朝夕は地表近くのもやが地平線の橙を保つので、上の空の青へは半分ほどしか寄せない
    toAerial *= 1.0 - SKY_VOID_AERIAL_LOW_SUN_KEEP * lowSun;
    result = mix(result, mix(mirrored, sea, saturate(distantOcean)), toAerial);
    // 太陽から離れた方位では地平線の空より明るくしない (日の当たる霞の上面が空より明るく光るのは太陽の近くだけ)
    vec3 horizonSky = getSkyRadiance(vec3(dir.x, horizonMu + SKY_HORIZON_SAMPLE_MU, dir.z));
    float nearSun = sqr(smoothstep(SKY_VOID_SUN_COS_FAR, SKY_VOID_SUN_COS_NEAR, dot(dir, getSunDir())));
    float maxLum = luminance(horizonSky) * mix(SKY_VOID_MAX_GAIN, SKY_VOID_MAX_GAIN_SUN, nearSun);
    return result * min(1.0, maxLum / max(luminance(result), 1e-9));
#else
    return sky;
#endif
}

/*
 * 背景の空 (deferred30 が空のピクセルに描く)
 * vanillaSky: gbuffers_skytextured が colortex0 に描いたもの (SUN_MOON_STYLE=0 の太陽月テクスチャ等)
 */
vec3 renderSky(vec3 dir, vec3 vanillaSky) {
#if defined HAS_SKY
    vec3 sky = getSkyRadiance(dir);
    float r = atmoViewerRadius();
    // 地平線より下は描画距離の外の霞んだ地面にして、虚空が明るく見えないようにする
    sky = skyBelowHorizon(dir, sky);

    vec3 viewT = atmoTransmittanceToLight(r, dir.y) * (1.0 - 0.95 * skyOvercast());
    #if SUN_MOON_STYLE >= 1
        sky += skySunDisk(dir, getSunDir(), getSunIlluminanceTOA(), viewT);
        sky += skyMoonDisk(dir, getMoonDir(), getMoonIlluminanceFull(), viewT);
    #endif
    sky += skyNightSky(dir, viewT);
    return sky + vanillaSky;
#elif defined WORLD_END
    return renderEndSky(dir) * SKY_BRIGHTNESS + vanillaSky;
#else
    return getSkyRadiance(dir) + vanillaSky;
#endif
}

#endif
