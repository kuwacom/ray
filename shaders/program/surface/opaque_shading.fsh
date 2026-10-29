/*
 * deferred30: 不透明面のシェーディング (全モジュールの光をここで合成) と空の描画
 *   光は surface の gatherSurfaceLights (lib/surface/surface_lights.glsl) で集め、BRDF・AO・溶岩・水たまり・SSS の減衰をここで掛ける
 *   太陽/月: 影 x 雲影、空の環境光: SH x スカイライト x AO
 *     (SSGI / ボクセル RT では GI のレイが向きと遮蔽込みで空の光を運び、これを置き換える。GI_TRACES_SKY)
 *   ブロックライト: 拡散 (+ 鏡面)、手持ち光源、GI
 * surface モジュール (lib/surface)
 *
 * 環境光の鏡面 (反射バッファ・空) はここでは足さず composite1 で足す (反射パスが colortex0 のこの結果を映すため)
 * 合成の考え方
 *   太陽: PCSS の影 (色付き・水底のコースティクス込み) x POM の自己影 x 接触影 x 雲影。影マップの外はスカイライトで近似
 *   SSS: 影のブロッカー探索で得た厚みで減衰させた太陽光を裏面透過として足す。手持ち光源の透過も含め、設定 SSS が無ければ外す
 *   AO: 空の照度には多重バウンス AO を全部、ブロックライトには半分 (光源シャドウで既に遮蔽されているため)、GI はバニラ AO だけ
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/exposure.glsl"
//@include "/lib/surface/surface.glsl"
//@include "/lib/sky/sky.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/surface/surface_lights.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/common/exposure.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_glint.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sh.glsl"
#include "/lib/common/phase.glsl"
#include "/lib/sky/atmosphere.glsl"
#include "/lib/sky/celestial.glsl"
#include "/lib/sky/sky_color.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/fog_template.glsl"
#include "/lib/sky/climate.glsl"
#include "/lib/sky/fog_styles.glsl"
#include "/lib/sky/fog.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/surface_lights.glsl"
// END GENERATED includes

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

const float AO_BLOCKLIGHT_WEIGHT = 0.5;
// GI が空の光を運ぶ時 (GI_TRACES_SKY): テクスチャ法線の凹凸の戻し方の範囲、GTAO を掛ける割合
const float GI_NORMAL_DETAIL_MIN = 0.5;
const float GI_NORMAL_DETAIL_MAX = 1.5;
const float GI_SKY_GTAO_WEIGHT = 0.5;
// SSS の減衰 (1/ブロック, sss = 1 の時)。葉 1 枚 (~0.1 ブロック) は通し、葉ブロック 1 個分でかなり暗くなる
const float SSS_DENSITY = 2.5;
// 溶岩の面が受けるブロックライト・GI の割合
const float LAVA_RECEIVED_LIGHT = 0.15;
/*
 * 溶岩の見た目の輝度。他の発光と同じ g.emission (0.12-0.3) x 露出の -0.45 乗では、暗い洞窟で
 * 溶岩に照らされた壁と同じ明るさになり、光って見えない。周りへの光 (光源・floodfill・GI の g.emission) は変えず、見た目の輝度だけ別に持つ
 *   橙の地 (テクスチャの線形輝度 LAVA_BODY_ALBEDO) を LAVA_LUMINANCE にし、黄色い筋は輝度の比の LAVA_PATTERN_CONTRAST 乗で明るくする
 *   画面に溶岩が多いと露出が下がって橙の地が露出後 0.3-0.5 に収まる。溶岩が小さく露出が高い時は、露出後の地の明るさを
 *   LAVA_EXPOSED_MAX で頭打ちにする (白く飛ばさない)。色は final の溶岩専用のトーンマップで橙のまま残す
 * 頭打ちのままではブルームの滲みが出ず光って見えないので、滲みはブルームの元でだけ溶岩を明るくして出す
 * (composite23 の LAVA_BLOOM_GAIN)。上限 1.2 (溶岩のトーンマップは白へ抜け始めが高いので、橙の地は淡くならない)
 * ここ (シーンの HDR) を上げると露出の測光が下がって周りの壁が暗くなり、ブルームも一緒に変わるので、
 * 見た目の明るさは final で表示の段だけ上げる (設定 LAVA_BRIGHTNESS)
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

const float PUDDLE_GLINT_MIN_VOH = 0.05;

/*
 * 水たまりの光 L の鏡面。傾きの分散 slopeVar で広げた滑らかなローブを (1 - share) 残し、share を輝点にする
 * (lib/common/water.glsl の waterSunGlint。composite1 の水面の sunGlint と同じ分け方)
 * 戻り値 rgb = 鏡面の放射輝度, a = そのうち輝点の輝度 (composite20 の TAA を通さずに足す分)
 */
