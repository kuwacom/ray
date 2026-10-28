/*
 * 体積雲の光: 位相関数・多重散乱・光源方向と空方向の光学的深さ・上の層の影
 * sky モジュール (cloud_volume.glsl が読む)
 */
#ifndef SKY_CLOUD_LIGHTING_GLSL
#define SKY_CLOUD_LIGHTING_GLSL

#include "/lib/sky/cloud_constants.glsl"
#include "/lib/sky/cloud_weather.glsl"
#include "/lib/sky/cloud_density.glsl"

// ライティング
// 雲粒の位相 (HG + Draine の Mie 近似 + グローリー)。scale で非対称性を弱める (多重散乱のオクターブ・厚い所)
float cloudPhase(float cosTheta, float scale) {
    float forward = phaseHG(cosTheta, CLOUD_MIE_G_HG * scale);
    float bulk = phaseDraine(cosTheta, CLOUD_MIE_G_D * scale, CLOUD_MIE_ALPHA * scale);
    float glory = phaseHG(cosTheta, CLOUD_GLORY_G * scale) * CLOUD_GLORY_WEIGHT;
    return mix(forward, bulk, CLOUD_MIE_W_D) + glory;
}

// 光源方向の透過率 (べき乗則)。厚い所ほど指数より光が抜ける
float cloudLightTransmittance(float od) { return pow(1.0 + od * (1.0 / CLOUD_HETEROGENEITY), -CLOUD_HETEROGENEITY); }

struct CloudLighting {
    vec3 lightDir;         // ワールドの光源方向 (参照空間へはサンプルごとに cloudRefDir で写す)
    vec3 lightIrradiance;  // 雲の高度での光源照度
    vec3 skyRadiance;      // 上半球の空の平均放射 (= 上向き照度 / pi)
    vec3 groundRadiance;   // 下からの地面の照り返し
    float cosTheta;        // 視線と光源の角度
    float overcastDiffuse; // 雨雲の拡散透過の重み
    float lobeShade;       // こぶの陰の強さ (雨雲では弱める)
    // スタイルの光の値 (cloud_styles.glsl の CS_*)。雨雲は Ray の値へ戻す
    float msGain;
    float silverBoost;
    float powder;
    float ambient;
    float bottomLight;
    float bottomSun;
};

// rain: 雲の中の光の雨天度 (CloudClimate.rainLight)。rainStrength (数秒で切り替わる) より少し遅く、被覆より早い
CloudLighting cloudLightingSetup(vec3 viewDir, float rain) {
    CloudLighting l;
    l.lightDir = frameData.skyParams[0].a > 0.0 ? getSunDir() : getMoonDir();
    l.lightIrradiance = frameData.skyParams[0].rgb;
    // 厚い雨雲の中の光は何度も散乱して太陽の色味が抜け、上から入る青空の光も混ざるのでわずかに寒色の灰になる
    // (太陽色のままだと雨雲が茶色く見える)
    l.lightIrradiance = mix(l.lightIrradiance, luminance(l.lightIrradiance) * CLOUD_OVERCAST_TINT, 0.7 * rain);
    vec3 skyUp = frameData.skyParams[2].rgb; // 彩度を落とす前の真上の空の照度 (prepare.csh)
    // 雷は雲の中を一瞬照らす。夜の露出のまま空一面が白飛びしないよう、月夜の地面の数倍の明るさに留める
    // (4.0 では月光の数百倍になり、雲の覆う空が真っ白で降雪が黒い点に見える)
    float lightning = lightningBoltPosition.w > 0.5 ? 1.0 : 0.0;
    skyUp += vec3(0.75, 0.8, 1.0) * lightning * CLOUD_LIGHTNING_FLASH;
    l.skyRadiance = skyUp * RCP_PI;
    vec3 groundIrradiance = frameData.sunIrradiance.rgb * max(getSunDir().y, 0.0) + frameData.moonIrradiance.rgb * max(getMoonDir().y, 0.0) + skyUp;
    l.groundRadiance = groundIrradiance * CLOUD_GROUND_ALBEDO * RCP_PI;
    l.cosTheta = dot(viewDir, l.lightDir);
    l.overcastDiffuse = CLOUD_OVERCAST_DIFFUSE * rain;
    // 厚い雨雲の中の光は拡散しきっていて、こぶ単位の陰は見えない (雷雨の雲には陰を付けない)
    l.lobeShade = CLOUD_LOBE_SHADE * (1.0 - rain);
    float style = 1.0 - rain;
    l.lightIrradiance *= mix(1.0, CS_SUN, style);
    l.msGain = CLOUD_MS_GAIN * mix(1.0, CS_MS, style);
    l.silverBoost = CLOUD_SILVER_BOOST * mix(1.0, CS_SILVER, style);
    l.powder = min(CLOUD_POWDER_STRENGTH * mix(1.0, CS_POWDER, style), 1.0);
    l.ambient = CLOUD_AMBIENT * mix(1.0, CS_AMBIENT, style);
    float baseShade = CLOUD_BASE_SHADE * mix(1.0, CS_BASE_SHADE, style);
    l.bottomLight = max(1.0 - 0.8 * baseShade, 0.0);
    l.bottomSun = max(1.0 - 0.25 * baseShade, 0.0);
    return l;
}

