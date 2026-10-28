/*
 * gbuffers_lightning: 雷の稲妻 (と Iris が同じ枠で描くエンダードラゴンの死亡時の光線)
 * 頂点形式は POSITION_COLOR だけでテクスチャ・法線・ライトマップが無い。G バッファ経路 (gbuffers_entities への
 * フォールバック) だと発光しない不透明物として暗い柱になるので、半透明バッファへ発光だけを足す
 */
//@include "/lib/common/common.glsl"
//@include "/lib/common/jitter.glsl"
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
// END GENERATED includes

out vec4 glcolor;

void main() {
    glcolor = gl_Color;
    gl_Position = ftransform();
    applyTaaJitter(gl_Position);
}
