/*
 * 反射体の反射光 (REFLECTOR_LIGHT、surface モジュール。gi_raw.csh が GI の照度に足す)
 * ガラス・氷・金属・鉱物のブロックの面を平面鏡とみなし、太陽・月とブロックライトの鏡像 (虚像の光源) が周りの面を照らす光を求める
 * 平面鏡は光を集めないので、受ける面の照度は 反射率 x 光源の照度 のまま距離で落ちず、反射体の形の帯になる
 *
 * 軸に沿った面は整数の位置 (パネルは中央) にしか無いので、受信点から鏡像へ向かう線が面と交わる点のセルを 1 枚ずつ引くだけで済む。
 * セルを辿るレイと違い、読むのは面ごとに 1 回で、反射体が無い画素は読みだけで終わる。見つけた 1 点だけ、受信点から面と、面から光源の
 * 遮蔽をトレースする。粗い面 (金属・氷) は、面の縁をレイの広がり (距離 x 粗さ) の分だけぼかす (セルの 4 近傍で縁までの距離を見る)
 *
 * - 太陽・月: 向きだけなので鏡像は 1 本。面の向き (±x ±z と上) ごとに、光の向きを面で鏡映した向きを辿る
 * - ブロックライト: ビンの明るい光源 REFLECTOR_BLOCKLIGHT_COUNT 個を、面の向き (±x ±z) ごとに面の位置で鏡映して辿る
 *   (光源の位置を面の位置で鏡映した点が、その面の鏡像の光源)
 * - 空の光の跳ね返しは持たない。金属・鉱物は GI (RSM・SSGI・ボクセル RT) が色の付いた拡散の照り返しとして既に出している
 */
#ifndef SURFACE_REFLECTOR_LIGHT_GLSL
#define SURFACE_REFLECTOR_LIGHT_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/light_select.glsl"
//@include "/lib/light/trace.glsl"
//@include "/lib/light/voxel_read.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/sky_color.glsl"
//@include "/lib/surface/brdf.glsl"
//@include "/lib/surface/material.glsl"
//@include "/lib/surface/sun_shadow.glsl"

#ifdef REFLECTOR_LIGHT

// 反射体の種類。パネルは面が中央にあるので別にする
const int REFLECTOR_KIND_NONE = 0;
const int REFLECTOR_KIND_GLASS = 1;
const int REFLECTOR_KIND_PANE = 2;
const int REFLECTOR_KIND_ICE = 3;
const int REFLECTOR_KIND_METAL = 4;
const int REFLECTOR_KIND_GEM = 5;

int reflectorKind(int id) {
    if (id < 10) return REFLECTOR_KIND_NONE;
    if (id < 100) {
        if (id == BLOCK_METAL || id == BLOCK_DECOR_GOLD) return REFLECTOR_KIND_METAL;
        if (id >= BLOCK_DECOR_LAPIS && id <= BLOCK_DECOR_DIAMOND) return REFLECTOR_KIND_GEM;
        return REFLECTOR_KIND_NONE;
    }
    if (id < 200 || id >= 300) return REFLECTOR_KIND_NONE;
    if (id == BLOCK_ICE) return REFLECTOR_KIND_ICE;
    if (id == BLOCK_GLASS || id == BLOCK_TINTED_GLASS || (id >= BLOCK_STAINED_GLASS && id < BLOCK_STAINED_GLASS + 16)) return REFLECTOR_KIND_GLASS;
    if (id == BLOCK_GLASS_PANE || (id >= BLOCK_STAINED_GLASS_PANE && id < BLOCK_STAINED_GLASS_PANE + 16)) return REFLECTOR_KIND_PANE;
    return REFLECTOR_KIND_NONE;
}