/*
 * 1 サンプルの内散乱放射 (散乱係数 1 あたり)
 * extinction: その点の消散係数, odLight / odSky: 光源 / 真上への光学的深さ, groundVisibility: 地面の照り返しの届き具合
 * upperT: 上の層による光源の透過率, cloudHeight: その雲の中の高さ (底 0 / 頂 1)
 * odNear: 光源方向の近く (こぶの大きさ) だけの光学的深さ (こぶの陰。使わない層は 0)
 */
vec3 cloudInscatter(CloudLighting l, float extinction, float odLight, float odNear, float odSky, float groundVisibility, float upperT, float cloudHeight) {
    // 周りに散乱体が少ない縁では多重散乱が育たない
    float growth = 1.0 - exp(-extinction * CLOUD_MS_LENGTH);
    float msGain = growth * l.msGain;
    float anisotropy = 1.0 / (1.0 + CLOUD_ANISO_DECAY * odLight);
    // 銀の縁: 前方の光を後段でもう一段持ち上げる (光学的に薄い逆光の縁ほど単散乱が残るので際立つ)
    float silver = l.silverBoost * phaseHG(l.cosTheta, CLOUD_SILVER_G * anisotropy);
    float sun = cloudPhase(l.cosTheta, anisotropy) * cloudLightTransmittance(odLight) * (1.0 + silver);
    float ms = 0.0;
    float a = CLOUD_MS_ATTENUATION, b = CLOUD_MS_CONTRIBUTION, c = CLOUD_MS_ECCENTRICITY;
    for (int i = 1; i < CLOUD_MULTISCATTER; i++) {
        // 最後のオクターブは基準の数までの残りの寄与 (b の等比の和) を持つ。a は 3 つ目で下限に張り付くので透過率はほぼ同じ
        float w = i == CLOUD_MULTISCATTER - 1 ? b * (1.0 - pow(CLOUD_MS_CONTRIBUTION, float(max(CLOUD_MS_REF_OCTAVES - i, 1)))) / (1.0 - CLOUD_MS_CONTRIBUTION) : b;
        ms += w * cloudPhase(l.cosTheta, anisotropy * c) * cloudLightTransmittance(odLight * a);
        // 拡散光も吸収と横への漏れで減衰するので、高次のオクターブでも透過率の傾きを 0 にしない
        // (0 にすると厚い雲の底まで上面とほぼ同じ明るさになり、立体感が消える)
        a = max(a * CLOUD_MS_ATTENUATION, CLOUD_MS_DIFFUSION);
        b *= CLOUD_MS_CONTRIBUTION;
        c *= CLOUD_MS_ECCENTRICITY;
    }
    // 暗く重い底: 底の近くほど多重散乱と空の光が届かない
    float bottom = mix(l.bottomLight, 1.0, smoothstep(0.0, CLOUD_BOTTOM_REACH, cloudHeight));
    sun += ms * msGain * bottom * exp(-l.lobeShade * odNear) * (1.0 + silver * CLOUD_SILVER_MS);
    // 下部の側面は上の塊に空と太陽の一部を遮られ、上から下へ明るさが落ちる (順光で雲全体が一様に白く、立体感の無い綿玉に見えた)
    sun *= mix(l.bottomSun, 1.0, smoothstep(0.0, CLOUD_BOTTOM_REACH, cloudHeight));
    // powder: 順光ほど、散乱体の少ない縁が暗い縁取りになる (逆光では縁が銀に光るので効かせない)
    float powder = 1.0 - l.powder * saturate(0.5 - 0.5 * l.cosTheta) * exp(-extinction * CLOUD_POWDER_LENGTH);
    sun *= powder;
    sun += l.overcastDiffuse * PHASE_ISOTROPIC / (1.0 + CLOUD_AMBIENT_DIFFUSION * odLight);
    // 空の光は上半球からの等方入射 = E / 2pi。地面の照り返しは雲の底ほど届く
    float sky = (1.0 + CLOUD_AMBIENT_MS * growth) / (1.0 + CLOUD_AMBIENT_DIFFUSION * odSky) * mix(0.6, 1.0, bottom);
    vec3 ambient = (l.skyRadiance * 0.5 * sky + l.groundRadiance * 0.5 * groundVisibility) * l.ambient;
    // 上の層の影は雲の表面だけにくっきり落ち、奥では光が拡散して均される (底に放射状の縞を作らない)
    float shadow = pow(upperT, exp(-0.2 * odLight));
    return l.lightIrradiance * (sun * shadow) + ambient;
}

