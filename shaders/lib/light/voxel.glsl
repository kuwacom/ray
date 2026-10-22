/*
 * ボクセルの読み書き (light モジュール)
 * 書き込みは shadow パス (地形: 頂点シェーダー / エンティティ: ジオメトリシェーダー) からのみ
 */
#ifndef LIGHT_VOXEL_GLSL
#define LIGHT_VOXEL_GLSL

const uint VOXEL_ENTITY_MASK = 0x00FFu; // 全エンティティ (自分を含む) の 2x2x2 サブセル占有
const uint VOXEL_PLAYER_MASK = 0xFF00u; // 自分 (current_player) だけのサブセル占有

uint packVoxelBlock(int voxelId, int emission) {
    return uint(voxelId & 0xFFF) | (uint(clamp(emission, 0, 15)) << 12u);
}
int unpackVoxelBlockId(uint v) { return int(v & 0xFFFu); }
int unpackVoxelEmission(uint v) { return int(v >> 12u); }

uint readVoxelBlock(ivec3 cell) {
    if (!isInVoxelVolume(cell)) return 0u;
    return texelFetch(voxelBlockSampler, cell, 0).r;
}

uint readVoxelEntity(ivec3 cell) {
    if (!isInVoxelVolume(cell)) return 0u;
    return texelFetch(voxelEntitySampler, cell, 0).r;
}

// 光を完全に通さないボクセルか (floodfill の壁)。部分形状・植物・半透明は通す
bool isVoxelOpaque(int voxelId) {
    if (voxelId == BLOCK_SOLID || (voxelId >= 10 && voxelId < 100) || voxelId == BLOCK_DOOR_CLOSED) return true;
    int light = getBlockLightIndex(voxelId);
    return light != LIGHT_NONE && (getLightDef(light).info.x & LIGHT_FLAG_OCCLUDES) != 0u;
}

/*
 * floodfill が 1 セル通過する時の透過率。葉は光を弱める (バニラも葉で 1 段減衰する)
 * 部分形状は方向によらず通す (ハーフブロックの下に光が回り込まないと不自然に暗くなるため)
 */
const float FLOOD_LEAVES_TRANSMITTANCE = 0.7;

vec3 floodCellTransmittance(int voxelId) {
    if (voxelId == BLOCK_LEAVES) return vec3(FLOOD_LEAVES_TRANSMITTANCE);
    if (isTintBlock(voxelId)) {
        vec4 t = getTint(getTintIndex(voxelId));
        return t.rgb * (1.0 - t.a);
    }
    return vec3(1.0);
}

// ボクセル内の位置 [0,1)^3 -> サブセルのビット (下位 8bit 用)
uint entitySubcellBit(vec3 voxelPos) {
    ivec3 s = clamp(ivec3(fract(voxelPos) * 2.0), ivec3(0), ivec3(1));
    return 1u << uint(s.x + s.y * 2 + s.z * 4);
}

/*
 * 地形の頂点からボクセルへ書く (shadow.vsh)
 * playerPos: 頂点の player 空間位置 (揺れ適用前), midOffset: at_midBlock.xyz / 64
 * 同じブロックの全頂点が同じ値を書くので imageStore の競合は問題にならない
 * 呼ぶプログラムは IMG_VOXEL_BLOCK を定義する (lib/buffers/images.glsl)
 */
#ifdef IMG_VOXEL_BLOCK
void voxelizeTerrainVertex(vec3 playerPos, vec3 midOffset, int blockId, float emissionLevel) {
    ivec3 cell = ivec3(floor(playerToVoxel(playerPos + midOffset)));
    if (!isInVoxelVolume(cell)) return;
    int voxelId = blockIdToVoxelId(blockId);
    imageStore(voxelBlockImg, cell, uvec4(packVoxelBlock(voxelId, int(emissionLevel + 0.5))));
}
#endif

/*
 * エンティティの三角形をボクセルの表面占有として書く (shadow_entities.gsh / shadow_block.gsh)
 * 閉じた箱の表面だけ埋めれば、箱を横切るレイは必ず表面セルを通るので遮蔽判定には十分
 * 呼ぶプログラムは IMG_VOXEL_ENTITY を定義する
 */
// サンプル間隔 = サブセル (0.5 ブロック) の半分。これより粗いと斜めの面に穴が開く
const float ENTITY_VOXEL_SAMPLES_PER_BLOCK = 4.0;
// 1 辺あたりの分割上限。巨大な三角形 (エンダードラゴン等) で GS が重くなり過ぎないように
const int ENTITY_VOXEL_MAX_SPLIT = 16;

#ifdef IMG_VOXEL_ENTITY
void voxelizeEntityTriangle(vec3 p0, vec3 p1, vec3 p2, bool isCurrentPlayer) {
    vec3 v0 = playerToVoxel(p0);
    vec3 v1 = playerToVoxel(p1);
    vec3 v2 = playerToVoxel(p2);
    // 体積の外の三角形は丸ごと捨てる (遠くのエンティティで無駄な atomic を出さない)
    vec3 lo = min(v0, min(v1, v2));
    vec3 hi = max(v0, max(v1, v2));
    if (any(greaterThanEqual(lo, vec3(VOXEL_SIZE))) || any(lessThan(hi, vec3(0.0)))) return;

    float edge = max(length(v1 - v0), max(length(v2 - v0), length(v2 - v1)));
    int n = clamp(int(ceil(edge * ENTITY_VOXEL_SAMPLES_PER_BLOCK)), 1, ENTITY_VOXEL_MAX_SPLIT);
    uint playerShift = isCurrentPlayer ? 8u : 0u;
    // 直前に書いたセル・ビットと同じなら atomic を省く (小さい三角形はほぼ全サンプルが同じサブセルに落ちる)
    ivec3 lastCell = ivec3(-1);
    uint lastBit = 0u;
    for (int i = 0; i <= n; i++) {
        for (int j = 0; j <= n - i; j++) {
            vec3 p = v0 + (v1 - v0) * (float(i) / float(n)) + (v2 - v0) * (float(j) / float(n));
            ivec3 cell = ivec3(floor(p));
            if (!isInVoxelVolume(cell)) continue;
            uint bit = entitySubcellBit(p);
            if (cell == lastCell && bit == lastBit) continue;
            lastCell = cell;
            lastBit = bit;
            imageAtomicOr(voxelEntityImg, cell, bit | (bit << playerShift));
        }
    }
}
#endif

#endif
