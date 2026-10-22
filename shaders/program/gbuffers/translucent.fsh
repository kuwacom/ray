/*
 * 半透明ジオメトリ共通のフラグメントシェーダー (前方シェーディングして colortex4/5 へ)
 * 屈折・反射・水中フォグは composite1 で合成する
 * surface モジュール (lib/surface)
 *
 * 水: 色は書かず (a = 0)、法線とライトマップだけを colortex5 に残す。水の見た目 (屈折・吸収・反射・泡・太陽の鏡面) は
 *     composite1 でまとめて計算する (屈折先の深度と経路長が要るため)
 * ガラス等: 拡散だけを前方で照らす。鏡面 (太陽・反射) と透過は composite1 が掛ける
 *     透過色は block_data の tints 表 (光源シャドウ・色付き影と同じ色) を使うので、その index を colortex5 に残す
 * 半透明パーティクル: 普通のアルファ合成。colortex5 は書かない (水面の情報を上書きして穴が開くのを防ぐ)
 * 半透明エンティティ / ブロックエンティティ: Iris 26.1 はプレイヤー (スキンが entityTranslucent)・文字・旗の模様などを
 *     deferred の後 (renderTranslucentFeatures) に描くので G バッファに書いても照明されない。ここで前方シェーディングする
 */
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"

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
    LightSample sun = getCelestialLight();
    sun.irradiance *= getSunShadow(playerPos, geoNormal, dither) * getCloudShadow(playerPos);
    vec3 color = evalDirectDiffuse(m, normal, V, sun);

    LightSample handMain, handOff;
    getHandLights(playerPos, geoNormal, dither, handMain, handOff);
    color += evalDirectDiffuse(m, normal, V, handMain);
    color += evalDirectDiffuse(m, normal, V, handOff);

#ifdef GBUF_FORWARD_OPAQUE
    vec3 blockLight = getBlockLightForwardEntity(playerPos, geoNormal, normal, lmcoord.x);
#else
    vec3 blockLight = getBlockLightForward(playerPos, normal, lmcoord.x);
#endif
    vec3 ambient = getSkyIrradiance(normal) * skylightCurve(lmcoord.y) + blockLight
        + MIN_AMBIENT + nightVision * NIGHT_VISION_AMBIENT;
#ifdef GBUF_ENTITIES_TRANSLUCENT
    /*
     * 手持ち光源は floodfill に入らず、この経路には GI も無いので、三人称の自分の背中 (光源の反対側) が真っ黒になる
     * 周りの壁・床で跳ね返った光を、影なし・向きなしの照度の一定割合の環境光として足す
     * (影付きの照度に掛けると、体で遮られた側に何も残らない)
     */
    ambient += getHandLightFill(playerPos) * HAND_LIGHT_BOUNCE;
#endif
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
    // 光を散乱する割合は a (既定のブレンドで a が掛かる)。残り (1 - a) の透過分に composite1 が透過色を掛ける
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
