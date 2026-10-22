/*
 * ボクセル空間 (カメラ追従のブロック単位グリッド)
 * - セル (0,0,0) のワールド座標 = cameraBlock - VOXEL_HALF
 * - voxelPos = playerPos + cameraFract + VOXEL_HALF。セル = ivec3(floor(voxelPos))
 * - 前フレームのデータは「今のセル + getVoxelFrameOffset()」に格納されている
 */
#ifndef COMMON_VOXEL_SPACE_GLSL
#define COMMON_VOXEL_SPACE_GLSL

const ivec3 VOXEL_SIZE = ivec3(VOXEL_SIZE_X, VOXEL_SIZE_Y, VOXEL_SIZE_Z);
const ivec3 VOXEL_HALF = VOXEL_SIZE / 2;

// Iris の cameraPositionInt は切り捨てなので、負の座標でも床関数になるよう補正する
ivec3 getCameraBlock() { return cameraPositionInt + ivec3(floor(cameraPositionFract)); }
vec3 getCameraFract() { return cameraPositionFract - floor(cameraPositionFract); }
ivec3 getPrevCameraBlock() { return previousCameraPositionInt + ivec3(floor(previousCameraPositionFract)); }

vec3 playerToVoxel(vec3 playerPos) { return playerPos + getCameraFract() + vec3(VOXEL_HALF); }
vec3 voxelToPlayer(vec3 voxelPos) { return voxelPos - getCameraFract() - vec3(VOXEL_HALF); }

ivec3 playerToVoxelCell(vec3 playerPos) { return ivec3(floor(playerToVoxel(playerPos))); }

bool isInVoxelVolume(ivec3 cell) {
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, VOXEL_SIZE));
}

bool isInVoxelVolume(vec3 voxelPos) {
    return all(greaterThanEqual(voxelPos, vec3(0.0))) && all(lessThan(voxelPos, vec3(VOXEL_SIZE)));
}

// 今フレームのセル c に対応する前フレームのセル = c + getVoxelFrameOffset()
ivec3 getVoxelFrameOffset() { return getCameraBlock() - getPrevCameraBlock(); }

// 体積の端に近づくほど 0 に落ちる重み (外側はバニラのライトマップへフォールバックさせる)
float voxelEdgeFade(vec3 voxelPos, float margin) {
    vec3 d = min(voxelPos, vec3(VOXEL_SIZE) - voxelPos);
    return saturate(minOf(d) / margin);
}

#endif
