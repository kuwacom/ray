/*
 * 光源・形状・透過色のデータ表 (正本)
 * setup.csh がこれを評価して SSBO blockData に書き込み、実行時は lib/light/block_data.glsl で引く
 * ID の追加は block/item/entity.properties と同時に変える必要がある
 *
 * 色は sRGB で書き、ここで線形に変換する。到達半径は光源レベル 15 のときの値で、
 * 実際のレベル (at_midBlock.w またはテーブルの既定値) に比例して縮む
 */
#ifndef LIGHT_LIGHT_TABLE_GLSL
#define LIGHT_LIGHT_TABLE_GLSL

// 炎の色。BLOCKLIGHT_WARMTH で中性からバニラ寄りの暖色まで動かす
// 黒体で 0 = 約 4300K, 0.25 = 約 3800K, 0.5 = 約 3300K。AgX は明るい所の彩度を落とすので、
// 0.25 では石や板が白〜灰に写り寒く見えた。0.5 でも洞窟の R/B が 2.9 (iterationT 4.0) と中性すぎたので
// 既定 0.6 (たいまつの灯る洞窟での R/B 3.75)
const vec3 FIRE_NEUTRAL_SRGB = vec3(1.00, 0.86, 0.72);
const vec3 FIRE_WARM_SRGB = vec3(1.00, 0.62, 0.30);
const vec3 SOUL_SRGB = vec3(0.45, 0.85, 1.00);
const vec3 COPPER_FLAME_SRGB = vec3(0.55, 1.00, 0.65);
const vec3 LAVA_SRGB = vec3(1.00, 0.45, 0.15);

// 鉱物ブロックを光源にした時の明るさと光レベル (到達半径は 15 x レベル / 15 ブロック)
const float DECOR_LIGHT_BRIGHTNESS = 0.5;
const float DECOR_LIGHT_LEVEL = 7.0;

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
    d.params = vec4(15.0, flicker, level, 0.0);
    d.info = uvec4(flags, 0u, 0u, 0u);
    return d;
}

const vec3 LT_CENTER = vec3(0.5);
const uint LT_OCC = LIGHT_FLAG_OCCLUDES;
const uint LT_CAT_ITEM = LIGHT_FLAG_CAT_ITEM;
const uint LT_CAT_PROJ = LIGHT_FLAG_CAT_PROJECTILE;
const uint LT_CAT_BURN = LIGHT_FLAG_CAT_BURNING;
const uint LT_CAT_GLOW = LIGHT_FLAG_CAT_GLOWING;

