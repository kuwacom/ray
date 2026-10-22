/*
 * ボクセル空間のレイトレース (light モジュール)
 * Amanatides & Woo 1987 の DDA を自前実装する。ブロック形状 (LIGHT_SHAPE_TRACE)、
 * 半透明の色 (LIGHT_TRANSLUCENT_TINT)、エンティティのサブセル占有 (三角形方式では三角形, lib/light/entity_tri.glsl) を判定に使う
 * 画面空間の接触影 (screenSpaceShadow) もここに置く (ボクセルに入らない細部の補完)
 */
#ifndef LIGHT_TRACE_GLSL
#define LIGHT_TRACE_GLSL

// traceVisibility のフラグ
const uint TRACE_ENTITIES = 1u; // エンティティ占有で遮る (LIGHT_ENTITY_OCCLUSION)
const uint TRACE_PLAYER = 2u;   // 自分 (current_player) で遮る。一人称の手持ち光源では外す
const uint TRACE_TINT = 4u;     // 半透明ブロックで色付け
const uint TRACE_SHAPES = 8u;   // 部分形状の AABB で判定

// 最大ステップ数。到達半径 15 の光源を対角に辿ると 45 セル前後、雷 (半径 30) で 90 セル前後
const int TRACE_MAX_STEPS = 96;
// 透過率がこれを下回ったら完全な影として打ち切る
const float TRACE_MIN_TRANSMITTANCE = 0.01;
// 葉 1 セルの透過率 (完全に遮るとまばらな木の下が真っ暗になる)
const float TRACE_LEAVES_TRANSMITTANCE = 0.5;
// 着色点を幾何法線方向へ押し出す量 (ブロック)。開始セルを面の手前の空気セルに確定させる
const float TRACE_NORMAL_OFFSET = 0.05;
// エンティティ占有を無視する区間の既定値 (ブロック)。着色点自身・光源自身の体で遮らないため
const float TRACE_ENTITY_SKIP_START = 0.3;
const float TRACE_ENTITY_SKIP_START_ENTITY = 0.75; // 着色点がエンティティの表面の時
const float TRACE_ENTITY_SKIP_END = 0.75;

// 設定から既定のフラグを作る (設置光源用)
uint blockLightTraceFlags() {
    uint f = 0u;
#ifdef LIGHT_ENTITY_OCCLUSION
    f |= TRACE_ENTITIES;
#endif
#ifdef LIGHT_PLAYER_OCCLUSION
    f |= TRACE_PLAYER;
#endif
#ifdef LIGHT_TRANSLUCENT_TINT
    f |= TRACE_TINT;
#endif
#ifdef LIGHT_SHAPE_TRACE
    f |= TRACE_SHAPES;
#endif
    return f;
}

// 部分形状のうち、形状判定なしでも完全なブロックとして遮るもの (階段は 3/4 が埋まっている)
bool isShapeOccluderWithoutTrace(int voxelId) {
    return voxelId == BLOCK_STAIRS_BOTTOM || voxelId == BLOCK_STAIRS_TOP || voxelId == BLOCK_DOOR_CLOSED;
}

// 部分形状の AABB (最大 2 個) とレイ区間 [tEnter, tLeave] の交差。ro はセルローカルの原点
bool shapeIntersect(int voxelId, vec3 ro, vec3 rdInv, float tEnter, float tLeave, out float tHit, out vec3 hitNormal) {
    uvec4 s = getShape(getShapeIndex(voxelId));
    tHit = 1e9;
    hitNormal = vec3(0.0);
    bool hit = false;
    for (int b = 0; b < 2; b++) {
        vec3 bmin = unpackUnorm4x8(b == 0 ? s.x : s.z).xyz;
        vec3 bmax = unpackUnorm4x8(b == 0 ? s.y : s.w).xyz;
        if (any(greaterThan(bmin, bmax))) continue;
        vec3 t0 = (bmin - ro) * rdInv;
        vec3 t1 = (bmax - ro) * rdInv;
        vec3 tmin = min(t0, t1);
        vec3 tmax = max(t0, t1);
        float tn = max(maxOf(tmin), tEnter);
        float tf = min(minOf(tmax), tLeave);
        if (tn < tf && tn < tHit) {
            tHit = tn;
            hit = true;
            // 入射面の法線 = tmin が最大の軸の逆向き
            vec3 axis = vec3(equal(tmin, vec3(maxOf(tmin))));
            hitNormal = -sign(rdInv) * axis;
        }
    }
    return hit;
}

