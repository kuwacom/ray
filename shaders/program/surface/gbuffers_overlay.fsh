//@include "/lib/common/common.glsl"
//@include "/lib/common/exposure.glsl"
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
// END GENERATED includes

in vec2 texcoord;
in vec4 glcolor;

#ifdef GBUF_ARMOR_GLINT
/* RENDERTARGETS: 1,4 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outForward;
#else
/* RENDERTARGETS: 1 */
layout(location = 0) out vec4 outAlbedo;
#endif

void main() {
    vec4 c = texture(gtexture, texcoord) * glcolor;
#ifdef GBUF_DAMAGEDBLOCK
    if (c.a < 0.01) discard;
#endif
#ifdef GBUF_ARMOR_GLINT
    /*
     * 着た鎧は deferred の後に半透明の経路 (colortex4) で描かれ、アルベド (colortex1) への光沢は deferred が読まないので消える
     * 鎧の画素は colortex5 に印があるので、そこでは colortex4 へ加算し、手持ち・額縁 (deferred の前) はこれまでどおりアルベドへ重ねる
     * blend は colortex1 が SRC_COLOR ONE、colortex4 が ONE ONE (shaders.properties)。使わない側は 0 を書いて何も足さない
     */
    bool afterDeferred = texelFetch(colortex5, ivec2(gl_FragCoord.xy), 0).a > 0.0;
    outAlbedo = afterDeferred ? vec4(0.0) : vec4(c.rgb, c.a);
    outForward = afterDeferred ? vec4(c.rgb * c.rgb * (getVisibleEmissionLuminance() * EMISSION_STRENGTH), 0.0) : vec4(0.0);
#else
    outAlbedo = vec4(c.rgb, c.a);
#endif
}
