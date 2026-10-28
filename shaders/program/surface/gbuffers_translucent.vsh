/*
 * 半透明ジオメトリ共通の頂点シェーダー (水・色ガラス・手持ちの半透明・半透明パーティクル・半透明エンティティ)
 * 呼び出し元が GBUF_WATER / GBUF_HAND_WATER / GBUF_PARTICLES_TRANSLUCENT / GBUF_ENTITIES_TRANSLUCENT / GBUF_BLOCK_TRANSLUCENT を define する
 * surface モジュール (lib/surface)
 */
#ifdef GBUF_ENTITIES_TRANSLUCENT
    // 半透明で描かれる光源エンティティ (アレイ等) も画面内で登録する (lib/buffers/images.glsl, light_bins.glsl)
    #define IMG_VOXEL_EMIT
    #define SSBO_LIGHT_BINS_WRITE
#endif
//@include "/lib/common/common.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/jitter.glsl"
//@include "/lib/surface/surface.glsl"
#ifdef GBUF_ENTITIES_TRANSLUCENT
    //@include "/lib/light/light.glsl"
#endif
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
#include "/lib/common/jitter.glsl"
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
#ifdef GBUF_ENTITIES_TRANSLUCENT
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
    #include "/lib/buffers/frame_data.glsl"
    #include "/lib/light/entity_light.glsl"
    #include "/lib/light/hand_light.glsl"
    #include "/lib/light/blocklight.glsl"
    #include "/lib/light/light.glsl"
#endif
// END GENERATED includes

#ifdef GBUF_WATER
    in vec2 mc_Entity;
    in vec4 at_midBlock;
#endif
in vec4 at_tangent;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 viewPos;
out vec3 normalPlayer;
out vec4 tangentPlayer;
flat out int blockId;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord = saturate(((gl_TextureMatrix[1] * gl_MultiTexCoord1).xy - 1.0 / LIGHTMAP_TEXELS) * LIGHTMAP_TEXELS / LIGHTMAP_RANGE);
    glcolor = gl_Color;
    normalPlayer = viewToPlayerDir(normalize(gl_NormalMatrix * gl_Normal));
    tangentPlayer = vec4(viewToPlayerDir(normalize(gl_NormalMatrix * at_tangent.xyz)), at_tangent.w);
#ifdef GBUF_WATER
    blockId = int(round(mc_Entity.x));
#else
    blockId = 0;
#endif
    viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
#ifdef GBUF_ENTITIES_TRANSLUCENT
    if ((gl_VertexID & 3) == 0) injectEntityLight(viewToPlayer(viewPos), entityId, currentRenderedItemId, entityColor);
#endif
    gl_Position = gl_ProjectionMatrix * vec4(viewPos, 1.0);
    applyTaaJitter(gl_Position);
}
