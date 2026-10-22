/*
 * 実行時のブロックデータ参照 (SSBO blockData は setup.csh が lib/light/light_table.glsl から構築)
 */
#ifndef LIGHT_BLOCK_DATA_GLSL
#define LIGHT_BLOCK_DATA_GLSL

LightDef getLightDef(int index) { return blockData.lightDefs[clamp(index, 0, LIGHT_TABLE_SIZE - 1)]; }
vec4 getTint(int index) { return blockData.tints[clamp(index, 0, TINT_TABLE_SIZE - 1)]; }
uvec4 getShape(int index) { return blockData.shapes[clamp(index, 0, SHAPE_TABLE_SIZE - 1)]; }

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
// 1 ブロックの距離で旧来の逆二乗 (0.5) と同じ照度になるように掛ける正規化 (1 + a + b) / 2
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
