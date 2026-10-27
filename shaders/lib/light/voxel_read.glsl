/*
 * ボクセルのブロック ID の読み取り (light モジュール)
 * voxel.glsl の軽い部分。block_data の SSBO を宣言したくないプログラムはこちらだけを読む
 */
#ifndef LIGHT_VOXEL_READ_GLSL
#define LIGHT_VOXEL_READ_GLSL

#include "/lib/buffers/images.glsl"

int unpackVoxelBlockId(uint v) { return int(v & 0xFFFu); }

// 範囲の判定をしない読み取り。呼ぶ側が isInVoxelVolume を済ませている所で使う
int fetchVoxelBlockId(ivec3 cell) {
    return unpackVoxelBlockId(texelFetch(voxelBlockSampler, cell, 0).r);
}

#endif
