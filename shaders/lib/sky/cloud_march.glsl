/*
 * 体積雲のレイマーチ・空中遠近・層の合成 (renderClouds)・雲影マップ
 * sky モジュール (cloud_volume.glsl が読む)
 */
#ifndef SKY_CLOUD_MARCH_GLSL
#define SKY_CLOUD_MARCH_GLSL

//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/cloud_constants.glsl"
//@include "/lib/sky/cloud_weather.glsl"
//@include "/lib/sky/cloud_density.glsl"
//@include "/lib/sky/cloud_lighting.glsl"
//@include "/lib/sky/cloud_vanilla.glsl"

// レイマーチ (ワールドの視線で歩き、サンプルを参照空間へ写す)
struct CloudAccum {
    vec3 scattering;
    float transmittance;
    float meanDistance; // 散乱の重み付き平均距離 (参照 m, 空中遠近用)
    float meanAltitude; // 同じく参照高度
};

// 視線 dir の距離 t (ワールド) の点 (参照高度 altitude) までの参照空間の距離。kh: その層の水平の縮尺
float cloudRefDistance(CloudContext ctx, vec3 dir, float t, float altitude, float kh) {
    return length(vec2(t * length(dir.xz) * kh, altitude - ctx.cameraAltitude));
}
float cloudRefDistance(CloudContext ctx, vec3 dir, float t, float altitude) { return cloudRefDistance(ctx, dir, t, altitude, CLOUD_KH); }

// 重み付き平均の距離・高度を書き込む
void cloudAccumFinish(inout CloudAccum acc, vec3 sums, CloudContext ctx, vec3 dir, float tStart) {
    if (sums.z > 1e-4) {
        acc.meanDistance = sums.x / sums.z;
        acc.meanAltitude = sums.y / sums.z;
    } else {
        float y = cloudAltitudeAt(cameraPosition.y, dir.y, tStart, cameraPosition.y);
        acc.meanAltitude = cloudRefAltitude(y);
        acc.meanDistance = cloudRefDistance(ctx, dir, tStart, acc.meanAltitude);
    }
}

// share: 区間を分けて呼ぶ時のこの区間の歩数の割合 (分けない時 1)
CloudAccum cloudMarchLow(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, vec2 dither, float share) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_BASE + ctx.lowTopWorld);
    // 水平に近い視線ほど層の中を長く通るので歩数を増やす (上限 3 倍)
    float stepScale = clamp(segLength / share / ((ctx.lowTopWorld - CLOUD_BASE) * 1.5), 1.0, CLOUD_STEP_SCALE_MAX);
    int steps = max(int(float(CLOUD_LOW_STEPS) * stepScale * share), 4);
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither.x;
    float y0 = cameraPosition.y;
    vec3 sums = vec3(0.0); // 距離 x 重み, 高度 x 重み, 重み
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        vec2 rel = dir.xz * (t * CLOUD_KH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        CloudColumn col = cloudLowColumn(cloudMapFetch(rel));
        float cloudHeight;
        float density = cloudLowDensity(ctx, col, rel, altitude, cloudDetailLod(tRef), false, cloudHeight);
        if (density <= 0.0) continue;

        float extinction = density * CLOUD_LOW_SIGMA;
        float h = saturate((altitude - CLOUD_R_BASE) / CLOUD_R_DEPTH);
        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH, slope);
        float odNear;
        float odLight = cloudLowLightOD(ctx, col, rel, altitude, lightDir, dither.y, odNear);
        float odSky = cloudLowSkyOD(ctx, col, rel, altitude);
        float upperT = cloudUpperTransmittance(ctx, rel, altitude, lightDir);
        vec3 inscatter = cloudInscatter(l, extinction, odLight, odNear, odSky, sqr(1.0 - h), upperT, cloudHeight);

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
        if (acc.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            // 打ち切った残りを 0 にする (残りの数 % でも太陽円盤や星は雲より桁違いに明るく、厚い雲を透けて見えてしまう)
            acc.transmittance = 0.0;
            break;
        }
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}

#ifdef CLOUD_VANILLA_SHAPE
// 光源が低い (朝夕) ほど 1
float cloudVanillaDusk(CloudLighting l) { return 1.0 - smoothstep(0.0, VANILLA_CLOUD_DUSK_SUN_Y, l.lightDir.y); }

