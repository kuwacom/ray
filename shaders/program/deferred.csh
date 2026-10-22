/*
 * deferred (compute): floodfill の 1 ステップ伝搬 + ブロック光源・エンティティ光源のグローバルリスト登録
 * gbuffers_entities / shadow_entities が今フレームに登録したエンティティ光源 (voxelEmitImg + 蓄積表) もここで取り込む
 * light モジュール (lib/light)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_BLOCK
#define IMG_VOXEL_EMIT
#define IMG_FLOOD
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
// Iris はリテラルしか読めないので VOXEL_VOLUME ごとに書く (VOXEL_SIZE / 8)
#if VOXEL_VOLUME == 0
    const ivec3 workGroups = ivec3(16, 8, 16);
#elif VOXEL_VOLUME == 1
    const ivec3 workGroups = ivec3(24, 12, 24);
#elif VOXEL_VOLUME == 2
    const ivec3 workGroups = ivec3(32, 16, 32);
#else
    const ivec3 workGroups = ivec3(48, 16, 48);
#endif

// 1 ステップあたりの減衰。6 近傍平均と組み合わせて見た目の到達距離を決める
const float FLOOD_DECAY = 0.995;

/*
 * 液体 (溶岩) の直接光: 表面のセルを水平 FLUID_LIGHT_SPACING 間隔で間引いて登録する
 * 全セルを登録するとネザーの溶岩の海でライトビン (64 個) が溢れて光源がちらつくため。
 * 間引いた分は放射を増やして平均の明るさを保ち、到達半径を縮めてビンの混雑を抑える
 */
const int FLUID_LIGHT_SPACING = 4;
const float FLUID_LIGHT_EMISSION_MUL = 8.0;
const float FLUID_LIGHT_RANGE_MUL = 0.7;
const float FLUID_LIGHT_SIZE = 1.5;

// エンティティ光源の塊: 代表セルの判定半径 (局所最大) と重心を集める半径
const int ENTITY_REP_RADIUS = 1;
const int ENTITY_GATHER_RADIUS = 2;

// 雷: 到達半径の倍率と、着弾点から光源を持ち上げる高さ (細長い光を 1 点で近似するため)
const float LIGHTNING_RANGE_MUL = 2.0;
const float LIGHTNING_HEIGHT = 3.0;

vec3 loadPrevFlood(ivec3 cell) {
    ivec3 prev = cell + getVoxelFrameOffset();
    if (!isInVoxelVolume(prev)) return vec3(0.0);
    return floodWritesA() ? imageLoad(floodImgB, prev).rgb : imageLoad(floodImgA, prev).rgb;
}

void registerLight(vec3 voxelPos, float range, vec3 emission, float size, bool isBlock) {
    uint slot = atomicAdd(globalLights.count, 1u);
    if (slot >= uint(MAX_GLOBAL_LIGHTS)) {
        atomicAdd(globalLights.overflow, 1u);
        return;
    }
    if (isBlock) atomicAdd(globalLights.blockCount, 1u);
    else atomicAdd(globalLights.entityCount, 1u);
    globalLights.lights[slot].posRadius = vec4(voxelPos, range);
    globalLights.lights[slot].colorSize = vec4(emission, size);
}

int cellRank(ivec3 c) { return c.x + c.y * VOXEL_SIZE.x + c.z * VOXEL_SIZE.x * VOXEL_SIZE.y; }

// 同じ光源インデックスの近傍セルにより上位のものがあれば、このセルは代表ではない
bool isEntityLightRepresentative(ivec3 cell, uint key) {
    uint index = key & 255u;
    int rank = cellRank(cell);
    for (int z = -ENTITY_REP_RADIUS; z <= ENTITY_REP_RADIUS; z++)
    for (int y = -ENTITY_REP_RADIUS; y <= ENTITY_REP_RADIUS; y++)
    for (int x = -ENTITY_REP_RADIUS; x <= ENTITY_REP_RADIUS; x++) {
        ivec3 n = cell + ivec3(x, y, z);
        if ((x == 0 && y == 0 && z == 0) || !isInVoxelVolume(n)) continue;
        uint k = imageLoad(voxelEmitImg, n).r;
        if ((k & 255u) != index) continue;
        if (k > key || (k == key && cellRank(n) > rank)) return false;
    }
    return true;
}

