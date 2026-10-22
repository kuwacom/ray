/*
 * 光源インデックス (0-255)。光源テーブル (lib/light/light_table.glsl) の添字
 *   1-127  : ブロック光源 (block.properties / item.properties の 1000 + index)
 *   128-191: アイテム専用光源 (item.properties の 1000 + index)
 *   192-255: エンティティ光源 (entity.properties の 5100 + (index - 192))
 */
#ifndef IDS_LIGHT_IDS_GLSL
#define IDS_LIGHT_IDS_GLSL

const int LIGHT_NONE = 0;

// ブロック光源
const int LIGHT_TORCH = 1;
const int LIGHT_SOUL_TORCH = 2;
const int LIGHT_REDSTONE_TORCH = 3;
const int LIGHT_COPPER_TORCH = 4;
const int LIGHT_LANTERN = 5;
const int LIGHT_SOUL_LANTERN = 6;
const int LIGHT_COPPER_LANTERN = 7;
const int LIGHT_GLOWSTONE = 8;
const int LIGHT_SEA_LANTERN = 9;
const int LIGHT_SHROOMLIGHT = 10;
const int LIGHT_JACK_O_LANTERN = 11;
const int LIGHT_LAVA = 12;
const int LIGHT_FIRE = 13;
const int LIGHT_SOUL_FIRE = 14;
const int LIGHT_CAMPFIRE = 15;
const int LIGHT_SOUL_CAMPFIRE = 16;
const int LIGHT_MAGMA_BLOCK = 17;
const int LIGHT_END_ROD = 18;
const int LIGHT_BEACON = 19;
const int LIGHT_CONDUIT = 20;
const int LIGHT_SEA_PICKLE = 21;
const int LIGHT_GLOW_LICHEN = 22;
const int LIGHT_AMETHYST = 23;
const int LIGHT_CRYING_OBSIDIAN = 24;
const int LIGHT_RESPAWN_ANCHOR = 25;
const int LIGHT_REDSTONE_LAMP = 26;
const int LIGHT_OCHRE_FROGLIGHT = 27;
const int LIGHT_VERDANT_FROGLIGHT = 28;
const int LIGHT_PEARLESCENT_FROGLIGHT = 29;
const int LIGHT_CANDLE = 30;
const int LIGHT_CANDLE_COLORED = 31; // 31-46 (white..black, block_ids の色順)
const int LIGHT_COPPER_BULB = 47;
const int LIGHT_REDSTONE_ORE = 48;
const int LIGHT_FURNACE = 49;
const int LIGHT_BREWING_STAND = 50;
const int LIGHT_ENCHANTING_TABLE = 51;
const int LIGHT_END_PORTAL_FRAME = 52;
const int LIGHT_END_PORTAL = 53;
const int LIGHT_NETHER_PORTAL = 54;
const int LIGHT_LIGHT_BLOCK = 55;
const int LIGHT_SCULK_CATALYST = 56;
const int LIGHT_SCULK_SENSOR = 57;
const int LIGHT_CAVE_VINES = 58;
const int LIGHT_DRAGON_EGG = 59;
const int LIGHT_ENDER_CHEST = 60;
const int LIGHT_FIREFLY_BUSH = 61;
const int LIGHT_TRIAL_SPAWNER = 62;
const int LIGHT_DECOR_FIRST = 63; // 63-68: BLOCK_DECOR_* (lapis, emerald, diamond, gold, redstone, amethyst)。DECORATIVE_BLOCK_LIGHTS 2 の時だけ使う
const int LIGHT_BLOCK_LAST = 127;

// アイテム専用光源 (ドロップ・手持ち)
const int LIGHT_ITEM_LAVA_BUCKET = 128;
const int LIGHT_ITEM_GLOWSTONE_DUST = 129;
const int LIGHT_ITEM_BLAZE = 130;
const int LIGHT_ITEM_MAGMA_CREAM = 131;
const int LIGHT_ITEM_GLOW = 132;
const int LIGHT_ITEM_NETHER_STAR = 133;
const int LIGHT_ITEM_SPECTRAL_ARROW = 134;
const int LIGHT_ITEM_FIRE_CHARGE = 135;
const int LIGHT_ITEM_EXPERIENCE_BOTTLE = 136;
const int LIGHT_ITEM_END_CRYSTAL = 137;
const int LIGHT_ITEM_LAST = 191;

// エンティティ光源
const int LIGHT_ENTITY_BLAZE = 192;
const int LIGHT_ENTITY_MAGMA_CUBE = 193;
const int LIGHT_ENTITY_GLOW_SQUID = 194;
const int LIGHT_ENTITY_ALLAY = 195;
const int LIGHT_ENTITY_END_CRYSTAL = 196;
const int LIGHT_ENTITY_EXPERIENCE_ORB = 197;
const int LIGHT_ENTITY_SPECTRAL_ARROW = 198;
const int LIGHT_ENTITY_FIREBALL = 199;
const int LIGHT_ENTITY_DRAGON_FIREBALL = 200;
const int LIGHT_ENTITY_TNT = 201;
const int LIGHT_ENTITY_CREEPER = 202;
const int LIGHT_ENTITY_FIREWORK = 203;
const int LIGHT_ENTITY_LIGHTNING = 204;
const int LIGHT_ENTITY_FLAME = 205;
const int LIGHT_ENTITY_SHULKER_BULLET = 206;
const int LIGHT_ENTITY_TNT_MINECART = 207;

// 光源フラグ (LightDef.info.x)
const uint LIGHT_FLAG_OCCLUDES = 1u;        // 光源ブロック自体が完全遮蔽物 (グロウストーン等)
const uint LIGHT_FLAG_FLUID = 2u;           // 液体 (溶岩)
const uint LIGHT_FLAG_CAT_ITEM = 4u;        // ITEM_LIGHTS の対象
const uint LIGHT_FLAG_CAT_PROJECTILE = 8u;  // PROJECTILE_LIGHTS の対象
const uint LIGHT_FLAG_CAT_BURNING = 16u;    // BURNING_ENTITY_LIGHTS の対象
const uint LIGHT_FLAG_CAT_GLOWING = 32u;    // GLOWING_ENTITY_LIGHTS の対象
const uint LIGHT_FLAG_ENTITY_FLASH = 64u;   // entityColor.a (点滅) が強い時だけ光る (TNT・クリーパー)

#endif