// 垂直入射の反射率。ガラスは板 1 枚 (表面 + 裏面の往復) の合計で見る
const float REFLECTOR_GLASS_F0 = 0.04;
const float REFLECTOR_ICE_F0 = 0.018;
const float REFLECTOR_GEM_F0 = 0.17;
// 宝石の反射に乗せるブロックの色の割合 (誘電体の反射は無色だが、鉱物の模様と色を残すと反射光で何のブロックか分かる)
const float REFLECTOR_GEM_TINT = 0.6;
// 反射のローブの半幅 (ラジアン)。面の縁をぼかす広がりの元 (Ray の粗さの値から、表の FWHM の半分)
const float REFLECTOR_SPREAD_GLASS = 0.002;
const float REFLECTOR_SPREAD_GEM = 0.008;
const float REFLECTOR_SPREAD_ICE = 0.02;
const float REFLECTOR_SPREAD_METAL = 0.13;
// ぼかしの半径 (ブロック) がこれ未満なら縁を見ない。上限は隣のセルまで
const float REFLECTOR_EDGE_MIN = 0.04;
const float REFLECTOR_EDGE_MAX = 0.5;
// 面から光を受ける側へ浮かせる量 (ブロック)。トレースの終点を面の手前のセルに置く
const float REFLECTOR_FACE_OFFSET = 0.03;
// 面の向きに対する光の cos の下限 (かすめ角で面を見つけても受信側の寄与がほぼ 0)
const float REFLECTOR_MIN_COS = 0.02;
// ブロックライトの鏡像を探す面の枚数の上限 (受信点・光源から面まで)。光の届く距離の半分より先は鏡像が届かない
const int REFLECTOR_BLOCKLIGHT_PLANES = 12;
// 遮蔽のトレース。ガラスの色付けと部分形状は見る (動くエンティティは見ない)
const uint REFLECTOR_TRACE_FLAGS = TRACE_TINT | TRACE_SHAPES;
// ボクセル体積の端で反射光を弱める幅 (ブロック)。端の外は面を引けない
const float REFLECTOR_VOLUME_FADE = 16.0;
// 影マップの遮蔽の自己交差を避ける面からの浮かせ量 (影マップのテクセルの何倍か)
const float REFLECTOR_SHADOW_BIAS_TEXELS = 1.5;
const float REFLECTOR_SHADOW_OFFSET_MIN = 0.1;

float reflectorSpread(int kind) {
    if (kind == REFLECTOR_KIND_METAL) return REFLECTOR_SPREAD_METAL;
    if (kind == REFLECTOR_KIND_ICE) return REFLECTOR_SPREAD_ICE;
    if (kind == REFLECTOR_KIND_GEM) return REFLECTOR_SPREAD_GEM;
    return REFLECTOR_SPREAD_GLASS;
}

// 面の受ける光の cosI での反射の色。材質ごとの強さを掛け済み
vec3 reflectorReflectance(int kind, int id, float cosI) {
    if (kind == REFLECTOR_KIND_METAL) {
        return fresnelSchlick(metalReflectance(getBlockAlbedo(id)), cosI) * REFLECTOR_METAL_STRENGTH;
    }
    if (kind == REFLECTOR_KIND_GEM) {
        vec3 a = getBlockAlbedo(id);
        vec3 tint = mix(vec3(1.0), a / max(maxOf(a), 1e-3), REFLECTOR_GEM_TINT);
        return fresnelSchlick(vec3(REFLECTOR_GEM_F0), cosI) * tint * REFLECTOR_GEM_STRENGTH;
    }
    float f = fresnelSchlick(vec3(kind == REFLECTOR_KIND_ICE ? REFLECTOR_ICE_F0 : REFLECTOR_GLASS_F0), cosI).x;
    // 裏の面の反射は板を往復して色が付く
    vec4 t = getTint(getTintIndex(id));
    vec3 tr = t.rgb * (1.0 - t.a);
    return f * (vec3(1.0) + tr * tr) * REFLECTOR_GLASS_STRENGTH;
}

// 範囲の外は空気 (面の隣のセルを引く所は、体積の端で範囲の外へ出うる)
int reflectorBlockId(ivec3 cell) { return isInVoxelVolume(cell) ? fetchVoxelBlockId(cell) : BLOCK_AIR; }

/*
 * 粗い面の縁のぼかし: 面の点 q から radius (ブロック) の範囲のうち、反射体のセルに収まる割合。
 * 面の 2 軸それぞれで、縁までの距離が radius より近く、その先の隣のセルが反射体でない分を引く
 */
float reflectorCoverage(ivec3 cell, int axis, vec3 q, float radius) {
    if (radius < REFLECTOR_EDGE_MIN) return 1.0;
    radius = min(radius, REFLECTOR_EDGE_MAX);
    int u = (axis + 1) % 3;
    int v = (axis + 2) % 3;
    vec2 f = vec2(fract(q[u]), fract(q[v]));
    vec2 loss = vec2(0.0);
    ivec3 n = cell;
    n[u] -= 1;
    if (reflectorKind(reflectorBlockId(n)) == REFLECTOR_KIND_NONE) loss.x += max(radius - f.x, 0.0);
    n[u] += 2;
    if (reflectorKind(reflectorBlockId(n)) == REFLECTOR_KIND_NONE) loss.x += max(radius - (1.0 - f.x), 0.0);
    n = cell;
    n[v] -= 1;
    if (reflectorKind(reflectorBlockId(n)) == REFLECTOR_KIND_NONE) loss.y += max(radius - f.y, 0.0);
    n[v] += 2;
    if (reflectorKind(reflectorBlockId(n)) == REFLECTOR_KIND_NONE) loss.y += max(radius - (1.0 - f.y), 0.0);
    vec2 keep = 1.0 - loss / (2.0 * radius);
    return keep.x * keep.y;
}

