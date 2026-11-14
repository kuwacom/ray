/*
 * 形状・透過色のデータ表 (正本)。光源の表は lib/light/light_table_data.glsl (生成)
 * setup.csh がこれを評価して SSBO blockData に書き込み、実行時は lib/light/block_data.glsl で引く
 * ID の追加は tools/id_tables.py と tools/gen_block_properties.py の表で行う
 */
#ifndef LIGHT_LIGHT_TABLE_GLSL
#define LIGHT_LIGHT_TABLE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/light/light_def.glsl"
//@include "/lib/light/light_table_data.glsl"

/*
 * 部分形状の遮蔽 AABB (index = ブロック ID - 300)。1 ブロックの 1/16 刻みの座標を 5bit ずつ (min xyz, max xyz の 30bit) に詰めて
 * 1 個を 1 uint にし、4 個まで持つ (lib/light/trace.glsl の unpackShapeBox が読む)。使わない箱は min > max で無効
 */
uint packBox(vec3 bmin, vec3 bmax) {
    uvec3 a = uvec3(bmin * 16.0 + 0.5);
    uvec3 b = uvec3(bmax * 16.0 + 0.5);
    return a.x | (a.y << 5) | (a.z << 10) | (b.x << 15) | (b.y << 20) | (b.z << 25);
}

const uint NO_BOX = 16u; // min.x = 16/16、max.x = 0

uvec4 packShape(vec3 min0, vec3 max0, vec3 min1, vec3 max1) {
    return uvec4(packBox(min0, max0), packBox(min1, max1), NO_BOX, NO_BOX);
}

/*
 * フェンス・塀・鉄格子: 柱 + 接続した向きの腕 (北 = -z、東 = +x)。腕は軸ごとに 1 個の箱にまとめ、柱の中を通して反対側の腕とつなぐ
 * conn = 北 1 東 2 南 4 西 8 の和。post = 柱の半幅、armHalf = 腕の半幅、[y0, y1] = 腕の高さの範囲
 * bars = 腕を中央の面の棒の並びで判定する (鉄格子)。柱はテクスチャでも中央の 2 列が埋まっているので箱のまま
 */
uvec4 connectedShape(int conn, float post, float armHalf, float y0, float y1, bool bars) {
    float c = 0.5;
    vec3 pmin = vec3(c - post, 0.0, c - post);
    vec3 pmax = vec3(c + post, 1.0, c + post);
    float zLo = (conn & 1) != 0 ? 0.0 : c - post;
    float zHi = (conn & 4) != 0 ? 1.0 : c + post;
    float xLo = (conn & 8) != 0 ? 0.0 : c - post;
    float xHi = (conn & 2) != 0 ? 1.0 : c + post;
    bool armZ = (conn & 5) != 0;
    bool armX = (conn & 10) != 0;
    return uvec4(packBox(pmin, pmax),
                 armZ ? packBox(vec3(c - armHalf, y0, zLo), vec3(c + armHalf, y1, zHi)) | (bars ? BOX_BARS_PLANE_X : 0u) : NO_BOX,
                 armX ? packBox(vec3(xLo, y0, c - armHalf), vec3(xHi, y1, c + armHalf)) | (bars ? BOX_BARS_PLANE_Z : 0u) : NO_BOX,
                 NO_BOX);
}

/*
 * 階段: ハーフ + 段 (上向きの階段は段が下)。並びは tools/gen_block_properties.py の stair_slot
 * 内角は箱 2 個に収まらないので、同じ向きの直線の ID に入っている
 * xy = xz の最小, zw = 最大 (北 = -z、東 = +x)。0-3 = 直線 (段が北・東・南・西の半分)、4-7 = 外角 (段が北西・北東・南東・南西の 1/4)
 */
const vec4 STAIR_STEP_XZ[8] = vec4[8](
    vec4(0.0, 0.0, 1.0, 0.5), vec4(0.5, 0.0, 1.0, 1.0), vec4(0.0, 0.5, 1.0, 1.0), vec4(0.0, 0.0, 0.5, 1.0),
    vec4(0.0, 0.0, 0.5, 0.5), vec4(0.5, 0.0, 1.0, 0.5), vec4(0.5, 0.5, 1.0, 1.0), vec4(0.0, 0.5, 0.5, 1.0)
);

uvec4 stairShape(int k) {
    bool top = k >= 8;
    vec4 s = STAIR_STEP_XZ[k & 7];
    float slabY = top ? 0.5 : 0.0;
    float stepY = top ? 0.0 : 0.5;
    return packShape(vec3(0.0, slabY, 0.0), vec3(1.0, slabY + 0.5, 1.0), vec3(s.x, stepY, s.y), vec3(s.z, stepY + 0.5, s.w));
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
    if (i >= BLOCK_STAIRS_FIRST - 300 && i <= BLOCK_STAIRS_LAST - 300) return stairShape(i - (BLOCK_STAIRS_FIRST - 300));
    // 腕はフェンスが上下 2 本の横木 (6/16-15/16)、塀は低い腕 14/16 と高い腕 16/16 の間、鉄格子は柱と同じ太さの板 (中は棒の並び)
    if (i >= BLOCK_FENCE_FIRST - 300 && i < BLOCK_FENCE_FIRST - 300 + 16) return connectedShape(i - (BLOCK_FENCE_FIRST - 300), 0.125, 0.0625, 0.375, 0.9375, false);
    if (i >= BLOCK_WALL_FIRST - 300 && i < BLOCK_WALL_FIRST - 300 + 16) return connectedShape(i - (BLOCK_WALL_FIRST - 300), 0.25, 0.1875, 0.0, 0.9375, false);
    if (i >= BLOCK_PANE_BARS_FIRST - 300 && i < BLOCK_PANE_BARS_FIRST - 300 + 16) return connectedShape(i - (BLOCK_PANE_BARS_FIRST - 300), 0.0625, 0.0625, 0.0, 1.0, true);
    switch (i) {
        case BLOCK_SLAB_BOTTOM - 300:   return packShape(vec3(0.0), vec3(1.0, 0.5, 1.0), NO_MIN, NO_MAX);
        case BLOCK_SLAB_TOP - 300:      return packShape(vec3(0.0, 0.5, 0.0), vec3(1.0), NO_MIN, NO_MAX);
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
