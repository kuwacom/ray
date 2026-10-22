/*
 * deferred30: 不透明面のシェーディング (全モジュールの光をここで合成) と空の描画
 *   太陽/月: sky の getCelestialLight x surface の getSunShadow x sky の getCloudShadow
 *   空の環境光: sky の getSkyIrradiance x スカイライト x surface の AO
 *   ブロックライト: light の getBlockLightOpaque (+ 鏡面 getBlockLightSpecular)
 *   手持ち光源: light の getHandLights
 *   GI: surface の getIndirectLight
 * surface モジュール (lib/surface)
 *
 * 環境光の鏡面 (反射バッファ・空) はここでは足さず composite1 で足す (反射パスが colortex0 のこの結果を映すため)
 * 合成の考え方
 *   太陽: PCSS の影 (色付き・水底のコースティクス込み) x POM の自己影 x 接触影 x 雲影。影マップの外はスカイライトで近似
 *   SSS: 影のブロッカー探索で得た厚みで減衰させた太陽光を裏面透過として足す
 *   AO: 空の照度には多重バウンス AO を全部、ブロックライトには半分 (光源シャドウで既に遮蔽されているため)、GI はバニラ AO だけ
 */
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

const float AO_BLOCKLIGHT_WEIGHT = 0.5;
// SSS の減衰 (1/ブロック, sss = 1 の時)。葉 1 枚 (~0.1 ブロック) は通し、葉ブロック 1 個分でかなり暗くなる
const float SSS_DENSITY = 2.5;
// 溶岩の面が受けるブロックライト・GI の割合
const float LAVA_RECEIVED_LIGHT = 0.15;
/*
 * 溶岩の見た目の輝度。以前は他の発光と同じ g.emission (0.12-0.3) x 露出の -0.45 乗で、暗い洞窟では
 * 溶岩に照らされた壁と同じ明るさになり、光って見えなかった。周りへの光 (光源・floodfill・GI の g.emission) は変えず、見た目の輝度だけ別に持つ
 *   橙の地 (テクスチャの線形輝度 LAVA_BODY_ALBEDO) を LAVA_LUMINANCE にし、黄色い筋は輝度の比の LAVA_PATTERN_CONTRAST 乗で明るくする
 *   画面に溶岩が多いと露出が下がって橙の地が露出後 0.3-0.5 に収まる。溶岩が小さく露出が高い時は、露出後の地の明るさを
 *   LAVA_EXPOSED_MAX で頭打ちにする (白く飛ばさない)。色は final の溶岩専用のトーンマップで橙のまま残す
 * -> 頭打ちのままではブルームの滲みが出ず光って見えなかった。滲みはブルームの元でだけ溶岩を明るくして出す
 *    (composite23 の LAVA_BLOOM_GAIN)。上限は 0.7 -> 1.2 (トーンマップの白へ抜け始めを上げたので橙の地は淡くならない)
 * -> ここ (シーンの HDR) を上げると露出の測光が下がって周りの壁が暗くなり、ブルームも一緒に変わるので、
 *    見た目の明るさは final で表示の段だけ上げる (設定 LAVA_BRIGHTNESS)。上限 1.2 はそのまま
 */
const float LAVA_LUMINANCE = 0.8;
const float LAVA_BODY_ALBEDO = 0.175;
const float LAVA_PATTERN_CONTRAST = 1.7;
const float LAVA_EXPOSED_MAX = 1.2;

vec3 lavaRadiance(vec3 albedo) {
    float lum = max(luminance(albedo), 1e-4);
    float pattern = pow(lum / LAVA_BODY_ALBEDO, LAVA_PATTERN_CONTRAST);
    float exposed = LAVA_LUMINANCE * getExposure();
    float limit = inversesqrt(1.0 + sqr(exposed / LAVA_EXPOSED_MAX));
    return albedo / lum * (pattern * LAVA_LUMINANCE * limit);
}

