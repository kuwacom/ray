/*
 * ID の解釈 (ブロック / アイテム / エンティティ ID -> 光源インデックス・マテリアル ID)
 * 番号帯の算術だけで引けるように ID を設計してある (lib/ids/*_ids.glsl)
 */
#ifndef IDS_ID_DECODE_GLSL
#define IDS_ID_DECODE_GLSL

// mc_Entity.x (未登録は -1) をボクセルに格納する 12bit ID へ
int blockIdToVoxelId(int blockId) {
    return (blockId <= 0 || blockId > 4095) ? BLOCK_SOLID : blockId;
}

bool isDecorativeBlock(int blockId) { return blockId >= BLOCK_DECOR_LAPIS && blockId <= BLOCK_DECOR_AMETHYST; }

int getBlockLightIndex(int blockId) {
#if DECORATIVE_BLOCK_LIGHTS == 2
    if (isDecorativeBlock(blockId)) return LIGHT_DECOR_FIRST + (blockId - BLOCK_DECOR_LAPIS);
#endif
    return (blockId > BLOCK_LIGHT_BASE && blockId <= BLOCK_LIGHT_BASE + 255) ? blockId - BLOCK_LIGHT_BASE : LIGHT_NONE;
}

int getItemLightIndex(int itemId) {
    return (itemId > ITEM_LIGHT_BASE && itemId <= ITEM_LIGHT_LAST) ? itemId - ITEM_LIGHT_BASE : LIGHT_NONE;
}

int getEntityLightIndex(int entId) {
    return (entId >= ENTITY_LIGHT_BASE && entId <= ENTITY_LIGHT_LAST) ? LIGHT_ENTITY_BLAZE + (entId - ENTITY_LIGHT_BASE) : LIGHT_NONE;
}

bool isTintBlock(int blockId) { return blockId >= 200 && blockId < 300; }
int getTintIndex(int blockId) { return blockId - 200; }
bool isShapeBlock(int blockId) { return blockId >= 300 && blockId < 400; }
int getShapeIndex(int blockId) { return blockId - 300; }

bool isPlantBlock(int blockId) { return blockId >= 100 && blockId < 130; }

// 光源ブロックのうち完全遮蔽しないものを除いた「光を通さない固体」判定はテーブルが要るので lib/light/ に置く

int blockIdToMaterial(int blockId) {
    if (blockId <= 0) return MAT_TERRAIN;
    if (blockId == BLOCK_METAL) return MAT_METAL;
    if (blockId == BLOCK_GLOSSY) return MAT_GLOSSY;
    // 鉱物ブロックは光源扱いでも元の質感のまま (発光は gbuffers の estimateEmission で足す)
    if (isDecorativeBlock(blockId)) {
        if (blockId == BLOCK_DECOR_GOLD) return MAT_METAL;
        return blockId <= BLOCK_DECOR_DIAMOND ? MAT_GLOSSY : MAT_TERRAIN;
    }
    if (blockId == BLOCK_SNOW || blockId == BLOCK_SNOW_LAYER || (blockId >= BLOCK_SNOW_LAYER_2 && blockId <= BLOCK_SNOW_LAYER_8)) return MAT_SNOW;
    if (blockId == BLOCK_LEAVES) return MAT_LEAVES;
    if (blockId == BLOCK_UNDERWATER_PLANT) return MAT_UNDERWATER_PLANT;
    if (isPlantBlock(blockId)) return MAT_PLANT;
    if (blockId == BLOCK_WATER) return MAT_WATER;
    if (blockId == BLOCK_ICE) return MAT_ICE;
    if (blockId == BLOCK_GLASS || blockId == BLOCK_GLASS_PANE || blockId == BLOCK_TINTED_GLASS) return MAT_GLASS;
    if (blockId == BLOCK_SLIME || blockId == BLOCK_HONEY) return MAT_SLIME_HONEY;
    if (blockId >= BLOCK_STAINED_GLASS && blockId < BLOCK_STAINED_GLASS_PANE + 16) return MAT_STAINED_GLASS;
    int light = getBlockLightIndex(blockId);
    if (light == LIGHT_LAVA) return MAT_LAVA;
    if (light == LIGHT_NETHER_PORTAL) return MAT_NETHER_PORTAL;
    if (light != LIGHT_NONE) return MAT_EMISSIVE_BLOCK;
    return MAT_TERRAIN;
}

int entityIdToMaterial(int entId, int itemId) {
    if (entId == ENTITY_CURRENT_PLAYER || entId == ENTITY_PLAYER) return MAT_PLAYER;
    if (entId == ENTITY_ITEM) return getItemLightIndex(itemId) != LIGHT_NONE ? MAT_EMISSIVE_ENTITY : MAT_ITEM_ENTITY;
    int light = getEntityLightIndex(entId);
    if (light == LIGHT_ENTITY_LIGHTNING) return MAT_LIGHTNING;
    // 点滅の間だけ光る光源 (クリーパー・TNT) は、表面は普通のエンティティ。点滅の白さはバニラの entityColor が付ける
    if (light == LIGHT_ENTITY_CREEPER || light == LIGHT_ENTITY_TNT || light == LIGHT_ENTITY_TNT_MINECART) return MAT_ENTITY;
    if (light != LIGHT_NONE) return MAT_EMISSIVE_ENTITY;
    return MAT_ENTITY;
}

#endif
