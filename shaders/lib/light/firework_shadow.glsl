/*
 * 花火の光の遮り (light モジュール)。着色点から花火へボクセルのレイを辿る (設置光源の影と同じ traceVisibility)
 * 花火は上空でボクセルの範囲の外にあることが多い。traceVisibility は範囲の端まで辿り、外へ出たら遮りなしとみなす
 * 範囲の外の地形 (遠くの丘) では遮らない
 * firework_light.glsl から分けたのは、粒の頂点 (gbuffers) や begin・霧の合成がトレースの本文を読み込まないため
 */
#ifndef LIGHT_FIREWORK_SHADOW_GLSL
#define LIGHT_FIREWORK_SHADOW_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/light/trace.glsl"
//@include "/lib/light/firework_light.glsl"

// 終点を火花の球の半径のこの割合の円板で揺らして半影にする (TAA で均す)。球いっぱいでは影がぼけすぎて壁の裏も明るんだ
const float FIREWORK_SHADOW_SOFTNESS = 0.4;
// 円板の半径の位相を角度と別にする倍率 (同じ dither で角度と半径がそろうと点が渦の線に並ぶ)
const float FIREWORK_SHADOW_DISK_PHASE = 7.31;

/*
 * 遮りを掛けた花火の光。geoNormal: 幾何法線 (始点を面の手前へ押し出す。光源に背を向けた面は自分のブロックの影なので 0)
 * エンティティ (三角形・占有) では遮らない。花火 1 つの光に体の影を付けると、全画素で三角形を辿る分だけ重い
 */
LightSample shadowFireworkLight(LightSample s, vec3 playerPos, vec3 geoNormal, float dither) {
#ifdef LIGHT_SHADOWS
    if (maxOf(s.irradiance) <= 0.0) return s;
    if (dot(geoNormal, s.direction) <= 0.0) return noLight();
    vec3 fromVoxel = playerToVoxel(playerPos + geoNormal * TRACE_NORMAL_OFFSET);
    if (!isInVoxelVolume(fromVoxel)) return s;
    mat3 tbn = tbnFromNormal(s.direction);
    float a = dither * TAU;
    vec2 disk = sqrt(fract(dither * FIREWORK_SHADOW_DISK_PHASE)) * vec2(cos(a), sin(a)) * (fireworkLight.posRadius.w * FIREWORK_SHADOW_SOFTNESS);
    vec3 target = playerToVoxel(fireworkLight.posRadius.xyz) + tbn[0] * disk.x + tbn[1] * disk.y;
    uint flags = blockLightTraceFlags() & ~(TRACE_ENTITIES | TRACE_PLAYER);
    s.irradiance *= blockLightShadow(traceVisibility(fromVoxel, target, flags, dither, 0.0, 0.0));
#endif
    return s;
}

#endif
