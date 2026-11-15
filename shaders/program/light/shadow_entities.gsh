/*
 * shadow_entities / shadow_block のジオメトリ: エンティティのボクセル化 (または三角形の保持)・光源登録・影マップ出力
 * PROGRAM_SHADOW_BLOCK が定義されていればブロックエンティティ (blockEntityId)
 * light モジュール。処理の本体は lib/light/shadow_entity.glsl (shadow.gsh と共有)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_LIGHT_BINS_WRITE
#define SSBO_ENTITY_TRIS_WRITE
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_ENTITY
#define IMG_VOXEL_EMIT
//@include "/lib/common/common.glsl"
//@include "/lib/common/shadow_space.glsl"
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
#include "/lib/common/shadow_space.glsl"
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
in vec3 vPlayerPos[];
in vec3 vNormal[];

out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;

void main() {
#ifdef PROGRAM_SHADOW_BLOCK
    bool castShadow = shadowBlockEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2]);
#else
    bool castShadow = shadowEntityTriangle(vPlayerPos[0], vPlayerPos[1], vPlayerPos[2],
                                           vTexcoord[0], vTexcoord[1], vTexcoord[2], vColor[0], vColor[1], vColor[2]);
#endif

    if (!castShadow) return;
    for (int i = 0; i < 3; i++) {
        texcoord = vTexcoord[i];
        glcolor = vColor[i];
        normalPlayer = vNormal[i];
        vec3 clip = (shadowProjection * vec4(playerToShadowView(vPlayerPos[i]), 1.0)).xyz;
        gl_Position = vec4(distortShadowClip(clip), 1.0);
        EmitVertex();
    }
    EndPrimitive();
}