/*
 * ブロックボクセル 1 セルの透過率 (rgb)。origin/rdInv はレイ、[tEnter, tLeave] はセル内の区間
 */
vec3 voxelCellTransmittance(int id, ivec3 cell, vec3 origin, vec3 rdInv, float tEnter, float tLeave, uint flags) {
    if (id == BLOCK_SOLID || (id >= 10 && id < 100)) return vec3(0.0);
    if (id < 200) return id == BLOCK_LEAVES ? vec3(TRACE_LEAVES_TRANSMITTANCE) : vec3(1.0);
    if (id < 300) {
        if ((flags & TRACE_TINT) != 0u) {
            vec4 t = getTint(getTintIndex(id));
            vec3 cellT = t.rgb * (1.0 - t.a);
            /*
             * 水はセルを通る長さで減衰させる。1 セル 1 回の透過率だと、光が横切るセルの数が変わる所 (水のブロックの
             * 境目を受け面へ写した線) で明るさが 16% ずつ段になり、水の中の床や壁にブロックの境目の線が出る。ガラスは薄い板なので 1 回のまま
             */
            if (id == BLOCK_WATER) return pow(cellT, vec3(max(tLeave - tEnter, 0.0)));
            return cellT;
        }
        // 色付けしない時も遮光ガラスだけは光を止める (バニラでも光を通さない)
        return id == BLOCK_TINTED_GLASS ? vec3(0.0) : vec3(1.0);
    }
    if (id < 400) {
        if ((flags & TRACE_SHAPES) != 0u) {
            float tHit;
            vec3 n;
            return shapeIntersect(id, origin - vec3(cell), rdInv, tEnter, tLeave, tHit, n) ? vec3(0.0) : vec3(1.0);
        }
        return isShapeOccluderWithoutTrace(id) ? vec3(0.0) : vec3(1.0);
    }
    int light = getBlockLightIndex(id);
    if (light != LIGHT_NONE) {
        return (getLightDef(light).info.x & LIGHT_FLAG_OCCLUDES) != 0u ? vec3(0.0) : vec3(1.0);
    }
    return vec3(1.0);
}

// フラグに応じて使うサブセル占有ビット (8bit) を取り出す
uint entityOccupancyForFlags(uint raw, uint flags) {
    uint everyone = raw & VOXEL_ENTITY_MASK;
    uint player = (raw & VOXEL_PLAYER_MASK) >> 8u;
    bool ent = (flags & TRACE_ENTITIES) != 0u;
    bool ply = (flags & TRACE_PLAYER) != 0u;
    if (ent && ply) return everyone;
    // 自分と他のエンティティが同じサブセルにいると他方も消えるが、密着している時だけなので許容する
    if (ent) return everyone & ~player;
    if (ply) return player;
    return 0u;
}

/*
 * セル内の 2x2x2 サブセルを辿り、占有されたサブセルにレイ区間 [t0, t1] が入るか
 * ro はセルローカルの原点、dir は単位方向、rdInv = 1/dir (符号付き)
 */
