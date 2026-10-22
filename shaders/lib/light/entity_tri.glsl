/*
 * エンティティの三角形による光源シャドウ (light モジュール)
 * 占有ボクセル (0.5 ブロックのサブセル) では影が箱型になり、プレイヤーの影が「体の形」ではなく
 * 「1 ブロック分が欠けた」ように見えた。shadow_entities.gsh が三角形そのものを SSBO 4 に書き、
 * 光源シャドウのレイは 2 段の AABB (グループ -> クラスタ) で絞ってから Möller-Trumbore で判定する
 *
 * 容量の配分: [プレイヤー | カメラ近傍 | 遠方 (floodfill で照らされている所)] を別々のカウンタで確保する
 *   GS の実行順は決まらないので、優先度は領域ごとの容量で付ける。プレイヤーは専用領域なので必ず入る
 *   近傍で溢れた三角形は遠方の領域へ回し、それでも溢れたら従来の占有ボクセルへ書く (形は箱に戻るが影は消えない)
 * クラスタ (8 スロット) とグループ (128 スロット) の AABB は GS が atomicMin/Max で直接広げる
 *   同じ描画呼び出しの連続した三角形はほぼ連続したスロットに入るので、クラスタは部位の面程度の小さい箱になる
 *   (順序が崩れても箱が大きくなるだけで、判定結果は変わらない)
 *   大きさは計測で決めた (32/256 よりモブ 8 体の場面で約 2 倍速い)
 * 透明部分: 三角形の重心座標を 8x8 に区切った各セルのアルファを GS で読み、64bit のマスクにする
 *   (スケルトンの肋骨・スキンの外側レイヤー等。全部透明な三角形は保持しない)
 */
#ifndef LIGHT_ENTITY_TRI_GLSL
#define LIGHT_ENTITY_TRI_GLSL

const uint ENT_TRI_CAPACITY = uint(min(LIGHT_ENTITY_TRIANGLES, ENT_TRI_MAX));
// プレイヤー 1 人分 (外側レイヤー・防具・手持ち・エリトラ込み) に足りる量。ENT_TRI_GROUP の倍数
const uint ENT_TRI_PLAYER_CAP = 1024u;
// 近傍と遠方で残りを半分ずつ (容量の候補はどれも ENT_TRI_GROUP の倍数に割り切れる)
const uint ENT_TRI_OTHER_CAP = (ENT_TRI_CAPACITY - ENT_TRI_PLAYER_CAP) / 2u;
// 近傍: 手持ち光源の到達範囲を含む距離。遠方: これより先は占有ボクセルに任せる (player 空間の距離)
const float ENT_TRI_NEAR_DIST = 16.0;
const float ENT_TRI_FAR_DIST = 48.0;
// 遠方の三角形は floodfill の照度がこれ以上の所だけ保持する (光の届かない所の影は見えない)
const float ENT_TRI_FAR_MIN_FLOOD = 0.01;
// アルファの閾値 (shadow_entities.fsh の discard と同じ)
const float ENT_TRI_ALPHA_CUTOFF = 0.1;
// 着色点側で無視する距離。法線方向の押し出し (TRACE_NORMAL_OFFSET) と合わせて自分の面での即ヒットを防ぐ
const float ENT_TRI_T_MIN = 0.01;
// AABB の判定を少し太らせる (頂点の丸め誤差で縁の三角形を取りこぼさないため)
const float ENT_TRI_AABB_PAD = 1e-3;

uint entityTriRegionStart(int region) {
    return region == 0 ? 0u : (region == 1 ? ENT_TRI_PLAYER_CAP : ENT_TRI_PLAYER_CAP + ENT_TRI_OTHER_CAP);
}
uint entityTriRegionCap(int region) { return region == 0 ? ENT_TRI_PLAYER_CAP : ENT_TRI_OTHER_CAP; }

// float の大小と uint の大小が一致する符号化 (atomicMin/Max で AABB を広げるため)
uint entityTriOrderedFromFloat(float f) {
    uint u = floatBitsToUint(f);
    return (u & 0x80000000u) != 0u ? ~u : (u | 0x80000000u);
}
float entityTriFloatFromOrdered(uint u) {
    return uintBitsToFloat((u & 0x80000000u) != 0u ? (u & 0x7FFFFFFFu) : ~u);
}

/*
 * 三角形の透明部分のマスク。重心座標 (a, b) (a = e1 方向, b = e2 方向) を 8x8 に区切り、
 * 三角形に入る 36 セルの中心でテクスチャのアルファを読む
 */
