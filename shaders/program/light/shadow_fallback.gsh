/*
 * shadow のジオメトリ: shadow_solid / shadow_cutout / shadow_water / shadow_entities / shadow_block の無いジオメトリの受け皿
 * shadow_entities が読まれない Iris (1.8 未満) では地形もエンティティもここに来るので、renderStage で分けて
 * エンティティ・ブロックエンティティは shadow_entities / shadow_block と同じ処理をする (lib/light/shadow_entity.glsl)
 * 新しい Iris ではリードなど少数だけが来るので、素通しする
 * light モジュール
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_LIGHT_BINS_WRITE
#define SSBO_ENTITY_TRIS_WRITE
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_ENTITY
#define IMG_VOXEL_EMIT
//@include "/lib/common/common.glsl"
//@include "/lib/settings/capabilities.glsl"
//@include "/lib/light/shadow_entity.glsl"
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
#include "/lib/settings/capabilities.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/block_ids.glsl"
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
#include "/lib/buffers/entity_tris.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/buffers/frame_data.glsl"
#include "/lib/buffers/light_bins.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_pose.glsl"
#include "/lib/light/shadow_entity.glsl"
// END GENERATED includes

layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

in vec2 vTexcoord[];
in vec4 vColor[];
in vec3 vNormal[];
in float vSkyLight[];
flat in int vBlockId[];
flat in vec3 vTint[];
in vec3 vPlayerPos[];

out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;
out float skyLight;
flat out int blockId;
flat out vec3 tintTransmittance;

void main() {
    bool isEntity = false;
#ifdef FX_SHADOW_NON_TERRAIN
    // プレイヤーは設定に依らず来る (shadowPlayer) ので、FX_ENTITY_VOXEL_IN_SHADOW ではなく地形以外が来るかで分け、shadow_entities と同じ判定にする
    bool castShadow = true;
    if (renderStage == MC_RENDER_STAGE_ENTITIES) {
        isEntity = true;
        castShadow = shadowEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2],
                                          vTexcoord[0], vTexcoord[1], vTexcoord[2], vColor[0], vColor[1], vColor[2]);
    } else if (renderStage == MC_RENDER_STAGE_BLOCK_ENTITIES) {
        isEntity = true;
        castShadow = shadowBlockEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2]);
    }
    if (!castShadow) return;
#endif

    for (int i = 0; i < 3; i++) {
        texcoord = vTexcoord[i];
        // 地形の頂点色の a は影に使わない (shadow_terrain.fsh)
        glcolor = isEntity ? vColor[i] : vec4(vColor[i].rgb, 1.0);
        normalPlayer = vNormal[i];
        // エンティティの影のスカイライトは 1 (shadow_entities.fsh と同じ)
        skyLight = isEntity ? 1.0 : vSkyLight[i];
        blockId = vBlockId[i];
        tintTransmittance = vTint[i];
        // 地形以外は揺れないので、エンティティの位置は shadow_entities.gsh で求めるものと同じ
        gl_Position = gl_in[i].gl_Position;
        EmitVertex();
    }
    EndPrimitive();
}
