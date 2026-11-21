/*
 * 実行時のブロックデータ参照 (SSBO blockData は setup.csh が lib/light/light_table.glsl から構築)
 */
#ifndef LIGHT_BLOCK_DATA_GLSL
#define LIGHT_BLOCK_DATA_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/block_data.glsl"
//@include "/lib/ids/material_ids.glsl"

LightDef getLightDef(int index) { return blockData.lightDefs[clamp(index, 0, LIGHT_TABLE_SIZE - 1)]; }
vec4 getTint(int index) { return blockData.tints[clamp(index, 0, TINT_TABLE_SIZE - 1)]; }
uvec4 getShape(int index) { return blockData.shapes[clamp(index, 0, SHAPE_TABLE_SIZE - 1)]; }
// 形のあるブロック (ID 300-399) が面全体をふさぐ向き。それ以外の ID は 0 (lib/buffers/block_data.glsl の shapeFaces)
uint getShapeCoveredFaces(int voxelId) {
    uint i = uint(voxelId - 300);
    return i < 100u ? blockData.shapeFaces[i] : 0u;
}
// ボクセル ID の平均の色 (線形アルベド)。floodfill の照り返しとボクセル RT の画面外の当たりに使う
vec3 getBlockAlbedo(int voxelId) {
    return srgbToLinear(unpackUnorm4x8(blockData.albedo[voxelId & (ALBEDO_TABLE_SIZE - 1)]).rgb);
}
/*
 * ブロックの平均の色 (線形、反射率の設定を掛ける前) の最大成分。テラコッタの反射率 (lib/ids/id_decode.glsl applyPatternAlbedo) が使う
 * 反射率の設定が有効な時だけ setup_tables.csh が albedo の a に sRGB で入れる (rgb は設定を掛けた後の色になるため)
 */
float colorBlockMeanMax(int blockId) {
    return srgbToLinear(vec3(unpackUnorm4x8(blockData.albedo[blockId & (ALBEDO_TABLE_SIZE - 1)]).a)).x;
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
    return d.color.rgb * d.color.a * (level / LIGHT_LEVEL_MAX) * BLOCKLIGHT_ILLUMINANCE * BLOCKLIGHT_BRIGHTNESS;
}

#if LIGHT_FALLOFF_MODE == 1
/*
 * 到達半径 (ブロック)。光の量 (明るさ x レベル) の平方根に比例させ、光源の種類ごとの下限 (d.params.w) と上限 (d.params.x) に収める
 * 減衰は遠くで逆二乗なので、決まった照度まで届く距離は光の量の平方根に比例する。レベルに比例させると
 * 暗い光源ほど窓関数で早く切れ (レベル 3 のマグマブロックは 3 ブロック)、まだ見える明るさのうちに光が消えた
 * 下限は、減衰が 0 へ落ちる所を暗い光源の近くに置かないため。半径は減衰と光源ビンの範囲だけに効き、近くの明るさはほぼ変わらない
 * レベルに比例する半径より短くはしない (明るさを控えめにしたシーランタン (0.75) がレベル 15 のまま届くように)
 * 下限が上限より大きい設定では下限を優先する (clamp は lo > hi で未定義)
 */
float lightRange(LightDef d, float level) {
    float relLevel = level / LIGHT_LEVEL_MAX;
    float flux = d.color.a * relLevel;
    return max(min(d.params.x * max(relLevel, sqrt(max(flux, 0.0))), d.params.x), d.params.w);
}
#else
// 到達半径 (ブロック)。レベルに比例
float lightRange(LightDef d, float level) { return d.params.x * level / LIGHT_LEVEL_MAX; }
#endif

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

#if LIGHT_FALLOFF_MODE == 1
/*
 * 距離減衰。1 次 + 2 次の減衰 g から、到達半径での値 g(R) を (距離 / 半径)^2 の重みで引き、半径でちょうど 0 にする (引き算の窓)
 * 窓関数を掛ける形 (Karis 2013) は半径の 3/4 から急に落ち、暗い光源の光だまりの縁が円く見えた。引き算は端に近いほど
 * 減衰の値そのものに比べて小さな量を引くので、端の数ブロックも 1 ブロックあたりの落ち方が手前の調子から少しずつ強まって 0 に着く
 * 重みを付けずに引くと、遠くの値 (たいまつの 19 ブロックで 1 ブロックの 1/15) が近くからも引かれて 1-4 ブロックが 11-14 % 暗くなるので、
 * 距離の 2 乗に比例させて近くではほとんど引かない
 * 引いた値を 2 乗して g で割る ((g - 引く量)^2 / g) のは、0 に着く所の傾きも 0 にするため。そのまま (1 乗) では端で
 * 直線的に 0 に落ちて、半径の短い光源 (下限 7) で最後の 1 ブロックの落ちが急だった (26.1.2 の床の測定で 1 ブロックの落ち方の変わりが
 * アメジスト x1.82 -> x1.36、ヒカリゴケ x1.86 -> x1.47)
 */
float lightFalloff(float dist, float range) {
    float r = max(range, EPS);
    float atRange = 1.0 / (1.0 + r * (LIGHT_FALLOFF_LINEAR + LIGHT_FALLOFF_QUADRATIC * r));
    float g = 1.0 / (1.0 + dist * (LIGHT_FALLOFF_LINEAR + LIGHT_FALLOFF_QUADRATIC * dist));
    float v = max(g - atRange * (dist / r) * (dist / r), 0.0);
    return v * v / g * LIGHT_FALLOFF_NORM;
}
#else
/*
 * 距離減衰。1 次 + 2 次の減衰に、到達半径で滑らかに 0 へ落とす窓関数を掛ける
 * (Karis 2013 の窓。半径外の光源を打ち切ってもポップしない)
 */