/*
 * 鉱物・金のブロックの模様: 光るブロックの面のテクスチャの 4x4 の明暗 (lightMasks) を、反射の点の面の位置で引く
 * 受ける面には、反射体の面の明るい所と暗い所が像になって映る。平均が 1 になるように割る (面全体の光の量は変えない)
 * 面の向きと左右は厳密にはテクスチャと合わせていない (模様は統計的な濃淡として使う)
 */
float reflectorPattern(int id, int axis, vec3 q) {
    if (REFLECTOR_PATTERN <= 0.0 || id < BLOCK_DECOR_LAPIS || id > BLOCK_DECOR_GOLD) return 1.0;
    LightFaceMask f = readLightMask(LIGHT_DECOR_FIRST + (id - BLOCK_DECOR_LAPIS), axis == 1 ? LIGHT_FACE_UP : LIGHT_FACE_SIDE);
    if (f.gridScale <= 0.0) return 1.0;
    vec2 uv = axis == 1 ? vec2(fract(q.x), fract(q.z)) : vec2(fract(q[axis == 0 ? 2 : 0]), 1.0 - fract(q.y));
    vec2 r = (uv - f.rect.xy) / max(f.rect.zw - f.rect.xy, vec2(1e-3));
    ivec2 c = ivec2(clamp(floor(r * 4.0), 0.0, 3.0));
    int k = c.y * 4 + c.x;
    float level = float(((k < 8 ? f.grid.x : f.grid.y) >> (4u * uint(k & 7))) & 15u);
    float sum = 0.0;
    for (int i = 0; i < 16; i++) sum += float(((i < 8 ? f.grid.x : f.grid.y) >> (4u * uint(i & 7))) & 15u);
    return mix(1.0, level / max(sum / 16.0, 1.0), REFLECTOR_PATTERN);
}

struct ReflectorHit {
    vec3 q;       // 反射の点 (ボクセル空間)
    ivec3 cell;   // 反射体のセル
    int id;
    int kind;
};

/*
 * 軸 a の面 plane (反射体は s の側) のセルを引く。鏡像へ向かう線 x -> end と面の交点のセルが反射体なら 1 (h に入れる)、
 * 光を遮る固体なら 2 (これより先は見えない)、どちらでもなければ 0
 * lightPos: 光源の位置 (directional = false)、または光の向き (directional = true、x + 向き が線の終点)
 * ブロックライトは面の位置で光源を鏡映した点が終点。パネルは面がセルの中央にあるので、面を中央にして交点を引き直す
 */
vec3 reflectorLineEnd(vec3 x, vec3 lightPos, bool directional, int a, float plane) {
    if (directional) return x + lightPos;
    vec3 e = lightPos;
    e[a] = 2.0 * plane - lightPos[a];
    return e;
}

int reflectorProbe(vec3 x, vec3 lightPos, bool directional, int a, float s, float plane, out ReflectorHit h) {
    h.q = x;
    h.cell = ivec3(0);
    h.id = 0;
    h.kind = REFLECTOR_KIND_NONE;
    vec3 end = reflectorLineEnd(x, lightPos, directional, a, plane);
    float den = end[a] - x[a];
    if (abs(den) < 1e-4) return 2;
    vec3 q = x + (end - x) * ((plane - x[a]) / den);
    ivec3 cell = ivec3(floor(q));
    cell[a] = int(floor(plane + 0.001 * s));
    if (!isInVoxelVolume(cell)) return 2;
    int id = fetchVoxelBlockId(cell);
    if (id == BLOCK_AIR) return 0;
    int kind = reflectorKind(id);
    if (kind == REFLECTOR_KIND_NONE) return (isPlainSolidBlock(id) || (id >= 10 && id < 100)) ? 2 : 0;
    if (kind == REFLECTOR_KIND_PANE) {
        float mid = float(cell[a]) + 0.5;
        end = reflectorLineEnd(x, lightPos, directional, a, mid);
        den = end[a] - x[a];
        if (abs(den) < 1e-4) return 0;
        q = x + (end - x) * ((mid - x[a]) / den);
        ivec3 c2 = ivec3(floor(q));
        c2[a] = cell[a];
        if (c2 != cell) return 0;
    } else {
        // 面の手前のセルが固体なら面は隠れている (線が手前のセルの横から入ると、面の位置の 1 枚前では見つからない)。
        // 光を通すガラス・氷は色付けのトレースが見る
        ivec3 front = cell;
        front[a] -= int(s);
        int fid = reflectorBlockId(front);
        if (isPlainSolidBlock(fid) || (fid >= 10 && fid < 100)) return 2;
    }
    h.q = q;
    h.cell = cell;
    h.id = id;
    h.kind = kind;
    return 1;
}