// 影マップの外での日向の判定 (スカイライトがこれ以上なら日向とみなす)
const vec2 SHADOW_FALLBACK_SKYLIGHT = vec2(0.8, 0.97);

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex0, texel, 0).r;

    if (depth >= 1.0) {
        vec3 dir = normalize(viewToPlayerDir(screenToView(vec3(texcoord, 1.0))));
        vec3 sky = renderSky(dir, texelFetch(colortex0, texel, 0).rgb);
        vec4 clouds = getCloudLayer(texel);
        outColor = vec4(sky * clouds.a + clouds.rgb, 1.0);
        return;
    }

    GBufferData g = readGBuffer(texel);
    Material m = decodeMaterial(g);
    bool hand = isHandDepth(depth);
    vec3 viewPos = screenToView(vec3(texcoord, fixHandDepth(depth)));
    vec3 playerPos = viewToPlayer(viewPos);
    vec3 V = -normalize(playerPos);
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);
    vec4 indirect = getIndirectLight(texel);
    float pomShadow, puddle;
    readSurfaceExtra(texel, pomShadow, puddle);

    // ---- 太陽 / 月 ----
    LightSample sun = getCelestialLight();
    SunShadow ss = evalSunShadow(playerPos, g.geoNormal, m.sss, dither);
    float fallback = smoothstep(SHADOW_FALLBACK_SKYLIGHT.x, SHADOW_FALLBACK_SKYLIGHT.y, g.lightmap.y);
    vec3 sunVis = mix(vec3(fallback), ss.visibility, ss.fade) * pomShadow;
    // 一人称の手は影マップ上で自分の体の影の中にあるので、スカイライトから日向を推定する
    if (hand) sunVis = vec3(fallback);
#ifdef SCREEN_SPACE_SHADOWS
    if (!hand && maxOf(sunVis) > 0.0) sunVis *= screenSpaceShadow(viewPos, playerToViewDir(g.geoNormal), playerToViewDir(sun.direction), dither);
#endif
    float cloudShadow = getCloudShadow(playerPos);
    LightSample sunLit = sun;
    sunLit.irradiance *= sunVis * cloudShadow;
    vec3 color = evalDirectLight(m, g.normal, V, sunLit);

    if (m.sss > 0.0) {
        // 厚みに応じた減衰。アルベドの色ほど通りやすい (葉は緑に透ける)
        float thickness = mix(1.0 - fallback, ss.thickness, ss.fade);
        vec3 transmit = exp(-thickness * SSS_DENSITY / max(m.sss, 0.05) * (1.15 - m.albedo));
        LightSample through = sun;
        through.irradiance *= transmit * cloudShadow * pomShadow;
        color += evalTranslucency(m, g.normal, V, through) * SSS_STRENGTH;
    }

    // ---- 手持ち光源・ブロックライトの鏡面 ----
    LightSample handMain, handOff;
    getHandLights(playerPos, g.geoNormal, dither, handMain, handOff);
    color += evalDirectLight(m, g.normal, V, handMain) + evalTranslucency(m, g.normal, V, handMain);
    color += evalDirectLight(m, g.normal, V, handOff) + evalTranslucency(m, g.normal, V, handOff);
    LightSample blockSpec[BLOCKLIGHT_SPECULAR_LIGHTS];
    int blockSpecCount = getBlockLightSpecular(texel, playerPos, g.geoNormal, blockSpec);
    for (int j = 0; j < blockSpecCount; j++) color += evalDirectSpecular(m, g.normal, V, blockSpec[j]);

    // ---- 環境光 (空・ブロックライト・GI) ----
    float ao = g.ao * indirect.a;
    vec3 skyAmbient = getSkyIrradiance(g.normal) * skylightCurve(g.lightmap.y) * aoMultiBounce(ao, m.albedo + m.f0 * m.metalness);
    vec3 blockLight = getBlockLightOpaque(texel, playerPos, g.geoNormal, g.normal, g.lightmap.x) * mix(1.0, ao, AO_BLOCKLIGHT_WEIGHT);
    // 手の見える面は大抵カメラ (= 光源の反対側) を向くので直接光が当たらず真っ黒になる
    // 画面に貼り付いた小物なので、立ち位置のバニラのライトマップ相当を下限にする
    if (hand) blockLight = max(blockLight, blockLightmapFallback(g.lightmap.x));
    else blockLight += getHandLightFill(playerPos) * ao;
    vec3 indirectLight = indirect.rgb * g.ao;
    bool lava = readMaterialId(texel) == MAT_LAVA;
    if (lava) {
        /*
         * 溶岩の面は隣のセルの流体光源 (表面のアンカー) と floodfill に至近距離から照らされ、発光より何倍も明るくなって
         * AgX の肩で彩度が抜け、溶岩の滝が白っぽいサーモン色になった。見た目は発光に任せる
         */
        blockLight *= LAVA_RECEIVED_LIGHT;
        indirectLight *= LAVA_RECEIVED_LIGHT;
    }
    vec3 ambient = skyAmbient + blockLight + indirectLight + (MIN_AMBIENT + nightVision * NIGHT_VISION_AMBIENT) * ao;
    color += evalDiffuseIrradiance(m, ambient);

    if (lava) color += lavaRadiance(g.albedo) * EMISSION_STRENGTH;
    else color += g.albedo * g.emission * getVisibleEmissionLuminance() * EMISSION_STRENGTH;
    outColor = vec4(color, 1.0);
}
