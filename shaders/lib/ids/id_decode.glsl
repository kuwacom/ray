/*
 * ID の解釈 (ブロック / アイテム / エンティティ ID -> 光源インデックス・マテリアル ID)
 * 番号帯の算術だけで引けるように ID を設計してある (lib/ids/*_ids.glsl)
 */
#ifndef IDS_ID_DECODE_GLSL
#define IDS_ID_DECODE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/entity_ids.glsl"
//@include "/lib/ids/light_ids.glsl"
//@include "/lib/ids/material_ids.glsl"

// mc_Entity.x (未登録は -1) をボクセルに格納する 12bit ID へ
int blockIdToVoxelId(int blockId) {
    return (blockId <= 0 || blockId > 4095) ? BLOCK_SOLID : blockId;
}

/*
 * ID の無い (BLOCK_SOLID の) ブロックを、発光レベル (at_midBlock.w) で光源として扱うか (GENERIC_LIGHT)
 * 表にある ID (> 1) は対象にしない。明るい色ではなく発光レベルだけで決めるので、雪や白いブロックは光らない
 * レベル 1 (バニラの終端の枠など) は光源にしない。弱すぎて光だまりにならず、光源の数だけ増える
 */
const int GENERIC_LIGHT_MIN_LEVEL = 2;
bool isGenericEmitter(int voxelId, int emissionLevel) {
#ifdef GENERIC_LIGHT
    return voxelId == BLOCK_SOLID && emissionLevel >= GENERIC_LIGHT_MIN_LEVEL;
#else
    return false;
#endif
}

// mc_Entity.x の流れる水を水に戻す (流れる水の ID はボクセルの印 VOXEL_WATER_FLOWING にだけ使う)
int terrainBlockId(int blockId) { return blockId == BLOCK_WATER_FLOWING ? BLOCK_WATER : blockId; }

// 光を通さない普通の固体 (未登録 = BLOCK_SOLID と、色の表に載せた 2000 番台)
bool isPlainSolidBlock(int blockId) { return blockId == BLOCK_SOLID || blockId >= BLOCK_COLOR_FIRST; }

bool isDecorativeBlock(int blockId) { return blockId >= BLOCK_DECOR_LAPIS && blockId <= BLOCK_DECOR_AMETHYST; }

// 種類ごとの設定 (DECOR_*) で発光する鉱物ブロック。発光・光源の両方がこれに従う
// ビット i が BLOCK_DECOR_LAPIS + i。比較を並べるとトレースの 1 セルごとの判定など呼ぶ所すべてに展開されるので、表と範囲の判定 1 回にする
const uint DECOR_GLOW_MASK = 0u
#ifdef DECOR_LAPIS
    | (1u << uint(BLOCK_DECOR_LAPIS - BLOCK_DECOR_LAPIS))
#endif
#ifdef DECOR_EMERALD
    | (1u << uint(BLOCK_DECOR_EMERALD - BLOCK_DECOR_LAPIS))
#endif
#ifdef DECOR_DIAMOND
    | (1u << uint(BLOCK_DECOR_DIAMOND - BLOCK_DECOR_LAPIS))
#endif
#ifdef DECOR_GOLD
    | (1u << uint(BLOCK_DECOR_GOLD - BLOCK_DECOR_LAPIS))
#endif
#ifdef DECOR_REDSTONE
    | (1u << uint(BLOCK_DECOR_REDSTONE - BLOCK_DECOR_LAPIS))
#endif
#ifdef DECOR_AMETHYST
    | (1u << uint(BLOCK_DECOR_AMETHYST - BLOCK_DECOR_LAPIS))
#endif
    ;

bool isDecorGlowBlock(int blockId) {
    uint i = uint(blockId - BLOCK_DECOR_LAPIS);
    return i <= uint(BLOCK_DECOR_AMETHYST - BLOCK_DECOR_LAPIS) && ((DECOR_GLOW_MASK >> i) & 1u) != 0u;
}

