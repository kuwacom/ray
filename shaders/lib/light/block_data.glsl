/*
 * 実行時のブロックデータ参照 (SSBO blockData は setup.csh が lib/light/light_table.glsl から構築)
 */
#ifndef LIGHT_BLOCK_DATA_GLSL
#define LIGHT_BLOCK_DATA_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/buffers/block_data.glsl"

LightDef getLightDef(int index) { return blockData.lightDefs[clamp(index, 0, LIGHT_TABLE_SIZE - 1)]; }
vec4 getTint(int index) { return blockData.tints[clamp(index, 0, TINT_TABLE_SIZE - 1)]; }
uvec4 getShape(int index) { return blockData.shapes[clamp(index, 0, SHAPE_TABLE_SIZE - 1)]; }
// ボクセル ID の平均の色 (線形アルベド)。floodfill の照り返しとボクセル RT の画面外の当たりに使う
vec3 getBlockAlbedo(int voxelId) {
    return srgbToLinear(unpackUnorm4x8(blockData.albedo[voxelId & (ALBEDO_TABLE_SIZE - 1)]).rgb);
}
// 面の向きが分かる時 (レイの当たり)。上向きの面は上面の色 (草ブロックは全体の平均だと側面の土で茶色になる)
vec3 getBlockAlbedo(int voxelId, vec3 faceNormal) {
    int i = voxelId & (ALBEDO_TABLE_SIZE - 1);
    return srgbToLinear(unpackUnorm4x8(faceNormal.y > 0.5 ? blockData.albedoUp[i] : blockData.albedo[i]).rgb);
}

// 光源の実効レベル。at_midBlock.w (Iris 1.7+) が 0 ならテーブルの既定値を使う
float resolveLightLevel(LightDef d, float attributeLevel) {
    return attributeLevel > 0.5 ? attributeLevel : d.params.z;
}

// 光源 1 つの放射の強さ (LightInstance.colorSize.rgb に入れる値)
vec3 lightEmission(LightDef d, float level) {
    return d.color.rgb * d.color.a * (level / 15.0) * BLOCKLIGHT_ILLUMINANCE * BLOCKLIGHT_BRIGHTNESS;
}

// 到達半径 (ブロック)。レベルに比例
float lightRange(LightDef d, float level) { return d.params.x * level / 15.0; }

/*
 * 距離減衰の 1 次・2 次の係数 (1 / (1 + a d + b d^2))
 * 純粋な逆二乗 (a = 0, b = 1) は 1 ブロックに対して 4 ブロックで 1/8、7 ブロックで 1/25 になり、
 * バニラの光レベル (1 ブロックごとに 1 段: 4 ブロックで約 1/2、7 ブロックで約 1/4) よりずっと狭い光だまりになった
 * 実際の部屋では壁・床の多重反射が遠くを持ち上げるので、それを 1 次の項で近似し、バニラの到達距離感に寄せる
 */
const float LIGHT_FALLOFF_LINEAR = 0.3;
const float LIGHT_FALLOFF_QUADRATIC = 0.035;
// 1 ブロックの距離で素の逆二乗 (0.5) と同じ照度になるように掛ける正規化 (1 + a + b) / 2
const float LIGHT_FALLOFF_NORM = (1.0 + LIGHT_FALLOFF_LINEAR + LIGHT_FALLOFF_QUADRATIC) * 0.5;

/*
 * 距離減衰。1 次 + 2 次の減衰に、到達半径で滑らかに 0 へ落とす窓関数を掛ける
 * (Karis 2013 の窓。半径外の光源を打ち切ってもポップしない)
 */
float lightFalloff(float dist, float range) {
    float x = saturate(1.0 - pow4(dist / max(range, EPS)));
    return x * x * LIGHT_FALLOFF_NORM / (1.0 + dist * (LIGHT_FALLOFF_LINEAR + LIGHT_FALLOFF_QUADRATIC * dist));
}

/*
 * 光源の面からの近距離の放射 (lightFalloff に足す係数)
 * lightFalloff は遠くを持ち上げた分だけ光源のすぐそばで逆二乗より緩く、光源を付けた壁や発光ブロックの足元が
 * 周りとあまり変わらない明るさになる。光源を見かけの半径 x LIGHT_NEAR_RADIUS_SCALE の発光面とみなし、
 * 球の面光源の形態係数 r^2 / (d^2 + r^2) で光源の周りだけを明るくする
 */
