/*
 * 光るパーティクル (花火の火花など) の見た目 (surface モジュール、FIREWORK_GLOW)
 * バニラは自己発光の粒 (花火の火花と尾・エンドロッド・トーテム・発光イカや電気の火花) をライトマップ最大 (空と光源とも 240) で描く。
 * 照明の代わりに発光にする
 *   - 明るさは AgX の肩の手前に置いて色を残し、白を超えた分のブルームで光らせる。芯だけ少し白へ寄せる。
 *     花火の炎色は単色に近いので、テクスチャ x 頂点色の色を濃くする (そのままでは明るい粒が淡いピンクや水色になった)
 *   - 遠くの粒は画素より小さくなり、ジッターで当たり外れして TAA (露出込みの c / (1 + L) で混ぜる) で光が潰れる。
 *     四角を画面で PARTICLE_GLOW_MARGIN_PX だけ広げて必ず数画素に掛け、広げた分だけ明るさを割って光の量を保つ。
 *     数画素の粒はテクスチャ (8x8) の点の当たり外れでも消えるので、テクスチャの代わりに丸い点にする
 *   - 白を超えた分は composite2 が鏡面の白飛びと同じ経路 (SPECULAR_SPARKLE) で TAA の外へ渡す
 *   - 点光源の画素の明るさは距離の 2 乗で落ちて遠くの花火がくすむので、遠いほど距離の平方根で明るくする
 * 花火の開いた瞬間の閃光 (バニラの flash の粒) はライトマップが周りの明るさのままで、夜は空より暗い円盤になって星を隠していた。
 * 数ブロックの大きさの半透明の粒は閃光だけなので、大きさで見分けて光らせる
 */
#ifndef SURFACE_PARTICLE_GLOW_GLSL
#define SURFACE_PARTICLE_GLOW_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/exposure.glsl"

// ライトマップの生の値 (0-240)。空と光源の両方が最大の粒だけを光る粒とみなす
const float PARTICLE_FULLBRIGHT_LIGHTMAP = 239.5;
// 四角を広げる幅 (画素)。ジッター (±0.5 画素) があっても 2x2 画素以上に掛かる
const float PARTICLE_GLOW_MARGIN_PX = 1.5;
// 元の四角がこの画素数より小さい時はテクスチャの代わりに丸い点で描く
const vec2 PARTICLE_GLOW_DOT_PX = vec2(2.0, 5.0);
const float PARTICLE_GLOW_DOT_FALLOFF = 3.0;
// 露出に合わせた発光 (getVisibleEmissionLuminance) に対する倍率。6 では夜の大きな玉が白い円盤になり、1.5 でも色が淡いピンクに抜けた
const float PARTICLE_GLOW_GAIN = 0.6;
// 色の濃さ (最大成分で割った色の累乗)
const float PARTICLE_GLOW_PURITY = 1.6;
// テクスチャの明るい画素 (粒の芯) を白へ寄せる範囲と割合
const vec2 PARTICLE_GLOW_CORE = vec2(0.8, 1.0);
const float PARTICLE_GLOW_CORE_WHITE = 0.2;
// これより遠い粒は距離の平方根で明るくする (ブロック)。上限の倍率
const float PARTICLE_GLOW_NEAR_DISTANCE = 16.0;
const float PARTICLE_GLOW_DISTANCE_GAIN_MAX = 4.0;
// 瞬きの揺らぎの細かさ (1/ブロック) と速さ (1/秒)。近い火花どうしが少しずつずれて瞬く
const float PARTICLE_TWINKLE_SCALE = 0.6;
const float PARTICLE_TWINKLE_RATE = 9.0;
// 閃光: これより大きい (ブロック) 半透明の粒で、空の見える所 (スカイライト) のもの。火花より暗く、丸く柔らかい光にする
const float FIREWORK_FLASH_MIN_SIZE = 2.5;
const float FIREWORK_FLASH_MIN_SKYLIGHT = 0.9;
const float FIREWORK_FLASH_GAIN = 0.12;
// 閃光の中心から縁への落ち方 (縁を輪郭にせず、空へ溶かす)
const float FIREWORK_FLASH_FALLOFF = 4.0;

bool isGlowingParticle(vec2 rawLightmap) { return min(rawLightmap.x, rawLightmap.y) > PARTICLE_FULLBRIGHT_LIGHTMAP; }

