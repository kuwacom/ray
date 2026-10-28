/*
 * shadow (地形) のフラグメント: 影マップの色・法線を書く
 * shadowcolor0: 最も太陽側の面の色 (半透明は透過色 + 不透明度)
 * shadowcolor1: rg = 法線 (oct), b = スカイライト, a = 種別 (0=不透明 0.2=葉 0.5=半透明 1=水)
 * light モジュール (RSM で使う内容は surface モジュールと調整)
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/encoding.glsl"
//@include "/lib/common/shadow_space.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/id_decode.glsl"
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
#include "/lib/common/color.glsl"
#include "/lib/common/encoding.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/ids/block_ids.glsl"
#include "/lib/ids/entity_ids.glsl"
#include "/lib/ids/light_ids.glsl"
#include "/lib/ids/material_ids.glsl"
#include "/lib/ids/id_decode.glsl"
// END GENERATED includes

in vec2 texcoord;
in vec4 glcolor;
in vec3 normalPlayer;
in float skyLight;
flat in int blockId;
flat in vec3 tintTransmittance;

/* RENDERTARGETS: 0,1 */
layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outNormal;

void main() {
    vec4 albedo = texture(gtexture, texcoord) * vec4(glcolor.rgb, 1.0);
    if (albedo.a < 0.1) discard;

    float kind = 0.0;
    if (blockId == BLOCK_WATER) {
        kind = 1.0;
        albedo = vec4(albedo.rgb, 0.3);
    } else if (isTintBlock(blockId)) {
        kind = 0.5;
        /*
         * テクスチャの不透明度 (色ガラスで 0.3-0.5 程度) で白と混ぜると透過色がほぼ白になり、
         * 半透明のブレンドでさらに薄まって色ガラスの日だまりが白かった。透過色の表の値を不透明で書く
         */
        albedo = vec4(linearToSrgb(tintTransmittance), 1.0);
    } else if (blockId == BLOCK_LEAVES) {
        // 葉はバイオームの色込みのまま不透明で書き、参照側 (SHADOW_LEAF_TINT) がこの色で透過させる
        kind = SHADOW_KIND_LEAVES;
        albedo.a = 1.0;
    } else {
        albedo.a = 1.0;
    }
    outColor = albedo;
    outNormal = vec4(octEncode(normalize(normalPlayer)), skyLight, kind);
}
