/*
 * 光源の表を組み立てる道具 (炎や染料の色、makeLight)
 * 表の中身 (光源ごとの色・形・フラグ) は lib/light/light_table_data.glsl に生成される
 *
 * 色は sRGB で書き、ここで線形に変換する。到達半径は光源レベル 15 のときの値で、
 * 実際のレベル (at_midBlock.w またはテーブルの既定値) に比例して縮む
 */
#ifndef LIGHT_LIGHT_DEF_GLSL
#define LIGHT_LIGHT_DEF_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/ids/light_ids.glsl"

// 炎の色。BLOCKLIGHT_WARMTH で中性からバニラ寄りの暖色まで動かす
// 黒体で 0 = 約 4300K, 0.25 = 約 3800K, 0.5 = 約 3300K。AgX は明るい所の彩度を落とすので、
// 0.25 では石や板が白〜灰に写り寒く見え、0.5 でも洞窟の R/B が 2.9 と中性すぎるので、
// 炎の暖かさが分かる既定 0.6 にする (たいまつの灯る洞窟での R/B 3.75)
const vec3 FIRE_NEUTRAL_SRGB = vec3(1.00, 0.86, 0.72);
const vec3 FIRE_WARM_SRGB = vec3(1.00, 0.62, 0.30);
const vec3 SOUL_SRGB = vec3(0.45, 0.85, 1.00);
const vec3 COPPER_FLAME_SRGB = vec3(0.55, 1.00, 0.65);
const vec3 LAVA_SRGB = vec3(1.00, 0.45, 0.15);

// 鉱物ブロックを光源にした時の明るさと光レベル (到達半径は 15 x レベル / 15 ブロック)
const float DECOR_LIGHT_BRIGHTNESS = 0.5;
const float DECOR_LIGHT_LEVEL = 7.0;
const float LIGHT_RANGE_MAX = 15.0; // レベル最大の光源の到達半径 (ブロック)

vec3 fireSrgb() { return mix(FIRE_NEUTRAL_SRGB, FIRE_WARM_SRGB, BLOCKLIGHT_WARMTH); }

// 染料 16 色 (white, orange, magenta, light_blue, yellow, lime, pink, gray, light_gray, cyan, purple, blue, brown, green, red, black)
vec3 dyeSrgb(int i) {
    const vec3 dyes[16] = vec3[16](
        vec3(0.98, 0.98, 0.98), vec3(0.98, 0.50, 0.11), vec3(0.78, 0.31, 0.75), vec3(0.23, 0.70, 0.85),
        vec3(1.00, 0.85, 0.24), vec3(0.50, 0.78, 0.10), vec3(0.95, 0.55, 0.67), vec3(0.28, 0.31, 0.33),
        vec3(0.62, 0.62, 0.59), vec3(0.09, 0.61, 0.61), vec3(0.54, 0.20, 0.72), vec3(0.24, 0.27, 0.67),
        vec3(0.51, 0.33, 0.20), vec3(0.37, 0.49, 0.09), vec3(0.69, 0.18, 0.15), vec3(0.11, 0.11, 0.13)
    );
    return dyes[clamp(i, 0, 15)];
}

LightDef makeLight(vec3 srgb, float brightness, float level, float sourceSize, vec3 center, float flicker, uint flags) {
    LightDef d;
    vec3 c = srgbToLinear(srgb);
    d.color = vec4(c / max(maxOf(c), EPS), brightness);
    d.shape = vec4(center, sourceSize);
    d.params = vec4(LIGHT_RANGE_MAX, flicker, level, 0.0);
    d.info = uvec4(flags, 0u, 0u, 0u);
    return d;
}

const vec3 LT_CENTER = vec3(0.5);
const uint LT_OCC = LIGHT_FLAG_OCCLUDES;
const uint LT_CAT_ITEM = LIGHT_FLAG_CAT_ITEM;
const uint LT_CAT_PROJ = LIGHT_FLAG_CAT_PROJECTILE;
const uint LT_CAT_BURN = LIGHT_FLAG_CAT_BURNING;
const uint LT_CAT_GLOW = LIGHT_FLAG_CAT_GLOWING;

#endif

