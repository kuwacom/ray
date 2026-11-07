/*
 * ボクセルのブロック ID の読み取り (light モジュール)
 * voxel.glsl の軽い部分。block_data の SSBO を宣言したくないプログラムはこちらだけを読む
 */
#ifndef LIGHT_VOXEL_READ_GLSL
#define LIGHT_VOXEL_READ_GLSL

//@include "/lib/buffers/images.glsl"

// 水のセルの発光の欄 (上位 4bit) の印: 上面が水源より低い流れる水
const uint VOXEL_WATER_FLOWING = 1u;

int unpackVoxelBlockId(uint v) { return int(v & 0xFFFu); }

// 範囲の判定をしない読み取り。呼ぶ側が isInVoxelVolume を済ませている所で使う
uint fetchVoxelBlockData(ivec3 cell) {
    return texelFetch(voxelBlockSampler, cell, 0).r;
}

int fetchVoxelBlockId(ivec3 cell) {
    return unpackVoxelBlockId(fetchVoxelBlockData(cell));
}

#endif