// 板の光の絞り (cloud_vanilla.glsl の VANILLA_CLOUD_*)
CloudLighting cloudVanillaLighting(CloudLighting l) {
    l.lightIrradiance *= VANILLA_CLOUD_SUN;
    l.msGain *= VANILLA_CLOUD_MS_GAIN;
    l.silverBoost *= VANILLA_CLOUD_SILVER;
    l.powder = min(l.powder * VANILLA_CLOUD_POWDER, 1.0);
    // 日が低いと厚い柱の側面に横から日が当たり、橙の光で明るく黄ばむので、直達光を絞って彩度を抜く
    float dusk = cloudVanillaDusk(l);
    l.ambient *= VANILLA_CLOUD_AMBIENT;
    l.lightIrradiance *= 1.0 + VANILLA_CLOUD_DUSK_SUN_GAIN * dusk;
    l.lightIrradiance = mix(l.lightIrradiance, vec3(luminance(l.lightIrradiance)), VANILLA_CLOUD_DUSK_SUN_DESAT * dusk);
    l.lightIrradiance *= mix(1.0, VANILLA_CLOUD_RAIN_SUN, l.rainDeck);
    l.ambient *= mix(1.0, VANILLA_CLOUD_RAIN_AMBIENT, l.rainDeck);
    l.bottomLight = max(1.0 - (1.0 - l.bottomLight) * VANILLA_CLOUD_BASE_SHADE, 0.0);
    l.bottomSun = max(1.0 - (1.0 - l.bottomSun) * VANILLA_CLOUD_BASE_SHADE, 0.0);
    l.bottomLight = mix(l.bottomLight, 1.0, VANILLA_CLOUD_RAIN_BASE * l.rainDeck);
    l.bottomSun = mix(l.bottomSun, 1.0, VANILLA_CLOUD_RAIN_BASE * l.rainDeck);
    float saturation = mix(VANILLA_CLOUD_SKY_SATURATION, VANILLA_CLOUD_DUSK_SATURATION, dusk);
    l.skyRadiance = mix(vec3(luminance(l.skyRadiance)), l.skyRadiance, saturation);
    l.groundRadiance = mix(vec3(luminance(l.groundRadiance)), l.groundRadiance, saturation);
    return l;
}

/*
 * バニラの形の雲 (マスごとの直方体の柱)。weight: 濃さの倍率 (雨の日は雨の濃さの倍率で濃くする)
 * 柱の表で空の区画 (4x4 マス) と空のマス・頭より上を飛ばし、柱の近くだけ細かく歩く。光を求めるのは密度のあるサンプルだけで、その数を
 * VANILLA_CLOUD_STEPS までにする。歩幅は距離に比例し、雲の近くでは縁の柔らかさの半分以下
 * 区間の入口は平らな面 (底・上端) との交差で、青ノイズで歩幅の分だけ揺らす (同心円の縞にならない)
 */