bool traceSubcells(uint mask, vec3 ro, vec3 dir, vec3 rdInv, ivec3 stepDir, float t0, float t1) {
    if (mask == 0u) return false;
    if (mask == 0xFFu) return true;
    vec3 p = ro + dir * (t0 + 1e-4);
    ivec3 s = clamp(ivec3(floor(p * 2.0)), ivec3(0), ivec3(1));
    vec3 tiny = vec3(lessThan(abs(dir), vec3(1e-6)));
    // 1 セル内のサブセル境界は各軸 1 枚なので最大 4 サブセルを通る
    for (int k = 0; k < 4; k++) {
        if ((mask & (1u << uint(s.x + s.y * 2 + s.z * 4))) != 0u) return true;
        vec3 boundary = (vec3(s) + vec3(greaterThan(stepDir, ivec3(0)))) * 0.5;
        vec3 tb = mix((boundary - ro) * rdInv, vec3(1e9), tiny);
        float tn = minOf(tb);
        if (tn >= t1) return false;
        if (tb.x == tn) s.x += stepDir.x;
        else if (tb.y == tn) s.y += stepDir.y;
        else s.z += stepDir.z;
        if (any(lessThan(s, ivec3(0))) || any(greaterThan(s, ivec3(1)))) return false;
    }
    return false;
}

/*
 * fromVoxel -> toVoxel の透過率 (rgb, 0 = 完全に遮られた)。両端のセルは判定しない
 * (光源ブロック自身・着色点のブロック自身で遮らないため)
 * エンティティ占有は区間 [entSkipStart, 長さ - entSkipEnd] だけで判定する (着色点・光源自身の体を除くため)
 * 体積の外に出たら以降は遮蔽なしとみなす
 */
vec3 traceVisibilityEx(vec3 fromVoxel, vec3 toVoxel, uint flags, float dither, float entSkipStart, float entSkipEnd) {
    vec3 delta = toVoxel - fromVoxel;
    float len = length(delta);
    if (len < 1e-4) return vec3(1.0);
    vec3 dir = delta / len;

    ivec3 cell = ivec3(floor(fromVoxel));
    ivec3 endCell = ivec3(floor(toVoxel));
    /*
     * 三角形方式では両端が同じセルでも打ち切らない (下の DDA はすぐ抜ける)。三人称で手の光源が足元と同じセルにある時、
     * 足元のタイルだけ自分の三角形の判定が飛ばされ、影がタイルの境目で直線に切れていた
     */
#ifndef ENTITY_TRI_OCCLUSION
    if (cell == endCell) return vec3(1.0);
#endif

    ivec3 stepDir = ivec3(greaterThanEqual(dir, vec3(0.0))) * 2 - 1;
    vec3 tDelta = 1.0 / max(abs(dir), vec3(1e-7));
    vec3 rdInv = vec3(stepDir) * tDelta;
    vec3 fr = fromVoxel - vec3(cell);
    vec3 tMax = mix(fr, 1.0 - fr, vec3(greaterThan(stepDir, ivec3(0)))) * tDelta;

    bool testEntities = (flags & (TRACE_ENTITIES | TRACE_PLAYER)) != 0u;
    float entT0 = entSkipStart;
    float entT1 = len - entSkipEnd;

    vec3 transmit = vec3(1.0);
    /*
     * 着色点が水の中なら、始点のセルの水も通る長さで減衰させる。始点のセルは判定しないので、光が始点のセルを出るまでの
     * 水の分だけ減衰が抜ける。その長さはブロックの中の位置で変わり、水の中の床の明るさがブロックの境目で段になっていた
     */
    if ((flags & TRACE_TINT) != 0u && isInVoxelVolume(cell)) {
        int startId = int(texelFetch(voxelBlockSampler, cell, 0).r & 0xFFFu);
        if (startId == BLOCK_WATER) transmit = voxelCellTransmittance(startId, cell, fromVoxel, rdInv, 0.0, min(minOf(tMax), len), flags);
    }
    for (int i = 0; i < TRACE_MAX_STEPS && cell != endCell; i++) {
        float tEnter = minOf(tMax);
        if (tEnter >= len) break;
        if (tMax.x == tEnter) { cell.x += stepDir.x; tMax.x += tDelta.x; }
        else if (tMax.y == tEnter) { cell.y += stepDir.y; tMax.y += tDelta.y; }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; }
        if (cell == endCell || !isInVoxelVolume(cell)) break;
        float tLeave = min(minOf(tMax), len);

        int id = int(texelFetch(voxelBlockSampler, cell, 0).r & 0xFFFu);
        if (id != BLOCK_AIR) {
            transmit *= voxelCellTransmittance(id, cell, fromVoxel, rdInv, tEnter, tLeave, flags);
            if (maxOf(transmit) < TRACE_MIN_TRANSMITTANCE) return vec3(0.0);
        }

        if (testEntities) {
            float t0 = max(tEnter, entT0);
            float t1 = min(tLeave, entT1);
            if (t0 < t1) {
                uint mask = entityOccupancyForFlags(texelFetch(voxelEntitySampler, cell, 0).r, flags);
                if (traceSubcells(mask, fromVoxel - vec3(cell), dir, rdInv, stepDir, t0, t1)) return vec3(0.0);
            }
        }
    }