uvec2 entityTriAlphaMask(vec2 uv0, vec2 uv1, vec2 uv2, float vertexAlpha) {
    uvec2 mask = uvec2(0u);
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8 - j; i++) {
            vec2 b = (vec2(i, j) + 0.5) / 8.0;
            vec2 uv = uv0 + (uv1 - uv0) * b.x + (uv2 - uv0) * b.y;
            if (textureLod(gtexture, uv, 0.0).a * vertexAlpha < ENT_TRI_ALPHA_CUTOFF) continue;
            int bit = i + j * 8;
            if (bit < 32) mask.x |= 1u << uint(bit);
            else mask.y |= 1u << uint(bit - 32);
        }
    }
    return mask;
}

void entityTriGrowBounds(bool group, uint index, vec3 lo, vec3 hi) {
    uint base = index * 6u;
    for (int k = 0; k < 3; k++) {
        uint mn = entityTriOrderedFromFloat(lo[k]);
        uint mx = entityTriOrderedFromFloat(hi[k]);
        if (group) {
            atomicMin(entityTris.groupBounds[base + uint(k)], mn);
            atomicMax(entityTris.groupBounds[base + 3u + uint(k)], mx);
        } else {
            atomicMin(entityTris.clusterBounds[base + uint(k)], mn);
            atomicMax(entityTris.clusterBounds[base + 3u + uint(k)], mx);
        }
    }
}

/*
 * shadow_entities.gsh から三角形 1 つを書く。p* は player 空間, uv* はテクスチャ座標
 * 戻り値 false = 保持しなかった (遠すぎる・容量超過)。呼び出し側は占有ボクセルへ退避する
 * 透明・縮退・体積外の三角形は遮蔽物にならないので true (何もしない) を返す
 */
bool storeEntityTriangle(vec3 p0, vec3 p1, vec3 p2, vec2 uv0, vec2 uv1, vec2 uv2, float vertexAlpha, bool isPlayer) {
    vec3 v0 = playerToVoxel(p0);
    vec3 v1 = playerToVoxel(p1);
    vec3 v2 = playerToVoxel(p2);
    vec3 lo = min(v0, min(v1, v2));
    vec3 hi = max(v0, max(v1, v2));
    if (any(greaterThanEqual(lo, vec3(VOXEL_SIZE))) || any(lessThan(hi, vec3(0.0)))) return true;
    vec3 e1 = v1 - v0;
    vec3 e2 = v2 - v0;
    if (lengthSqr(cross(e1, e2)) < 1e-12) return true;

    int region = 0;
    if (!isPlayer) {
        vec3 c = (p0 + p1 + p2) / 3.0;
        float d = length(c);
        if (d < ENT_TRI_NEAR_DIST) {
            region = 1;
        } else if (d < ENT_TRI_FAR_DIST) {
            region = 2;
#ifdef FLOODFILL
            ivec3 cell = ivec3(floor(playerToVoxel(c)));
            if (!isInVoxelVolume(cell) || maxOf(fetchFlood(cell)) < ENT_TRI_FAR_MIN_FLOOD) return false;
#endif
        } else {
            return false;
        }
    }

    uvec2 mask = entityTriAlphaMask(uv0, uv1, uv2, vertexAlpha);
    if (mask.x == 0u && mask.y == 0u) return true;

    uint slot = atomicAdd(entityTris.counts[region], 1u);
    if (region == 1 && slot >= entityTriRegionCap(1)) {
        /*
         * 近傍が溢れたら遠方の領域を使う (近傍を優先する。遠方が空いている場面が多い)
         * GS の実行順は決まらないので、溢れると近いモブが箱の影に戻っていた
         */
        region = 2;
        slot = atomicAdd(entityTris.counts[2], 1u);
    }
    if (slot >= entityTriRegionCap(region)) {
        atomicAdd(entityTris.counts[3], 1u);
        return false;
    }
    uint index = entityTriRegionStart(region) + slot;
    entityTris.tris[index] = EntityTriangle(v0, mask.x, e1, mask.y, e2, 0u);
    entityTriGrowBounds(false, index / uint(ENT_TRI_CLUSTER), lo, hi);
    entityTriGrowBounds(true, index / uint(ENT_TRI_GROUP), lo, hi);
    return true;
}

// begin.csh: 今フレームの三角形を空にする (1 スレッド = 1 クラスタ / グループの AABB)
void clearEntityTriangles(uint i) {
    if (i < uint(ENT_TRI_MAX_CLUSTERS * 6)) entityTris.clusterBounds[i] = (i % 6u) < 3u ? 0xFFFFFFFFu : 0u;
    if (i < uint(ENT_TRI_MAX_GROUPS * 6)) entityTris.groupBounds[i] = (i % 6u) < 3u ? 0xFFFFFFFFu : 0u;
    if (i < 4u) entityTris.counts[i] = 0u;
}