/*
 * 鉱物ブロックの色の濃さ (DECOR_SATURATION)。decorIndex は BLOCK_DECOR_LAPIS からの番号 (光源は LIGHT_DECOR_FIRST から同じ順)
 * アメジストは薄い紫で、原色へ寄せると青が大きく勝って青紫に見えるので、元の紫を少し濃くする所で止める
 */
const float DECOR_AMETHYST_SATURATION_MAX = 1.25;
float decorSaturation(int decorIndex) {
    return decorIndex == BLOCK_DECOR_AMETHYST - BLOCK_DECOR_LAPIS ? min(DECOR_SATURATION, DECOR_AMETHYST_SATURATION_MAX) : DECOR_SATURATION;
}

/*
 * 色の付いた固体の反射率 (ALBEDO_*_STRENGTH)。線形のアルベドを種類ごとの倍率で明るくする
 * 各成分を同じ倍率で掛けて色相と色の濃さ (成分の比) を保ち、一番大きい成分が COLOR_ALBEDO_MAX に着いた所で倍率を止める
 * (成分ごとに上限で切ると、明るい成分から頭打ちになって白っぽくなる)。もともと上限を超える画素は 1 倍以上では暗くしない
 * G バッファ・影マップ (RSM の VPL)・ボクセルの色の表に同じものを掛け、見た目と照り返しの色をそろえる
 */
const float COLOR_ALBEDO_MAX = 0.9;
// 全部 1 倍の時は呼ぶ側も色の変換 (sRGB と線形の往復) を省いて、8bit の色を 1 段も動かさない
const bool COLOR_ALBEDO_ACTIVE = ALBEDO_CONCRETE_STRENGTH != 1.0 || ALBEDO_WOOL_STRENGTH != 1.0 || ALBEDO_TERRACOTTA_STRENGTH != 1.0
                               || ALBEDO_DYED_STRENGTH != 1.0;

// 反射率の設定の対象になりうる ID (2000 番台の色の付いた固体、20-35 の彩釉テラコッタ、130-178 の染めた小物、400-432 の染めたブロックエンティティ)
bool isColorAlbedoBlock(int blockId) {
    return blockId >= BLOCK_COLOR_FIRST || (blockId >= BLOCK_GLAZED_TERRACOTTA && blockId <= BLOCK_GLAZED_LAST)
        || (blockId >= BLOCK_CARPET && blockId <= BLOCK_DYED_LAST) || (blockId >= BLOCK_BED && blockId <= BLOCK_DYED_ENTITY_LAST);
}

float colorBlockAlbedoStrength(int blockId) {
    if (blockId >= BLOCK_COLOR_FIRST) {
        int kind = blockColorKind(blockId);
        return kind == COLOR_KIND_CONCRETE ? ALBEDO_CONCRETE_STRENGTH
             : kind == COLOR_KIND_WOOL ? ALBEDO_WOOL_STRENGTH
             : kind == COLOR_KIND_TERRACOTTA ? ALBEDO_TERRACOTTA_STRENGTH : 1.0;
    }
    if (blockId >= BLOCK_CARPET && blockId < BLOCK_BANNER) return ALBEDO_WOOL_STRENGTH;
    if (blockId >= BLOCK_BANNER && blockId <= BLOCK_DYED_LAST) return ALBEDO_DYED_STRENGTH;
    if (blockId >= BLOCK_GLAZED_TERRACOTTA && blockId <= BLOCK_GLAZED_LAST) return ALBEDO_TERRACOTTA_STRENGTH;
    // ベッドは掛け布団が羊毛 (レシピも羊毛) なので羊毛の設定、シュルカーボックスは旗・ロウソクと同じ染めた物の設定
    if (blockId >= BLOCK_BED && blockId < BLOCK_SHULKER_BOX) return ALBEDO_WOOL_STRENGTH;
    if (blockId >= BLOCK_SHULKER_BOX && blockId <= BLOCK_DYED_ENTITY_LAST) return ALBEDO_DYED_STRENGTH;
    return 1.0;
}

