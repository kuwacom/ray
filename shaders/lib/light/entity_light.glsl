/*
 * 動的エンティティ光源 (ドロップ・投擲・燃焼・発光・ブロックエンティティ) の判定と登録 (light モジュール)
 * 呼び出し元: gbuffers_entities.vsh (画面内) と shadow_entities.gsh / shadow_block.gsh (画面外を含む)
 *
 * 登録の流れ
 *   1. injectEntityLight: voxelEmitImg に光源キーを atomicMax、セルごとの頂点位置の和を蓄積表に足す
 *   2. deferred.csh: 発光セルの塊ごとに代表セルを 1 つ選び (局所最大)、蓄積表から重心を求めて
 *      グローバル光源リストへ 1 個だけ登録する (大きいエンティティが複数セルにまたがっても 1 光源になる)
 *
 * 蓄積表は SSBO3 lightBins.binLights の先頭を一時領域として借りる。
 * binLights は deferred_a.csh が書くまで使われない (begin でクリア -> shadow / gbuffers で蓄積 -> deferred で読む -> deferred_a で上書き)
 */
#ifndef LIGHT_ENTITY_LIGHT_GLSL
#define LIGHT_ENTITY_LIGHT_GLSL

const int ENTITY_ACC_SIZE = 4096;      // エントリ数 (2 のべき乗)
const int ENTITY_ACC_STRIDE = 8;       // 1 エントリの uint 数: key, count, sumX, sumY, sumZ, 予備 x3
const int ENTITY_ACC_PROBES = 8;       // 線形探索の上限
const float ENTITY_ACC_SCALE = 256.0;  // セル内位置の固定小数点倍率
const int ENTITY_ACC_UINTS = ENTITY_ACC_SIZE * ENTITY_ACC_STRIDE;

// 登録の締め切りフラグ (frameData.lightStats.z)。deferred_a 以降 (半透明エンティティ等) の登録は蓄積表を壊すので受け付けない
bool entityLightsClosed() { return frameData.lightStats.z != 0u; }

uint entityCellKey(ivec3 cell) {
    // x, z は最大 384 (9bit), y は最大 128 (7bit)。0 を空きの印にするため +1
    return (uint(cell.x) | (uint(cell.y) << 9u) | (uint(cell.z) << 16u)) + 1u;
}

uint entityAccSlot(uint h, int i) {
    return ((h + uint(i)) & uint(ENTITY_ACC_SIZE - 1)) * uint(ENTITY_ACC_STRIDE);
}

void entityAccAdd(ivec3 cell, vec3 local) {
    uint key = entityCellKey(cell);
    uint h = pcgHash(key);
    for (int i = 0; i < ENTITY_ACC_PROBES; i++) {
        uint base = entityAccSlot(h, i);
        uint prev = atomicCompSwap(lightBins.binLights[base], 0u, key);
        if (prev == 0u || prev == key) {
            uvec3 q = uvec3(saturate(local) * ENTITY_ACC_SCALE + 0.5);
            atomicAdd(lightBins.binLights[base + 1u], 1u);
            atomicAdd(lightBins.binLights[base + 2u], q.x);
            atomicAdd(lightBins.binLights[base + 3u], q.y);
            atomicAdd(lightBins.binLights[base + 4u], q.z);
            return;
        }
    }
}

// セルの頂点数と位置の和 (セルローカル, [0,1]) を探す。見つからなければ false
bool entityAccFind(ivec3 cell, out float count, out vec3 localSum) {
    uint key = entityCellKey(cell);
    uint h = pcgHash(key);
    count = 0.0;
    localSum = vec3(0.0);
    for (int i = 0; i < ENTITY_ACC_PROBES; i++) {
        uint base = entityAccSlot(h, i);
        uint k = lightBins.binLights[base];
        if (k == 0u) return false;
        if (k == key) {
            count = float(lightBins.binLights[base + 1u]);
            localSum = vec3(lightBins.binLights[base + 2u], lightBins.binLights[base + 3u], lightBins.binLights[base + 4u]) / ENTITY_ACC_SCALE;
            return count > 0.0;
        }
    }
    return false;
}