#if defined REFLECTOR_SUN && defined HAS_SUN_SHADOWS
// 面の点の太陽の可視率 (影マップを 1 回引く。面から離して自分の影を避ける)。範囲外は 1
float reflectorSunVisibility(vec3 qPlayer, vec3 n) {
    vec3 clip0 = playerToShadowClip(qPlayer);
    float texel = shadowTexelWorldSize(clip0.xy);
    vec3 clip = playerToShadowClip(qPlayer + n * (REFLECTOR_SHADOW_OFFSET_MIN + REFLECTOR_SHADOW_BIAS_TEXELS * texel));
    vec2 uv = shadowClipToUv(clip.xy);
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 1.0;
    float z = shadowClipToDepth(clip.z) - SHADOW_CONSTANT_BIAS * texel * shadowDepthPerBlock();
    return shadowCompareBilinear(shadowtex1, uv, z);
}

/*
 * 太陽・月の反射光 (受ける面の照度)。xVox: 受信点 (ボクセル空間)、N: 受信面の幾何法線
 * 面の外向きの法線 n ごとに、光の向き L を面で鏡映した向き dir (受信点から面へ向かう向き) へ軸方向の面を辿る
 */
vec3 reflectorSun(vec3 xVox, vec3 N, LightSample sun) {
    vec3 sum = vec3(0.0);
    for (int k = 0; k < 5; k++) {
        // 0-3: ±x ±z、4: 上向きの面 (上から受けた光は上へ返り、下向きの面を照らす)
        int a = k < 2 ? 0 : (k < 4 ? 2 : 1);
        float sgn = (k & 1) == 0 ? 1.0 : -1.0;
        vec3 n = vec3(0.0);
        n[a] = k == 4 ? 1.0 : sgn;
        float cosI = dot(n, sun.direction);
        if (cosI <= REFLECTOR_MIN_COS) continue;
        vec3 dir = sun.direction - 2.0 * cosI * n;
        float cosR = dot(N, dir);
        if (cosR <= REFLECTOR_MIN_COS || abs(dir[a]) < 1e-3) continue;
        float s = -n[a];
        float start = s > 0.0 ? floor(xVox[a]) + 1.0 : floor(xVox[a]);
        int steps = min(int(float(REFLECTOR_DISTANCE) * abs(dir[a])) + 1, REFLECTOR_DISTANCE);
        for (int i = 0; i < steps; i++) {
            ReflectorHit h;
            int st = reflectorProbe(xVox, dir, true, a, s, start + s * float(i), h);
            if (st == 2) break;
            if (st == 0) continue;
            float path = length(h.q - xVox);
            float spread = sqrt(sqr(reflectorSpread(h.kind)) + sqr(SUN_ANGULAR_RADIUS));
            float cover = reflectorCoverage(h.cell, a, h.q, path * spread);
            if (cover <= 0.0) break;
            vec3 vis = traceVisibility(xVox, h.q - dir * REFLECTOR_FACE_OFFSET, REFLECTOR_TRACE_FLAGS, 0.5, 0.0, 0.0);
            if (maxOf(vis) <= 0.0) break;
            vec3 qPlayer = voxelToPlayer(h.q);
            float sunVis = reflectorSunVisibility(qPlayer, n) * getCloudShadow(qPlayer);
            if (sunVis <= 0.0) break;
            sum += sun.irradiance * reflectorReflectance(h.kind, h.id, cosI) * (vis * (sunVis * cover * cosR * reflectorPattern(h.id, a, h.q)));
            break;
        }
    }
    return sum;
}
#endif

#ifdef REFLECTOR_BLOCKLIGHT
/*
 * ブロックライトの反射光。ビンの明るい REFLECTOR_BLOCKLIGHT_COUNT 個の光源を、面の向き ±x ±z ごとに面の位置で鏡映して辿る
 * 光源が受信点と同じ側にある面だけが鏡になるので、面は受信点と光源の両方より先 (反射体の側) に置く
 */
