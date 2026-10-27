/*
 * deferred_a (compute): グローバル光源リストをワールド空間のライトビンへ振り分ける
 * 1 スレッド = 1 光源。光源の到達球が重なるビン全部に登録する
 * ここでエンティティ光源の蓄積表の受け付けを締め切る
 *
 * 容量 (LIGHT_BIN_CAPACITY) を超えたビンで残す光源 (LIGHT_CULL_MODE)
 *   0: 到着順。atomicAdd の順 (スレッドの実行順で毎フレーム変わる) で先着の分だけ残すので、溢れたビンの光源が毎フレーム入れ替わってちらつく
 *   1/2: 重要度の降順。各ビンの枠を「atomicMax で大きい方を残し、小さい方を次の枠へ運ぶ」鎖にすると、
 *        到着順に関係なく枠 j に j+1 番目に大きいキーが残る (atomic の挿入ソート)。最後の 1 枠には外れたうち最大のキーが残る
 *        重要度は光源とビンの位置関係だけで決まり、カメラの向きや揺らぎに依らないので、止まった光源の組は毎フレーム同じ
 * スレッド 0 は次フレームの光源の間引き距離 (globalLights.cullDistance) も決める (LIGHT_CULL_MODE 1/2)
 * light モジュール (lib/light)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_FRAME_DATA_WRITE
#define SSBO_GLOBAL_LIGHTS_WRITE
#define SSBO_LIGHT_BINS_WRITE
#include "/lib/common/common.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light.glsl"

layout(local_size_x = 64) in;
// Iris はリテラルしか読めないので LIGHT_MAX_COUNT ごとに書く (LIGHT_MAX_COUNT / 64)
#if LIGHT_MAX_COUNT == 1024
    const ivec3 workGroups = ivec3(16, 1, 1);
#elif LIGHT_MAX_COUNT == 2048
    const ivec3 workGroups = ivec3(32, 1, 1);
#elif LIGHT_MAX_COUNT == 4096
    const ivec3 workGroups = ivec3(64, 1, 1);
#else
    const ivec3 workGroups = ivec3(128, 1, 1);
#endif

#if LIGHT_CULL_MODE != 0
/*
 * ビンの中の順位でビンの中心からの距離を少しだけ効かせる係数 (1 / (1 + 係数 x 中心までの距離))
 * ビンの中にある光源はビンの箱までの距離が全部 0 で同順位になるので、中心に近い方を残す
 */
const float BIN_CENTER_WEIGHT = 0.1;

// 光源 i がビン (箱 lo..lo+SIZE) の着色点に与えうる寄与の目安
float binImportance(vec3 p, float r, float power, vec3 lo, float boxDist) {
    float centerDist = distance(p, lo + 0.5 * float(LIGHT_BIN_SIZE));
    float centerTerm = 1.0 / (1.0 + BIN_CENTER_WEIGHT * centerDist);
    #if LIGHT_CULL_MODE == 1
    return centerTerm / (1.0 + boxDist);
    #else
    return power * lightFalloff(boxDist, r) * centerTerm;
    #endif
}

void insertBinKey(int bin, uint key) {
    uint base = lightBinBase(bin);
    const uint last = uint(LIGHT_BIN_CAPACITY);
    atomicAdd(lightBins.binCount[bin], 1u);
    /*
     * 枠の値は増えるだけで、枠 j の値は枠 j-1 を通ったものなので常に枠 j-1 以下 (降順)
     * 読んだ値がキーより大きい枠は atomicMax しても素通りするだけなので、二分探索で飛ばす (古い値を読んでも飛ばし過ぎない)
     */
    uint lo = 0u;
    uint hi = last;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        if (lightBins.binLights[base + mid] > key) lo = mid + 1u;
        else hi = mid;
    }
    for (uint j = lo; j <= last && key != 0u; j++) {
        uint old = atomicMax(lightBins.binLights[base + j], key);
        key = min(old, key);
    }
}

/*
 * 次フレームの間引き距離。登録しようとした光源の距離の分布から、総数が上限の LIGHT_CULL_BUDGET 倍に収まる距離を求め、
 * 今の値をそこへ 1 フレームあたり一定の速さで寄せる (急に変えると境界の光源がまとめて消える・現れる)
 * ただし上限を超える距離 (溢れて到着順で捨てられる) には一度も置かない
 */
