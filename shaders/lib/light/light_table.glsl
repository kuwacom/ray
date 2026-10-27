/*
 * 形状・透過色のデータ表 (正本)。光源の表は lib/light/light_table_data.glsl (生成)
 * setup.csh がこれを評価して SSBO blockData に書き込み、実行時は lib/light/block_data.glsl で引く
 * ID の追加は tools/id_tables.py と tools/gen_block_properties.py の表で行う
 */
#ifndef LIGHT_LIGHT_TABLE_GLSL
#define LIGHT_LIGHT_TABLE_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/math.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"

// 部分形状の遮蔽 AABB (index = ブロック ID - 300)。box1 は min > max で無効
uvec4 packShape(vec3 min0, vec3 max0, vec3 min1, vec3 max1) {
    return uvec4(packUnorm4x8(vec4(min0, 0.0)), packUnorm4x8(vec4(max0, 0.0)), packUnorm4x8(vec4(min1, 0.0)), packUnorm4x8(vec4(max1, 0.0)));
}

uvec4 shapeStatic(int i) {
    const vec3 NO_MIN = vec3(1.0), NO_MAX = vec3(0.0);
    /*
     * 積もった雪は層の数 x 1/8 の高さ。層の数によらず 1/4 の箱にすると、自然に積もる 1 層 (1/8) では見えている面が
     * 箱の中に埋まる。面から少し浮かせたレイ (GI・反射・ブロックライトの影) が隣の雪の箱の側面に当たり、
     * 近い距離 (浮かせる量が 1/8 に届かない範囲) でだけブロックの継ぎ目に線が出る
     */
    if (i == BLOCK_SNOW_LAYER - 300) return packShape(vec3(0.0), vec3(1.0, 0.125, 1.0), NO_MIN, NO_MAX);
    if (i >= BLOCK_SNOW_LAYER_2 - 300 && i <= BLOCK_SNOW_LAYER_8 - 300) {
        return packShape(vec3(0.0), vec3(1.0, float(i + 300 - BLOCK_SNOW_LAYER) / 8.0, 1.0), NO_MIN, NO_MAX);
    }
    switch (i) {
        case BLOCK_SLAB_BOTTOM - 300:   return packShape(vec3(0.0), vec3(1.0, 0.5, 1.0), NO_MIN, NO_MAX);
        case BLOCK_SLAB_TOP - 300:      return packShape(vec3(0.0, 0.5, 0.0), vec3(1.0), NO_MIN, NO_MAX);
        // 階段は向きの状態を ID に持たないのでハーフブロックで近似
        case BLOCK_STAIRS_BOTTOM - 300: return packShape(vec3(0.0), vec3(1.0, 0.5, 1.0), NO_MIN, NO_MAX);
        case BLOCK_STAIRS_TOP - 300:    return packShape(vec3(0.0, 0.5, 0.0), vec3(1.0), NO_MIN, NO_MAX);
        case BLOCK_FENCE - 300:         return packShape(vec3(0.375, 0.0, 0.375), vec3(0.625, 1.0, 0.625), NO_MIN, NO_MAX);
        case BLOCK_WALL - 300:          return packShape(vec3(0.25, 0.0, 0.25), vec3(0.75, 1.0, 0.75), NO_MIN, NO_MAX);
        case BLOCK_PANE_BARS - 300:     return packShape(vec3(0.4375, 0.0, 0.4375), vec3(0.5625, 1.0, 0.5625), NO_MIN, NO_MAX);
        case BLOCK_LOW - 300:           return packShape(vec3(0.0), vec3(1.0, 0.5625, 1.0), NO_MIN, NO_MAX);
        case BLOCK_DOOR_CLOSED - 300:   return packShape(vec3(0.0), vec3(1.0), NO_MIN, NO_MAX);
    }
    return packShape(vec3(0.0), vec3(1.0), NO_MIN, NO_MAX);
}

/*
 * 色ガラスの透過率。染料の色をそのまま線形化すると赤や青の主成分でも 0.4-0.5 しか通さず、色ガラス越しの光が暗く濁った
 * 主成分を STAINED_GLASS_PEAK に揃える (明るさの下限 0.5 で割るので黒・灰のガラスは暗いまま)
 */
const float STAINED_GLASS_PEAK = 0.85;

vec3 stainedGlassTransmittance(vec3 dye) {
    vec3 c = srgbToLinear(mix(dye, vec3(1.0), 0.15));
    return c * (STAINED_GLASS_PEAK / max(maxOf(c), 0.5));
}

// 半透明ブロックの透過色 (index = ブロック ID - 200)。rgb = 線形の透過率, a = 散乱で失う割合
vec4 tintStatic(int i) {
    if (i >= 10 && i < 26) return vec4(stainedGlassTransmittance(dyeSrgb(i - 10)), 0.1);
    if (i >= 30 && i < 46) return vec4(stainedGlassTransmittance(dyeSrgb(i - 30)), 0.1);
    switch (i) {
        case BLOCK_WATER - 200:        return vec4(srgbToLinear(vec3(0.80, 0.92, 1.0)), 0.05);
        case BLOCK_ICE - 200:          return vec4(srgbToLinear(vec3(0.85, 0.93, 1.0)), 0.1);
        case BLOCK_GLASS - 200:        return vec4(vec3(0.95), 0.02);
        case BLOCK_GLASS_PANE - 200:   return vec4(vec3(0.95), 0.02);
        case BLOCK_SLIME - 200:        return vec4(srgbToLinear(vec3(0.55, 0.90, 0.45)), 0.2);
        case BLOCK_HONEY - 200:        return vec4(srgbToLinear(vec3(1.0, 0.70, 0.20)), 0.2);
        case BLOCK_TINTED_GLASS - 200: return vec4(srgbToLinear(vec3(0.15, 0.12, 0.18)), 0.8);
    }
    return vec4(vec3(1.0), 0.0);
}

#endif