vec4 puddleSpecular(Material m, vec3 N, vec3 V, LightSample L, vec3 playerPos, vec3 geoNormal, float slopeVar, float share) {
    Material rough = m;
    rough.roughness = sqrt(sqr(m.roughness) + slopeVar);
    vec3 lobe = evalDirectSpecular(rough, N, V, L);
    if (maxOf(lobe) <= 0.0) return vec4(0.0);
    float dist = length(playerPos);
    float pixelWorld = dist * 2.0 / (gbufferProjection[1][1] * viewSize().y);
    float NoVGeo = abs(dot(V, geoNormal));
    vec3 H = normalize(V + L.direction);
    // 照り返しの芯が白く飛んでいる所は点にしない (白い面の中の点がブルームと光条の起点になる)
    share *= glintWhiteKeep(luminance(lobe) * getExposure());
    /*
     * waterSunGlint の円盤の面積は、光源の立体角を半ベクトルへ写す 1 / (4 VoH) を省いている。低い太陽を見る水たまり (VoH 0.1-0.3)
     * では光源を映す面の数が数分の一になり、点が少なく、1 点が下の上限で切られて照り返しの明るさの大半が消えていた
     * 水面は今の見た目で合わせてあるので変えず、ここで円盤の半径を広げて渡す
     */
    float facetRadius = L.angularSize * inversesqrt(max(dot(V, H), PUDDLE_GLINT_MIN_VOH));
    vec2 gl = waterSunGlint(playerPos.xz + cameraPosition.xz, N, V, L.direction, slopeVar, facetRadius, pixelWorld, NoVGeo);
    // 1 枚の面が映す明るさは光源の円盤の鏡像まで (GGX の裾と正規分布の裾の違いで出る極端な値を抑える)
    vec3 mirror = L.irradiance * materialFresnel(m, saturate(dot(V, H))) / (PI * sqr(max(L.angularSize, 1e-3)));
    vec3 point = min(lobe * gl.y, mirror) * share;
    return vec4(lobe * (1.0 - share + share * (gl.x - gl.y)) + point, luminance(point));
}

// 直接光 (拡散 + 鏡面)。水たまり (share > 0) は鏡面を puddleSpecular に置き換え、輝点の輝度を glintLum に足す
vec3 directLight(Material m, vec3 N, vec3 V, LightSample L, vec3 playerPos, vec3 geoNormal, float slopeVar, float share, inout float glintLum) {
    if (share <= 0.0) return evalDirectLight(m, N, V, L);
    vec4 s = puddleSpecular(m, N, V, L, playerPos, geoNormal, slopeVar, share);
    glintLum += s.a;
    return max(evalDirectLight(m, N, V, L) - evalDirectSpecular(m, N, V, L), 0.0) + s.rgb;
}

vec3 directSpecular(Material m, vec3 N, vec3 V, LightSample L, vec3 playerPos, vec3 geoNormal, float slopeVar, float share, inout float glintLum) {
    if (share <= 0.0) return evalDirectSpecular(m, N, V, L);
    vec4 s = puddleSpecular(m, N, V, L, playerPos, geoNormal, slopeVar, share);
    glintLum += s.a;
    return s.rgb;
}

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
    SurfacePoint sp = surfacePoint(playerPos, g.normal);
    sp.viewPos = viewPos;
    sp.geoNormal = g.geoNormal;
    sp.lightmap = g.lightmap;
    sp.texel = texel;
    sp.dither = dither;
    sp.hand = hand;
    vec4 indirect = gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_NONE, SL_GI).indirect;
    float pomShadow, puddle;
    readSurfaceExtra(texel, pomShadow, puddle);
    // 水たまりの照り返しを輝点に分ける割合と傾きの分散。縁の半分から内側を水面とみなす (solid.fsh の法線の混ぜ方と同じ)
    float puddleWeight = hand ? 0.0 : saturate(puddle * 2.0);
    float glintShare = WATER_GLINT * PUDDLE_GLINT_POINT_SHARE * puddleWeight * glintNearFade(length(playerPos));
    float glintVar = puddleSlopeVar() * puddleWeight;
    float glintLum = 0.0;

    // 集める項: 太陽 (PCSS・POM・接触影・葉の透過。影マップの外はスカイライトで近似)・手持ち光源・ブロックライトの鏡面・
    //   空 (GI が運ぶ分を引く)・ブロックライト・手持ちの照り返し・GI
    // 省く項: なし (不透明面は全部掛かる)。環境光の鏡面 (反射) は composite1 が足す
    // 項ごとに分けて、太陽 -> 手持ち -> 鏡面 -> 空 -> ブロックライト -> 手持ちの照り返しの順に集める
    // (1 回にまとめると、トレースが太陽の BRDF より前に並んでドライバの出す命令の並びが変わる)
    sp.pomShadow = pomShadow;
#ifdef SSS
    sp.sss = m.sss;
#endif
    // SSS が無ければ透過を足さないので、裏向きの面の厚みの探索と影のにじみも要らない
    SurfaceLights L = gatherSurfaceLights(sp, SL_SUN_SHADOW_MAP_FALLBACK, SL_BLOCK_NONE, SL_SUN_CONTACT | SL_SUN_LEAF | SL_POM);

    // 太陽 / 月
    vec3 color = directLight(m, g.normal, V, L.sun, playerPos, g.geoNormal, glintVar, glintShare, glintLum);
    // 葉を透過した分 (拡散だけに使う。鏡面の太陽は葉の隙間を抜けた光だけで照り返す)
    if (maxOf(L.sunLeafVis) > 0.0) {
        LightSample leafLit = L.celestial;
        leafLit.irradiance *= L.sunLeafVis * L.cloudShadow;
        color += max(evalDirectLight(m, g.normal, V, leafLit) - evalDirectSpecular(m, g.normal, V, leafLit), 0.0);
    }