CloudAccum cloudMarchVanilla(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, vec2 dither, float weight) {
    l = cloudVanillaLighting(l);
    // 日が低いと底にも横から日が届くので、底の暗さを掛け始める高さを下げる
    float baseLift = VANILLA_CLOUD_BASE_LIFT * (1.0 - cloudVanillaDusk(l));
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    vec2 origin = vanillaCloudOrigin();
    float bottom = vanillaCloudBottom();
    // 距離 1 ブロックあたりの画素の大きさ (ブロック)。柔らかさを画素より細かくしない
    float pixel = 2.0 / (gbufferProjection[1][1] * viewHeight) * float(CLOUD_RES);
    vec3 sums = vec3(0.0);
    // カメラが柱の中にいる間は雲の中の霧が視界を閉じるので、柱は視線の消散を弱める (入る・出るときに一気に白く閉じない)。
    // 面から内側へ VANILLA_CLOUD_INSIDE_DEPTH 入るまでに弱め切る (霧の濃さではなくカメラの位置の深さで決めるので、縁のすぐ中で白く閉じない)
    float opacity = VANILLA_CLOUD_OPACITY;
#ifdef CLOUD_INTERIOR
    opacity = mix(opacity, VANILLA_CLOUD_INSIDE_OPACITY, smoothstep(0.0, VANILLA_CLOUD_INSIDE_DEPTH, vanillaCloudInsideDepth(origin, cameraPosition.y)));
#endif
    float t = seg.x + clamp(seg.x * VANILLA_CLOUD_STEP_REL, VANILLA_CLOUD_STEP_MIN, VANILLA_CLOUD_STEP_MAX) * dither.x;
    int samples = 0;
    for (int iter = 0; iter < VANILLA_CLOUD_MAX_ITER && t < seg.y && samples < VANILLA_CLOUD_STEPS; iter++) {
        vec2 q = origin + dir.xz * t;
        float y = cameraPosition.y + dir.y * t;
        ivec2 cell = vanillaCloudCellOf(q);
        vec4 column = vanillaCloudColumn(cell);
        // 4x4 マスの区画が空なら、その区画の箱を出るまで飛ばす
        if (column.w < 0.5) {
            t += vanillaCloudBoxExit(q, dir.xz, vec2(floor(vec2(cell) / float(VANILLA_CLOUD_BLOCK))) * (VANILLA_CLOUD_CELL * float(VANILLA_CLOUD_BLOCK)), VANILLA_CLOUD_CELL * float(VANILLA_CLOUD_BLOCK));
            continue;
        }
        float head = bottom + column.x;
        // 空のマスと頭より上は、マスの箱を出るまで (下へ向かう視線は頭の面に当たるまで) 飛ばす
        if (column.x <= 0.0 || y >= head) {
            float skip = vanillaCloudBoxExit(q, dir.xz, vec2(cell) * VANILLA_CLOUD_CELL, VANILLA_CLOUD_CELL);
            if (column.x > 0.0 && dir.y < 0.0) skip = min(skip, (head - y) / dir.y + VANILLA_CLOUD_SKIP_MARGIN);
            t += skip;
            continue;
        }
        float dt = clamp(t * VANILLA_CLOUD_STEP_REL, VANILLA_CLOUD_STEP_MIN, VANILLA_CLOUD_STEP_MAX);
        float occlusion;
        float density = vanillaCloudDensity(q, y, t * pixel, occlusion);
        if (density <= 0.0) {
            t += dt;
            continue;
        }
        samples++;

        float slope;
        float altitude = cloudRefAltitude(y, slope);
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        float height = saturate((y - bottom) / VANILLA_CLOUD_BASE_DEPTH);
        float extinction = density * weight * VANILLA_CLOUD_SHADE_SIGMA;
        float odLight = vanillaCloudLightOD(q, y, l.lightDir) * weight * vanillaCloudMottle(q);
        float odSky = vanillaCloudSkyOD(q, y) * weight;
        CloudLighting lit = l;
        lit.ambient *= 1.0 - occlusion;
        lit.lightIrradiance *= mix(1.0, vanillaCloudTopMottle(q), saturate(1.0 - (head - y) / VANILLA_CLOUD_TOP_MOTTLE_DEPTH));
        vec3 inscatter = cloudInscatter(lit, extinction, odLight, 0.0, odSky, sqr(1.0 - height), 1.0, max(height - baseLift, 0.0));

        float stepT = exp(-density * weight * VANILLA_CLOUD_SIGMA * opacity * dt * VANILLA_CLOUD_KREF);
        float w = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * w;
        sums += vec3(tRef, altitude, 1.0) * w;
        acc.transmittance *= stepT;
        if (acc.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            acc.transmittance = 0.0;
            break;
        }
        t += dt;
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}
#endif

#ifdef CLOUD_MID_LAYER
CloudAccum cloudMarchMid(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, vec2 dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_MID_BASE + CLOUD_MID_TOP);
    float stepScale = clamp(segLength / ((CLOUD_MID_TOP - CLOUD_MID_BASE) * 2.0), 1.0, CLOUD_STEP_SCALE_MAX);
    int steps = int(float(CLOUD_MID_STEPS) * stepScale);
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither.x;
    float y0 = cameraPosition.y;
    vec3 sums = vec3(0.0);
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        vec2 rel = dir.xz * (t * CLOUD_KH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        float cover = cloudMapFetch(rel).b * CLOUD_COVER_RANGE;
        float grainHeight;
        float density = cloudMidDensity(ctx, cover, rel, altitude, tRef < CLOUD_DETAIL_FADE.y, grainHeight);
        if (density <= 0.0) continue;

        float extinction = density * CLOUD_MID_SIGMA;
        float h = saturate((altitude - CLOUD_R_MID_BASE) / CLOUD_R_MID_DEPTH);
        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH, slope);
        float odLight = cloudMidLightOD(ctx, cover, rel, altitude, lightDir, dither.y);
        // 真上は層の上端までの 1 歩で足りる
        float above = CLOUD_R_MID_TOP - altitude;
        float odSky = cloudMidDensity(ctx, cover, rel, altitude + above * 0.5, false) * above * CLOUD_MID_SIGMA;
        float upperT = cloudUpperTransmittance(ctx, rel, altitude, lightDir);
        // 地面の照り返しは低層の雲にさえぎられるので弱める
        // 粒の下側を沈めて、粒ごとに陰影を付ける (層の中の高さだけで沈めると、陰の無い白い粒が並んで見える)
        vec3 inscatter = cloudInscatter(l, extinction, odLight, 0.0, odSky, 0.3 * (1.0 - h), upperT, CLOUD_MID_GRAIN_SHADE + (1.0 - CLOUD_MID_GRAIN_SHADE) * grainHeight);

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
        if (acc.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            // 打ち切った残りを 0 にする (残りの数 % でも太陽円盤や星は雲より桁違いに明るく、厚い雲を透けて見えてしまう)
            acc.transmittance = 0.0;
            break;
        }
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}
#endif

