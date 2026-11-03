/*
 * 光源のデータ表。makeLight の式は lib/light/light_def.glsl
 * tools/gen_block_properties.py が tools/id_tables.py から生成する。手で編集しない
 */
#ifndef LIGHT_LIGHT_TABLE_DATA_GLSL
#define LIGHT_LIGHT_TABLE_DATA_GLSL

//@include "/lib/light/light_def.glsl"
//@include "/lib/ids/light_ids.glsl"

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
        case LIGHT_JACK_O_LANTERN:   return makeLight(fire, 1.0, 15.0, 0.4, LT_CENTER, 0.3, LT_OCC | LIGHT_FLAG_FACING);
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
        case LIGHT_FURNACE:          return makeLight(mix(fire, FIRE_WARM_SRGB, 0.5), 0.9, 13.0, 0.3, vec3(0.5, 0.3, 0.5), 0.5, LT_OCC | LIGHT_FLAG_FACING);
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

#endif
