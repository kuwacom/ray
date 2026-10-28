/*
 * 色付き floodfill (light モジュール)
 * deferred.csh が毎フレーム 1 ステップ伝搬する。偶数フレームは A に書いて B を読む (奇数は逆)
 * 値はセルの照度 (BLOCKLIGHT_ILLUMINANCE 倍済み)。読む側は今フレームに書かれた方を使う
 */
#ifndef LIGHT_FLOODFILL_GLSL
#define LIGHT_FLOODFILL_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/buffers/images.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/voxel.glsl"

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
        if (isVoxelOpaque(fetchVoxelBlockId(c))) continue;
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

/*
 * 着色点のすぐ横の壁からの照り返しの割合 (rgb, BLOCKLIGHT_BOUNCE)。照度に掛けて足す
 * floodfill の伝搬にも壁の色を混ぜているが、光源シャドウ ON では floodfill は FLOODFILL_STRENGTH 倍の控えめな間接光なので、
 * トレースした直接光に埋もれて壁の色がほとんど見えない。受け取り側で、法線に垂直な 4 方向
 * BOUNCE_LOCAL_REACH ブロック以内の不透明な壁を探し、壁の平均の色 x 近さの重みを返す
 * 壁に当たる光は分からないので、呼び出し側が着色点の照度で代用する (壁ぎわの床と壁はほぼ同じ距離で光源に照らされる)
 */
const float BOUNCE_LOCAL_REACH = 2.0;
// 壁に接した所の重み (隣の大きな壁が見上げた半球の半分を占める時の形態係数)
const float BOUNCE_LOCAL_FORM_FACTOR = 0.5;
// 壁 1 面の反射率の上限 (伝搬の照り返しと同じ)
const float BOUNCE_MAX_REFLECTANCE = 0.9;

vec3 wallBounceReflectance(int voxelId) {
    return min(getBlockAlbedo(voxelId) * BLOCKLIGHT_BOUNCE, vec3(BOUNCE_MAX_REFLECTANCE));
}

vec3 localWallBounce(vec3 playerPos, vec3 geoNormal) {
    vec3 sum = vec3(0.0);
#ifdef FLOODFILL
    if (BLOCKLIGHT_BOUNCE <= 0.0) return sum;
    vec3 v = playerToVoxel(playerPos + geoNormal * 0.5);
    if (!isInVoxelVolume(v)) return sum;
    vec3 an = abs(geoNormal);
    int axis = an.x >= an.y && an.x >= an.z ? 0 : (an.y >= an.z ? 1 : 2);
    for (int k = 0; k < 4; k++) {
        int a = (axis + 1 + (k >> 1)) % 3;
        int s = (k & 1) == 0 ? 1 : -1;
        float f = fract(v[a]);
        // 着色点から壁の面までの距離 = 自分のセルの境界まで + 越えたセルの数
        float dist = s > 0 ? 1.0 - f : f;
        ivec3 c = ivec3(floor(v));
        for (int d = 0; d < int(BOUNCE_LOCAL_REACH); d++) {
            if (dist >= BOUNCE_LOCAL_REACH) break;
            c[a] += s;
            int id = unpackVoxelBlockId(readVoxelBlock(c));
            if (isVoxelOpaque(id)) {
                sum += wallBounceReflectance(id) * (1.0 - dist / BOUNCE_LOCAL_REACH);
                break;
            }
            dist += 1.0;
        }
    }
#endif
    return sum * BOUNCE_LOCAL_FORM_FACTOR;
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
