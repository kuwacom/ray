/*
 * deferred1 (compute): ブロック光源の直接光トレース (LIGHT_TRACE_RES 分の 1 解像度)
 * 1 スレッド = 1 低解像度テクセル (受け持つフル解像度テクセルは毎フレーム巡回, lib/light/light_select.glsl)
 *
 * 光源の選び方 (着色点のライトビンから)
 *   重み = 影なし照度の輝度 (放射 x 減衰 x NdotL)
 *   上位 (LIGHT_TRACE_COUNT - 1) 個は確定でトレース、残り全部からリザーバサンプリングで 1 個を
 *   重みに比例して選び 1/確率 倍でトレースする (選ばれなかった光源も影付きで不偏に寄与する)
 *   LIGHT_TRACE_COUNT = 1 の時は上位 1 個だけをトレースし、残りはその可視率で近似する
 *   動くエンティティの着色点はくじを引かず、残りで一番明るい 1 個を決まった光源としてトレースする
 *   (くじの光源がフレームごとに変わると、動く体の上で色の斑点になる)
 *
 * 出力 (左上 viewSize / LIGHT_TRACE_RES)
 *   blockLightRawImg: rgb = 影あり照度 S (幾何法線), a = 視線方向の距離 (デノイズの深度判定用, 空は -1)
 *   blockLightAuxImg: rgb = 同じ選択での影なし照度 U, a = 寄与最大の光源インデックス (鏡面用, encodeLightIndex)
 * light モジュール (lib/light)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_BLOCKLIGHT_RAW
#define IMG_BLOCKLIGHT_AUX
//@include "/lib/common/common.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/common/encoding.glsl"
//@include "/lib/common/gbuffer.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/buffers/slots.glsl"
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
#include "/lib/buffers/global_lights.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/entity_ids.glsl"
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
#include "/lib/settings/capabilities.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/light/hand_pose.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/buffers/slots.glsl"
// END GENERATED includes

layout(local_size_x = 8, local_size_y = 8) in;
#if LIGHT_TRACE_RES == 1
    const vec2 workGroupsRender = vec2(1.0, 1.0);
#elif LIGHT_TRACE_RES == 2
    const vec2 workGroupsRender = vec2(0.5, 0.5);
#else
    const vec2 workGroupsRender = vec2(0.25, 0.25);
#endif

#if LIGHT_TRACE_COUNT >= 2
    const int DET_COUNT = LIGHT_TRACE_COUNT - 1;
    #define STOCHASTIC_SLOT
#else
    const int DET_COUNT = 1;
#endif
/*
 * LIGHT_TRACE_SPLIT: 光の当たる光源が LIGHT_TRACE_COUNT より多いピクセルで、レイの割り振りを変える
 * 上位を確定で追っても、同じくらいの明るさの光源が並ぶ所 (アメジストの群れ) では確定の分が全体の一部にしかならず、
 * 残りの大半を 1 本のくじが受け持つので、本数のわりに可視率のノイズが減らない。
 * 確定で追うのは、くじで 1 回以上当たる見込みの光源 (重みが全体の 1 / LIGHT_TRACE_COUNT 以上) だけにし、
 * 残りの本数はすべて重みに比例したくじ (重複あり、1/確率 倍) に回す
 */
#if defined LIGHT_TRACE_SPLIT && LIGHT_TRACE_COUNT >= 2
    #define TRACE_SPLIT
    const int SPLIT_RAYS = LIGHT_TRACE_COUNT;
    // 枠ごとの乱数は 1 つの乱数を 1/枠数ずつずらして作る (枠ごとにハッシュを引くと光源 x 枠の数だけ重くなる)
    const float SPLIT_STEP = 1.0 / float(SPLIT_RAYS);
    const int SPLIT_CONTACT_RANK = min(LIGHT_CONTACT_SHADOW_COUNT, LIGHT_TRACE_COUNT - 1) - 1;
#endif
// 接触影を付ける光源数 (寄与の大きい順)。全光源に付けると EXTREME で重くなり過ぎる
const int CONTACT_SHADOW_LIGHTS = LIGHT_CONTACT_SHADOW_COUNT;
const float LIGHT_CONTACT_LENGTH = 1.25;
const float DITHER_STEP = 0.618034;
const int LIGHT_CONTACT_STEPS = 8;