#ifdef CLOUD_HIGH_LAYER
// 上層 (薄い体積)。光学的に薄いので単散乱 + 等方な多重散乱の底上げ + 空の光。光源までは層の上端までの解析的な透過率
CloudAccum cloudMarchHigh(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, float dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_HIGH_BASE + CLOUD_HIGH_TOP);
    float stepScale = clamp(segLength / ((CLOUD_HIGH_TOP - CLOUD_HIGH_BASE) * 2.0), 1.0, 1.5);
    int steps = int(float(CLOUD_HIGH_STEPS) * stepScale);
    // 上層の被覆は天気図の規模 (数十 km) でしか変わらないので、層の中ほどで 1 回だけ読む
    float cover = cloudMapFetch(dir.xz * ((seg.x + 0.5 * segLength) * CLOUD_KH)).a * CLOUD_COVER_RANGE;
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither;
    float y0 = cameraPosition.y;
    // 氷晶は前方散乱が液滴より弱い。巻層雲は太陽の周り 22 度にハロを作る
    float angle = acos(clamp(l.cosTheta, -1.0, 1.0));
    float haloLobe = CLOUD_HALO_STRENGTH * exp(-sqr((angle - CLOUD_HALO_ANGLE) / CLOUD_HALO_WIDTH));
    float icePhase = (1.0 - CLOUD_ICE_BACK) * phaseHG(l.cosTheta, CLOUD_ICE_G) + CLOUD_ICE_BACK * phaseHG(l.cosTheta, -0.2);
    vec3 sums = vec3(0.0);
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        // 天気図は低層と同じ縮尺の座標で引き、形は上層の縮尺で読む
        vec2 rel = dir.xz * (t * CLOUD_KH_HIGH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude, CLOUD_KH_HIGH);
        float veil;
        float extinction = cloudHighExtinction(ctx, cover, rel, altitude, tRef, true, veil);
        if (extinction <= 0.0) continue;

        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH_HIGH, slope);
        // 光源までは層の上端まで、その点と同じ濃さで続くとみなす
        float odLight = extinction * (CLOUD_R_HIGH_TOP - altitude) / max(abs(lightDir.y), 0.05);
        float phase = icePhase + veil * haloLobe;
        float multiScatter = PHASE_ISOTROPIC * (1.0 - exp(-odLight - extinction * 600.0));
        vec3 inscatter = l.lightIrradiance * (phase * exp(-odLight) + multiScatter) + l.skyRadiance * 0.5 + l.groundRadiance * 0.25;

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH_HIGH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}
#endif