// 低層の光源方向の光学的深さ。歩幅を毎回 2 倍に伸ばす (近くは細かく、遠くは粗く)。先頭 2 歩だけ侵食ノイズを使う
// lightDir: 参照空間の光源方向, odNear: 先頭 CLOUD_LOBE_STEPS 歩だけの光学的深さ (こぶの陰)
float cloudLowLightOD(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, vec3 lightDir, float dither, out float odNear) {
    float stepLength = CLOUD_LIGHT_STEP0;
    float t = 0.0;
    float od = 0.0;
    odNear = -1.0;
    for (int i = 0; i < CLOUD_LIGHT_STEPS; i++) {
        float sampleT = t + stepLength * dither;
        float a = altitude + lightDir.y * sampleT;
        if (a > ctx.lowTop || a < CLOUD_R_BASE || (CS_SLAB == 1 && ctx.lowTop < CLOUD_R_TOP && t > CLOUD_SLAB_LIGHT_REACH)) break;
        od += cloudLowDensity(ctx, col, rel + lightDir.xz * sampleT, a, i < 2, true) * stepLength;
        t += stepLength;
        stepLength *= 2.0;
        if (i == CLOUD_LOBE_STEPS - 1) odNear = od;
    }
    if (odNear < 0.0) odNear = od;
    const float scale = CLOUD_LOW_SHADE_SIGMA * CLOUD_LIGHT_OD_SCALE;
    odNear *= scale;
    return od * scale;
}