#ifdef ENTITY_TRI_OCCLUSION
    /*
     * 三角形方式: ボクセルの占有にはブロックエンティティと容量から溢れたエンティティだけが残っている
     * 三角形は形どおりなので着色点側の無視区間は要らない (自分の面での即ヒットは ENT_TRI_T_MIN と法線の押し出しで防ぐ)
     * 光源側の無視区間 (光源自身の体・手持ちの腕) は呼び出し側の entSkipEnd をそのまま使う
     */
    if (testEntities && traceEntityTriangles(fromVoxel, dir, ENT_TRI_T_MIN, len - entSkipEnd,
                                             (flags & TRACE_PLAYER) != 0u, (flags & TRACE_ENTITIES) != 0u)) {
        return vec3(0.0);
    }
#endif
    return transmit;
}

/*
 * 公開インターフェース (設計書の「モジュール間インターフェース」)。dither は現状未使用 (半影の揺らぎは呼び出し側で終点を動かして作る)
 */
vec3 traceVisibility(vec3 fromVoxel, vec3 toVoxel, uint flags, float dither) {
    return traceVisibilityEx(fromVoxel, toVoxel, flags, dither, TRACE_ENTITY_SKIP_START, TRACE_ENTITY_SKIP_END);
}

/*
 * 視線方向のレイが最初に当たる固体ボクセル (反射・GI 用, surface モジュールが使う)
 * 戻り値: true なら hitVoxel に交点 (voxel 空間), hitNormal に面法線, hitBlockId にブロック ID
 * 開始セルは判定しない。半透明・植物・光を遮らない光源 (たいまつ等) は素通りする。葉は当たる
 * 部分形状は常に AABB で判定する (反射に形が映るため)。エンティティは対象外
 */
