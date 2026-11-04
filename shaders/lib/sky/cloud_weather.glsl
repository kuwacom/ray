/*
 * 体積雲の天気図の読み取り・地域と気候・風・雲の文脈 (CloudContext)
 * sky モジュール (cloud_volume.glsl が読む)
 */
#ifndef SKY_CLOUD_WEATHER_GLSL
#define SKY_CLOUD_WEATHER_GLSL

//@include "/lib/sky/cloud_constants.glsl"

// 天気図 (水平位置は参照空間)
vec2 cloudMapCenter() { return floor(cameraPosition.xz * CLOUD_KH / CLOUD_MAP_TEXEL) * CLOUD_MAP_TEXEL; }

// カメラ基準の水平位置 rel の天気図。手動バイリニア (カスタムイメージのサンプラーのフィルタ設定に依存しない)
vec4 cloudMapFetch(vec2 rel) {
    // カメラから天気図の原点までの端数は畳んで求める (CLOUD_KH 倍の大きな座標どうしの引き算で桁落ちさせない)
    vec2 p = (rel + cloudFoldCamera(vec2(0.0), CLOUD_MAP_TEXEL)) / CLOUD_MAP_TEXEL + (CLOUD_MAP_RES * 0.5 - 0.5);
    p = clamp(p, vec2(0.0), vec2(CLOUD_MAP_RES - 1.0));
    ivec2 i = ivec2(p);
    vec2 f = p - vec2(i);
    ivec2 j = min(i + 1, ivec2(CLOUD_MAP_RES - 1.0));
    vec4 a = texelFetch(cloudWeatherSampler, i, 0);
    vec4 b = texelFetch(cloudWeatherSampler, ivec2(j.x, i.y), 0);
    vec4 c = texelFetch(cloudWeatherSampler, ivec2(i.x, j.y), 0);
    vec4 d = texelFetch(cloudWeatherSampler, j, 0);
    vec4 map = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    vec2 edge = abs(p - (CLOUD_MAP_RES * 0.5 - 0.5)) / (CLOUD_MAP_RES * 0.5);
    // 端の外は晴れにするが、雲が雨雲へ変わる空は一面の雨雲のまま (0 にすると地平線の手前に陽の当たる雲と直線の縁の晴れ間が出た)
    vec3 edgeFill = vec3(0.9, 0.85, 0.3) * max(rainStrength, rainWetness) * cloudRainReshape();
    map.rba = mix(map.rba, edgeFill, smoothstep(0.85, 0.99, max(edge.x, edge.y)));
    return map;
}

// 地域テンプレート (CLOUD_REGION_PRESET)・気候 (天気・日替わり・時刻) と風
struct CloudRegion {
    vec2 humidity;    // 低層の被覆の日替わりの範囲 (乾いた日, 湿った日)
    float convection; // 積雲の発達しやすさ
    float stratus;    // 湿った日・夜に層積雲へ広がる傾向
    float mid;        // 中層の量
    float high;       // 上層の量
    float storms;     // 晴れた日の午後の積乱雲の出やすさ (雷雨とは別)
    float diurnal;    // 対流の日変化の深さ (1 で明け方に対流がほぼ止まる)
};

// 快晴の日の割合と、その日の低層の被覆の倍率 (扁平雲がまばらに浮かぶ程度)
const float CLOUD_CLEAR_DAY_CHANCE = 0.12;
const float CLOUD_CLEAR_DAY_COVER = 0.4;
// 夕方から夜に低層の被覆を増やす割合 (日変化の最小の時)
const float CLOUD_EVENING_SPREAD = 0.35;
// 雷雨で中層・上層のベールを減らす割合と、雲の中の曇天の光 (色の抜け・拡散) を減らす割合
// 0.75 / 0.45 では雷雨の空が明るい灰色に白い綿雲が浮かぶ晴れの日のような見た目になる
const float CLOUD_THUNDER_VEIL_CUT = 0.45;
#ifdef CLOUD_VANILLA_SHAPE
// バニラの形は雷雨も雨と同じ曇天の暗さにする (減らすと、頭上の柱の底と日向の側面が雨の日より白く浮く)
const float CLOUD_THUNDER_LIGHT_CUT = 0.0;
#else
const float CLOUD_THUNDER_LIGHT_CUT = 0.25;
#endif
// 雷雨で雲の空中遠近のもやの雨の分を減らす割合 (遠くの積乱雲の塔が見えるように)
const float CLOUD_THUNDER_HAZE_CUT = 0.6;