/*
 * テラコッタ (無地と彩釉) は、ブロックの平均の色 (ボクセルの色の表) から決めた倍率をブロック全体に同じだけ掛ける
 * 画素ごとに上限で止めると、彩釉の模様の明るい所が先に止まって暗い所だけ明るくなり、模様が薄まった (2.0 で輝度の変動係数 0.77 倍)
 * 平均の最大成分を COLOR_ALBEDO_PATTERN_TARGET まで上げる倍率に抑え、使い切れなかった倍率は彩度で足す。明るい画素は肩でなめらかに上限へ寄せる
 * 1.21.1 のテクスチャで 2.0 の時、彩釉の模様の変動係数 0.98 倍、色の濃さ (max - min) の伸びは無地のテラコッタの 0.82 倍 (画素ごとは 0.77 倍 / 0.86 倍)
 * ベッド・シュルカーボックスなどのブロックエンティティは平均の色の表を持たない (地形の面が無い) ので、画素ごとのまま
 */
const float COLOR_ALBEDO_PATTERN_TARGET = 0.6;
const float COLOR_ALBEDO_PATTERN_KNEE = 0.75;
const float COLOR_ALBEDO_PATTERN_SAT_MAX = 2.0;

// 平均の色に対する比を保って掛けるブロック (テラコッタの設定の対象)
bool isPatternAlbedoBlock(int blockId) {
    return (blockId >= BLOCK_GLAZED_TERRACOTTA && blockId <= BLOCK_GLAZED_LAST)
        || (blockId >= BLOCK_COLOR_FIRST && blockColorKind(blockId) == COLOR_KIND_TERRACOTTA);
}

vec3 applyPatternAlbedo(vec3 albedo, float s, float meanMax) {
    if (s <= 1.0) return albedo * s;
    float kb = clamp(COLOR_ALBEDO_PATTERN_TARGET / max(meanMax, 1e-4), 1.0, s);
    vec3 b = albedo * kb;
    float mx = maxOf(b);
    if (mx > COLOR_ALBEDO_PATTERN_KNEE) {
        const float w = COLOR_ALBEDO_MAX - COLOR_ALBEDO_PATTERN_KNEE;
        float y = COLOR_ALBEDO_PATTERN_KNEE + w * (1.0 - exp(-(mx - COLOR_ALBEDO_PATTERN_KNEE) / w));
        // もともと上限を超える画素は元より暗くしない
        b *= max(y / mx, 1.0 / kb);
    }
    // 明るさで使い切れなかった倍率を彩度で。各成分が [0, COLOR_ALBEDO_MAX] に収まる所まで (白い画素は白のまま)
    float l = luminance(b);
    vec3 c = b - l;
    float t = min(s / kb, COLOR_ALBEDO_PATTERN_SAT_MAX);
    for (int i = 0; i < 3; i++) {
        if (c[i] > 1e-5) t = min(t, max((COLOR_ALBEDO_MAX - l) / c[i], 1.0));
        else if (c[i] < -1e-5) t = min(t, max(-l / c[i], 1.0));
    }
    return l + c * t;
}

/*
 * meanMax: ブロックの平均の色 (線形) の最大成分。テラコッタだけが使う (lib/light/block_data.glsl colorBlockMeanMax)
 * 他は画素ごとの倍率 (一番大きい成分が COLOR_ALBEDO_MAX に着いた所で止める)
 */
vec3 applyColorBlockAlbedo(int blockId, vec3 albedo, float meanMax) {
    if (!COLOR_ALBEDO_ACTIVE || !isColorAlbedoBlock(blockId)) return albedo;
    float s = colorBlockAlbedoStrength(blockId);
    if (s == 1.0) return albedo;
    if (isPatternAlbedoBlock(blockId)) return applyPatternAlbedo(albedo, s, meanMax);
    float k = s < 1.0 ? s : max(1.0, min(s, COLOR_ALBEDO_MAX / max(maxOf(albedo), 1e-4)));
    return albedo * k;
}

