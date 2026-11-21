/*
 * shadow_solid / shadow_cutout / shadow_water (地形): 太陽影マップ + 地形のボクセル化
 * light モジュール (影マップの出力内容は surface モジュールと調整)
 * PROGRAM_SHADOW_FALLBACK が定義されていれば shadow (専用のプログラムが無いジオメトリの受け皿)。
 * Iris 1.8 未満は地形もエンティティも shadow に来て、新しい Iris でもリードなどが来るので、地形用の処理を isTerrain で閉じる
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_BLOCK
//@include "/lib/common/common.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/ids/id_decode.glsl"
//@include "/lib/light/floodfill.glsl"
//@include "/lib/light/voxel.glsl"
//@include "/lib/common/shadow_space.glsl"
//@include "/lib/surface/waving.glsl"
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
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/surface/waving.glsl"
// END GENERATED includes

in vec2 mc_Entity;
in vec4 at_midBlock;

#ifdef PROGRAM_SHADOW_FALLBACK
// shadow はジオメトリシェーダー (shadow.gsh) を通る。GS の出力と同じ名前は使えないので、入力側の名前に替える
#define texcoord vTexcoord
#define glcolor vColor
#define normalPlayer vNormal
#define skyLight vSkyLight
#define blockId vBlockId
#define tintTransmittance vTint
// エンティティのボクセル化に使う、揺れ適用前の位置
out vec3 vPlayerPos;
#ifdef CHARGED_CREEPER_LIGHT
    flat out int vSwirlLayer;
    const float SWIRL_TEXTURE_MATRIX_EPS = 1e-6;
#endif
#endif
out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;
out float skyLight;
flat out int blockId;
flat out vec3 tintTransmittance;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    skyLight = saturate((lm.y - 1.0 / LIGHTMAP_TEXELS) * LIGHTMAP_TEXELS / LIGHTMAP_RANGE);
    normalPlayer = mat3(shadowModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    int rawBlockId = int(round(mc_Entity.x));
    blockId = terrainBlockId(stripMetalGate(rawBlockId));
    // 色付き影はブロックライト (floodfill / 光源シャドウ) と同じ透過色の表を使う
    tintTransmittance = isTintBlock(blockId) ? floodCellTransmittance(blockId) : vec3(1.0);

    vec3 playerPos = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;

    bool isTerrain = renderStage == MC_RENDER_STAGE_TERRAIN_SOLID
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
        || renderStage == MC_RENDER_STAGE_TERRAIN_TRANSLUCENT;
#ifdef PROGRAM_SHADOW_FALLBACK
    /*
     * エンティティの mc_Entity はブロック ID ではない (Iris は同じ場所にエンティティ ID を入れる)。at_midBlock も無い
     * 地形以外は BLOCK_AIR にして、色付き影・水・揺れの判定に当てない
     */
    if (!isTerrain) {
        blockId = BLOCK_AIR;
        tintTransmittance = vec3(1.0);
        // 染めたブロックエンティティ (旗・ベッド・シュルカーボックス) だけは ID を渡し、RSM の色に反射率の設定を掛ける (shadow_entities.fsh と同じ)
        // 渡すのは反射率の対象の ID だけなので、色付き影・水・揺れの判定には当たらない
        int beId = stripMetalGate(blockEntityId);
        if (COLOR_ALBEDO_ACTIVE && renderStage == MC_RENDER_STAGE_BLOCK_ENTITIES && isColorAlbedoBlock(beId)) blockId = beId;
    }
#endif
    if (isTerrain) {
        // ボクセルは揺れ適用前のブロック中心で書く
        // 流れる水は水として書き、発光の欄 (水は光らないので空いている) に印を残す
        // 水に浸った光源のセルの水 (Iris は流体の頂点に本体のブロックの発光を入れる) は書かない。水は不透明の後に描かれ、光源の ID を上書きしてしまう
        // at_midBlock が来ない環境 (Sodium なし) では発光が 0 なので、従来どおり水を書く
        bool waterloggedLight = blockId == BLOCK_WATER && at_midBlock.w > 0.5;
        float emission = rawBlockId == BLOCK_WATER_FLOWING ? float(VOXEL_WATER_FLOWING) : at_midBlock.w;
        if (!waterloggedLight) voxelizeTerrainVertex(playerPos, at_midBlock.xyz / 64.0, blockId, emission);
    }
#ifdef PROGRAM_SHADOW_FALLBACK
    vPlayerPos = playerPos;
    #ifdef CHARGED_CREEPER_LIGHT
        // 電気の渦の層だけがテクスチャ行列で UV を流す (shadow_entities.vsh と同じ見分け方)
        mat4 texMatOffset = gl_TextureMatrix[0] - mat4(1.0);
        vec4 texMatDiff = abs(texMatOffset[0]) + abs(texMatOffset[1]) + abs(texMatOffset[2]) + abs(texMatOffset[3]);
        vSwirlLayer = dot(texMatDiff, vec4(1.0)) > SWIRL_TEXTURE_MATRIX_EPS ? 1 : 0;
    #endif
#endif

    playerPos = applyWaving(playerPos, blockId, at_midBlock.y < 0.0, skyLight);
    vec3 clip = (shadowProjection * vec4(playerToShadowView(playerPos), 1.0)).xyz;
    gl_Position = vec4(distortShadowClip(clip), 1.0);
}