// 地域の雲の組み合わせテンプレート (頻度は気候学の一般的な傾向からの提案値)
CloudRegion cloudRegion() {
#if CLOUD_REGION_PRESET == 0
    // 温帯: 晴れの日は扁平雲・並雲と薄い巻雲、湿った日は層積雲。前線の前後に巻層雲・高層雲
    // (乾いた側 0.2 では大半の日が雲 1 つ 2 つの快晴に見えた。快晴の日は CLOUD_CLEAR_DAY_CHANCE で別に作る)
    return CloudRegion(vec2(0.5, 0.78), 1.0, 0.45, 0.65, 1.0, 0.0, 0.7);
#elif CLOUD_REGION_PRESET == 1
    // 熱帯: 朝の扁平雲が午後に雄大雲・積乱雲へ。巻雲は積乱雲のかなとこの名残。層状の雲は少ない
    return CloudRegion(vec2(0.35, 0.75), 1.35, 0.15, 0.4, 1.1, 0.8, 0.9);
#elif CLOUD_REGION_PRESET == 2
    // 乾燥: 雲量 2-3 割。薄い扁平雲の散在と高積雲の波。積乱雲はまれ
    return CloudRegion(vec2(0.03, 0.35), 0.8, 0.1, 0.7, 0.8, 0.15, 0.9);
#elif CLOUD_REGION_PRESET == 3
    // 寒冷・極域: 層状が支配的 (層積雲・高層雲)。対流は弱く、氷晶の巻雲・巻層雲がよく見える
    return CloudRegion(vec2(0.3, 0.95), 0.3, 1.0, 0.8, 1.2, 0.0, 0.25);
#elif CLOUD_REGION_PRESET == 4
    // 海洋: 広い層積雲が最多、晴れ間には大きな水滴のふわふわした積雲。日変化は小さい
    return CloudRegion(vec2(0.4, 0.95), 0.8, 0.85, 0.4, 0.7, 0.1, 0.3);
#else
    return CloudRegion(vec2(max(CLOUD_C_LOW - 0.3, 0.0), min(CLOUD_C_LOW + 0.3, 1.0)), CLOUD_C_CONVECTION, CLOUD_C_STRATUS, CLOUD_C_MID, CLOUD_C_HIGH, CLOUD_C_STORMS, 0.7);
#endif
}

struct CloudClimate {
    float lowCover;   // 低層の基準の被覆 (空に占める割合。1 超で全天)
    float lowType;    // 低層の基準の雲種 (0 層状 / 0.5 積雲 / 1 積乱雲)
    float midCover;
    float highCover;
    float convection; // 対流の強さ (積雲の背の高さ)
    float rain;
    float rainLight;  // 雲の中の光の雨天度 (被覆より早く切り替わる)
    float reshape;      // 雨が雲の量・雲種・形を雨雲へ変える度合い (rain の cloudRainReshape() 倍。バニラの形以外は rain そのもの、雷雨は常に変える)
    float reshapeLight; // 同じ度合いを rainLight で測ったもの (中層のベール)
    float thunder;
    float storm;      // 晴れた日の積乱雲の出やすさ (遠くだけに立てる)
};