int getBlockLightIndex(int blockId) {
#if DECORATIVE_BLOCK_LIGHTS == 2
    if (isDecorGlowBlock(blockId)) return LIGHT_DECOR_FIRST + (blockId - BLOCK_DECOR_LAPIS);
#endif
    // 向きのある光源 (東・南・西) は 256 ずつ上の帯。下位 8 bit が光源インデックス
    int r = blockId - BLOCK_LIGHT_BASE;
#ifndef GLOW_LICHEN_LIGHT
    if ((r & 255) == LIGHT_GLOW_LICHEN) return LIGHT_NONE;
#endif
    return (r > 0 && r <= BLOCK_LIGHT_LAST - BLOCK_LIGHT_BASE) ? (r & 255) : LIGHT_NONE;
}

// 向きのある光源ブロックの前面の向き (0 北 1 東 2 南 3 西)。LIGHT_FLAG_FACING の光源にだけ使う
int blockLightFacing(int blockId) {
    return max(blockId - BLOCK_LIGHT_BASE, 0) >> 8;
}

// 一部だけ金属のブロック・アイテムの ID は、元の ID + 金属の判定の番号 x METAL_GATE_STRIDE (番号 0 = 金属なし)
// 表に無いアイテム・ブロックエンティティの ID (-1) は、エンティティの頂点属性では判定の番号が範囲外になる大きな値で来る (16 bit の符号なしの 65535 と見られる)
// 範囲外は金属なしにする (パン・本・チェスト・ベッドが丸ごと金属になっていた)
int metalGateOfId(int id) {
    int gate = max(id, 0) / METAL_GATE_STRIDE;
    return gate <= METAL_GATE_GEM ? gate : 0;
}
int stripMetalGate(int id) { return id >= METAL_GATE_STRIDE ? id % METAL_GATE_STRIDE : id; }

int entityMetalGate(int entId) {
    int gate = entId - ENTITY_METAL_BASE;
    return (gate >= METAL_GATE_ALL && gate <= METAL_GATE_GEM) ? gate : 0;
}

int getItemLightIndex(int itemId) {
    itemId = stripMetalGate(itemId);
    return (itemId > ITEM_LIGHT_BASE && itemId <= ITEM_LIGHT_LAST) ? itemId - ITEM_LIGHT_BASE : LIGHT_NONE;
}

int getEntityLightIndex(int entId) {
    return (entId >= ENTITY_LIGHT_BASE && entId <= ENTITY_LIGHT_LAST) ? LIGHT_ENTITY_BLAZE + (entId - ENTITY_LIGHT_BASE) : LIGHT_NONE;
}

/*
 * blockEntityId がブロックエンティティを描いている間の値か
 * Iris はそれ以外では 0、ブロックのアイテムを描く間は 1 を入れる。block.properties は 0 と 1 を使わない (表に無いものは -1 / 65535)
 */
const int BLOCK_ENTITY_ID_NONE = 0;
const int BLOCK_ENTITY_ID_BLOCK_ITEM = 1;
bool isBlockEntityDraw(int beId) { return beId != BLOCK_ENTITY_ID_NONE && beId != BLOCK_ENTITY_ID_BLOCK_ITEM; }

bool isTintBlock(int blockId) { return blockId >= 200 && blockId < 300; }
int getTintIndex(int blockId) { return blockId - 200; }
int getShapeIndex(int blockId) { return blockId - 300; }

bool isPlantBlock(int blockId) { return blockId >= 100 && blockId < 130; }

// 光源ブロックのうち完全遮蔽しないものを除いた「光を通さない固体」判定はテーブルが要るので lib/light/ に置く

