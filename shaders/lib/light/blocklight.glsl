/*
 * ブロックライトの参照口 (light モジュールが実装、surface / sky モジュールが呼ぶ)
 *
 * 合成の考え方
 *   LIGHT_SHADOWS あり: 直接光 (colortex6, 上位 N 光源のトレース + デノイズ) + floodfill x FLOODFILL_STRENGTH (間接光)
 *   LIGHT_SHADOWS なし: floodfill をそのまま全光量として使う
 *   ボクセル体積の外: バニラのライトマップ (blockLightmapFallback) へ滑らかに戻す
 *
 * 鏡面 (LIGHT_SPECULAR): deferred30 は getBlockLightSpecular を evalDirectSpecular (鏡面のみ) に通す
 * 拡散は代表光源の分も含めて getBlockLightOpaque が全部返す (差し引くと代表光源の拡散が欠ける)
 */
#ifndef LIGHT_BLOCKLIGHT_GLSL
#define LIGHT_BLOCKLIGHT_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/buffers/global_lights.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/floodfill.glsl"
//@include "/lib/light/light_select.glsl"
//@include "/lib/light/light_table.glsl"
//@include "/lib/light/trace.glsl"

// バニラのブロックライトマップ値 [0,1] からの照度 (体積外のフォールバック)
vec3 blockLightmapFallback(float lm) {
    vec3 c = srgbToLinear(fireSrgb());
    float x = saturate(lm);
    // バニラの 1 段 = 1/15 の線形減衰を、逆二乗っぽい見た目に寄せる
    return c * (x * x * x * x) * BLOCKLIGHT_ILLUMINANCE * BLOCKLIGHT_BRIGHTNESS;
}

/*
 * 不透明面のブロックライト照度 (拡散用)。deferred30 から呼ぶ
 * texel: 画面座標, normal: テクスチャ法線, geoNormal: 幾何法線, lm: バニラのブロックライトマップ
 */
vec3 getBlockLightOpaque(ivec2 texel, vec3 playerPos, vec3 geoNormal, vec3 normal, float lm) {
    float coverage = floodCoverage(playerPos);
    vec3 flood = sampleFloodfill(playerPos, geoNormal);
#ifdef LIGHT_SHADOWS
    vec3 direct = texelFetch(colortex6, texel, 0).rgb;
    vec3 voxelLight = direct + flood * FLOODFILL_STRENGTH;
    // 壁の照り返し (floodfill の伝搬の照り返しは上の FLOODFILL_STRENGTH 倍では見えないため、すぐ横の壁の分を足す)
    voxelLight += voxelLight * localWallBounce(playerPos, geoNormal);
#else
    vec3 voxelLight = flood;
#endif
    return mix(blockLightmapFallback(lm), voxelLight, coverage);
}

// 半透明・パーティクル・雲など (トレースなし)。gbuffers の前方シェーディングから呼ぶ
vec3 getBlockLightForward(vec3 playerPos, vec3 normal, float lm) {
    float coverage = floodCoverage(playerPos);
    return mix(blockLightmapFallback(lm), sampleFloodfill(playerPos, normal), coverage);
}

/*
 * 前方シェーディングする不透明物 (三人称の自分・半透明ブロックエンティティ) のブロックライト
 * Iris 26.1 は自分を deferred の後に描くので、deferred1 の直接光 (トレース) も GI も届かず、floodfill だけでは
 * 光源に向いた面も暗く、背中は真っ黒になる。ビンの光源を直接トレースし、
 * GI の代わりに、光源から見通せる位置の向きなしの照度の一定割合を周りの壁・床からの照り返しとして足す
 * (floodfill は光源から 2-3 ブロックで急に弱まり、照り返しの代わりにならない)
 * 自分の体で自分を遮らないよう、エンティティの遮蔽は使わない (裏側は NdotL で暗くなる)
 */
const int FORWARD_TRACED_LIGHTS = 8;
// 照り返しの割合。物理的には周りの反射率 0.3 前後 x 光が周囲に当たる割合だが、0.3 では服の色が読めない
// 三人称で背中も床の照り返しで服の色が見えるよう多めにする (iterationT の三人称の見え方)
const float FORWARD_ENTITY_BOUNCE = 0.5;

/*
 * 1 光源分の影を掛ける前の直接光 (戻り値)・影を掛けない光る箱の照度 box・照り返し bounceE
 * vis = blockLightShadow(トレースの可視率) として、直接光は 戻り値 x vis + box、照り返しは bounceE x vis を足す
 * トレースはビンの枠の順 (k の昇順) に、光の届く光源を FORWARD_TRACED_LIGHTS 個まで。ループは lib/surface/surface_lights.glsl の
 * gatherTracedLights (手持ち光源・鏡面と同じ 1 か所でトレースする)
 * 半影の揺らぎは入れない (この経路はデノイズも TAA の速度も無いので、ノイズがそのまま残る)
 */
vec3 forwardEntityLightUnshadowed(LightInstance L, vec3 fromVoxel, vec3 normal, vec3 geoNormal, out vec3 box, out vec3 bounceE) {
    float dist = distance(L.posRadius.xyz, fromVoxel);
    box = lightBoxIrradiance(L, fromVoxel, geoNormal);
    bounceE = L.colorSize.rgb * lightFalloff(dist, L.posRadius.w);
    return evalLightIrradiance(L, fromVoxel, normal, geoNormal);
}