// 雨の強さ [0,1]。降り始めは rainStrength (約 5 秒で 1) で半分だけ、残りは rainWetness (既定の半減期 30 秒) で 1-2 分かけて進む
// (rainStrength のままだと数秒で空が一気に雨雲に変わった。雨上がりは rainWetness が残るので雲がゆっくり晴れる)
float cloudRainAmount() { return max(0.5 * rainStrength, rainWetness * mix(0.6, 1.0, rainStrength)); }

CloudClimate cloudClimate() {
    CloudClimate c;
    CloudRegion region = cloudRegion();
    float humidity = climateDayRandom(11u);
    float instability = climateDayRandom(23u);
    float midMoisture = climateDayRandom(37u);
    float highMoisture = climateDayRandom(53u);
    // 日射による対流は 14 時ごろ最大、明け方に最小 (worldTime 8000 = 14 時)
    float diurnal = 0.5 + 0.5 * cos(TAU * (float(worldTime) - 8000.0) / 24000.0);
    c.rain = cloudRainAmount();
    // 雲の中の光 (曇天の色・拡散) と中層・上層のベールは降り始めから早めに切り替える: 低い雲が覆う前に上空の高層雲が陽射しを弱める。
    // 被覆と同じ遅さだと、降り始めの 10 秒ほどは暗い雲に白く陽の当たる縁が残った劇的な空になった
    c.rainLight = max(c.rain, 0.85 * rainStrength);
    c.thunder = thunderStrength;
    float shape = cloudRainReshape();
    c.reshape = c.rain * shape;
    // 雷雨は嵐のセルの間が切れるので、中層のベールと雲の中の曇天の光も弱める (塔の日の当たる側面と陰が見えるように)
    float rainVeil = c.rainLight * (1.0 - CLOUD_THUNDER_VEIL_CUT * c.thunder) * shape;
    c.rainLight *= 1.0 - CLOUD_THUNDER_LIGHT_CUT * c.thunder;
    c.reshapeLight = c.rainLight * shape;
    c.convection = saturate(instability * region.convection * CS_CONVECTION * mix(1.0 - region.diurnal, 1.0, diurnal) + c.thunder);
    // 快晴の日 (高気圧に覆われた乾いた日) は時々だけ。被覆の範囲の下端で作ると大半の日が寂しい空になる
    float clearDay = 1.0 - smoothstep(0.5, 1.0, climateDayRandom(78u) / CLOUD_CLEAR_DAY_CHANCE);
    float lowBase = mix(region.humidity.x, region.humidity.y, humidity) * mix(1.0, CLOUD_CLEAR_DAY_COVER, clearDay);
    // 対流が弱まる夕方から夜は、積雲が平たく横へ広がって層積雲になる (夕焼けの逆光の雲・月夜の雲が小さな塊だけにならないように)
    lowBase *= 1.0 + CLOUD_EVENING_SPREAD * (1.0 - diurnal);
    lowBase *= CS_LOW_COVER;
    c.lowCover = mix(lowBase, 1.25, c.reshape) * (CLOUD_COVERAGE * CLOUD_LOW_COVERAGE);
    // 対流の強い昼は積雲、安定した湿った日や夜は層積雲 (積雲が平たく広がる)。雨雲へ変わる空は乱層雲
    c.lowType = mix(0.12, 0.8, c.convection) - 0.35 * region.stratus * humidity * (1.0 - region.diurnal * diurnal);
    c.lowType = mix(c.lowType + CS_TYPE_SHIFT, 0.05, c.reshape);
    c.midCover = mix(region.mid * midMoisture * midMoisture * CS_MID_COVER, 1.15, rainVeil) * (CLOUD_COVERAGE * CLOUD_MID_COVERAGE);
    // 上層の湿りは前線の先触れ。雨の前後は巻層雲が広がる
    c.highCover = mix(0.08, 0.75, highMoisture) * region.high * CS_HIGH_COVER + (CLOUD_CIRRUS_COVERAGE - 0.1) * 2.0 + rainVeil * 0.4;
    // 晴れた日の午後の積乱雲: 不安定な日の午後だけ
    c.storm = region.storms * smoothstep(0.4, 0.8, instability) * sqr(diurnal) * (1.0 - c.reshape);
#ifndef CLOUD_CB
    c.storm = 0.0;
#endif
#ifdef CLOUD_VANILLA_SHAPE
    c.storm = 0.0;
#endif
    return c;
}