/*
 * エンティティ / 描画中アイテムの光源インデックス (0 = 光らない)。個別スイッチをここで反映する
 * level: 光源レベル (0-15)
 */
int resolveEntityLight(int entId, int itemId, vec4 entColor, out float level) {
    level = 0.0;
#ifdef ENTITY_LIGHTS
    // 自分の手持ちは手持ち光源 (lib/light/hand_light.glsl) が受け持つので二重に光らせない
    if (entId == ENTITY_CURRENT_PLAYER || entId == ENTITY_ITEM_FRAME) return LIGHT_NONE;

    int index = getEntityLightIndex(entId);
    if (index == LIGHT_NONE) {
        // ドロップアイテム・他モブの手持ちアイテム
        int itemLight = getItemLightIndex(itemId);
    #ifdef ITEM_LIGHTS
        index = itemLight;
    #endif
        if (index == LIGHT_NONE) return LIGHT_NONE;
        level = getLightDef(index).params.z;
        return index;
    }

    LightDef d = getLightDef(index);
    uint flags = d.info.x;
    #ifndef PROJECTILE_LIGHTS
        if ((flags & LIGHT_FLAG_CAT_PROJECTILE) != 0u) return LIGHT_NONE;
    #endif
    #ifndef BURNING_ENTITY_LIGHTS
        if ((flags & LIGHT_FLAG_CAT_BURNING) != 0u) return LIGHT_NONE;
    #endif
    #ifndef GLOWING_ENTITY_LIGHTS
        if ((flags & LIGHT_FLAG_CAT_GLOWING) != 0u) return LIGHT_NONE;
    #endif
    level = d.params.z;
    // TNT・クリーパーは点滅 (entityColor.a) が強い間だけ光る
    if ((flags & LIGHT_FLAG_ENTITY_FLASH) != 0u) {
        level *= entityFlashStrength(entColor);
        if (level < 0.5) return LIGHT_NONE;
    }
    return index;
#else
    return LIGHT_NONE;
#endif
}

/*
 * 光源を登録する。playerPos はエンティティ上の代表点 (頂点 / 三角形重心)
 * 同じセルへの登録は voxelEmitImg の atomicMax で 1 つ (最も明るいもの) にまとまり、
 * 位置は蓄積表の平均 -> deferred.csh で塊の重心になる
 * 雷は形が細長く巨大なので、ここでは登録せず deferred.csh が lightningBoltPosition から登録する
 * 呼ぶプログラムは IMG_VOXEL_EMIT を定義する (lib/buffers/images.glsl)
 */
#ifdef IMG_VOXEL_EMIT
void injectLightAt(vec3 playerPos, int index, float level) {
    vec3 voxelPos = playerToVoxel(playerPos);
    ivec3 cell = ivec3(floor(voxelPos));
    if (!isInVoxelVolume(cell)) return;
    uint key = (uint(clamp(level, 0.0, 15.0) + 0.5) << 8u) | uint(index);
    imageAtomicMax(voxelEmitImg, cell, key);
    entityAccAdd(cell, voxelPos - vec3(cell));
}

void injectEntityLight(vec3 playerPos, int entId, int itemId, vec4 entColor) {
#ifdef ENTITY_LIGHTS
    if (entityLightsClosed()) return;
    float level;
    int index = resolveEntityLight(entId, itemId, entColor, level);
    if (index == LIGHT_NONE || index == LIGHT_ENTITY_LIGHTNING) return;
    injectLightAt(playerPos, index, level);
#endif
}

/*
 * ブロックエンティティの光源 (エンダーチェスト・コンジット等, shadow_block.gsh から)
 * 地形ボクセルにも同じ光源が乗っている場合は deferred.csh が二重登録を外す
 */
void injectBlockEntityLight(vec3 playerPos, int beId) {
    if (entityLightsClosed()) return;
    int index = getBlockLightIndex(beId);
    if (index == LIGHT_NONE) return;
    injectLightAt(playerPos, index, getLightDef(index).params.z);
}
#endif

#endif