bool traceVoxelRay(vec3 originVoxel, vec3 dir, float maxDist, out vec3 hitVoxel, out vec3 hitNormal, out int hitBlockId) {
    hitVoxel = originVoxel;
    hitNormal = vec3(0.0, 1.0, 0.0);
    hitBlockId = 0;
    float dl = length(dir);
    if (dl < 1e-6) return false;
    dir /= dl;

    ivec3 cell = ivec3(floor(originVoxel));
    ivec3 stepDir = ivec3(greaterThanEqual(dir, vec3(0.0))) * 2 - 1;
    vec3 tDelta = 1.0 / max(abs(dir), vec3(1e-7));
    vec3 rdInv = vec3(stepDir) * tDelta;
    vec3 fr = originVoxel - vec3(cell);
    vec3 tMax = mix(fr, 1.0 - fr, vec3(greaterThan(stepDir, ivec3(0)))) * tDelta;
    int maxSteps = min(int(maxDist * 1.8) + 2, 512);

    for (int i = 0; i < maxSteps; i++) {
        float tEnter = minOf(tMax);
        if (tEnter >= maxDist) return false;
        vec3 axis;
        if (tMax.x == tEnter) { cell.x += stepDir.x; tMax.x += tDelta.x; axis = vec3(1.0, 0.0, 0.0); }
        else if (tMax.y == tEnter) { cell.y += stepDir.y; tMax.y += tDelta.y; axis = vec3(0.0, 1.0, 0.0); }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; axis = vec3(0.0, 0.0, 1.0); }
        if (!isInVoxelVolume(cell)) return false;

        int id = int(texelFetch(voxelBlockSampler, cell, 0).r & 0xFFFu);
        if (id == BLOCK_AIR) continue;
        bool solid = false;
        float tHit = tEnter;
        vec3 n = -vec3(stepDir) * axis;
        if (id >= 300 && id < 400) {
            vec3 sn;
            float tLeave = minOf(tMax);
            if (shapeIntersect(id, originVoxel - vec3(cell), rdInv, tEnter, tLeave, tHit, sn)) {
                solid = true;
                n = sn;
            }
        } else {
            solid = isVoxelOpaque(id) || id == BLOCK_LEAVES;
        }
        if (solid) {
            if (tHit >= maxDist) return false;
            hitVoxel = originVoxel + dir * tHit;
            hitNormal = n;
            hitBlockId = id;
            return true;
        }
    }
    return false;
}

/*
 * 画面空間の接触影 (深度バッファのレイマーチ)。1 = 遮蔽なし
 * ボクセルに入らない細部 (手・小さいエンティティ・植物・ランタンの鎖等) を補う
 * depthtex1 (半透明を含まない) を使うので、deferred でも gbuffers_water でも同じ結果になる
 * 手 (手持ちアイテム) の深度は遮蔽物として扱わない (手持ち光源そのものを持っているため)
 * steps は指数的に伸ばす (近くほど細かく)。thickness より奥にある物は遮蔽物とみなさない
 */
const float SS_SHADOW_THICKNESS = 0.35;     // 遮蔽物の厚みの想定 (ブロック, 距離に比例して増やす)
const float SS_SHADOW_THICKNESS_DIST = 0.02;

float screenSpaceShadow(vec3 playerPos, vec3 geoNormal, vec3 toLight, float maxDist, int steps, float dither) {
    if (maxDist <= 0.05) return 1.0;
    vec3 startView = playerToView(playerPos);
    float startDist = -startView.z;
    // 遠いほど深度の精度が落ちるので押し出しを増やす
    startView += playerToViewDir(geoNormal) * (0.01 + 0.003 * startDist);
    vec3 dirView = playerToViewDir(toLight);
    float rayLen = maxDist;
    // near 面の手前で止める (カメラに向かうレイ)
    if (dirView.z > 1e-4) rayLen = min(rayLen, (-near * 2.0 - startView.z) / dirView.z);
    if (rayLen <= 0.0) return 1.0;

    vec2 screenSize = viewSize();
    for (int i = 0; i < steps; i++) {
        float x = (float(i) + dither) / float(steps);
        float t = rayLen * x * x;
        vec3 p = startView + dirView * t;
        vec3 sp = viewToScreen(p);
        if (any(lessThan(sp.xy, vec2(0.0))) || any(greaterThanEqual(sp.xy, vec2(1.0)))) break;
        float d = texelFetch(depthtex1, ivec2(sp.xy * screenSize), 0).r;
        if (d < HAND_DEPTH_THRESHOLD || d >= 1.0) continue;
        float sceneDist = -screenToView(vec3(sp.xy, d)).z;
        float rayDist = -p.z;
        float diff = rayDist - sceneDist;
        float bias = 0.02 + 0.002 * rayDist;
        float thickness = SS_SHADOW_THICKNESS + SS_SHADOW_THICKNESS_DIST * rayDist;
        if (diff > bias && diff < thickness) {
            // レイの終わり近くの遮蔽は弱めて、打ち切り位置の境界を目立たなくする
            return smoothstep(0.75, 1.0, x);
        }
    }
    return 1.0;
}

#endif