#ifdef SSS
    if (m.sss > 0.0) {
        // 厚みに応じた減衰。アルベドの色ほど通りやすい (葉は緑に透ける)
        float thickness = mix(1.0 - L.sunFallback, L.sunShadow.thickness, L.sunShadow.fade);
        vec3 transmit = exp(-thickness * SSS_DENSITY / max(m.sss, 0.05) * (1.15 - m.albedo));
        LightSample through = L.celestial;
        through.irradiance *= transmit * L.cloudShadow * pomShadow;
        color += evalTranslucency(m, g.normal, V, through) * SSS_STRENGTH;
    }
#endif

    // 手持ち光源・ブロックライトの鏡面
    sp.sunFade = L.sunShadow.fade;
    SurfaceLights H = gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_NONE, SL_HAND);
#ifdef SSS
    color += directLight(m, g.normal, V, H.handMain, playerPos, g.geoNormal, glintVar, glintShare, glintLum) + evalTranslucency(m, g.normal, V, H.handMain) * SSS_STRENGTH;
    color += directLight(m, g.normal, V, H.handOff, playerPos, g.geoNormal, glintVar, glintShare, glintLum) + evalTranslucency(m, g.normal, V, H.handOff) * SSS_STRENGTH;
#else
    color += directLight(m, g.normal, V, H.handMain, playerPos, g.geoNormal, glintVar, glintShare, glintLum);
    color += directLight(m, g.normal, V, H.handOff, playerPos, g.geoNormal, glintVar, glintShare, glintLum);
#endif
    SurfaceLights S = gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_NONE, SL_BLOCK_SPECULAR);
    for (int j = 0; j < S.blockSpecCount; j++) color += directSpecular(m, g.normal, V, S.blockSpec[j], playerPos, g.geoNormal, glintVar, glintShare, glintLum);

    // 環境光 (空・ブロックライト・GI)
    float ao = g.ao * indirect.a;
    SurfaceLights A = gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_NONE, SL_SKY | SL_GI);
    vec3 skyAmbient = A.sky * aoMultiBounce(ao, m.albedo + m.f0 * m.metalness);
    vec3 blockLight = gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_OPAQUE, 0u).block * mix(1.0, ao, AO_BLOCKLIGHT_WEIGHT);
    // 手の見える面は大抵カメラ (= 光源の反対側) を向くので直接光が当たらず真っ黒になる
    // 画面に貼り付いた小物なので、立ち位置のバニラのライトマップ相当を下限にする
    if (hand) blockLight = max(blockLight, blockLightmapFallback(g.lightmap.x));
    else blockLight += gatherSurfaceLights(sp, SL_SUN_NONE, SL_BLOCK_NONE, SL_HAND_FILL).handFill * ao;
    vec3 indirectLight = indirect.rgb * g.ao;
    if (A.giSky) {
        // GI は幾何法線で張った半球なので、テクスチャ法線の凹凸は空の SH の向きによる差で戻す
        // (照度として足すのではなく、2 つの法線の SH の比を取るだけなので gatherSurfaceLights を通さない)
        float detail = luminance(getSkyIrradiance(g.normal)) / max(luminance(getSkyIrradiance(g.geoNormal)), 1e-6);
        // ボクセルに入らない小物 (草・柵・エンティティ) の遮蔽は GTAO で足す。ブロックの遮蔽はレイが見ているので半分だけ
        indirectLight *= clamp(detail, GI_NORMAL_DETAIL_MIN, GI_NORMAL_DETAIL_MAX) * mix(1.0, indirect.a, GI_SKY_GTAO_WEIGHT);
    }
    bool lava = readMaterialId(texel) == MAT_LAVA;
    if (lava) {
        /*
         * 溶岩の面は隣のセルの流体光源 (表面のアンカー) と floodfill に至近距離から照らされ、発光より何倍も明るくなって
         * AgX の肩で彩度が抜け、溶岩の滝が白っぽいサーモン色になった。見た目は発光に任せる
         */
        blockLight *= LAVA_RECEIVED_LIGHT;
        indirectLight *= LAVA_RECEIVED_LIGHT;
    }
    vec3 ambient = skyAmbient + blockLight + indirectLight + minAmbientIrradiance() * ao;
    color += evalDiffuseIrradiance(m, ambient);

    if (lava) color += lavaRadiance(g.albedo) * EMISSION_STRENGTH;
    else color += g.albedo * g.emission * getVisibleEmissionLuminance() * EMISSION_STRENGTH;
    // 輝点の割合を a = 1 + 割合で composite1 -> composite11 -> composite20 (TAA の後に足す) へ渡す
    outColor = vec4(color, 1.0 + saturate(glintLum / max(luminance(color), 1e-6)));
}