#ifdef CLOUD_CB
/*
 * 降水の柱 (雨脚): カメラが雲底より下の時、雲底 (下向きは海面) までの区間で嵐の芯の下の雨を積む
 * 雨粒の幕は厚い雲の影の中なので、光源の光はわずかで、灰色の空の光が主
 */
CloudAccum cloudMarchShaft(CloudContext ctx, CloudLighting l, vec3 dir, float maxDist, float dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float y0 = cameraPosition.y;
    float tStart = CLOUD_SHAFT_NEAR / CLOUD_KH;
    float tEnd = min(maxDist, CLOUD_SHAFT_FAR / CLOUD_KH);
    if (dir.y > 1e-4) tEnd = min(tEnd, (CLOUD_BASE - y0) / dir.y);
    else if (dir.y < -1e-4) tEnd = min(tEnd, (y0 - SKY_SEA_LEVEL) / -dir.y);
    if (ctx.storm <= 1e-3 || y0 >= CLOUD_BASE || tEnd <= tStart) return acc;
    // 近くを細かく: 区間を距離の平方根で分ける
    float a = sqrt(tStart), b = sqrt(tEnd);
    float ds = (b - a) / float(CLOUD_SHAFT_STEPS);
    vec3 radiance = l.skyRadiance * 0.18 + l.lightIrradiance * (PHASE_ISOTROPIC * 0.06) + l.groundRadiance * 0.3;
    vec3 sums = vec3(0.0);
    for (int i = 0; i < CLOUD_SHAFT_STEPS; i++) {
        float s0 = a + ds * float(i);
        float s = s0 + ds * dither;
        float t = s * s;
        float dt = (s0 + ds) * (s0 + ds) - s0 * s0;
        float y = y0 + dir.y * t;
        float altitude = cloudRefAltitude(y);
        float fall = CLOUD_R_BASE - altitude;
        // 雨は風下へ流されながら落ちる (柱が斜めに傾く)
        vec2 rel = dir.xz * (t * CLOUD_KH) - CLOUD_WIND_DIR * (fall * CLOUD_SHAFT_SLANT);
        float type = cloudMapFetch(rel).g;
        float core = cloudStormCore(type) * cloudCumulonimbusWeight(type);
        if (core <= 0.0) continue;
        // 雨の強弱の筋と、地面に近いほど少し蒸発して薄れる
        float streak = 0.5 + texture(cloudNoiseTex, (rel + ctx.lowOrigin) / (CLOUD_CELL_PERIOD * 0.5) * vec2(1.0, 3.0)).g;
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        // 手前の打ち切り (CLOUD_SHAFT_NEAR) から距離をかけて濃くする。急に始めると、雲底がその距離より近くなる仰角を境に
        // 雨の幕の有無が切り替わり、幕の向こうの積乱雲に直線の縁の明るい面が出た
        float nearFade = smoothstep(CLOUD_SHAFT_NEAR, CLOUD_SHAFT_NEAR * 4.0, tRef);
        float extinction = linearStep(0.15, 0.6, core) * streak * mix(0.6, 1.0, saturate(altitude / CLOUD_R_BASE)) * CLOUD_SHAFT_SIGMA * ctx.storm * nearFade;
        float stepT = exp(-extinction * dt * cloudRefStretch(dir, y));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += radiance * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
    }
    cloudAccumFinish(acc, sums, ctx, dir, tStart);
    return acc;
}
#endif

// 高さ a..b (km) の区間での指数分布 exp(-y/H) の平均
float cloudExpMean(float a, float b, float H) {
    float d = b - a;
    return abs(d) < 1e-3 ? exp(-0.5 * (a + b) / H) : H * (exp(-a / H) - exp(-b / H)) / d;
}

// 大気の消散係数 (1/km) の高さ a..b (km) の区間平均。Mie はもやの倍率込み
vec3 cloudAerialExtinction(float a, float b, float haze) {
    return ATMO_RAYLEIGH_SCATTER * (CLOUD_AERIAL_RAYLEIGH * cloudExpMean(a, b, ATMO_RAYLEIGH_HEIGHT))
         + ATMO_MIE_EXTINCT * (haze * cloudExpMean(a, b, ATMO_MIE_HEIGHT));
}

