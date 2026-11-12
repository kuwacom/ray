/*
 * deferred (compute): floodfill の 1 ステップ伝搬 + ブロック光源・エンティティ光源のグローバルリスト登録
 * gbuffers_entities / shadow_entities が今フレームに登録したエンティティ光源 (voxelEmitImg + 蓄積表) もここで取り込む
 * light モジュール (lib/light)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_GLOBAL_LIGHTS_WRITE
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_BLOCK
#define IMG_VOXEL_EMIT
#define IMG_FLOOD
//@include "/lib/common/common.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/light/light.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/common/color.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
// END GENERATED includes

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

/*
 * 溶岩の光 (設定 LAVA_LIGHT = 1 のときの倍率)。表示上の溶岩本体は頭打ちで、近くの壁は直接光だけで白く飛んで本体より明るくなる
 * 直接光は 0.4 倍に抑えて近い壁を本体より暗くし、洞窟の遠い壁と床は floodfill の種を 10 倍にして持ち上げる
 */
const float LAVA_DIRECT_GAIN = 0.4;
const float LAVA_FLOOD_GAIN = 10.0;

// エンティティ光源の塊: 代表セルの判定半径 (局所最大) と重心を集める半径
const int ENTITY_REP_RADIUS = 1;
const int ENTITY_GATHER_RADIUS = 2;

// 雷: 到達半径の倍率と、着弾点から光源を持ち上げる高さ (細長い光を 1 点で近似するため)
const float LIGHTNING_RANGE_MUL = 2.0;
const float LIGHTNING_HEIGHT = 3.0;

vec3 loadPreviousFlood(ivec3 cell) {
    ivec3 prev = cell + getVoxelFrameOffset();
    if (!isInVoxelVolume(prev)) return vec3(0.0);
    return floodWritesA() ? imageLoad(floodImgB, prev).rgb : imageLoad(floodImgA, prev).rgb;
}

/*
 * 照り返し (BLOCKLIGHT_BOUNCE): 隣の不透明なセルを、0 (光を吸う壁) の代わりに「自分の照度 x 壁の平均の色 x 係数」として数える
 * 壁の色が伝搬に混ざり、色の付いた部屋では光がその色に寄る。1 面あたりの反射率を 1 未満に抑えるので、
 * 1 ステップの増幅は 6 近傍平均 x FLOOD_DECAY (< 1) を超えず、どの係数でも発散しない (値は光源の放射以下に収まる)
 * 壁の向こうへは何も渡さない (自分の照度を返すだけ) ので、薄い壁越しの漏れも増えない
 * 1 面の反射率は BOUNCE_MAX_REFLECTANCE (lib/light/floodfill.glsl の wallBounceReflectance) で抑える
 */

// これより暗いセルは照り返しを計算しない (体積の大半は光の届かない暗いセルで、隣の壁を読む分だけ重くなるため)
const float FLOOD_BOUNCE_MIN_ILLUMINANCE = 1e-4;

vec3 floodBounce(ivec3 cell) {
    vec3 self = loadPreviousFlood(cell);
    if (maxOf(self) < FLOOD_BOUNCE_MIN_ILLUMINANCE) return vec3(0.0);
    vec3 reflectance = vec3(0.0);
    for (int i = 0; i < 6; i++) {
        ivec3 n = cell;
        n[i >> 1] += (i & 1) == 0 ? 1 : -1;
        if (!isInVoxelVolume(n)) continue;
        int id = unpackVoxelBlockId(imageLoad(voxelBlockImg, n).r);
        if (isVoxelOpaque(id)) reflectance += wallBounceReflectance(id);
    }
    return reflectance * self;
}

/*
 * 光源の総数が GLOBAL_LIGHTS_MAX を超える時の間引き (LIGHT_CULL_MODE 1/2)
 * 到着順で溢れた分を捨てると、毎フレーム違う光源が消えてちらつく。代わりにカメラからの距離で遠い光源から外す
 * 距離は 1 = 光源まで, 2 = 光源の届く球の縁まで (明るく遠くまで届く光源ほど残る)
 * 間引く距離 (deferred_a が前フレームの分布から決め、ゆっくり動かす) の手前 LIGHT_CULL_FADE ブロックで滑らかに弱める
 */
const float LIGHT_CULL_FADE = 8.0;

float lightCullDistance(vec3 voxelPos, float range) {
    float d = distance(voxelPos, playerToVoxel(vec3(0.0)));
#if LIGHT_CULL_MODE == 1
    return d;
#else
    return max(d - range, 0.0);
#endif
}