int blockIdToMaterial(int blockId) {
    if (blockId <= 0) return MAT_TERRAIN;
    if (blockId == BLOCK_METAL) return MAT_METAL;
    if (blockId == BLOCK_GLOSSY || (blockId >= BLOCK_GLAZED_TERRACOTTA && blockId <= BLOCK_GLAZED_LAST)) return MAT_GLOSSY;
    // 鉱物ブロックは光源扱いでも元の質感のまま (発光は gbuffers の estimateEmission で足す)
    if (isDecorativeBlock(blockId)) {
        if (blockId == BLOCK_DECOR_GOLD) return MAT_METAL;
        return blockId <= BLOCK_DECOR_DIAMOND ? MAT_GLOSSY : MAT_TERRAIN;
    }
    if (blockId == BLOCK_SNOW || blockId == BLOCK_SNOW_LAYER || (blockId >= BLOCK_SNOW_LAYER_2 && blockId <= BLOCK_SNOW_LAYER_8)) return MAT_SNOW;
    if (blockId == BLOCK_LEAVES) return MAT_LEAVES;
    if (blockId == BLOCK_UNDERWATER_PLANT) return MAT_UNDERWATER_PLANT;
    // 光を通す小物 (ドア・トラップドア・看板・ボタン・線路など) は植物の帯にあるが、法線と質感はふつうのブロック
    // 植物にすると法線が上向きに固定され、開いたトラップドアのような立った面まで地面のように照らされててかった
    if (blockId == BLOCK_NON_OCCLUDING || (blockId >= BLOCK_CARPET && blockId <= BLOCK_DYED_LAST)) return MAT_TERRAIN;
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

/*
 * アイテム・ブロックエンティティの質感の推定に使うマテリアル ID
 * ブロックのアイテムは Iris が block.properties の ID を currentRenderedItemId に渡す (item.properties は見ない。その間の blockEntityId は 1) ので、鉄・金のブロックなどはブロックと同じ金属・光沢にする
 * 植物・発光などはブロックの形や光り方に結び付いた分類なので、手に持った物にはふつうのブロックの推定を使う
 */
int itemEstimateMaterial(int itemId) {
    int m = blockIdToMaterial(stripMetalGate(itemId));
    return (m == MAT_METAL || m == MAT_GLOSSY) ? m : MAT_TERRAIN;
}

// 点滅の間だけ光るエンティティ (クリーパー・TNT・TNT 付きトロッコ)
bool isFlashEntity(int entId) {
    int light = getEntityLightIndex(entId);
    return light == LIGHT_ENTITY_CREEPER || light == LIGHT_ENTITY_TNT || light == LIGHT_ENTITY_TNT_MINECART;
}

// 点滅 (entityColor) の強さ 0-1。白い点滅だけを数え、赤いダメージ表示 (rgb が赤) では光らせない
float entityFlashStrength(vec4 entColor) {
    return saturate(entColor.a * 2.0 - 0.2) * min(entColor.g, entColor.b);
}

int entityIdToMaterial(int entId, int itemId) {
    if (entId == ENTITY_CURRENT_PLAYER || entId == ENTITY_PLAYER) return MAT_PLAYER;
    if (entId == ENTITY_ITEM) return getItemLightIndex(itemId) != LIGHT_NONE ? MAT_EMISSIVE_ENTITY : MAT_ITEM_ENTITY;
    int light = getEntityLightIndex(entId);
    if (light == LIGHT_ENTITY_LIGHTNING) return MAT_LIGHTNING;
    // 点滅の間だけ光る光源 (クリーパー・TNT) は、表面は普通のエンティティ。点滅中の発光は gbuffers が entityColor から足す
    if (isFlashEntity(entId)) return MAT_ENTITY;
    if (light != LIGHT_NONE) return MAT_EMISSIVE_ENTITY;
    return MAT_ENTITY;
}

#endif