float lightFalloff(float dist, float range) {
    float x = saturate(1.0 - pow4(dist / max(range, EPS)));
    return x * x * LIGHT_FALLOFF_NORM / (1.0 + dist * (LIGHT_FALLOFF_LINEAR + LIGHT_FALLOFF_QUADRATIC * dist));
}
#endif

/*
 * 光源の面からの近距離の放射 (lightFalloff に足す係数)
 * lightFalloff は遠くを持ち上げた分だけ光源のすぐそばで逆二乗より緩く、光源を付けた壁や発光ブロックの足元が
 * 周りとあまり変わらない明るさになる。光源を見かけの半径 x LIGHT_NEAR_RADIUS_SCALE の発光面とみなし、
 * 球の面光源の形態係数 r^2 / (d^2 + r^2) で光源の周りだけを明るくする
 */
const float LIGHT_NEAR_CONTACT = 6.0;       // 光源に接した面の係数 (1 ブロック先の lightFalloff は 0.5)
const float LIGHT_NEAR_RADIUS_SCALE = 2.5;  // 発光面の半径 / 光源の見かけの半径 (炎や発光の照り返しで光る範囲は光源より広い)
const float LIGHT_NEAR_REACH = 6.0;         // この距離で 0 へ落とす (ブロック)

float lightNearField(float dist, float radius) {
    float r2 = radius * radius * (LIGHT_NEAR_RADIUS_SCALE * LIGHT_NEAR_RADIUS_SCALE);
    float w = saturate(1.0 - dist / LIGHT_NEAR_REACH);
    return LIGHT_NEAR_CONTACT * r2 / (dist * dist + r2) * (w * w);
}

/*
 * 球光源の NdotL。光源の見かけの半径ぶん地平線の下まで回り込ませる (wrap 近似)
 * 点光源の NdotL のままだと大きな光源 (グロウストーン等) の横の面が不自然に真っ暗になる
 */
float sphereLightNdotL(vec3 n, vec3 dir, float dist, float radius) {
    float sinA = saturate(radius / max(dist, EPS));
    return saturate((dot(n, dir) + sinA) / (1.0 + sinA));
}

/*
 * 法線を上向きに固定した植物 (十字の草・つた・花など。gbuffers_solid の isPlant) が点光源 (設置光源・手持ち光源) から受ける NdotL
 * 薄い両面の葉が向きばらばらに立っているので、光源の向きによらず縦の面の |cos| の平均 2/π とする
 * 上向きの法線のままでは、光源より上の植物は裏から照らされて暗く、光源と同じ高さではかすめ角の拡散 (EON の逆光側の持ち上げ) で
 * 明るくなり、上下で見え方が食い違った。太陽と空は地面と同じ明るさにするため上向きの法線のまま
 */
const float PLANT_LIGHT_NDOTL = 2.0 / PI;
// G バッファで法線を上向きに固定した植物とみなす幾何法線の y (符号化の誤差の分だけ 1 より下げる)
const float PLANT_UP_NORMAL_Y = 0.99;

bool isUpNormalPlant(int materialId, vec3 geoNormal) {
    return (materialId == MAT_PLANT || materialId == MAT_UNDERWATER_PLANT) && geoNormal.y > PLANT_UP_NORMAL_Y;
}

// フリッカーの速さ (1 秒あたりの揺らぎ数) と最大の暗くなり幅
const float FLICKER_SPEED = 6.0;
const float FLICKER_DEPTH = 0.3;
// 光源ごとの位相のずらし幅、2 オクターブ目の周波数倍率と重み
const float FLICKER_SEED_PHASE = 0.37;
const float FLICKER_OCTAVE_FREQ = 2.3;
const float FLICKER_WEIGHT_0 = 0.65;
const float FLICKER_WEIGHT_1 = 0.35;

/*
 * 炎系光源の明るさの揺らぎ倍率 (1 以下)。seed は光源ごとに固定の値 (ワールドのセル座標等)
 * 光源ごとに位相をずらした 2 オクターブの 1 次元値ノイズ。全光源が同期して揺れると不自然なため
 */
float lightFlicker(float amount, uvec3 seed) {
#ifdef LIGHT_FLICKER
    if (amount <= 0.0) return 1.0;
    uint h = pcg3d(seed).x;
    float t = frameTimeCounter * FLICKER_SPEED + float(h & 1023u) * FLICKER_SEED_PHASE;
    float n = 0.0;
    for (int o = 0; o < 2; o++) {
        float i = floor(t);
        float f = fract(t);
        f = f * f * (3.0 - 2.0 * f);
        uint base = h + uint(o) * 7919u;
        float a = hash1(base + uint(int(i) & 0xFFFF));
        float b = hash1(base + uint((int(i) + 1) & 0xFFFF));
        n += mix(a, b, f) * (o == 0 ? FLICKER_WEIGHT_0 : FLICKER_WEIGHT_1);
        t *= FLICKER_OCTAVE_FREQ;
    }
    return 1.0 - amount * FLICKER_DEPTH * n;
#else
    return 1.0;
#endif
}

#endif
