/*
 * 半透明ジオメトリ共通のフラグメントシェーダー (前方シェーディングして colortex4/5 へ)
 * 屈折・反射・水中フォグは composite2 で合成する
 * surface モジュール (lib/surface)
 *
 * 水: 色は書かず (a = 0)、法線とライトマップだけを colortex5 に残す。水の見た目 (屈折・吸収・反射・泡・太陽の鏡面) は
 *     composite2 でまとめて計算する (屈折先の深度と経路長が要るため)
 * ガラス等: 拡散だけを前方で照らす。鏡面 (太陽・手持ち光源・ブロックライト・反射) と透過は composite2 が掛ける
 *     透過色は block_data の tints 表 (光源シャドウ・色付き影と同じ色) を使うので、その index を colortex5 に残す
 * 半透明パーティクル: 普通のアルファ合成。colortex5 は書かない (水面の情報を上書きして穴が開くのを防ぐ)
 * 半透明エンティティ / ブロックエンティティ: Iris 26.1 はプレイヤー (スキンが entityTranslucent)・文字・旗の模様などを
 *     deferred の後 (renderTranslucentFeatures) に描くので G バッファに書いても照明されない。ここで前方シェーディングする
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
#include "/lib/common/water_glitter.glsl"
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
#include "/lib/sky/cloud_styles.glsl"
#include "/lib/sky/clouds.glsl"
#include "/lib/sky/sky_color.glsl"
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
in vec2 lmcoord;
in vec4 glcolor;
in vec3 viewPos;
in vec3 normalPlayer;
in vec4 tangentPlayer;
flat in int blockId;

#if defined GBUF_ENTITIES_TRANSLUCENT || defined GBUF_BLOCK_TRANSLUCENT
    #define GBUF_FORWARD_OPAQUE
#endif

#ifdef GBUF_PARTICLES_TRANSLUCENT
    /* RENDERTARGETS: 4 */
    layout(location = 0) out vec4 outColor;
#elif defined GBUF_ENTITIES_TRANSLUCENT
    /* RENDERTARGETS: 4,5,15 */
    layout(location = 0) out vec4 outColor;
    layout(location = 1) out vec4 outData;
    layout(location = 2) out vec4 outVelocity;
#else
    /* RENDERTARGETS: 4,5 */
    layout(location = 0) out vec4 outColor;
    layout(location = 1) out vec4 outData;
#endif

// 手持ち光源の照り返し (deferred30 と同じ getHandLightFill) に掛ける倍率。この経路には GI が無いのでその分を上乗せする
const float HAND_LIGHT_BOUNCE = 2.5;
// WATER_TEXTURE でバニラの水テクスチャを重ねる不透明度
const float WATER_TEXTURE_OPACITY = 0.3;

// colortex5.a の予備 8bit に透過色の index (+1, 0 = なし) を入れる
vec4 encodeTranslucentDataTint(vec3 normal, vec2 lightmap, int materialId, int tintIndex) {
    vec4 d = encodeTranslucentData(normal, lightmap, materialId);
    d.a = pack2x8(vec2(float(materialId), float(tintIndex)) / 255.0);
    return d;
}

// 前方シェーディングの拡散 (太陽 + 手持ち光源 + 空 + ブロックライト)
vec3 forwardDiffuse(Material m, vec3 playerPos, vec3 normal, vec3 geoNormal, vec3 V, float dither) {
    // 集める項: 太陽の影 (影マップの外は 1)・手持ち光源・空・ブロックライト
    // 省く項: 接触影と POM (深度に半透明が無い・POM なし)、鏡面 (composite2 が掛ける)、GI と AO (この経路にバッファが無い。手持ち光源の照り返しが GI の代わり)
    // 太陽 -> 手持ち -> 空とブロックライト -> 手持ちの照り返し に分けて集め、拡散を掛ける順番を保つ
    // (まとめて 1 回で集めると、手持ち光源のトレースが太陽の拡散より前に並んでドライバの出す命令の並びが変わる)
#ifdef GBUF_FORWARD_OPAQUE
    const int blockMode = SL_BLOCK_FORWARD_ENTITY;
#else
    const int blockMode = SL_BLOCK_FORWARD;
#endif
    SurfacePoint p = surfacePoint(playerPos, normal);
    p.geoNormal = geoNormal;
    p.lightmap = lmcoord;
    p.dither = dither;
    SurfaceLights L = gatherSurfaceLights(p, SL_SUN_SHADOW_MAP, SL_BLOCK_NONE, 0u);
    vec3 color = evalDirectDiffuse(m, normal, V, L.sun);
    L = gatherSurfaceLights(p, SL_SUN_NONE, SL_BLOCK_NONE, SL_HAND);
    color += evalDirectDiffuse(m, normal, V, L.handMain);
    color += evalDirectDiffuse(m, normal, V, L.handOff);
    L = gatherSurfaceLights(p, SL_SUN_NONE, blockMode, SL_SKY);

    vec3 ambient = L.sky + L.block + minAmbientIrradiance();
    /*
     * 手持ち光源は floodfill に入らず、この経路には GI も無いので、三人称の自分の背中 (光源の反対側) やガラスの陰が真っ黒になる
     * 周りの壁・床で跳ね返った光を、影なし・向きなしの照度の一定割合の環境光として足す
     * (影付きの照度に掛けると、体で遮られた側に何も残らない)
     */
    L = gatherSurfaceLights(p, SL_SUN_NONE, SL_BLOCK_NONE, SL_HAND_FILL);
    ambient += L.handFill * HAND_LIGHT_BOUNCE;
    return color + evalDiffuseIrradiance(m, ambient);
}

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < 0.01) discard;

