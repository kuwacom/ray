/*
 * 空・太陽・月 (sky モジュール)
 * 他モジュールに公開する関数のシグネチャは固定
 * 空の放射は SkyView LUT (prepare1, Hillaire 2020) から、ATMOSPHERE_MODE=0 では解析近似から
 */
#ifndef SKY_SKY_COLOR_GLSL
#define SKY_SKY_COLOR_GLSL

// 月光の色。物理的には太陽光とほぼ同じだが、夜の視覚 (プルキンエ効果) に寄せて青に振る
const vec3 MOON_TINT = vec3(0.72, 0.84, 1.0);
// 新月でも真っ暗にしない下限 (地球照・星明かり分)
const float MOON_PHASE_MIN_LIGHT = 0.08;
// 曇天 (雨) で空が灰色に寄る量と暗くなる量
const float SKY_OVERCAST_DESATURATE = 0.85;
const float SKY_OVERCAST_DARKEN = 0.55;
// 月も無い夜の空の下限 (大気光・星明かり)
const vec3 SKY_NIGHT_FLOOR = vec3(0.55, 0.75, 1.0) * 3e-5;
/*
 * 空の色の彩度 (LUT の値に掛ける見た目の調整)
 * そのままだと AgX を通した昼の天頂が灰青、夕方の太陽まわりが白っぽい桃色に寄った
 * iterationT も大気の色を錐体空間の行列で盛っている。環境光 (SH) 側は prepare.csh で別に彩度を落とす
 */
const float SKY_COLOR_SATURATION = 1.25;
// 描画距離の外の地面 (skyBelowHorizon)
const vec3 SKY_DISTANT_GROUND_ALBEDO = vec3(0.16, 0.18, 0.14); // 草地・森・岩の平均
// 雪原・砂漠では外の地面も明るい。草地の色のままだと、高所から見た夕方の雪原の描画距離の外が暗い灰色の壁に見えた
const vec3 SKY_DISTANT_SNOW_ALBEDO = vec3(0.55, 0.58, 0.62);  // 雪と針葉樹の混ざり
const vec3 SKY_DISTANT_SAND_ALBEDO = vec3(0.42, 0.34, 0.24);
// 海の外は地平線近くの空を映す水面 (かすめ角のフレネル)
const float SKY_DISTANT_OCEAN_REFLECTANCE = 0.8;
const float SKY_DISTANT_GROUND_HAZE = 70.0;    // 実際の大気の何倍の濃さで霞ませるか (描画距離内の空中遠近 14 倍 + もや分)
const float SKY_DISTANT_GROUND_RAIN = 4.0;    // 雨でエアロゾルが何倍になるか (空中遠近と同じ)
const float SKY_DISTANT_GROUND_OVERCAST = 0.85; // 雨雲で直達光が減る割合
const float SKY_DISTANT_GROUND_MIN_HEIGHT = 8.0; // 海面より低い視点でも地面までの距離を 0 にしない
const float SKY_HORIZON_SAMPLE_MU = 0.004;    // 地平線の色を読む高さ (地平線の真上の LUT の継ぎ目を避ける)
const float SKY_SHADOWED_HAZE_MU = 0.15;      // 朝夕の地表のもやの色を読む高さ
const float SKY_SHADOWED_HAZE = 0.7;          // 朝夕に地表のもやの色をその高さの空へ寄せる割合
const float SKY_SHADOWED_HAZE_FADE_MU = 0.03; // 地平線からこの深さまでで上の空の色へ寄せ始める

