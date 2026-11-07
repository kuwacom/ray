/*
 * 水に入った自分 (三人称のプレイヤー) の水面より下の判定 (surface モジュール)
 * Iris 26.1 は自分のスキン・防具を半透明の前方シェーディング (gbuffers_entities_translucent) で水より先に描き、その色が
 * 半透明の層に残るので、水の合成が水の中の脚を屈折も吸収も無いまま水面の上に重ねていた
 */
#ifndef SURFACE_WATER_SELF_GLSL
#define SURFACE_WATER_SELF_GLSL

//@include "/lib/common/voxel_space.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/light/voxel_read.glsl"

// 上に水の無い水のブロックの水面の高さ (バニラの水源の上面。Ray の水面は形を動かさず法線だけで波を描くので、描く水面もこの高さ)
const float WATER_SELF_SURFACE = 8.0 / 9.0;
// 水面を探して上へ辿るセルの数。これより深い所は辿った分の深さとみなす (吸収はそこで飽和している)
const int WATER_SELF_SEARCH = 4;
// 視線の上向きの cos の下限 (かすめ角で水の中の長さが無限にならない)
const float WATER_SELF_MIN_COS = 0.1;

bool waterSelfIsWater(ivec3 cell) {
    if (!isInVoxelVolume(cell)) return false;
    int id = fetchVoxelBlockId(cell);
    return id == BLOCK_WATER || id == BLOCK_UNDERWATER_PLANT;
}

// 水面からの深さ (ブロック)。水の中でなければ負
float waterSelfDepth(vec3 playerPos) {
    vec3 v = playerToVoxel(playerPos);
    ivec3 cell = ivec3(floor(v));
    if (!waterSelfIsWater(cell)) return -1.0;
    for (int k = 1; k <= WATER_SELF_SEARCH; k++) {
        if (!waterSelfIsWater(cell + ivec3(0, k, 0))) return float(cell.y + k - 1) + WATER_SELF_SURFACE - v.y;
    }
    return float(WATER_SELF_SEARCH);
}

#endif
