/*
 * 植物・葉の揺れ (surface モジュール)
 * gbuffers と shadow パスの両方から呼ぶ (影と本体の揺れを一致させるため)
 * ボクセル化には揺れ適用前の位置を使う (light モジュールの voxelizeTerrainVertex に渡すのは元の位置)
 *
 * 揺れはワールド座標の連続関数なので、隣り合うブロックで共有される頂点 (背の高い草の継ぎ目・コンブ・葉) は同じだけ動き、隙間が開かない
 */
#ifndef SURFACE_WAVING_GLSL
#define SURFACE_WAVING_GLSL

const float WIND_SPEED = 1.0;
const float WAVE_AMP_SHORT = 0.11;      // 草花の先端
const float WAVE_AMP_TALL = 0.09;       // 2 ブロックの植物の継ぎ目 (上半分の先端はこの 2 倍)
const float WAVE_AMP_LEAVES = 0.035;
const float WAVE_AMP_VINES = 0.04;
const float WAVE_AMP_UNDERWATER = 0.07;
const float WAVE_AMP_LILY = 0.015;

// 風の変位 (水平)。ゆっくりした突風の強弱と細かい揺れの和
vec3 windOffset(vec3 worldPos) {
    float t = frameTimeCounter * WIND_SPEED;
    float gust = 0.65 + 0.35 * sin(t * 0.21 + worldPos.x * 0.023 + worldPos.z * 0.017);
    float storm = 1.0 + rainStrength * 0.8 + thunderStrength * 1.2;
    vec3 off;
    off.x = sin(t * 1.7 + worldPos.x * 0.62 + worldPos.z * 0.31) * 0.65 + sin(t * 3.3 + worldPos.z * 1.37 + worldPos.y) * 0.25;
    off.z = sin(t * 1.3 + worldPos.z * 0.51 + worldPos.x * 0.43) * 0.65 + sin(t * 2.9 + worldPos.x * 1.13 - worldPos.y) * 0.25;
    off.y = sin(t * 2.3 + worldPos.x * 0.9 + worldPos.z * 0.7) * 0.15;
    return off * gust * storm;
}

// 水流の変位 (水中植物)。天候に関係なく一定方向に揺らす
vec3 currentOffset(vec3 worldPos) {
    float t = frameTimeCounter;
    return vec3(
        sin(t * 1.1 + worldPos.y * 0.8 + worldPos.x * 0.4) * 0.8 + 0.3,
        0.0,
        sin(t * 0.9 + worldPos.y * 0.7 + worldPos.z * 0.5) * 0.6
    );
}

/*
 * playerPos: 頂点の player 空間位置, blockId: mc_Entity.x
 * isTopVertex: 頂点がブロック上側か (根元固定の草で根元を揺らさないため。at_midBlock.y < 0 で判定可)
 */
vec3 applyWaving(vec3 playerPos, int blockId, bool isTopVertex, float skyLight) {
    vec3 worldPos = playerPos + cameraPosition;
    // 屋内や洞窟の植物は風が届かないので弱める
    float exposure = 0.25 + 0.75 * smoothstep(0.3, 0.9, skyLight);
#ifdef WAVING_PLANTS
    if (blockId == BLOCK_PLANT_SHORT || blockId == BLOCK_CROPS) {
        if (isTopVertex) playerPos += windOffset(worldPos) * WAVE_AMP_SHORT * exposure;
    } else if (blockId == BLOCK_PLANT_TALL_LOWER) {
        if (isTopVertex) playerPos += windOffset(worldPos) * WAVE_AMP_TALL * exposure;
    } else if (blockId == BLOCK_PLANT_TALL_UPPER) {
        playerPos += windOffset(worldPos) * WAVE_AMP_TALL * (isTopVertex ? 2.0 : 1.0) * exposure;
    } else if (blockId == BLOCK_VINES) {
        playerPos += windOffset(worldPos) * WAVE_AMP_VINES * exposure;
    } else if (blockId == BLOCK_UNDERWATER_PLANT) {
        playerPos += currentOffset(worldPos) * WAVE_AMP_UNDERWATER;
    } else if (blockId == BLOCK_LILY_PAD) {
        playerPos.y += sin(frameTimeCounter * 1.4 + worldPos.x * 0.7 + worldPos.z * 0.9) * WAVE_AMP_LILY;
    }
#endif
#ifdef WAVING_LEAVES
    if (blockId == BLOCK_LEAVES) playerPos += windOffset(worldPos) * WAVE_AMP_LEAVES * exposure;
#endif
    return playerPos;
}

#endif