// 集めた直接光と照り返しに floodfill を合わせ、体積の端でバニラのライトマップへ戻す
vec3 forwardEntityBlockLight(vec3 playerPos, vec3 geoNormal, float lm, vec3 direct, vec3 bounce) {
    float coverage = floodCoverage(playerPos);
    vec3 flood = sampleFloodfill(playerPos, geoNormal);
#ifdef LIGHT_SHADOWS
    vec3 voxelLight = direct + bounce * FORWARD_ENTITY_BOUNCE + flood * FLOODFILL_STRENGTH;
#else
    vec3 voxelLight = flood;
#endif
    return mix(blockLightmapFallback(lm), voxelLight, coverage);
}

// 鏡面ハイライトを足す光源の数の上限 (着色点のビンの中で照度の大きい順)
const int BLOCKLIGHT_SPECULAR_LIGHTS = LIGHT_SPECULAR_COUNT;

/*
 * ブロックライトの鏡面ハイライト用の光 (LIGHT_SPECULAR)。照度の大きい順に最大 BLOCKLIGHT_SPECULAR_LIGHTS 個を s に入れ、個数を返す
 * 代表光源 1 つだけだと、2 つの光源の拡散が釣り合う線で代表が入れ替わり、床の照り返しが斜めの直線で切れた
 * 光源ごとの可視率は無いので、deferred2 の可視率 (colortex7, トレースした光源全体の比) を共通に掛ける。
 * 体積の端ではフォールバックと同じ割合で弱める
 * colortex7 は不透明面の可視率なので、水・ガラスなど半透明の面は光源ごとにトレースして可視率を出す
 * (lib/surface/surface_lights.glsl の gatherTracedLights。選び方と LightSample はここの関数を使う)
 */
#if defined LIGHT_SPECULAR && defined LIGHT_SHADOWS
// 照度の大きい順の枠の番号を topIdx に入れる (足りない枠は -1)。光源の選び方は deferred1 と同じ (幾何法線で地平線の下の光源を除く)
void selectBlockSpecularLights(int bin, uint n, vec3 fromVoxel, vec3 geoNormal, out int topIdx[BLOCKLIGHT_SPECULAR_LIGHTS]) {
    // ビンの中の枠の番号 (境界の重みを lightBinLight で掛けるため、光源のインデックスではなく枠で持つ)
    float topW[BLOCKLIGHT_SPECULAR_LIGHTS];
    for (int j = 0; j < BLOCKLIGHT_SPECULAR_LIGHTS; j++) { topIdx[j] = -1; topW[j] = 0.0; }
    for (uint k = 0u; k < n; k++) {
        int ci = int(k);
        float cw = luminance(evalLightIrradiance(lightBinLight(bin, k), fromVoxel, geoNormal, geoNormal));
        if (cw <= 0.0) continue;
        for (int j = 0; j < BLOCKLIGHT_SPECULAR_LIGHTS; j++) {
            if (cw > topW[j]) {
                int ti = topIdx[j]; float tw = topW[j];
                topIdx[j] = ci; topW[j] = cw;
                ci = ti; cw = tw;
            }
        }
    }
}

// 影を掛ける前の鏡面の光。voxelPos は着色点 (押し出し前)、scale は可視率と体積の端の弱め
LightSample blockSpecularSample(LightInstance L, vec3 voxelPos, float scale) {
    LightSample s;
    vec3 toL = L.posRadius.xyz - voxelPos;
    float dist = length(toL);
    s.direction = toL / max(dist, EPS);
    s.irradiance = L.colorSize.rgb * lightFalloff(dist, L.posRadius.w) * scale;
    s.angularSize = atan(L.colorSize.a, max(dist, EPS));
    return s;
}
#endif

// 不透明面の鏡面 (deferred30)。可視率は deferred2 の colortex7
int getBlockLightSpecular(ivec2 texel, vec3 playerPos, vec3 geoNormal, out LightSample s[BLOCKLIGHT_SPECULAR_LIGHTS]) {
    for (int j = 0; j < BLOCKLIGHT_SPECULAR_LIGHTS; j++) s[j] = noLight();
#if defined LIGHT_SPECULAR && defined LIGHT_SHADOWS
    vec3 fromVoxel = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);
    if (!isInVoxelVolume(fromVoxel)) return 0;
    int bin = lightBinIndex(ivec3(fromVoxel));
    int topIdx[BLOCKLIGHT_SPECULAR_LIGHTS];
    selectBlockSpecularLights(bin, lightBinCount(bin), fromVoxel, geoNormal, topIdx);
    float scale = saturate(luminance(texelFetch(colortex7, texel, 0).rgb)) * floodCoverage(playerPos);
    vec3 voxelPos = playerToVoxel(playerPos);
    int count = 0;
    for (int j = 0; j < BLOCKLIGHT_SPECULAR_LIGHTS; j++) {
        if (topIdx[j] < 0) break;
        s[j] = blockSpecularSample(lightBinLight(bin, uint(topIdx[j])), voxelPos, scale);
        count++;
    }
    return count;
#else
    return 0;
#endif
}

// フォグ / VL 用: 体積内の点のブロックライト照度 (sky の FOG_BLOCKLIGHT が使う)
vec3 sampleBlockLightVolume(vec3 playerPos) {
    return sampleFloodfillVolume(playerPos);
}

#endif