vec2 cloudWindLow() { return CLOUD_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_WIND_SPEED); }
vec2 cloudWindMid() { return CLOUD_MID_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_MID_WIND_SPEED); }
vec2 cloudWindHigh() { return CLOUD_HIGH_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_HIGH_WIND_SPEED); }

struct CloudContext {
    vec2 lowOrigin;  // 低層のノイズ座標の原点 (カメラ - 風 を CLOUD_LOW_TILE で畳んだもの, m)
    vec2 midOrigin;
    vec2 highOrigin;
    vec3 evolve;     // 形状ノイズの追加の流れ (m)
    float convection;
    float rain;
    float rainLight;
    float reshape;
    float reshapeLight;
    float densityScale;
    float storm;     // 積乱雲が立ちうるか (雷雨 or 晴れた日の積乱雲)。0 なら低層の上端は積雲の層まで
    float lowTop;    // 低層の上端 (参照 m)
    float lowTopWorld;
    float cameraAltitude; // カメラの参照高度
    float seaAltitude;    // 海面の参照高度 (空中遠近の基準)
};

CloudContext cloudContextSetup(CloudClimate climate) {
    CloudContext ctx;
    vec2 windLow = cloudWindLow();
    ctx.lowOrigin = cloudFoldCamera(windLow, CLOUD_LOW_TILE);
    ctx.midOrigin = cloudFoldCamera(cloudWindMid(), CLOUD_MID_TILE);
    ctx.highOrigin = cloudFoldCamera(cloudWindHigh(), CLOUD_HIGH_TILE, CLOUD_KH_HIGH);
    float time = frameTimeCounter * CLOUD_SPEED;
    ctx.evolve = vec3(-windLow.x * CLOUD_EVOLVE, -time * CLOUD_UPDRAFT, -windLow.y * CLOUD_EVOLVE);
    ctx.convection = climate.convection;
    ctx.rain = climate.rain;
    ctx.rainLight = climate.rainLight;
    ctx.reshape = climate.reshape;
    ctx.reshapeLight = climate.reshapeLight;
    // 雷雨の雲は液水量が多く、底が一段暗い (0.4 では雷雨の雲が明るい灰色のままになる)
    // 晴天の消散係数は芯の実測の 1/3 なので、雨・雷雨はここで濃くする (雨の日の重い雲底を出す)
    ctx.densityScale = 1.0 + 2.0 * climate.rain + 3.0 * climate.thunder;
#ifdef CLOUD_CB
    ctx.storm = max(climate.thunder, climate.storm);
#else
    ctx.storm = 0.0;
#endif
    ctx.lowTop = ctx.storm > 1e-3 ? CLOUD_R_CB_TOP : CLOUD_R_TOP;
    ctx.lowTopWorld = ctx.storm > 1e-3 ? CLOUD_CB_TOP : CLOUD_TOP;
    ctx.cameraAltitude = cloudRefAltitude(cameraPosition.y);
    ctx.seaAltitude = cloudRefAltitude(SKY_SEA_LEVEL);
    return ctx;
}

// 雨天の濃さの倍率。雨天度の範囲でなめらかに効かせる (雨上がりの rainWetness が残る間に、小さな雲だけが濃くならないように)
float cloudRainDensityScale(CloudContext ctx) {
    return mix(1.0, ctx.densityScale, smoothstep(CLOUD_RAIN_DENSITY.x, CLOUD_RAIN_DENSITY.y, ctx.rain));
}

#endif