void registerLight(vec3 voxelPos, float range, vec3 emission, float power, float size, bool isBlock) {
#if LIGHT_CULL_MODE != 0
    float cullDist = lightCullDistance(voxelPos, range);
    int bucket = min(int(cullDist / LIGHT_CULL_BUCKET_WIDTH), LIGHT_CULL_BUCKETS - 1);
    atomicAdd(globalLights.cullHist[bucket], 1u);
    float cutoff = globalLights.cullDistance;
    // 0 (起動直後) と LIGHT_CULL_NONE は間引かない
    if (cutoff > 0.0 && cutoff < LIGHT_CULL_NONE) {
        if (cullDist >= cutoff) {
            atomicAdd(globalLights.culled, 1u);
            return;
        }
        float fade = 1.0 - smoothstep(cutoff - LIGHT_CULL_FADE, cutoff, cullDist);
        emission *= fade;
        power *= fade;
    }
#endif
    uint slot = atomicAdd(globalLights.count, 1u);
    if (slot >= uint(GLOBAL_LIGHTS_MAX)) {
        atomicAdd(globalLights.overflow, 1u);
        return;
    }
    if (isBlock) atomicAdd(globalLights.blockCount, 1u);
    else atomicAdd(globalLights.entityCount, 1u);
    globalLights.lights[slot].posRadius = vec4(voxelPos, range);
    globalLights.lights[slot].colorSize = vec4(emission, size);
    globalLights.lightPower[slot] = power;
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
                    flickered * (FLUID_LIGHT_EMISSION_MUL * LAVA_DIRECT_GAIN * LAVA_LIGHT), luminance(emission) * (FLUID_LIGHT_EMISSION_MUL * LAVA_DIRECT_GAIN * LAVA_LIGHT), FLUID_LIGHT_SIZE, true);
            }
            emission *= LAVA_FLOOD_GAIN * LAVA_LIGHT;
        } else if (level > 0.5) {
            registerLight(vec3(cell) + d.shape.xyz, range, flickered, luminance(emission), d.shape.w, true);
        }
    }

    // エンティティ光源 (地形に同じ光源がある時は二重に数えない)
    uint emitKey = imageLoad(voxelEmitImg, cell).r;
    if (emitKey != 0u && lightIndex == LIGHT_NONE && isEntityLightRepresentative(cell, emitKey)) {
        LightDef d = getLightDef(int(emitKey & 255u));
        float level = float((emitKey >> 8u) & 15u);
        vec3 e = lightEmission(d, level);
        registerLight(entityLightCentroid(cell, emitKey), lightRange(d, level), e * lightFlicker(d.params.y, uvec3(worldCell + 0x8000)), luminance(e), d.shape.w, false);
        emission = max(emission, e);
    }

#ifdef GLOWING_ENTITY_LIGHTS
    // 雷は 1 スレッドだけが登録する
    if (cell == ivec3(0) && lightningBoltPosition.w > 0.5) {
        vec3 p = playerToVoxel(lightningBoltPosition.xyz + vec3(0.0, LIGHTNING_HEIGHT, 0.0));
        if (isInVoxelVolume(p)) {
            LightDef d = getLightDef(LIGHT_ENTITY_LIGHTNING);
            registerLight(p, lightRange(d, LIGHT_LEVEL_MAX) * LIGHTNING_RANGE_MUL, lightEmission(d, LIGHT_LEVEL_MAX), luminance(lightEmission(d, LIGHT_LEVEL_MAX)), d.shape.w, false);
        }
    }
#endif

#ifdef FLOODFILL
    vec3 light = vec3(0.0);
    if (!isVoxelOpaque(voxelId)) {
        light = loadPreviousFlood(cell + ivec3(1, 0, 0)) + loadPreviousFlood(cell - ivec3(1, 0, 0))
              + loadPreviousFlood(cell + ivec3(0, 1, 0)) + loadPreviousFlood(cell - ivec3(0, 1, 0))
              + loadPreviousFlood(cell + ivec3(0, 0, 1)) + loadPreviousFlood(cell - ivec3(0, 0, 1));
        if (BLOCKLIGHT_BOUNCE > 0.0) light += floodBounce(cell);
        light *= (FLOOD_DECAY / 6.0) * floodCellTransmittance(voxelId);
    }
    light = max(light, emission);

    if (floodWritesA()) imageStore(floodImgA, cell, vec4(light, 1.0));
    else imageStore(floodImgB, cell, vec4(light, 1.0));
#endif
}
