/*
 * composite (compute): 反射 (SSR, REFLECTIONS=3 ではボクセル補完) を reflectionImg に書く
 * 対象は不透明の鏡面 (G バッファ) と水・ガラスの表面 (colortex5)
 * surface モジュール (lib/surface)
 *
 * 1. 反射方向: 鏡面に近い面は完全反射、それ以外は GGX の可視法線サンプリング (REFLECTIONS>=2)
 * 2. スクリーンスペースのレイマーチ (lib/surface/screen_trace.glsl) で deferred30 の結果 (colortex0) を拾う
 * 3. 外れたら REFLECTIONS=3 はボクセルのレイ (light モジュールの traceVoxelRay)、最後は空 (horizon 減衰 + スカイライト)
 * 4. ラフ反射は前フレームの面へ再投影して時間蓄積 (反射面の距離で無効な履歴を捨てる)
 * レイアウトは lib/surface/reflection.glsl
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_REFLECTION
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"
#include "/lib/post/post.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/reflection.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
const vec2 workGroupsRender = vec2(0.5, 0.5);

// SSR の当たりの判定と定数 (SSR_MAX_DISTANCE など) は composite1 の鏡面のフル解像度の SSR と共有するため lib/surface/reflection.glsl に置く
const float VOXEL_REFLECTION_DISTANCE = 64.0;
const float REFLECTION_ALPHA_MIN = 0.12;     // 最も粗い面の時間蓄積の新しい値の割合
#if REFLECTIONS == 1
    const float SSR_ROUGHNESS_LIMIT = 0.3;   // SSR のみの設定では粗い面は空のフォールバックで済ませる
#else
    const float SSR_ROUGHNESS_LIMIT = SSR_MAX_ROUGHNESS;
#endif

void main() {
    ivec2 low = ivec2(gl_GlobalInvocationID.xy);
    ivec2 lowSize = reflectionLowSize();
    if (any(greaterThanEqual(low, lowSize))) return;
    ivec2 region = reflectionRegion(frameCounter);
    ivec2 prevRegion = reflectionRegion(frameCounter + 1);
    ivec2 texel = low * 2 + lowResOffset(frameCounter);

    ReflectSurface s = getReflectSurface(texel);
    if (!s.valid) {
        imageStore(reflectionImg, low + region, vec4(0.0));
        return;
    }
    vec3 playerPos = viewToPlayer(s.viewPos);
    float dist = length(playerPos);
    vec3 V = -playerPos / max(dist, 1e-4);
    vec3 N;
    vec3 Ng;
    if (s.translucent) {
        N = dot(s.normal, V) < 0.0 ? -s.normal : s.normal;
        Ng = N;
    } else {
        // 不透明面で裏を向くのはテクスチャ法線だけ。反転すると反射が面の中へ向かい自分自身を映すので、視線側へ倒す
        Ng = dot(s.geoNormal, V) < 0.0 ? -s.geoNormal : s.geoNormal;
        N = frontFacingNormal(s.normal, V, REFLECT_MIN_NOV);
    }
    bool underside = s.translucent && s.materialId == MAT_WATER && isEyeInWater == 1;
    vec4 noise = blueNoise(texel);

    if (s.translucent && s.materialId == MAT_WATER && !underside) N = waterReflectNormal(N, V);
    vec3 R = reflect(-V, N);
    // 波の斜面で下向きに反射した光は隣の波に当たって上へ返る。画面の深度 (depthtex1) は水底なので、そのまま辿ると
    // 水面の下の水底を映して茶色の斑になる。平均水面でもう一度反射させて上向きにする
    // 空へ抜けた時に引く方向。水面は画素より細かい波の粗さの分だけ高い空を映す (composite1 と揃える。SSR は R のまま)
    vec3 skyDir = R;
    // 折り返すのは上向きの水面だけ (側面で折り返すと、少し上から見た滝が足元の地面ではなく空を映して白っぽく光った)
    bool waterTop = s.translucent && s.materialId == MAT_WATER && !underside && abs(N.y) >= 0.5;
    if (waterTop) {
        R.y = abs(R.y);
        skyDir = R;
        if (N.y > 0.5) {
            float footprint = waterFootprint(dist, abs(V.y));
            skyDir = waterRoughReflectDir(R, waterUnresolvedSlopeVar(waterSeaState(s.skyLm), footprint));
        }
    }
#if REFLECTIONS >= 2
    if (s.perceptualRoughness >= MIRROR_ROUGHNESS) {
        float a = max(s.perceptualRoughness * s.perceptualRoughness, MIN_ROUGHNESS);
        mat3 basis = tbnFromNormal(N);
        vec3 H = basis * sampleGgxVndf(V * basis, a, noise.xy);
        vec3 Rs = reflect(-V, H);
        if (dot(Rs, N) > 0.0) R = Rs;
    }
#endif
    /*
     * テクスチャ法線 (特に自動生成法線) の反射と VNDF のサンプルは幾何面の下を向くことがある。そのまま辿ると SSR は
     * 始点のすぐ先の自分の面に、ボクセルは隣の床ブロックに当たり、少しずれた自分のテクスチャを映して
     * z-fighting のようにちらついていた。幾何面で折り返し、最低限の仰角を持たせる
     */
    if (!s.translucent) {
        float e = dot(R, Ng);
        R = normalize(R + Ng * (max(abs(e), REFLECT_MIN_ELEVATION) - e));
    }

    // 水中から見た水面の裏は全反射で水中を映すので空は使わない (外れた分は sky の水中フォグが埋める)
    if (!s.translucent || s.materialId != MAT_WATER) skyDir = R;
    vec3 radiance = underside ? vec3(0.0) : skyReflectionFallback(skyDir, s.skyLm, s.perceptualRoughness);
    bool skyMiss = false;

    if (s.perceptualRoughness < SSR_ROUGHNESS_LIMIT) {
        // 鏡面 (水・ガラス) は遠くの島や岸も映るよう描画距離まで辿る
        float maxDist = s.perceptualRoughness < MIRROR_ROUGHNESS ? mirrorTraceDistance() : SSR_MAX_DISTANCE;
        vec4 hit = traceReflectionHit(s.viewPos, playerPos, Ng, R, dist, maxDist, !s.translucent, waterTop, noise.z);
        bool found = hit.w > 0.5;
        float edge = hit.z;
#if REFLECTIONS == 3
        // 画面端で SSR を薄める先は空ではなくボクセルのレイにする。空へ溶かすと洞窟 (スカイライト 0) では
        // 画面の端ほど反射が黒く抜け、屋外でも端に映る地形が空の色に化けていた
        if (edge < 1.0) {
            // voxelRayOrigin は幾何法線の主軸で固体セルから押し出す前提 (テクスチャ法線だと横の床セルへ押し出すことがある)
            vec4 v = traceVoxelRadiance(voxelRayOrigin(playerPos, Ng), R, VOXEL_REFLECTION_DISTANCE, s.skyLm, true);
            if (v.a > 0.5) radiance = v.rgb;
            found = found || v.a > 0.5;
        }
#endif
        if (edge > 0.0) radiance = mix(radiance, textureLod(colortex0, hit.xy, 0.0).rgb, edge);
        // 何にも当たらず空へ抜けた鏡面の反射は、同じ方向の空の画素 (雲込み) を映す。空は無限遠なので面の位置によらず
        // カメラから見た R 方向の画素と同じ。LUT の空 (雲なし) のままだと、昼の水面の遠くが一様な水色の帯になり
        // 雲の映り込みが無かった
        if (!found && !underside && s.perceptualRoughness < MIRROR_ROUGHNESS && R.y > 0.0) {
            // 水面は composite1 が自分の画素の反射方向で空を引き直す (半分の解像度の隣の画素の空では、波の法線と
            // ずれた 2x2 のモザイクになり、中景の水面が白い砂目のつやの無い面に見えた)。空へ抜けた印に距離を負で書く
            if (s.materialId == MAT_WATER) skyMiss = true;
            else radiance = skyPixelReflection(skyDir, s.skyLm, radiance);
        }
    }

    float lum = luminance(radiance);
    if (lum > REFLECTION_MAX_LUMINANCE) radiance *= REFLECTION_MAX_LUMINANCE / lum;

#if REFLECTIONS >= 2
    if (s.perceptualRoughness >= MIRROR_ROUGHNESS) {
        float alpha = mix(0.5, REFLECTION_ALPHA_MIN, saturate((s.perceptualRoughness - MIRROR_ROUGHNESS) / 0.4));
        vec2 uv = (vec2(texel) + 0.5) / viewSize();
        vec2 prevUv = getPreviousUv(uv, s.depth);
        if (all(greaterThan(prevUv, vec2(0.0))) && all(lessThan(prevUv, vec2(1.0)))) {
            ivec2 pl = clamp(ivec2(prevUv * vec2(lowSize)), ivec2(0), lowSize - 1);
            vec4 h = imageLoad(reflectionImg, pl + prevRegion);
            float expected = length(playerPos + cameraPosition - previousCameraPosition);
            if (h.a > 0.0 && abs(h.a - expected) < expected * 0.04 + 0.1) radiance = mix(h.rgb, radiance, alpha);
        }
    }
#endif

    imageStore(reflectionImg, low + region, vec4(radiance, skyMiss ? -dist : dist));
}
