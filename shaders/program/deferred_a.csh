/*
 * deferred_a (compute): グローバル光源リストをワールド空間のライトビンへ振り分ける
 * 1 スレッド = 1 光源。光源の到達球が重なるビン全部に atomicAdd で登録する (容量超過分は捨てる)
 * ここで binLights を上書きするので、エンティティ光源の蓄積表 (binLights の先頭) の受け付けを締め切る
 * light モジュール (lib/light)
 */
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 64) in;
const ivec3 workGroups = ivec3(64, 1, 1); // MAX_GLOBAL_LIGHTS / 64

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i == 0u) frameData.lightStats.z = 1u;
    if (i >= globalLightCount()) return;

    vec4 posRadius = globalLights.lights[i].posRadius;
    vec3 p = posRadius.xyz;
    float r = posRadius.w;
    if (r <= 0.0) return;

    ivec3 bmin = clamp(ivec3(floor((p - r) / float(LIGHT_BIN_SIZE))), ivec3(0), LIGHT_BIN_GRID - 1);
    ivec3 bmax = clamp(ivec3(floor((p + r) / float(LIGHT_BIN_SIZE))), ivec3(0), LIGHT_BIN_GRID - 1);
    float r2 = r * r;
    for (int z = bmin.z; z <= bmax.z; z++)
    for (int y = bmin.y; y <= bmax.y; y++)
    for (int x = bmin.x; x <= bmax.x; x++) {
        vec3 lo = vec3(x, y, z) * float(LIGHT_BIN_SIZE);
        vec3 q = clamp(p, lo, lo + float(LIGHT_BIN_SIZE));
        if (lengthSqr(q - p) > r2) continue;
        int bin = x + y * LIGHT_BIN_GRID.x + z * LIGHT_BIN_GRID.x * LIGHT_BIN_GRID.y;
        uint slot = atomicAdd(lightBins.binCount[bin], 1u);
        if (slot < uint(LIGHT_BIN_CAPACITY)) lightBins.binLights[uint(bin * LIGHT_BIN_CAPACITY) + slot] = i;
    }
}