/*
 * 雲の空中遠近: 視線 dir で参照距離 dist、参照高度 altitude の雲までの大気の透過率 (戻り値) と、
 * その方向の空の放射 (= 大気の上端までの内散乱) のうち雲より手前の区間の取り分 share
 * 取り分は光学的深さの割合 (1 - T(dist)) / (1 - T(大気の上端)) で見積もる。空の色そのもの (SkyView LUT) を使うので、
 * 時刻・太陽高度・方位に応じた色へ溶ける (夕方は地平線の雲が橙の空に溶け、真上の雲には青みが少し乗る)
 * 参照空間の距離で測るので、縮めた高さテンプレートでも遠い雲の霞み方が現実比と同じ
 */
vec3 cloudAerialPerspective(CloudContext ctx, vec3 dir, float dist, float altitude, float rain, out vec3 share) {
    float haze = CLOUD_AERIAL_MIE * (1.0 + CLOUD_AERIAL_RAIN * rain);
    float y0 = max(ctx.cameraAltitude - ctx.seaAltitude, 0.0) * 1e-3;
    float y1 = max(altitude - ctx.seaAltitude, 0.0) * 1e-3;
    vec3 transmittance = exp(-cloudAerialExtinction(y0, y1, haze) * (dist * 1e-3));
    // 大気の上端までの光学的深さ: 指数大気の鉛直積分を見かけの傾きで割る (地平線付近は曲率で長さが頭打ちになる)
    float mu = max(dir.y, 0.03);
    vec3 odFull = (ATMO_RAYLEIGH_SCATTER * (CLOUD_AERIAL_RAYLEIGH * ATMO_RAYLEIGH_HEIGHT * exp(-y0 / ATMO_RAYLEIGH_HEIGHT))
                 + ATMO_MIE_EXTINCT * (haze * ATMO_MIE_HEIGHT * exp(-y0 / ATMO_MIE_HEIGHT))) / mu;
    share = saturate((1.0 - transmittance) / max(1.0 - exp(-odFull), 1e-3));
    return transmittance;
}

// 層の結果を手前から重ねる。遠い雲ほど空の色に溶かし、fadeEnd (参照 m) で完全に空へ戻す
void cloudComposite(CloudContext ctx, inout vec3 scattering, inout float transmittance, CloudAccum layer, vec3 dir, vec3 skyColor, float fadeEnd) {
    vec3 share;
    float farFade = 1.0 - smoothstep(fadeEnd * 0.6, fadeEnd, layer.meanDistance);
    vec3 fade = cloudAerialPerspective(ctx, dir, layer.meanDistance, layer.meanAltitude, ctx.rain * (1.0 - CLOUD_THUNDER_HAZE_CUT * thunderStrength), share) * farFade;
    share = mix(vec3(1.0), share, farFade);
    // 雲が隠した背景の空のうち、雲より手前の大気の内散乱のぶんは雲の上に戻す
    vec3 s = layer.scattering * fade + skyColor * share * (1.0 - layer.transmittance);
    scattering += transmittance * s;
    transmittance *= layer.transmittance;
}

#ifdef CLOUD_RAIN_KEEPS_SHAPE
/*
 * 雨の日の雲の向こうの空を置き換える、雲の上の見えない雨雲の層の下面 (rgb = 放射輝度, a = 置き換える割合)
 * 雲のマーチの末尾と、水面などの反射の空 (prepare2 が frameData.skyParams[6] に書き、skyReflectionFallback が使う) で同じ値にする
 */
vec4 cloudRainVeil(CloudContext ctx, CloudLighting l) {
    float veil = saturate(ctx.rainLight) * (1.0 - cloudRainReshape()) * cloudRainBelowDeck();
    vec3 radiance = (l.skyRadiance + l.lightIrradiance * (CLOUD_RAIN_VEIL_SUN * max(l.lightDir.y, 0.0) * RCP_PI)) * CLOUD_RAIN_VEIL_GAIN;
    return vec4(radiance, veil);
}
#endif

/*
 * 視線 dir の雲 (降水の柱 + 低層 + 中層 + 上層を手前から順に)。maxDist: 地形までの距離 (ワールド, 空なら大きな値)
 * dither: x = 視線方向, y = 光方向のマーチの開始位置
 * 戻り値: rgb = 散乱光 (空中遠近込み), a = 透過率
 */
