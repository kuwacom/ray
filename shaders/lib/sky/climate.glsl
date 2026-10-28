/*
 * 日替わりの天気の傾向と地域 (sky モジュール。フォグが使う)
 * 雲 (cloud_weather.glsl の cloudClimate) も climateDayRandom を同じ種で呼ぶので、湿った日・快晴の日は雲とフォグでそろう
 */
#ifndef SKY_CLIMATE_GLSL
#define SKY_CLIMATE_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/uniforms.glsl"

// 日替わりの種 (cloud_weather.glsl の cloudClimate と同じ値)
const uint CLIMATE_SEED_HUMIDITY = 11u;
const uint CLIMATE_SEED_CLEAR_DAY = 78u;
const float CLIMATE_CLEAR_DAY_CHANCE = 0.12;

// 日ごとの傾向 [0,1]。夕方から 0 時にかけて次の日の傾向へ移る (worldTime 0 = 6 時)
float climateDayRandom(uint seed) {
    float t = float(worldDay) + float(worldTime + 6000) / 24000.0;
    float day = floor(t);
    float a = hash1(uint(int(day)) * 7919u + seed);
    float b = hash1(uint(int(day) + 1) * 7919u + seed);
    return mix(a, b, smoothstep(0.7, 1.0, t - day));
}

float climateHumidity() { return climateDayRandom(CLIMATE_SEED_HUMIDITY); }

// 快晴の日 (高気圧に覆われた乾いた日) の度合い。晴れて風の弱い夜は放射霧が出やすい
float climateClearDay() { return 1.0 - smoothstep(0.5, 1.0, climateDayRandom(CLIMATE_SEED_CLEAR_DAY) / CLIMATE_CLEAR_DAY_CHANCE); }

/*
 * 雲の地域 (CLOUD_REGION_PRESET) ごとのフォグの倍率: x = もや, y = 霧の層, z = 地表の霧
 * 海洋は霧の層が多く、乾燥は地表の霧なし、熱帯は朝の谷霧が多く、寒冷はもやが薄い
 */
vec3 climateFogRegion() {
#if CLOUD_REGION_PRESET == 1
    return vec3(1.2, 1.0, 1.5);
#elif CLOUD_REGION_PRESET == 2
    return vec3(1.1, 0.3, 0.0);
#elif CLOUD_REGION_PRESET == 3
    return vec3(0.6, 0.8, 1.2);
#elif CLOUD_REGION_PRESET == 4
    return vec3(1.1, 1.5, 0.8);
#else
    return vec3(1.0);
#endif
}

#endif