// 塊に属するセルの頂点位置の平均 (蓄積表に無いセルはセル中心で代用)
vec3 entityLightCentroid(ivec3 cell, uint key) {
    uint index = key & 255u;
    vec3 sum = vec3(0.0);
    float total = 0.0;
    for (int z = -ENTITY_GATHER_RADIUS; z <= ENTITY_GATHER_RADIUS; z++)
    for (int y = -ENTITY_GATHER_RADIUS; y <= ENTITY_GATHER_RADIUS; y++)
    for (int x = -ENTITY_GATHER_RADIUS; x <= ENTITY_GATHER_RADIUS; x++) {
        ivec3 n = cell + ivec3(x, y, z);
        if (!isInVoxelVolume(n)) continue;
        if ((imageLoad(voxelEmitImg, n).r & 255u) != index) continue;
        float count;
        vec3 localSum;
        if (entityAccFind(n, count, localSum)) {
            sum += vec3(n) * count + localSum;
            total += count;
        } else {
            sum += vec3(n) + 0.5;
            total += 1.0;
        }
    }
    return total > 0.0 ? sum / total : vec3(cell) + 0.5;
}

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID);
    if (!isInVoxelVolume(cell)) return;
    ivec3 worldCell = getCameraBlock() - VOXEL_HALF + cell;

    // packed は NVIDIA の GLSL で予約語なので変数名に使わない
    uint voxelData = imageLoad(voxelBlockImg, cell).r;
    int voxelId = unpackVoxelBlockId(voxelData);
    vec3 emission = vec3(0.0);

    int lightIndex = getBlockLightIndex(voxelId);
    if (lightIndex != LIGHT_NONE) {
        LightDef d = getLightDef(lightIndex);
        float level = resolveLightLevel(d, float(unpackVoxelEmission(voxelData)));
        /*
         * 揺らぎは直接光 (光源リスト) だけに掛け、floodfill の種には掛けない
         * floodfill は 1 フレームに 1 セルずつ広がるので、揺れる種は遅れて波のように伝わり、
         * 直接光の当たらない影の側が光源と位相のずれた明滅になっていた
         */
        emission = lightEmission(d, level);
        vec3 flickered = emission * lightFlicker(d.params.y, uvec3(worldCell + 0x4000));
        float range = lightRange(d, level);
        if ((d.info.x & LIGHT_FLAG_FLUID) != 0u) {
            bool surface = unpackVoxelBlockId(imageLoad(voxelBlockImg, cell + ivec3(0, 1, 0)).r) != voxelId;
            bool anchor = ((worldCell.x | worldCell.z) & (FLUID_LIGHT_SPACING - 1)) == 0;
            if (surface && anchor && level > 0.5) {
                registerLight(vec3(cell) + d.shape.xyz, range * FLUID_LIGHT_RANGE_MUL,
                    flickered * FLUID_LIGHT_EMISSION_MUL, FLUID_LIGHT_SIZE, true);
            }
        } else if (level > 0.5) {
            registerLight(vec3(cell) + d.shape.xyz, range, flickered, d.shape.w, true);
        }
    }

    // エンティティ光源 (地形に同じ光源がある時は二重に数えない)
    uint emitKey = imageLoad(voxelEmitImg, cell).r;
    if (emitKey != 0u && lightIndex == LIGHT_NONE && isEntityLightRepresentative(cell, emitKey)) {
        LightDef d = getLightDef(int(emitKey & 255u));
        float level = float((emitKey >> 8u) & 15u);
        vec3 e = lightEmission(d, level);
        registerLight(entityLightCentroid(cell, emitKey), lightRange(d, level), e * lightFlicker(d.params.y, uvec3(worldCell + 0x8000)), d.shape.w, false);
        emission = max(emission, e);
    }

#ifdef GLOWING_ENTITY_LIGHTS
    // 雷は 1 スレッドだけが登録する
    if (cell == ivec3(0) && lightningBoltPosition.w > 0.5) {
        vec3 p = playerToVoxel(lightningBoltPosition.xyz + vec3(0.0, LIGHTNING_HEIGHT, 0.0));
        if (isInVoxelVolume(p)) {
            LightDef d = getLightDef(LIGHT_ENTITY_LIGHTNING);
            registerLight(p, lightRange(d, 15.0) * LIGHTNING_RANGE_MUL, lightEmission(d, 15.0), d.shape.w, false);
        }
    }
#endif

#ifdef FLOODFILL
    vec3 light = vec3(0.0);
    if (!isVoxelOpaque(voxelId)) {
        light = loadPrevFlood(cell + ivec3(1, 0, 0)) + loadPrevFlood(cell - ivec3(1, 0, 0))
              + loadPrevFlood(cell + ivec3(0, 1, 0)) + loadPrevFlood(cell - ivec3(0, 1, 0))
              + loadPrevFlood(cell + ivec3(0, 0, 1)) + loadPrevFlood(cell - ivec3(0, 0, 1));
        light *= (FLOOD_DECAY / 6.0) * floodCellTransmittance(voxelId);
    }
    light = max(light, emission);

    if (floodWritesA()) imageStore(floodImgA, cell, vec4(light, 1.0));
    else imageStore(floodImgB, cell, vec4(light, 1.0));
#endif
}