#if defined GBUF_ENTITIES_TRANSLUCENT
    // バニラの丸影は太陽影・光源シャドウと二重になるので描かない
    if (entityId == ENTITY_SHADOW || albedo.a < alphaTestRef) discard;
    int materialId = entityIdToMaterial(entityId, currentRenderedItemId);
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
#elif defined GBUF_BLOCK_TRANSLUCENT
    if (albedo.a < alphaTestRef) discard;
    int materialId = MAT_BLOCK_ENTITY;
#elif defined GBUF_WATER
    int materialId = blockIdToMaterial(blockId);
#elif defined GBUF_HAND_WATER
    int materialId = MAT_HAND;
#else
    int materialId = MAT_PARTICLE;
#endif

    vec3 playerPos = viewToPlayer(viewPos);
    vec3 geoNormal = normalize(normalPlayer);
    vec3 V = -normalize(playerPos);
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    GBufferData g = gbufferDefault();
    g.albedo = srgbToLinear(albedo.rgb);
    Material m = decodeMaterial(g);

#ifndef GBUF_PARTICLES_TRANSLUCENT
    if (materialId == MAT_WATER) {
        vec3 worldPos = playerPos + cameraPosition;
        WaterSea sea = waterSeaState(lmcoord.y);
        float footprint = waterFootprint(length(playerPos), abs(dot(geoNormal, V)));
        // 流れる水の上面は傾いているが、頂点の法線は真上のままなので三角形の向きは画面微分から取る
        vec3 faceNormal = normalize(cross(dFdx(playerPos), dFdy(playerPos)));
        if (dot(faceNormal, geoNormal) < 0.0) faceNormal = -faceNormal;
        vec2 flow = waterFlowVelocity(faceNormal, geoNormal);
        if (geoNormal.y > 0.5 && dot(flow, flow) < 1e-4) worldPos = waterParallax(sea, worldPos, -V, footprint);
        vec3 normal = getWaterNormal(sea, worldPos, geoNormal, footprint, flow);
        outData = encodeTranslucentDataTint(normal, lmcoord, MAT_WATER, 0);
    #ifdef WATER_TEXTURE
        outColor = vec4(forwardDiffuse(m, playerPos, geoNormal, geoNormal, V, dither), albedo.a * WATER_TEXTURE_OPACITY);
    #else
        outColor = vec4(0.0);
    #endif
        return;
    }
#endif

    vec3 color = forwardDiffuse(m, playerPos, geoNormal, geoNormal, V, dither);
    if (materialId == MAT_NETHER_PORTAL) color += m.albedo * getVisibleEmissionLuminance() * EMISSION_STRENGTH;
#ifdef GBUF_FORWARD_OPAQUE
    // G バッファ経路 (solid.fsh の estimateEmission) と同じく、発光エンティティは明るい画素だけ光らせる
    if (materialId == MAT_EMISSIVE_ENTITY) {
        color += m.albedo * smoothstep(0.55, 0.9, maxOf(albedo.rgb)) * getVisibleEmissionLuminance() * EMISSION_STRENGTH;
    }
#endif
    int tintIndex = 0;
#ifdef GBUF_WATER
    // 光を散乱する割合は a (既定のブレンドで a が掛かる)。残り (1 - a) の透過分に composite2 が透過色を掛ける
    if (isTintBlock(blockId)) tintIndex = getTintIndex(blockId) + 1;
#endif

    outColor = vec4(color, albedo.a);
#ifndef GBUF_PARTICLES_TRANSLUCENT
    outData = encodeTranslucentDataTint(geoNormal, lmcoord, materialId, tintIndex);
#endif
#ifdef GBUF_ENTITIES_TRANSLUCENT
    // 半透明の描画は距離順に並べ替えられて頂点の対応が崩れ、at_velocity が使えない (三人称の自分が大きくぶれる)
    // (そもそも Iris 26.1 には at_velocity が無い。lib/post/velocity.glsl)
    // a = 0 にして深度からの再投影 (静止物扱い) に任せる。背後のエンティティの速度も上書きする
    outVelocity = vec4(0.0);
#endif
}