const float LIGHT_CULL_BUDGET = 0.85;
const float LIGHT_CULL_GROW = 0.5;   // 1 フレームに広げる距離 (ブロック)
const float LIGHT_CULL_SHRINK = 2.0; // 1 フレームに縮める距離 (ブロック)

void updateCullDistance() {
    const float maxDist = float(LIGHT_CULL_BUCKETS) * LIGHT_CULL_BUCKET_WIDTH;
    float soft = LIGHT_CULL_NONE;
    float hard = LIGHT_CULL_NONE;
    float budgetSoft = float(MAX_GLOBAL_LIGHTS) * LIGHT_CULL_BUDGET;
    float budgetHard = float(MAX_GLOBAL_LIGHTS);
    float cum = 0.0;
    for (int b = 0; b < LIGHT_CULL_BUCKETS; b++) {
        float h = float(globalLights.cullHist[b]);
        globalLights.cullHist[b] = 0u;
        if (soft >= LIGHT_CULL_NONE && cum + h > budgetSoft) soft = (float(b) + (budgetSoft - cum) / h) * LIGHT_CULL_BUCKET_WIDTH;
        if (hard >= LIGHT_CULL_NONE && cum + h > budgetHard) hard = (float(b) + (budgetHard - cum) / h) * LIGHT_CULL_BUCKET_WIDTH;
        cum += h;
    }
    float cur = min(globalLights.cullDistance, maxDist);
    // 初回 (0 や NaN) は間引かない状態から始める
    if (!(cur > 0.0)) cur = maxDist;
    cur = cur > soft ? max(soft, cur - LIGHT_CULL_SHRINK) : min(soft, cur + LIGHT_CULL_GROW);
    cur = min(cur, hard);
    globalLights.cullDistance = (soft >= LIGHT_CULL_NONE && cur >= maxDist) ? LIGHT_CULL_NONE : cur;
}
#endif

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i == 0u) {
        frameData.lightStats.z = 1u;
#if LIGHT_CULL_MODE != 0
        updateCullDistance();
#endif
    }
    if (i >= globalLightCount()) return;

    vec4 posRadius = globalLights.lights[i].posRadius;
    vec3 p = posRadius.xyz;
    float r = posRadius.w;
    if (r <= 0.0) return;

    ivec3 offset = lightBinOffset();
    ivec3 bmin = clamp(ivec3(floor((p + vec3(offset) - r) / float(LIGHT_BIN_SIZE))), ivec3(0), LIGHT_BIN_GRID - 1);
    ivec3 bmax = clamp(ivec3(floor((p + vec3(offset) + r) / float(LIGHT_BIN_SIZE))), ivec3(0), LIGHT_BIN_GRID - 1);
    float r2 = r * r;
#if LIGHT_CULL_MODE != 0
    float power = globalLights.lightPower[i];
    uint tie = pcg3d(uvec3(ivec3(floor(p)) + getCameraBlock() - VOXEL_HALF + 0x4000)).x;
#endif
    for (int z = bmin.z; z <= bmax.z; z++)
    for (int y = bmin.y; y <= bmax.y; y++)
    for (int x = bmin.x; x <= bmax.x; x++) {
        vec3 lo = vec3(ivec3(x, y, z) * LIGHT_BIN_SIZE - offset);
        vec3 q = clamp(p, lo, lo + float(LIGHT_BIN_SIZE));
        float d2 = lengthSqr(q - p);
        if (d2 > r2) continue;
        int bin = x + y * LIGHT_BIN_GRID.x + z * LIGHT_BIN_GRID.x * LIGHT_BIN_GRID.y;
#if LIGHT_CULL_MODE == 0
        uint slot = atomicAdd(lightBins.binCount[bin], 1u);
        if (slot < uint(LIGHT_BIN_CAPACITY)) lightBins.binLights[lightBinBase(bin) + slot] = i;
#else
        insertBinKey(bin, packLightBinKey(binImportance(p, r, power, lo, sqrt(d2)), i, tie));
#endif
    }
}