// 四角の頂点の角 (-1..1)。バニラの粒は 4 頂点ずつ 右下・右上・左上・左下 の順に並ぶ
vec2 particleCorner(int vertexId) {
    const vec2 CORNERS[4] = vec2[4](vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0), vec2(-1.0, -1.0));
    return CORNERS[vertexId & 3];
}

// view 空間の頂点を画面で PARTICLE_GLOW_MARGIN_PX だけ外へ出す (粒の四角はカメラに正対している)
vec3 expandParticleCorner(vec3 viewPos, vec2 corner) {
    float pixel = 2.0 * max(-viewPos.z, 0.05) / (gbufferProjection[1][1] * viewHeight);
    viewPos.xy += corner * (0.5 * PARTICLE_GLOW_MARGIN_PX * pixel);
    return viewPos;
}

// 明るさの倍率 (1 の前後)
float particleTwinkle(vec3 worldPos) {
    float n = valueNoise3d(worldPos * PARTICLE_TWINKLE_SCALE + vec3(0.0, 0.0, frameTimeCounter * PARTICLE_TWINKLE_RATE));
    return 1.0 + FIREWORK_TWINKLE_STRENGTH * (n * 2.0 - 1.0);
}

vec3 particleGlowColor(vec3 srgb) {
    vec3 lin = srgbToLinear(srgb);
    float peak = maxOf(lin);
    return peak * pow(lin / max(peak, 1e-4), vec3(PARTICLE_GLOW_PURITY));
}

/*
 * 光る粒の放射輝度 (rgb) と不透明度 (a)
 * tex: テクスチャ (sRGB、頂点色を掛ける前)、color: 頂点色、corner: 補間した四角の角、cornerWidth: その fwidth
 * (分岐の外で求める)、gain: 瞬きの倍率、dist: カメラからの距離
 */
vec4 evalParticleGlow(vec4 tex, vec4 color, vec2 corner, vec2 cornerWidth, float gain, float dist) {
    // 広げた後と前の四角の画素数 (角の値は四角の端から端で 2 変わる)
    vec2 px = 2.0 / max(cornerWidth, vec2(1e-4));
    vec2 orig = max(px - PARTICLE_GLOW_MARGIN_PX, vec2(0.0));
    float energy = (orig.x / px.x) * (orig.y / px.y);
    float dotShape = 1.0 - smoothstep(PARTICLE_GLOW_DOT_PX.x, PARTICLE_GLOW_DOT_PX.y, min(orig.x, orig.y));
    float disk = exp(-dot(corner, corner) * PARTICLE_GLOW_DOT_FALLOFF);
    vec3 texRgb = mix(tex.rgb, vec3(1.0), dotShape);
    float alpha = mix(tex.a, disk, dotShape) * color.a;
    vec3 lin = particleGlowColor(texRgb * color.rgb);
    lin = mix(lin, vec3(maxOf(lin)), smoothstep(PARTICLE_GLOW_CORE.x, PARTICLE_GLOW_CORE.y, maxOf(texRgb)) * PARTICLE_GLOW_CORE_WHITE);
    float far = clamp(sqrt(dist / PARTICLE_GLOW_NEAR_DISTANCE), 1.0, PARTICLE_GLOW_DISTANCE_GAIN_MAX);
    float radiance = getVisibleEmissionLuminance() * (PARTICLE_GLOW_GAIN * FIREWORK_GLOW_STRENGTH) * gain * energy * far;
    return vec4(lin * radiance, alpha);
}

// 閃光の粒か。quadSize: 四角の幅 (ブロック)、skylight: ライトマップのスカイライト (0-1)
bool isFireworkFlash(float quadSize, float skylight) {
    return quadSize > FIREWORK_FLASH_MIN_SIZE && skylight > FIREWORK_FLASH_MIN_SKYLIGHT;
}

// 閃光の放射輝度と不透明度。テクスチャの粗い段を出さないように、角から求めた丸い形にする
vec4 evalFireworkFlash(vec4 color, vec2 corner) {
    float r2 = saturate(dot(corner, corner));
    float shape = exp(-FIREWORK_FLASH_FALLOFF * r2) * (1.0 - r2);
    float radiance = getVisibleEmissionLuminance() * (FIREWORK_FLASH_GAIN * FIREWORK_GLOW_STRENGTH);
    return vec4(particleGlowColor(color.rgb) * radiance, shape * color.a);
}

#endif