// ネザー・エンドの環境
/*
 * ネザーの環境光と霧の色 (バイオームごと)
 * 以前は fogColor から作っていたが、真紅の森の fogColor は純粋な赤 (sRGB 51,3,3) で、彩度を落としても環境光が赤一色になり
 * 地面のテクスチャの色が読めなかった。明るさもバイオームで 40 倍違う (歪んだ森 0.003, 玄武岩 0.12)。
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
        // 霧 (1.0, 0.30, 0.22) と暖色の環境光で、赤い地面・崖・遠景が赤一色になった (R/B 7.9 vs iterationT 5.3)
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

// 球状のランバート体の位相関数 (満月 = 1)。月の照り返しが位相でどれだけ減るか
float moonPhaseFactor() {
    float a = moonPhaseAngle();
    float lambert = ((PI - a) * cos(a) + sin(a)) * RCP_PI;
    return mix(MOON_PHASE_MIN_LIGHT, 1.0, saturate(lambert));
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

// 法線 n の面が空から受ける拡散照度 (遮蔽なし。AO・スカイライトは受け取り側が掛ける)
vec3 getSkyIrradiance(vec3 n) { return shEvalIrradiance(n); }

// 洞窟の度合い (0 = 屋外, 1 に近いほど空が見えない)。目の位置のスカイライトから (Kappa / Nostalgia と同じ考え方)
float getCaveFactor() {
#ifdef HAS_SKYLIGHT
    return 1.0 - smoothstep(0.05, 0.6, float(eyeBrightnessSmooth.y) / 240.0);
#else
    return 0.0;
#endif
}

// 雨で曇った空へ寄せる (雲の無い LUT を灰色の曇天に近づける)
vec3 skyApplyOvercast(vec3 radiance) {
    float overcast = rainStrength;
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
vec3 skyBelowHorizon(vec3 dir, vec3 sky) {
#if defined HAS_SKY
    float horizonMu = atmoHorizonMu(atmoViewerRadius());
    float below = horizonMu - dir.y;
    if (below <= 0.0) return sky;
    // 地平線の少し上の空の色 (同じ方位)
    vec3 horizon = getSkyRadiance(vec3(dir.x, horizonMu + SKY_HORIZON_SAMPLE_MU, dir.z));
    // 朝夕は地表近くのもやが地球の影に入り、直射の照りではなく空の光で光る。地平線の照りの色のままだと赤茶色の面になるので、
    // 太陽が低いほど少し上の空 (同じ方位) の色に寄せる
    float lowSun = 1.0 - smoothstep(0.02, 0.15, getSunDir().y);
    // 地平線のすぐ下 (海面近くから見た描画距離の外の数ピクセル) は照りの色のまま残す。ここを上の空の紫灰色にすると、
    // 夕方の海で水面の端と地平線の間に灰色の線が出た
    float shadowedHaze = SKY_SHADOWED_HAZE * lowSun * smoothstep(0.0, SKY_SHADOWED_HAZE_FADE_MU, below);
    horizon = mix(horizon, getSkyRadiance(vec3(dir.x, SKY_SHADOWED_HAZE_MU, dir.z)), shadowedHaze);
    float height = max(cameraPosition.y - SKY_SEA_LEVEL, SKY_DISTANT_GROUND_MIN_HEIGHT);
    float dist = height / max(below, 1e-4);
    vec3 extinction = ATMO_RAYLEIGH_SCATTER + ATMO_MIE_EXTINCT * (1.0 + SKY_DISTANT_GROUND_RAIN * rainStrength);
    vec3 transmittance = exp(-extinction * (1e-3 * SKY_DISTANT_GROUND_HAZE * FOG_DENSITY) * dist);
    vec3 irradiance = getSunIrradiance() * max(getSunDir().y, 0.0) * (1.0 - SKY_DISTANT_GROUND_OVERCAST * rainStrength)
                    + getMoonIrradiance() * max(getMoonDir().y, 0.0) + getSkyIrradiance(vec3(0.0, 1.0, 0.0));
    vec3 albedo = mix(SKY_DISTANT_GROUND_ALBEDO, SKY_DISTANT_SNOW_ALBEDO, saturate(distantSnow));
    albedo = mix(albedo, SKY_DISTANT_SAND_ALBEDO, saturate(distantSand));
    vec3 ground = irradiance * (albedo * RCP_PI);
    // 海: 同じ方位で地平線から同じ角度だけ上の空を映す
    vec3 sea = getSkyRadiance(vec3(dir.x, horizonMu + below, dir.z)) * SKY_DISTANT_OCEAN_REFLECTANCE;
    ground = mix(ground, sea, saturate(distantOcean));
    return mix(horizon, ground, transmittance);
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

    vec3 viewT = atmoTransmittanceToLight(r, dir.y) * (1.0 - 0.95 * rainStrength);
    #if SUN_MOON_STYLE == 1
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