vec3 reflectorBlockLights(vec3 xVox, vec3 N) {
    int bin = lightBinIndex(ivec3(floor(xVox)));
    uint count = lightBinCount(bin);
    int topIdx[REFLECTOR_BLOCKLIGHT_COUNT];
    float topW[REFLECTOR_BLOCKLIGHT_COUNT];
    for (int j = 0; j < REFLECTOR_BLOCKLIGHT_COUNT; j++) { topIdx[j] = -1; topW[j] = 0.0; }
    for (uint k = 0u; k < count; k++) {
        LightInstance L = lightBinLight(bin, k);
        float w = luminance(L.colorSize.rgb) * lightFalloff(distance(L.posRadius.xyz, xVox), L.posRadius.w);
        int ci = int(k);
        for (int j = 0; j < REFLECTOR_BLOCKLIGHT_COUNT; j++) {
            if (w > topW[j]) {
                int ti = topIdx[j];
                float tw = topW[j];
                topIdx[j] = ci;
                topW[j] = w;
                ci = ti;
                w = tw;
            }
        }
    }
    vec3 sum = vec3(0.0);
    for (int j = 0; j < REFLECTOR_BLOCKLIGHT_COUNT; j++) {
        if (topIdx[j] < 0) break;
        LightInstance L = lightBinLight(bin, uint(topIdx[j]));
        vec3 lp = L.posRadius.xyz;
        float reach = L.posRadius.w;
        for (int k = 0; k < 4; k++) {
            int a = k < 2 ? 0 : 2;
            float s = (k & 1) == 0 ? 1.0 : -1.0;
            float near = s > 0.0 ? max(xVox[a], lp[a]) : min(xVox[a], lp[a]);
            float start = s > 0.0 ? floor(near) + 1.0 : ceil(near) - 1.0;
            int planes = min(int(reach * 0.5) + 1, REFLECTOR_BLOCKLIGHT_PLANES);
            for (int i = 0; i < planes; i++) {
                ReflectorHit h;
                int st = reflectorProbe(xVox, lp, false, a, s, start + s * float(i), h);
                if (st == 2) break;
                if (st == 0) continue;
                float plane = s > 0.0 ? float(h.cell[a]) : float(h.cell[a] + 1);
                if (h.kind == REFLECTOR_KIND_PANE) plane = float(h.cell[a]) + 0.5;
                vec3 image = lp;
                image[a] = 2.0 * plane - lp[a];
                vec3 toImage = image - xVox;
                float dist = length(toImage);
                if (dist >= reach) break;
                vec3 dir = toImage / dist;
                vec3 n = vec3(0.0);
                n[a] = -s;
                float cosR = sphereLightNdotL(N, dir, dist, L.colorSize.a);
                float cosI = dot(n, normalize(lp - h.q));
                if (cosR <= 0.0 || cosI <= REFLECTOR_MIN_COS) break;
                float cover = reflectorCoverage(h.cell, a, h.q, dist * reflectorSpread(h.kind));
                if (cover <= 0.0) break;
                vec3 vis = traceVisibility(xVox, h.q - dir * REFLECTOR_FACE_OFFSET, REFLECTOR_TRACE_FLAGS, 0.5, 0.0, 0.0);
                if (maxOf(vis) <= 0.0) break;
                vis *= traceVisibility(h.q + n * REFLECTOR_FACE_OFFSET, lp, REFLECTOR_TRACE_FLAGS, 0.5, 0.0, 0.0);
                sum += L.colorSize.rgb * lightFalloff(dist, reach) * reflectorReflectance(h.kind, h.id, cosI) * (vis * (cosR * cover * reflectorPattern(h.id, a, h.q)));
                break;
            }
        }
    }
    return sum;
}
#endif

/*
 * 受信点 (面から浮かせた player 空間の点) と幾何法線の反射光の照度。REFLECTOR_STRENGTH 込み
 * 体積の端は面を引けないので弱める
 */
vec3 reflectorLight(vec3 originPlayer, vec3 geoNormal) {
    vec3 xVox = playerToVoxel(originPlayer);
    float fade = voxelEdgeFade(xVox, REFLECTOR_VOLUME_FADE);
    if (fade <= 0.0) return vec3(0.0);
    vec3 sum = vec3(0.0);
#if defined REFLECTOR_SUN && defined HAS_SUN_SHADOWS
    LightSample sun = getCelestialLight();
    if (maxOf(sun.irradiance) > 0.0) sum += reflectorSun(xVox, geoNormal, sun);
#endif
#ifdef REFLECTOR_BLOCKLIGHT
    sum += reflectorBlockLights(xVox, geoNormal);
#endif
    return sum * (fade * REFLECTOR_STRENGTH);
}

#endif

#endif