/*
 * 光源 1 つの可視率 (色付き)。終点を光源半径の円板上で揺らして半影を作る
 */
vec3 traceBlockLight(int li, vec3 fromVoxel, vec3 playerPos, vec3 geoNormal, uint flags, float skipStart,
                     vec2 xi, float dither, bool contact) {
    LightInstance L = globalLights.lights[li];
    vec3 lp = L.posRadius.xyz;
    vec3 toL = lp - fromVoxel;
    float dist = length(toL);
    vec3 dir = toL / max(dist, EPS);
    mat3 tbn = tbnFromNormal(dir);
    float a = xi.y * TAU;
    vec2 disk = sqrt(xi.x) * vec2(cos(a), sin(a)) * lightJitterRadius(L);
    vec3 target = lp + tbn[0] * disk.x + tbn[1] * disk.y;
    // 片面の光源 (かまど) は口の面のすぐ内側にあり、揺らした終点が口の前のセルへ出る。トレースは終点のセルを判定しないので、
    // 口の前を塞いだ石の向こうの床まで照らしていた。終点を光源のセルの中に留める
    if (L.colorSize.a < 0.0) target = clamp(target, floor(lp) + LIGHT_ONE_SIDED_CELL_MARGIN, floor(lp) + (1.0 - LIGHT_ONE_SIDED_CELL_MARGIN));
    vec3 vis = traceVisibility(fromVoxel, target, flags, dither, skipStart, lightEntitySkip(L));
#ifdef LIGHT_CONTACT_SHADOWS
    if (contact && maxOf(vis) > 0.0) {
        // 光源自身の形 (たいまつの棒・ランタンの枠) で遮らないよう手前で止める
        float len = min(LIGHT_CONTACT_LENGTH, dist - 0.5);
        vis *= lightContactShadow(playerPos, geoNormal, normalize(target - fromVoxel), len, LIGHT_CONTACT_STEPS, dither);
    }
#endif
    return blockLightShadow(vis);
}

