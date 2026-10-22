/*
 * 色付き floodfill (light モジュール)
 * deferred.csh が毎フレーム 1 ステップ伝搬する。偶数フレームは A に書いて B を読む (奇数は逆)
 * 値はセルの照度 (BLOCKLIGHT_ILLUMINANCE 倍済み)。読む側は今フレームに書かれた方を使う
 */
#ifndef LIGHT_FLOODFILL_GLSL
#define LIGHT_FLOODFILL_GLSL

bool floodWritesA() { return (frameCounter & 1) == 0; }

vec3 sampleFloodRaw(vec3 voxelPos) {
    vec3 uv = voxelPos / vec3(VOXEL_SIZE);
    return floodWritesA() ? texture(floodSamplerA, uv).rgb : texture(floodSamplerB, uv).rgb;
}

vec3 fetchFlood(ivec3 cell) {
    return floodWritesA() ? texelFetch(floodSamplerA, cell, 0).rgb : texelFetch(floodSamplerB, cell, 0).rgb;
}

/*
 * 固体セルを除外した手動トリリニア (漏れ対策)
 * ハードウェアのトリリニアは壁の向こうのセルや光を持たない固体セルを混ぜるので、
 * 角や薄い壁の際で光が漏れたり不自然に暗くなったりする。固体セルの重みを 0 にして正規化し直す
 */
vec3 sampleFloodFiltered(vec3 voxelPos) {
    vec3 p = voxelPos - 0.5;
    ivec3 base = ivec3(floor(p));
    vec3 f = p - vec3(base);
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 8; i++) {
        ivec3 o = ivec3(i & 1, (i >> 1) & 1, i >> 2);
        ivec3 c = base + o;
        if (!isInVoxelVolume(c)) continue;
        if (isVoxelOpaque(unpackVoxelBlockId(texelFetch(voxelBlockSampler, c, 0).r))) continue;
        vec3 w3 = mix(1.0 - f, f, vec3(o));
        float w = w3.x * w3.y * w3.z;
        sum += fetchFlood(c) * w;
        wsum += w;
    }
    return wsum > 1e-4 ? sum / wsum : vec3(0.0);
}

// floodfill が有効な範囲での重み (外では 0。呼び出し側がバニラのライトマップへ混ぜる)
float floodCoverage(vec3 playerPos) {
#ifdef FLOODFILL
    return voxelEdgeFade(playerToVoxel(playerPos), 8.0);
#else
    return 0.0;
#endif
}

/*
 * 面の位置 playerPos での floodfill 照度。法線方向に半セル押し出して自分のブロックの中を読まないようにする
 * 押し出し後の位置は法線軸ではセル中心になるので、残りの 2 軸だけが補間される
 */
vec3 sampleFloodfill(vec3 playerPos, vec3 normal) {
#ifdef FLOODFILL
    vec3 voxelPos = playerToVoxel(playerPos + normal * 0.5);
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    return sampleFloodFiltered(voxelPos);
#else
    return vec3(0.0);
#endif
}

// 体積内の任意点 (フォグ用。押し出しなし。大量に呼ばれるのでハードウェア補間で軽く済ませる)
vec3 sampleFloodfillVolume(vec3 playerPos) {
#ifdef FLOODFILL
    vec3 voxelPos = playerToVoxel(playerPos);
    if (!isInVoxelVolume(voxelPos)) return vec3(0.0);
    return sampleFloodRaw(voxelPos);
#else
    return vec3(0.0);
#endif
}

#endif