LightDef lightDefStatic(int i) {
    vec3 fire = fireSrgb();
    // 色付きロウソクは炎の色と染料の色の中間 (染料色そのままだと暗い色が光らなくなる)
    if (i >= LIGHT_CANDLE_COLORED && i < LIGHT_CANDLE_COLORED + 16) {
        return makeLight(mix(fire, dyeSrgb(i - LIGHT_CANDLE_COLORED), 0.5), 1.0, 12.0, 0.05, vec3(0.5, 0.4, 0.5), 0.5, 0u);
    }
    switch (i) {
        // ブロック光源: (sRGB 色, 明るさ, 既定レベル, 光源半径, 発光中心, フリッカー, フラグ)
        case LIGHT_TORCH:            return makeLight(fire, 1.0, 14.0, 0.08, vec3(0.5, 0.65, 0.5), 0.6, 0u);
        case LIGHT_SOUL_TORCH:       return makeLight(SOUL_SRGB, 0.8, 10.0, 0.08, vec3(0.5, 0.65, 0.5), 0.4, 0u);
        case LIGHT_REDSTONE_TORCH:   return makeLight(vec3(1.0, 0.25, 0.15), 0.6, 7.0, 0.06, vec3(0.5, 0.65, 0.5), 0.0, 0u);
        case LIGHT_COPPER_TORCH:     return makeLight(COPPER_FLAME_SRGB, 0.9, 14.0, 0.08, vec3(0.5, 0.65, 0.5), 0.5, 0u);
        case LIGHT_LANTERN:          return makeLight(fire, 1.0, 15.0, 0.15, vec3(0.5, 0.35, 0.5), 0.3, 0u);
        case LIGHT_SOUL_LANTERN:     return makeLight(SOUL_SRGB, 0.8, 10.0, 0.15, vec3(0.5, 0.35, 0.5), 0.2, 0u);
        case LIGHT_COPPER_LANTERN:   return makeLight(COPPER_FLAME_SRGB, 0.9, 15.0, 0.15, vec3(0.5, 0.35, 0.5), 0.3, 0u);
        case LIGHT_GLOWSTONE:        return makeLight(vec3(1.0, 0.80, 0.52), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        // シーランタンは青緑 (0.75, 0.95, 1.0) だと橙の板が黄緑に転んだので白寄りの水色
        // 明るさ 1.0 では近くの炎の灯りを打ち消して室内がオリーブ色に濁ったので控えめに
        case LIGHT_SEA_LANTERN:      return makeLight(vec3(0.85, 0.95, 1.0), 0.75, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_SHROOMLIGHT:      return makeLight(vec3(1.0, 0.70, 0.45), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_JACK_O_LANTERN:   return makeLight(fire, 1.0, 15.0, 0.4, LT_CENTER, 0.3, LT_OCC);
        case LIGHT_LAVA:             return makeLight(LAVA_SRGB, 1.2, 15.0, 0.5, vec3(0.5, 0.45, 0.5), 0.2, LIGHT_FLAG_FLUID);
        case LIGHT_FIRE:             return makeLight(mix(fire, FIRE_WARM_SRGB, 0.3), 1.1, 15.0, 0.4, vec3(0.5, 0.4, 0.5), 0.8, 0u);
        case LIGHT_SOUL_FIRE:        return makeLight(SOUL_SRGB, 0.9, 10.0, 0.4, vec3(0.5, 0.4, 0.5), 0.6, 0u);
        case LIGHT_CAMPFIRE:         return makeLight(fire, 1.1, 15.0, 0.35, vec3(0.5, 0.4, 0.5), 0.7, 0u);
        case LIGHT_SOUL_CAMPFIRE:    return makeLight(SOUL_SRGB, 0.9, 10.0, 0.35, vec3(0.5, 0.4, 0.5), 0.5, 0u);
        case LIGHT_MAGMA_BLOCK:      return makeLight(vec3(1.0, 0.40, 0.15), 0.8, 3.0, 0.5, LT_CENTER, 0.1, LT_OCC);
        case LIGHT_END_ROD:          return makeLight(vec3(0.95, 0.90, 1.0), 0.9, 14.0, 0.1, LT_CENTER, 0.0, 0u);
        case LIGHT_BEACON:           return makeLight(vec3(0.85, 0.95, 1.0), 1.2, 15.0, 0.4, LT_CENTER, 0.0, 0u);
        case LIGHT_CONDUIT:          return makeLight(vec3(0.60, 0.90, 1.0), 1.0, 15.0, 0.2, LT_CENTER, 0.0, 0u);
        case LIGHT_SEA_PICKLE:       return makeLight(vec3(0.60, 1.0, 0.75), 0.8, 15.0, 0.15, vec3(0.5, 0.3, 0.5), 0.0, 0u);
        case LIGHT_GLOW_LICHEN:      return makeLight(vec3(0.60, 1.0, 0.85), 0.6, 7.0, 0.3, LT_CENTER, 0.0, 0u);
        case LIGHT_AMETHYST:         return makeLight(vec3(0.80, 0.55, 1.0), 0.7, 5.0, 0.2, vec3(0.5, 0.35, 0.5), 0.0, 0u);
        case LIGHT_CRYING_OBSIDIAN:  return makeLight(vec3(0.60, 0.25, 1.0), 0.8, 10.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_RESPAWN_ANCHOR:   return makeLight(vec3(0.65, 0.30, 1.0), 1.0, 15.0, 0.4, vec3(0.5, 0.9, 0.5), 0.0, LT_OCC);
        case LIGHT_REDSTONE_LAMP:    return makeLight(vec3(1.0, 0.75, 0.55), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_OCHRE_FROGLIGHT:  return makeLight(vec3(1.0, 0.85, 0.55), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_VERDANT_FROGLIGHT:return makeLight(vec3(0.75, 1.0, 0.60), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_PEARLESCENT_FROGLIGHT: return makeLight(vec3(1.0, 0.75, 0.95), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_CANDLE:           return makeLight(fire, 1.0, 12.0, 0.05, vec3(0.5, 0.4, 0.5), 0.5, 0u);
        case LIGHT_COPPER_BULB:      return makeLight(vec3(1.0, 0.80, 0.60), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_REDSTONE_ORE:     return makeLight(vec3(1.0, 0.20, 0.10), 0.6, 9.0, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_FURNACE:          return makeLight(fire, 0.9, 13.0, 0.3, vec3(0.5, 0.3, 0.5), 0.5, LT_OCC);
        case LIGHT_BREWING_STAND:    return makeLight(vec3(1.0, 0.85, 0.50), 0.6, 1.0, 0.1, vec3(0.5, 0.2, 0.5), 0.0, 0u);
        case LIGHT_ENCHANTING_TABLE: return makeLight(vec3(0.70, 0.60, 1.0), 0.6, 7.0, 0.3, vec3(0.5, 0.75, 0.5), 0.0, 0u);
        case LIGHT_END_PORTAL_FRAME: return makeLight(vec3(0.50, 0.90, 0.75), 0.5, 1.0, 0.2, vec3(0.5, 0.9, 0.5), 0.0, 0u);
        case LIGHT_END_PORTAL:       return makeLight(vec3(0.50, 0.75, 0.90), 0.8, 15.0, 0.5, LT_CENTER, 0.0, 0u);
        case LIGHT_NETHER_PORTAL:    return makeLight(vec3(0.60, 0.25, 1.0), 0.9, 11.0, 0.5, LT_CENTER, 0.2, 0u);
        case LIGHT_LIGHT_BLOCK:      return makeLight(vec3(1.0, 0.95, 0.90), 1.0, 15.0, 0.0, LT_CENTER, 0.0, 0u);
        case LIGHT_SCULK_CATALYST:   return makeLight(vec3(0.30, 0.85, 0.90), 0.6, 6.0, 0.4, vec3(0.5, 0.9, 0.5), 0.0, LT_OCC);
        case LIGHT_SCULK_SENSOR:     return makeLight(vec3(0.30, 0.85, 0.90), 0.5, 1.0, 0.2, vec3(0.5, 0.4, 0.5), 0.0, 0u);
        case LIGHT_CAVE_VINES:       return makeLight(vec3(1.0, 0.75, 0.40), 0.9, 14.0, 0.15, LT_CENTER, 0.0, 0u);
        case LIGHT_DRAGON_EGG:       return makeLight(vec3(0.70, 0.30, 1.0), 0.5, 1.0, 0.3, LT_CENTER, 0.0, 0u);
        case LIGHT_ENDER_CHEST:      return makeLight(vec3(0.40, 0.90, 0.80), 0.6, 7.0, 0.3, LT_CENTER, 0.0, 0u);
        case LIGHT_FIREFLY_BUSH:     return makeLight(vec3(0.85, 1.0, 0.50), 0.5, 2.0, 0.4, vec3(0.5, 0.7, 0.5), 0.6, 0u);
        case LIGHT_TRIAL_SPAWNER:    return makeLight(vec3(1.0, 0.70, 0.40), 0.8, 8.0, 0.4, LT_CENTER, 0.3, 0u);
        // 鉱物ブロック (DECORATIVE_BLOCK_LIGHTS 2 の時だけ光源)。本物の光源より暗く狭い、鉱物の色のほのかな灯り
        case LIGHT_DECOR_FIRST + 0:  return makeLight(vec3(0.25, 0.45, 1.00), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_DECOR_FIRST + 1:  return makeLight(vec3(0.30, 1.00, 0.50), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_DECOR_FIRST + 2:  return makeLight(vec3(0.50, 0.95, 1.00), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_DECOR_FIRST + 3:  return makeLight(vec3(1.00, 0.80, 0.35), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_DECOR_FIRST + 4:  return makeLight(vec3(1.00, 0.15, 0.08), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);
        case LIGHT_DECOR_FIRST + 5:  return makeLight(vec3(0.75, 0.50, 1.00), DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC);

        // アイテム専用光源 (ドロップ / 手持ち)
        case LIGHT_ITEM_LAVA_BUCKET:      return makeLight(LAVA_SRGB, 1.0, 15.0, 0.2, LT_CENTER, 0.2, LT_CAT_ITEM);
        case LIGHT_ITEM_GLOWSTONE_DUST:   return makeLight(vec3(1.0, 0.80, 0.52), 0.7, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM);
        case LIGHT_ITEM_BLAZE:            return makeLight(mix(fire, FIRE_WARM_SRGB, 0.5), 0.8, 10.0, 0.1, LT_CENTER, 0.3, LT_CAT_ITEM);
        case LIGHT_ITEM_MAGMA_CREAM:      return makeLight(LAVA_SRGB, 0.7, 8.0, 0.1, LT_CENTER, 0.1, LT_CAT_ITEM);
        case LIGHT_ITEM_GLOW:             return makeLight(vec3(0.50, 1.0, 0.85), 0.6, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM);
        case LIGHT_ITEM_NETHER_STAR:      return makeLight(vec3(0.95, 0.90, 1.0), 1.0, 12.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM);
        case LIGHT_ITEM_SPECTRAL_ARROW:   return makeLight(vec3(1.0, 0.90, 0.50), 0.6, 8.0, 0.05, LT_CENTER, 0.0, LT_CAT_ITEM);
        case LIGHT_ITEM_FIRE_CHARGE:      return makeLight(fire, 0.8, 10.0, 0.1, LT_CENTER, 0.5, LT_CAT_ITEM);
        case LIGHT_ITEM_EXPERIENCE_BOTTLE:return makeLight(vec3(0.70, 1.0, 0.30), 0.6, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM);
        case LIGHT_ITEM_END_CRYSTAL:      return makeLight(vec3(1.0, 0.70, 0.95), 0.9, 12.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM);

        // エンティティ光源
        case LIGHT_ENTITY_BLAZE:          return makeLight(mix(fire, FIRE_WARM_SRGB, 0.5), 1.0, 12.0, 0.4, LT_CENTER, 0.5, LT_CAT_GLOW);
        case LIGHT_ENTITY_MAGMA_CUBE:     return makeLight(LAVA_SRGB, 0.8, 10.0, 0.4, LT_CENTER, 0.1, LT_CAT_GLOW);
        case LIGHT_ENTITY_GLOW_SQUID:     return makeLight(vec3(0.40, 1.0, 0.90), 0.6, 6.0, 0.4, LT_CENTER, 0.0, LT_CAT_GLOW);
        case LIGHT_ENTITY_ALLAY:          return makeLight(vec3(0.50, 0.85, 1.0), 0.6, 5.0, 0.2, LT_CENTER, 0.0, LT_CAT_GLOW);
        case LIGHT_ENTITY_END_CRYSTAL:    return makeLight(vec3(1.0, 0.70, 0.95), 1.2, 15.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW);
        case LIGHT_ENTITY_EXPERIENCE_ORB: return makeLight(vec3(0.70, 1.0, 0.30), 0.5, 5.0, 0.1, LT_CENTER, 0.0, LT_CAT_GLOW);
        case LIGHT_ENTITY_SPECTRAL_ARROW: return makeLight(vec3(1.0, 0.90, 0.50), 0.7, 8.0, 0.05, LT_CENTER, 0.0, LT_CAT_PROJ);
        case LIGHT_ENTITY_FIREBALL:       return makeLight(fire, 1.0, 13.0, 0.3, LT_CENTER, 0.5, LT_CAT_PROJ);
        case LIGHT_ENTITY_DRAGON_FIREBALL:return makeLight(vec3(0.85, 0.40, 1.0), 1.0, 12.0, 0.3, LT_CENTER, 0.3, LT_CAT_PROJ);
        case LIGHT_ENTITY_TNT:            return makeLight(vec3(1.0, 1.0, 1.0), 1.0, 10.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH);
        case LIGHT_ENTITY_CREEPER:        return makeLight(vec3(1.0, 1.0, 1.0), 0.8, 8.0, 0.4, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH);
        case LIGHT_ENTITY_FIREWORK:       return makeLight(vec3(1.0, 0.85, 0.60), 0.8, 10.0, 0.1, LT_CENTER, 0.6, LT_CAT_PROJ);
        case LIGHT_ENTITY_LIGHTNING:      return makeLight(vec3(0.80, 0.85, 1.0), 4.0, 15.0, 1.0, LT_CENTER, 0.0, LT_CAT_GLOW);
        case LIGHT_ENTITY_FLAME:          return makeLight(mix(fire, FIRE_WARM_SRGB, 0.3), 1.0, 15.0, 0.4, LT_CENTER, 0.8, LT_CAT_BURN);
        case LIGHT_ENTITY_SHULKER_BULLET: return makeLight(vec3(1.0, 0.95, 0.85), 0.6, 6.0, 0.1, LT_CENTER, 0.0, LT_CAT_PROJ);
        case LIGHT_ENTITY_TNT_MINECART:   return makeLight(vec3(1.0, 1.0, 1.0), 1.0, 10.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH);
    }
    LightDef none;
    none.color = vec4(0.0);
    none.shape = vec4(LT_CENTER, 0.0);
    none.params = vec4(0.0);
    none.info = uvec4(0u);
    return none;
}

// 部分形状の遮蔽 AABB (index = ブロック ID - 300)。box1 は min > max で無効
uvec4 packShape(vec3 min0, vec3 max0, vec3 min1, vec3 max1) {
    return uvec4(packUnorm4x8(vec4(min0, 0.0)), packUnorm4x8(vec4(max0, 0.0)), packUnorm4x8(vec4(min1, 0.0)), packUnorm4x8(vec4(max1, 0.0)));
}

uvec4 shapeStatic(int i) {
    const vec3 NO_MIN = vec3(1.0), NO_MAX = vec3(0.0);
    /*
     * 積もった雪は層の数 x 1/8 の高さ。以前は層の数によらず 1/4 の箱で、自然に積もる 1 層 (1/8) では見えている面が
     * 箱の中に埋まっていた。面から少し浮かせたレイ (GI・反射・ブロックライトの影) が隣の雪の箱の側面に当たり、
     * 近い距離 (浮かせる量が 1/8 に届かない範囲) でだけブロックの継ぎ目に線が出ていた
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