void main() {
    ivec2 low = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(low, lightTraceLowResSize()))) return;
    ivec2 src = lightTraceSourceTexel(low, frameCounter);

    float depth = texelFetch(depthtex0, src, 0).r;
    if (depth >= 1.0) {
        imageStore(STORE_BLOCKLIGHT_RAW, low, vec4(0.0, 0.0, 0.0, -1.0));
        imageStore(blockLightAuxImg, low, vec4(0.0, 0.0, 0.0, encodeLightIndex(-1)));
        return;
    }
    vec2 uv = (vec2(src) + 0.5) / viewSize();
    vec3 viewPos = screenToView(vec3(uv, fixHandDepth(depth)));
    vec3 playerPos = viewToPlayer(viewPos);
    vec3 geoNormal = octDecode(unpack2x8(texelFetch(colortex2, src, 0).b));
    int material = readMaterialId(src);
    // 上向きに固定した植物は光源の方を向いた面として選び (light_select.glsl の plantLightNormal)、接触影は付けない
    // (細い葉どうしを厚みのある板として遮り、葉ごとの縁に黒い線が出る。植物の影はボクセルのトレースで付く)
    bool plant = isUpNormalPlant(material, geoNormal);

    vec3 shadowed = vec3(0.0);
    vec3 unshadowed = vec3(0.0);
    int dominant = -1;
    vec3 fromVoxel = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);

    if (isInVoxelVolume(fromVoxel)) {
        int bin = lightBinIndex(ivec3(fromVoxel));
        uint n = lightBinCount(bin);

        int topIdx[DET_COUNT];
        float topW[DET_COUNT];
        vec3 topE[DET_COUNT];
        for (int j = 0; j < DET_COUNT; j++) { topIdx[j] = -1; topW[j] = 0.0; topE[j] = vec3(0.0); }
        float restSum = 0.0;
        vec3 restTotal = vec3(0.0);
        int restIdx = -1;
        float restW = 0.0;
        vec3 restE = vec3(0.0);
    #ifdef STOCHASTIC_SLOT
        int nextIdx = -1;
        float nextW = 0.0;
        vec3 nextE = vec3(0.0);
    #endif
    #ifdef TRACE_SPLIT
        // くじの枠ごとのリザーバ。枠 0 は restIdx と同じ乱数なので、1 から持つ
        int splitIdx[SPLIT_RAYS];
        float splitW[SPLIT_RAYS];
        vec3 splitE[SPLIT_RAYS];
        for (int m = 0; m < SPLIT_RAYS; m++) { splitIdx[m] = -1; splitW[m] = 0.0; splitE[m] = vec3(0.0); }
        uint lit = 0u;
        float litSum = 0.0;
    #endif
        uint seed = pcgHash(uint(low.x) | (uint(low.y) << 16u)) ^ pcgHash(uint(frameCounter));

        for (uint k = 0u; k < n; k++) {
            int li = lightBinEntry(bin, k);
            LightInstance L = lightBinLight(bin, k);
            vec3 ln = geoNormal;
            vec3 lg = geoNormal;
            float scale = plant ? plantLightNormal(L, fromVoxel, ln, lg) : 1.0;
            vec3 e = evalLightIrradiance(L, fromVoxel, ln, lg) * scale;
            float w = luminance(e);
            if (w <= 0.0) continue;
    #ifdef TRACE_SPLIT
            lit++;
            litSum += w;
    #endif
            // 上位 DET_COUNT 個を挿入ソートで保つ。押し出された光源は残りの集合 (リザーバ) へ
            int ci = li;
            float cw = w;
            vec3 ce = e;
            for (int j = 0; j < DET_COUNT; j++) {
                if (cw > topW[j]) {
                    int ti = topIdx[j]; float tw = topW[j]; vec3 te = topE[j];
                    topIdx[j] = ci; topW[j] = cw; topE[j] = ce;
                    ci = ti; cw = tw; ce = te;
                }
            }
            if (ci < 0 || cw <= 0.0) continue;
            restSum += cw;
            restTotal += ce;
            if (hash1(seed + k * 0x9E3779B9u) * restSum < cw) {
                restIdx = ci;
                restW = cw;
                restE = ce;
            }
    #ifdef TRACE_SPLIT
            float splitU = hash1(seed + k * 0x9E3779B9u);
            for (int m = 1; m < SPLIT_RAYS; m++) {
                if (fract(splitU + float(m) * SPLIT_STEP) * restSum < cw) {
                    splitIdx[m] = ci; splitW[m] = cw; splitE[m] = ce;
                }
            }
    #endif
    #ifdef STOCHASTIC_SLOT
            if (cw > nextW) {
                nextIdx = ci;
                nextW = cw;
                nextE = ce;
            }
    #endif
        }

        uint flags = blockLightTraceFlags();
        float skipStart = TRACE_ENTITY_SKIP_START;
        if (isHandMaterial(material)) {
            // 一人称の手は自分の体のボクセルの中にあるので自分では遮らない
            flags &= ~TRACE_PLAYER;
        } else if (isEntityMaterial(material) || material == MAT_BLOCK_ENTITY) {
            skipStart = TRACE_ENTITY_SKIP_START_ENTITY;
        }
        vec4 bn = blueNoise(low);
        dominant = topIdx[0];

    #ifdef TRACE_SPLIT
        // 動くエンティティは下のくじを引かない決まった光源の扱いのまま
        bool split = lit > uint(LIGHT_TRACE_COUNT) && !isMovingEntityMaterial(material);
        if (split) {
            int det = 0;
            for (int j = 0; j < SPLIT_RAYS - 1; j++) {
                if (topW[j] * float(SPLIT_RAYS) < litSum) break;
                det++;
            }
            splitIdx[0] = restIdx; splitW[0] = restW; splitE[0] = restE;
            // 確定で追わない上位の光源をくじの集合へ戻す (重み付きリザーバは足す順によらない)
            for (int j = 0; j < DET_COUNT; j++) {
                if (j < det || topIdx[j] < 0) continue;
                restSum += topW[j];
                float u = hash1(seed + (n + uint(j)) * 0x9E3779B9u);
                for (int m = 0; m < SPLIT_RAYS; m++) {
                    if (fract(u + float(m) * SPLIT_STEP) * restSum < topW[j]) {
                        splitIdx[m] = topIdx[j]; splitW[m] = topW[j]; splitE[m] = topE[j];
                    }
                }
            }
            float pickScale = restSum / float(SPLIT_RAYS - det);
            // くじの枠は同じ分布で独立なので、レイ r には枠 r を使う (r - det で引くと添字が実行時に決まり、配列がローカルメモリに落ちる)
            for (int r = 0; r < SPLIT_RAYS; r++) {
                int li;
                vec3 e;
                if (r < det) {
                    li = topIdx[min(r, DET_COUNT - 1)];
                    e = topE[min(r, DET_COUNT - 1)];
                } else {
                    li = splitIdx[r];
                    e = splitE[r] * (pickScale / max(splitW[r], EPS));
                }
                if (li < 0) continue;
                vec2 xi = fract(bn.xy + r2Sequence(r));
                float dither = fract(bn.z + DITHER_STEP * float(r));
                // 接触影は、割り振りを変えない時と同じく上位 CONTACT_SHADOW_LIGHTS 個の光源だけに付ける
                // (くじの光源すべてに付けると、接触影の付く光の割合が増えて物の根元が暗くなる)
                bool contact = r < det ? r < CONTACT_SHADOW_LIGHTS : splitW[r] >= topW[SPLIT_CONTACT_RANK];
                shadowed += e * traceBlockLight(li, fromVoxel, playerPos, geoNormal, flags, skipStart, xi, dither, contact && !plant);
                unshadowed += e;
            }
        } else {
    #endif
        for (int j = 0; j < DET_COUNT; j++) {
            if (topIdx[j] < 0) break;
            vec2 xi = fract(bn.xy + r2Sequence(j));
            float dither = fract(bn.z + DITHER_STEP * float(j));
            vec3 vis = traceBlockLight(topIdx[j], fromVoxel, playerPos, geoNormal, flags, skipStart, xi, dither, j < CONTACT_SHADOW_LIGHTS && !plant);
            shadowed += topE[j] * vis;
            unshadowed += topE[j];
    #ifndef STOCHASTIC_SLOT
            // 1 光源しかトレースしない設定では、残りを最大光源の可視率で近似する
            shadowed += restTotal * luminance(vis);
            unshadowed += restTotal;
    #endif
        }
    #ifdef STOCHASTIC_SLOT
        int pickIdx = restIdx;
        vec3 pickE = restIdx >= 0 ? restE * (restSum / restW) : vec3(0.0);
        // 動くエンティティは自分の速度を持たず、デノイズの履歴が体の別の場所の値になる。くじの光源が
        // フレームごとに変わると色の比が振れたまま混ざって斑点になるので、くじの代わりに残りで一番明るい
        // 光源を決まった 1 本としてトレースする。それ以外は、トレースした光源の可視率 (照度の輝度で重み付け)
        // で近似する (最大光源だけの可視率だと、その影の中が他の光源にも照らされず黒く硬い縞になる)
        bool moving = isMovingEntityMaterial(material);
        if (moving) {
            pickIdx = nextIdx;
            pickE = nextE;
        }
        if (pickIdx >= 0) {
            vec2 xi = fract(bn.xy + r2Sequence(DET_COUNT));
            float dither = fract(bn.w + 0.5);
            shadowed += pickE * traceBlockLight(pickIdx, fromVoxel, playerPos, geoNormal, flags, skipStart, xi, dither, false);
            unshadowed += pickE;
        }
        if (moving) {
            vec3 farE = max(restTotal - pickE, vec3(0.0));
            shadowed += farE * (luminance(shadowed) / max(luminance(unshadowed), EPS));
            unshadowed += farE;
        }
    #endif
    #ifdef TRACE_SPLIT
        }
    #endif
    }

    imageStore(STORE_BLOCKLIGHT_RAW, low, vec4(shadowed, -viewPos.z));
    imageStore(blockLightAuxImg, low, vec4(unshadowed, encodeLightIndex(dominant)));
}