// 低層の真上 (空の光) 方向の光学的深さ
float cloudLowSkyOD(CloudContext ctx, CloudColumn col, vec2 rel, float altitude) {
    float stepLength = CLOUD_R_DEPTH * 0.06;
    float t = 0.0;
    float od = 0.0;
    for (int i = 0; i < CLOUD_SKY_STEPS; i++) {
        float a = altitude + t + stepLength * 0.5;
        if (a > ctx.lowTop) break;
        od += cloudLowDensity(ctx, col, rel, a, false, false) * stepLength;
        t += stepLength;
        stepLength *= 3.0;
    }
    // 視線の密度で読んでいるので、スタイルの濃さ CS_DENSITY は光源方向と同じ割合に直す (晴天だけ)
    float styleScale = max(CS_DENSITY / CLOUD_STYLE_LIGHT_SIGMA_RATIO, 1.0) / CS_DENSITY;
    styleScale = mix(styleScale, 1.0, smoothstep(CLOUD_HAZE_RAIN.x, CLOUD_HAZE_RAIN.y, ctx.rain));
    return od * (CLOUD_LOW_SHADE_SIGMA * CLOUD_SKY_OD_SCALE * styleScale);
}

// 中層の光源方向の光学的深さ (薄い層なので短く)
float cloudMidLightOD(CloudContext ctx, float cover, vec2 rel, float altitude, vec3 lightDir, float dither) {
    float stepLength = CLOUD_LIGHT_STEP0 * 0.75;
    float t = 0.0;
    float od = 0.0;
    for (int i = 0; i < CLOUD_MID_LIGHT_STEPS; i++) {
        float sampleT = t + stepLength * dither;
        float a = altitude + lightDir.y * sampleT;
        if (a > CLOUD_R_MID_TOP || a < CLOUD_R_MID_BASE) break;
        od += cloudMidDensity(ctx, cover, rel + lightDir.xz * sampleT, a, i == 0) * stepLength;
        t += stepLength;
        stepLength *= 2.5;
    }
    return od * CLOUD_MID_SIGMA;
}

/*
 * 上の層 (中層・上層) が参照高度 altitude の点に落とす影 (光源の透過率)。lightDir: 参照空間の光源方向
 * 上の層の真ん中の高さで 1 点だけ密度を見る (層が薄いので十分)
 */
float cloudUpperTransmittance(CloudContext ctx, vec2 rel, float altitude, vec3 lightDir) {
    float ly = max(lightDir.y, 0.08);
    float transmittance = 1.0;
#ifdef CLOUD_MID_LAYER
    if (altitude < CLOUD_R_MID_BASE) {
        // 粒単位の影は下の雲に斑点を作るだけなので、群れの粗い被覆で柔らかく落とす。
        // 途切れた層の平均の透過率は「隙間の割合 + 雲の割合 x 雲 1 つの透過率」(密度を均してから Beer にすると暗くなりすぎる)
        vec2 p = rel + lightDir.xz * ((CLOUD_R_MID_BASE + 0.5 * CLOUD_R_MID_DEPTH - altitude) / ly);
        float fraction = cloudMidCoverage(ctx, cloudMapFetch(p).b * CLOUD_COVER_RANGE, p);
        float cloudT = cloudLightTransmittance(CLOUD_MID_SIGMA * CLOUD_R_MID_DEPTH * CLOUD_MID_SHADOW / ly);
        transmittance *= 1.0 - fraction * (1.0 - cloudT);
    }
#endif
#ifdef CLOUD_CIRRUS
    if (altitude < CLOUD_R_HIGH_BASE) {
        float a = CLOUD_R_HIGH_BASE + 0.7 * CLOUD_R_HIGH_DEPTH;
        vec2 ph = rel + lightDir.xz * ((a - altitude) / ly);
        float veil;
        float od = cloudHighExtinction(ctx, cloudMapFetch(ph).a * CLOUD_COVER_RANGE, ph * (CLOUD_KH_HIGH / CLOUD_KH), a, 0.0, false, veil) * (0.6 * CLOUD_R_HIGH_DEPTH);
        // 氷晶の散乱はほとんど前方なので、影としての減衰は光学的深さの一部だけ。
        // 夕方に細い筋の影が下の雲にくっきり縞を作らないよう、斜めの光路の伸びも抑える
        transmittance *= exp(-0.3 * od / max(ly, 0.3));
    }
#endif
    return transmittance;
}

#endif
