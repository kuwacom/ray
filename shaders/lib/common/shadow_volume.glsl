/*
 * 影マップの 1 点の読み取り (sun_shadow の面の影と、sky の体積マーチが共有する)
 * 半透明の透過色か、水の吸収 + コースティクス
 */
#ifndef COMMON_SHADOW_VOLUME_GLSL
#define COMMON_SHADOW_VOLUME_GLSL

#include "/lib/settings.glsl"
#include "/lib/common/color.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/shadow_space.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/water.glsl"

float shadowDepthPerBlock() { return abs(shadowProjection[2][2]) * SHADOW_DEPTH_SCALE * 0.5; }

/*
 * 影マップの 1 点の透過色。半透明の透過色 (ガラス) か水の吸収 + コースティクス
 * receiverPlayer: 受け点, z: 受け点の影深度
 */
vec3 shadowTranslucentTint(vec2 uv, float z, vec3 receiverPlayer) {
#ifdef SHADOW_COLORED
    vec4 kind = texture(shadowcolor1, uv);
    if (kind.a > 0.75) {
        float surfaceDepth = texture(shadowtex0, uv).r;
        float depthBelow = max(z - surfaceDepth, 0.0) / shadowDepthPerBlock();
        vec3 L = getShadowLightDir();
        vec3 t = exp(-waterExtinction() * depthBelow);
        return t * waterCaustics(receiverPlayer + cameraPosition, depthBelow, L);
    }
    vec4 c = texture(shadowcolor0, uv);
    return mix(vec3(1.0), srgbToLinear(c.rgb), c.a);
#else
    return vec3(1.0);
#endif
}

/*
 * VL 等の体積マーチ用の 1 タップ影 (sky モジュールが使う)。rgb = 色付き透過率
 */
vec3 sampleShadowVolume(vec3 playerPos) {
#ifdef HAS_SUN_SHADOWS
    vec3 s = playerToShadowScreen(playerPos);
    if (any(lessThan(s, vec3(0.0))) || any(greaterThan(s, vec3(1.0)))) return vec3(1.0);
    float opaqueVis = step(s.z, texture(shadowtex1, s.xy).r);
    #ifdef SHADOW_COLORED
        float allVis = step(s.z, texture(shadowtex0, s.xy).r);
        if (opaqueVis > 0.0 && allVis < 1.0) return shadowTranslucentTint(s.xy, s.z, playerPos);
    #endif
    return vec3(opaqueVis);
#else
    return vec3(1.0);
#endif
}

#endif