const float LIGHT_NEAR_CONTACT = 4.5;       // 光源に接した面の係数 (1 ブロック先の lightFalloff は 0.5)
const float LIGHT_NEAR_RADIUS_SCALE = 2.5;  // 発光面の半径 / 光源の見かけの半径 (炎や発光の照り返しで光る範囲は光源より広い)
const float LIGHT_NEAR_REACH = 6.0;         // この距離で 0 へ落とす (ブロック)

float lightNearField(float dist, float radius) {
    float r2 = radius * radius * (LIGHT_NEAR_RADIUS_SCALE * LIGHT_NEAR_RADIUS_SCALE);
    float w = saturate(1.0 - dist / LIGHT_NEAR_REACH);
    return LIGHT_NEAR_CONTACT * r2 / (dist * dist + r2) * (w * w);
}

/*
 * ブロック全体が光る光源 (グロウストーン・シーランタン・光る鉱物ブロックなど) の面からの近距離の放射
 * 中心の点からの近距離の放射では、ブロックの隣の床や壁が根元ほど明るくならない (根元は中心から 0.7 ブロック離れている)。
 * ブロックの箱からの距離 s で、面光源の形態係数に似た s に対して急に落ちる形 h^2 / (s^2 + h^2) を使う (接した面で 1)
 * 面の明るさは見た目の発光で決まり、光源の明るさとレベル (遠くへの届き方) とは別なので、呼ぶ側がそれで割った係数を掛ける
 * 向きは中心への余弦。同じ平面に並ぶ面 (床に埋めた光源の隣の床) は光る面が見えないので 0 になる
 */
const float LIGHT_BOX_CONTACT = 3.0;   // 接した面の照度 / (色 x BLOCKLIGHT_ILLUMINANCE)
const float LIGHT_BOX_SPREAD = 0.7;    // 形態係数の広がり h (ブロック)
const float LIGHT_BOX_REACH = 4.0;     // この距離で 0 へ落とす (ブロック)

float lightBoxNearField(vec3 voxelPos, vec3 boxCenter, vec3 n) {
    vec3 q = max(abs(voxelPos - boxCenter) - 0.5, 0.0);
    float s = length(q);
    if (s >= LIGHT_BOX_REACH) return 0.0;
    float facing = saturate(dot(n, normalize(boxCenter - voxelPos)));
    float w = 1.0 - s / LIGHT_BOX_REACH;
    const float h2 = LIGHT_BOX_SPREAD * LIGHT_BOX_SPREAD;
    return LIGHT_BOX_CONTACT * h2 / (s * s + h2) * facing * (w * w);
}

/*
 * 球光源の NdotL。光源の見かけの半径ぶん地平線の下まで回り込ませる (wrap 近似)
 * 点光源の NdotL のままだと大きな光源 (グロウストーン等) の横の面が不自然に真っ暗になる
 */
float sphereLightNdotL(vec3 n, vec3 dir, float dist, float radius) {
    float sinA = saturate(radius / max(dist, EPS));
    return saturate((dot(n, dir) + sinA) / (1.0 + sinA));
}

// フリッカーの速さ (1 秒あたりの揺らぎ数) と最大の暗くなり幅
const float FLICKER_SPEED = 6.0;
const float FLICKER_DEPTH = 0.3;

/*
 * 炎系光源の明るさの揺らぎ倍率 (1 以下)。seed は光源ごとに固定の値 (ワールドのセル座標等)
 * 光源ごとに位相をずらした 2 オクターブの 1 次元値ノイズ。全光源が同期して揺れると不自然なため
 */
float lightFlicker(float amount, uvec3 seed) {
#ifdef LIGHT_FLICKER
    if (amount <= 0.0) return 1.0;
    uint h = pcg3d(seed).x;
    float t = frameTimeCounter * FLICKER_SPEED + float(h & 1023u) * 0.37;
    float n = 0.0;
    for (int o = 0; o < 2; o++) {
        float i = floor(t);
        float f = fract(t);
        f = f * f * (3.0 - 2.0 * f);
        uint base = h + uint(o) * 7919u;
        float a = hash1(base + uint(int(i) & 0xFFFF));
        float b = hash1(base + uint((int(i) + 1) & 0xFFFF));
        n += mix(a, b, f) * (o == 0 ? 0.65 : 0.35);
        t *= 2.3;
    }
    return 1.0 - amount * FLICKER_DEPTH * n;
#else
    return 1.0;
#endif
}

#endif
