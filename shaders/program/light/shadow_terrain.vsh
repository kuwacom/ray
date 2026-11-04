/*
 * shadow (地形: solid / cutout / 半透明): 太陽影マップ + 地形のボクセル化
 * light モジュール (影マップの出力内容は surface モジュールと調整)
 * shadow_entities / shadow_block が無いジオメトリもここに来るが、Iris 1.8+ ではエンティティは来ない
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_BLOCK
//@include "/lib/common/common.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/light/light.glsl"
//@include "/lib/surface/surface.glsl"
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
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/light_bins.glsl"
#include "/lib/common/color.glsl"
#include "/lib/buffers/block_data.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/light/light_def.glsl"
#include "/lib/light/light_table_data.glsl"
#include "/lib/light/light_table.glsl"
#include "/lib/common/noise.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/common/voxel_space.glsl"
#include "/lib/buffers/images.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
#include "/lib/light/voxel_read.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/common/frame_offset.glsl"
#include "/lib/buffers/global_lights.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"
#include "/lib/light/light.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/gbuffer.glsl"
#include "/lib/surface/material.glsl"
#include "/lib/surface/brdf.glsl"
#include "/lib/common/look_presets.glsl"
#include "/lib/surface/gi.glsl"
#include "/lib/common/water_waves.glsl"
#include "/lib/common/water_normal.glsl"
#include "/lib/common/water.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/shadow_volume.glsl"
#include "/lib/surface/sun_shadow.glsl"
#include "/lib/surface/waving.glsl"
#include "/lib/surface/surface.glsl"
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
    blockId = int(round(mc_Entity.x));
    // 色付き影はブロックライト (floodfill / 光源シャドウ) と同じ透過色の表を使う
    tintTransmittance = isTintBlock(blockId) ? floodCellTransmittance(blockId) : vec3(1.0);

    vec3 playerPos = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;

    bool isTerrain = renderStage == MC_RENDER_STAGE_TERRAIN_SOLID
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
        || renderStage == MC_RENDER_STAGE_TERRAIN_TRANSLUCENT;
    if (isTerrain) {
        // ボクセルは揺れ適用前のブロック中心で書く
        voxelizeTerrainVertex(playerPos, at_midBlock.xyz / 64.0, blockId, at_midBlock.w);
    }

    playerPos = applyWaving(playerPos, blockId, at_midBlock.y < 0.0, skyLight);
    vec3 clip = (shadowProjection * vec4(playerToShadowView(playerPos), 1.0)).xyz;
    gl_Position = vec4(distortShadowClip(clip), 1.0);
}
