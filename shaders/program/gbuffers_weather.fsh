#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"

in vec2 texcoord;
in vec4 glcolor;
in vec2 lmcoord;
in vec3 playerPos;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec4 outColor;

// 雨粒は細く透明なので不透明度を下げ、空の光を映す明るさで描く。雪は白く拡散する
const float RAIN_OPACITY = 0.35;
const float SNOW_OPACITY = 0.85;
// 雨粒が逆光で光る前方散乱の強さ (水滴の屈折で光源側が明るく見える)
const float RAIN_FORWARD_SCATTER = 0.25;

void main() {
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < alphaTestRef) discard;

    bool snow = biome_precipitation == 2;
    vec3 V = normalize(playerPos);
    LightSample celestial = getCelestialLight();
    float skyLight = sqr(lmcoord.y);
    float sunVisibility = getCloudShadow(playerPos) * skyLight;

    vec3 ambient = getSkyIrradiance(vec3(0.0, 1.0, 0.0)) * skyLight + getBlockLightForward(playerPos, -V, lmcoord.x) + MIN_AMBIENT;
    vec3 color;
    float opacity;
    if (snow) {
        color = srgbToLinear(c.rgb) * (ambient + celestial.irradiance * 0.5 * sunVisibility) * RCP_PI;
        opacity = c.a * SNOW_OPACITY;
    } else {
        float phase = skyPhaseHG(dot(V, celestial.direction), 0.7);
        color = srgbToLinear(c.rgb) * (ambient * RCP_PI + celestial.irradiance * phase * RAIN_FORWARD_SCATTER * sunVisibility);
        opacity = c.a * RAIN_OPACITY;
    }
    // colortex4 は既定のアルファブレンドで乗算済みになるので、ここでは掛けない
    outColor = vec4(color, opacity);
}