// 区間 [t0, t1] のレイが AABB (bounds の base から 6 uint) に入るか
bool entityTriRayBox(bool group, uint index, vec3 ro, vec3 rdInv, float t0, float t1) {
    uint base = index * 6u;
    vec3 lo, hi;
    if (group) {
        lo = vec3(entityTriFloatFromOrdered(entityTris.groupBounds[base]), entityTriFloatFromOrdered(entityTris.groupBounds[base + 1u]),
                  entityTriFloatFromOrdered(entityTris.groupBounds[base + 2u]));
        hi = vec3(entityTriFloatFromOrdered(entityTris.groupBounds[base + 3u]), entityTriFloatFromOrdered(entityTris.groupBounds[base + 4u]),
                  entityTriFloatFromOrdered(entityTris.groupBounds[base + 5u]));
    } else {
        lo = vec3(entityTriFloatFromOrdered(entityTris.clusterBounds[base]), entityTriFloatFromOrdered(entityTris.clusterBounds[base + 1u]),
                  entityTriFloatFromOrdered(entityTris.clusterBounds[base + 2u]));
        hi = vec3(entityTriFloatFromOrdered(entityTris.clusterBounds[base + 3u]), entityTriFloatFromOrdered(entityTris.clusterBounds[base + 4u]),
                  entityTriFloatFromOrdered(entityTris.clusterBounds[base + 5u]));
    }
    vec3 a = (lo - ENT_TRI_AABB_PAD - ro) * rdInv;
    vec3 b = (hi + ENT_TRI_AABB_PAD - ro) * rdInv;
    float tn = max(maxOf(min(a, b)), t0);
    float tf = min(minOf(max(a, b)), t1);
    return tn <= tf;
}

// Möller-Trumbore (両面)。透明なセルに当たった場合は外れ
bool entityTriHit(uint index, vec3 ro, vec3 dir, float t0, float t1) {
    EntityTriangle tri = entityTris.tris[index];
    vec3 p = cross(dir, tri.e2);
    float det = dot(tri.e1, p);
    if (abs(det) < 1e-12) return false;
    float inv = 1.0 / det;
    vec3 s = ro - tri.v0;
    float a = dot(s, p) * inv;
    if (a < 0.0 || a > 1.0) return false;
    vec3 q = cross(s, tri.e1);
    float b = dot(dir, q) * inv;
    if (b < 0.0 || a + b > 1.0) return false;
    float t = dot(tri.e2, q) * inv;
    if (t < t0 || t > t1) return false;
    ivec2 c = min(ivec2(vec2(a, b) * 8.0), ivec2(7));
    if (c.x + c.y > 7) c.y = 7 - c.x;
    int bit = c.x + c.y * 8;
    uint word = bit < 32 ? tri.maskLo : tri.maskHi;
    return (word & (1u << uint(bit & 31))) != 0u;
}

/*
 * ボクセル空間のレイ ro + dir * t (dir は単位ベクトル) が区間 [t0, t1] でエンティティの三角形に当たるか
 * player: 自分 (current_player) の三角形, others: それ以外のエンティティの三角形
 */
bool traceEntityTriangles(vec3 ro, vec3 dir, float t0, float t1, bool player, bool others) {
    if (t1 <= t0) return false;
    vec3 rdInv = sign(dir + 1e-20) / max(abs(dir), vec3(1e-7));
    for (int region = 0; region < 3; region++) {
        if (region == 0 ? !player : !others) continue;
        uint n = min(entityTris.counts[region], entityTriRegionCap(region));
        if (n == 0u) continue;
        uint start = entityTriRegionStart(region);
        uint end = start + n;
        for (uint g = start / uint(ENT_TRI_GROUP); g * uint(ENT_TRI_GROUP) < end; g++) {
            if (!entityTriRayBox(true, g, ro, rdInv, t0, t1)) continue;
            uint gEnd = min(end, (g + 1u) * uint(ENT_TRI_GROUP));
            for (uint c = g * uint(ENT_TRI_GROUP / ENT_TRI_CLUSTER); c * uint(ENT_TRI_CLUSTER) < gEnd; c++) {
                if (!entityTriRayBox(false, c, ro, rdInv, t0, t1)) continue;
                uint cEnd = min(gEnd, (c + 1u) * uint(ENT_TRI_CLUSTER));
                for (uint i = c * uint(ENT_TRI_CLUSTER); i < cEnd; i++) {
                    if (entityTriHit(i, ro, dir, t0, t1)) return true;
                }
            }
        }
    }
    return false;
}

#endif