vec4 renderClouds(vec3 dir, float maxDist, vec2 dither) {
    CloudContext ctx = cloudContextSetup(cloudClimate());
    CloudLighting l = cloudLightingSetup(dir, ctx.rainLight);
    vec3 skyColor = getSkyRadiance(dir);
    float y0 = cameraPosition.y;
    // 雲の上から見下ろす視線は、雲の向こうが描画距離の外の虚空 (renderSky が描く青い遠景) なので、雲の縁に戻す空の色も同じにする
    if (dir.y < 0.0 && y0 > cloudLowestBase()) skyColor = skyBelowHorizon(dir, skyColor);
    vec3 scattering = vec3(0.0);
    float transmittance = 1.0;
#ifdef CLOUD_VANILLA_SHAPE
    // 写実の層 (積雲・中層・上層・積乱雲) は描かず、バニラの形の雲だけを描く
    vec2 segVanilla = vanillaCloudSegment(y0, dir.y, min(maxDist, VANILLA_CLOUD_FAR));
    if (segVanilla.y > segVanilla.x) {
        cloudComposite(ctx, scattering, transmittance, cloudMarchVanilla(ctx, l, dir, segVanilla, dither, cloudRainDensityScale(ctx)), dir, skyColor, VANILLA_CLOUD_FAR * CLOUD_KH);
    }
#else
    float farLimit = min(maxDist, CLOUD_MAX_DISTANCE_WORLD);

    vec2 segLow = cloudLayerSegment(y0, dir.y, CLOUD_BASE, ctx.lowTopWorld);
    segLow.y = min(segLow.y, farLimit);
    vec2 segMid = vec2(1.0, 0.0);
#ifdef CLOUD_MID_LAYER
    segMid = cloudLayerSegment(y0, dir.y, CLOUD_MID_BASE, CLOUD_MID_TOP);
    segMid.y = min(segMid.y, farLimit);
#endif
    vec2 segHigh = vec2(1.0, 0.0);
#ifdef CLOUD_HIGH_LAYER
    segHigh = cloudLayerSegment(y0, dir.y, CLOUD_HIGH_BASE, CLOUD_HIGH_TOP);
    segHigh.y = min(segHigh.y, min(maxDist, CLOUD_HIGH_MAX_DISTANCE / CLOUD_KH));
#endif

#ifdef CLOUD_CB
    // 降水の柱は雲底より下だけなので、どの層よりも手前
    if (ctx.storm > 1e-3) cloudComposite(ctx, scattering, transmittance, cloudMarchShaft(ctx, l, dir, maxDist, dither.x), dir, skyColor, CLOUD_SHAFT_FAR);
#endif
    // 層を視線の入口が近い順に処理する (カメラが雲の上にいる時は順序が逆になる)
    // 積乱雲は中層の高さを突き抜けるので、低層の区間を視線が中層を抜ける所で 2 つに分け、その先 (中層より上の塔・かなとこ) は
    // 中層の後ろに重ねる (分けないと雨の日の中層の雲の上にある陽の当たる塔が手前に描かれ、灰色の空に直線の縁の白い面が出た)
    vec2 segLowFar = vec2(1.0, 0.0);
    float lowShare = 1.0;
    if (ctx.storm > 1e-3 && segMid.y > segMid.x && segMid.y > segLow.x && segMid.y < segLow.y) {
        lowShare = (segMid.y - segLow.x) / (segLow.y - segLow.x);
        segLowFar = vec2(segMid.y, segLow.y);
        segLow.y = segMid.y;
    }
    const int LAYER_SLOTS = 4;
    float starts[LAYER_SLOTS] = float[LAYER_SLOTS](segLow.y > segLow.x ? segLow.x : CLOUD_SEG_NONE, segMid.y > segMid.x ? segMid.x : CLOUD_SEG_NONE, segHigh.y > segHigh.x ? segHigh.x : CLOUD_SEG_NONE, segLowFar.y > segLowFar.x ? segLowFar.x : CLOUD_SEG_NONE);
    /*
     * 回数は区間のある層の数 (それより先は starts が全部 1e30 で抜ける)。定数の回数にするとドライバがループを展開し、
     * 各層のマーチが層の数だけ複製されてリンクが数秒延びる
     */
    int layerCount = 0;
    for (int m = 0; m < LAYER_SLOTS; m++) layerCount += starts[m] < CLOUD_SEG_NONE_TEST ? 1 : 0;
    for (int k = 0; k < layerCount; k++) {
        int idx = 0;
        for (int m = 1; m < LAYER_SLOTS; m++) if (starts[m] < starts[idx]) idx = m;
        if (starts[idx] >= CLOUD_SEG_NONE_TEST || transmittance < CLOUD_MIN_TRANSMITTANCE) break;
        starts[idx] = CLOUD_SEG_NONE;
        // 低層の手前と奥 (積乱雲で分けた分) は同じ呼び出しで回す (2 か所に書くとマーチが 2 つ展開される)
        if (idx == 0 || idx == 3) {
            bool far = idx == 3;
            cloudComposite(ctx, scattering, transmittance, cloudMarchLow(ctx, l, dir, far ? segLowFar : segLow, dither, far ? 1.0 - lowShare : lowShare),
                           dir, skyColor, CLOUD_MAX_DISTANCE);
        }
#ifdef CLOUD_MID_LAYER
        else if (idx == 1) {
            cloudComposite(ctx, scattering, transmittance, cloudMarchMid(ctx, l, dir, segMid, dither), dir, skyColor, CLOUD_MAX_DISTANCE);
        }
#endif
#ifdef CLOUD_HIGH_LAYER
        else {
            cloudComposite(ctx, scattering, transmittance, cloudMarchHigh(ctx, l, dir, segHigh, dither.x), dir, skyColor, CLOUD_HIGH_MAX_DISTANCE);
        }
#endif
    }
#endif
#ifdef CLOUD_RAIN_KEEPS_SHAPE
    // 雨の空: 雲の向こうの空は、雲の上の見えない雨雲の層の下面 (一様な灰色) にする。雲の形と量は変えず、隙間から晴れの青空や
    // 太陽が見えないようにするだけ。地形のある画素の手前の雲には掛けない。雷雨は雲の側で覆うので掛けない
    if (maxDist > 1e8) {
        vec4 veil = cloudRainVeil(ctx, l);
        scattering += transmittance * veil.a * veil.rgb;
        transmittance *= 1.0 - veil.a;
    }
#endif
    return vec4(scattering, transmittance);
}

