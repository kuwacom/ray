/*
 * shadow (地形: solid / cutout / 半透明): 太陽影マップ + 地形のボクセル化
 * light モジュール (影マップの出力内容は surface モジュールと調整)
 * shadow_entities / shadow_block が無いジオメトリもここに来るが、Iris 1.8+ ではエンティティは来ない
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
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/common/color.glsl"
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
    if (isTerrain) {
        // ボクセルは揺れ適用前のブロック中心で書く
        // 流れる水は水として書き、発光の欄 (水は光らないので空いている) に印を残す
        float emission = rawBlockId == BLOCK_WATER_FLOWING ? float(VOXEL_WATER_FLOWING) : at_midBlock.w;
        voxelizeTerrainVertex(playerPos, at_midBlock.xyz / 64.0, blockId, emission);
    }

    playerPos = applyWaving(playerPos, blockId, at_midBlock.y < 0.0, skyLight);
    vec3 clip = (shadowProjection * vec4(playerToShadowView(playerPos), 1.0)).xyz;
    gl_Position = vec4(distortShadowClip(clip), 1.0);
}