/*
 * 雲影マップ用: 低層の下面の点 rel (ワールド, カメラ基準) から光源方向に層を抜けるまでの透過率 (上の層の影も含む)
 * lightDir: ワールドの光源方向
 */
float cloudShadowTransmittance(CloudContext ctx, vec2 relWorld, vec3 lightDirWorld, float dither) {
#ifdef CLOUD_VANILLA_SHAPE
    return vanillaCloudShadowTransmittance(relWorld, lightDirWorld, cloudRainDensityScale(ctx));
#else
    const int SHADOW_STEPS = 10;
    vec2 rel = relWorld * CLOUD_KH;
    vec3 lightDir = cloudRefDir(lightDirWorld, CLOUD_BASE);
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    float depth = ctx.lowTop - CLOUD_R_BASE;
    float pathLength = min(depth / ly, depth * 4.0);
    float dt = pathLength / float(SHADOW_STEPS);
    // 天気図は粗いので、光の通り道の手前寄りの 1 点で代表させる
    CloudColumn col = cloudLowColumn(cloudMapFetch(rel + lightDir.xz * (0.3 * pathLength)));
    float od = 0.0;
    for (int i = 0; i < SHADOW_STEPS; i++) {
        float t = (float(i) + dither) * dt;
        od += cloudLowDensity(ctx, col, rel + lightDir.xz * t, CLOUD_R_BASE + ly * t, false, true) * dt;
    }
    od *= CLOUD_LOW_SIGMA;
    // 多重散乱で厚い雲の下にも光が少し抜ける (オクターブ和の 2 項目相当)
    float transmittance = max(exp(-od), 0.25 * exp(-od * 0.25));
    transmittance *= cloudUpperTransmittance(ctx, rel, CLOUD_R_BASE, lightDir);
    return transmittance;
#endif
}

#endif
