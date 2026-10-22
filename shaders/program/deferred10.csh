/*
 * deferred10 (compute): GI / AO の生値 (GI_RES 分の 1 解像度) を giRawImg に書く
 * GI_MODE: 1=RSM (shadowcolor0/1) 2=SSGI 3=ボクセル RT (light モジュールの traceVoxelRay + floodfill で着色)
 * surface モジュール (lib/surface)
 *
 * 出力 giRawImg (左上 1/GI_RES): rgb = 間接光の照度 (GI_STRENGTH 込み), a = AO (AO_STRENGTH 込み)
 * GI_RES=2 では 2x2 ブロックのうち lowResOffset(frameCounter) の 1 ピクセルだけを計算し、deferred11 が時空間で埋める
 *
 * AO
 *   AO_MODE=2 GTAO (Jimenez et al. 2016): 視線と法線を含むスライスで水平線角を探し、余弦重みの可視率を解析積分
 *             Minecraft は柵・草などの細い遮蔽物が多いので、半径の外側では水平線を戻す減衰 (XeGTAO の falloff) を入れる
 *   AO_MODE=1 法線方向の半球サンプルの SSAO (範囲チェック付き)
 * GI
 *   RSM (Dachsbacher & Stamminger 2005): 影マップの各テクセルを太陽に照らされた微小面光源 (VPL) とみなす。可視性は見ない
 *        ので、壁越しの漏れはスカイライトで抑える
 *   SSGI: 余弦重みの半球レイを深度バッファで辿り、当たった面を G バッファから照らし直す (前フレームの画像に頼らない)
 *   ボクセル RT: 同じレイをボクセルで辿る (画面外・厚みの問題が無い)。当たった面が画面に映っていればそのアルベドを使う
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_GI_RAW
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/lighting.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
#if GI_RES == 1
    const vec2 workGroupsRender = vec2(1.0, 1.0);
#else
    const vec2 workGroupsRender = vec2(0.5, 0.5);
#endif

const float AO_RADIUS = 1.5;          // AO の探索半径 (ブロック)
const float AO_FALLOFF_START = 0.6;   // 半径のこの割合から先の遮蔽物を弱める
const float AO_MAX_RADIUS_PX = 160.0; // 近距離で半径が画面の大半を覆わないように
const int GTAO_SLICES = 2;
const int GTAO_STEPS = 6;
const int SSAO_SAMPLES = 8;

const float RSM_RADIUS = 10.0;        // VPL を集める半径 (ブロック)
const float RSM_MIN_DIST2 = 1.0;      // 近接 VPL の 1/d^2 の発散を抑える
const float SSGI_DISTANCE = 16.0;
const int SSGI_STEPS = 16;
const float VOXEL_GI_DISTANCE = 32.0;

float linearDepthAt(vec2 uv) { return linearizeDepth(texture(depthtex1, uv).r); }

#if AO_MODE == 2
float gtao(vec3 viewPos, vec3 viewNormal, vec2 noise) {
    vec3 V = normalize(-viewPos);
    float radiusPx = AO_RADIUS * gbufferProjection[1][1] * 0.5 * viewHeight / max(-viewPos.z, 1e-3);
    if (radiusPx < 1.0) return 1.0;
    radiusPx = min(radiusPx, AO_MAX_RADIUS_PX);
    vec2 pxToUv = 1.0 / viewSize();
    vec2 uv0 = viewToScreen(viewPos).xy;

    float visibility = 0.0;
    for (int slice = 0; slice < GTAO_SLICES; slice++) {
        float phi = (float(slice) + noise.x) * PI / float(GTAO_SLICES);
        vec2 dir = vec2(cos(phi), sin(phi));
        vec3 dirV = vec3(dir, 0.0);
        vec3 orthoDir = dirV - dot(dirV, V) * V;
        vec3 axis = normalize(cross(dirV, V));
        vec3 projN = viewNormal - axis * dot(viewNormal, axis);
        float projLen = length(projN);
        if (projLen < 1e-4) continue;
        float cosN = saturate(dot(projN, V) / projLen);
        float n = (dot(orthoDir, projN) >= 0.0 ? 1.0 : -1.0) * acos(cosN);

        float h[2];
        for (int side = 0; side < 2; side++) {
            float s = side == 0 ? -1.0 : 1.0;
            // 面の接平面より下の水平線は数えない
            float lowCos = cos(n + s * HALF_PI);
            float maxCos = lowCos;
            for (int i = 0; i < GTAO_STEPS; i++) {
                float t = (float(i) + noise.y) / float(GTAO_STEPS);
                vec2 uv = uv0 + s * dir * (t * t * radiusPx + 1.0) * pxToUv;
                if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;
                float d = texture(depthtex1, uv).r;
                if (isHandDepth(d) || d >= 1.0) continue;
                vec3 S = screenToView(vec3(uv, d)) - viewPos;
                float dist = length(S);
                float c = dot(S / max(dist, 1e-4), V);
                float falloff = saturate((dist / AO_RADIUS - AO_FALLOFF_START) / (1.0 - AO_FALLOFF_START));
                maxCos = max(maxCos, mix(c, lowCos, falloff));
            }
            h[side] = s * acos(clamp(maxCos, -1.0, 1.0));
        }
        float h0 = max(h[0], n - HALF_PI);
        float h1 = min(h[1], n + HALF_PI);
        float sinN = sin(n);
        float a0 = (-cos(2.0 * h0 - n) + cosN + 2.0 * h0 * sinN) * 0.25;
        float a1 = (-cos(2.0 * h1 - n) + cosN + 2.0 * h1 * sinN) * 0.25;
        visibility += projLen * (a0 + a1);
    }
    return saturate(visibility / float(GTAO_SLICES));
}
#elif AO_MODE == 1
float ssao(vec3 viewPos, vec3 viewNormal, vec4 noise) {
    mat3 basis = tbnFromNormal(viewNormal);
    float occlusion = 0.0;
    for (int i = 0; i < SSAO_SAMPLES; i++) {
        vec2 xi = fract(noise.xy + r2Sequence(i));
        float r = AO_RADIUS * (float(i) + noise.z) / float(SSAO_SAMPLES);
        vec3 p = viewPos + basis * cosineHemisphere(xi) * r;
        vec3 s = viewToScreen(p);
        if (any(lessThan(s.xy, vec2(0.0))) || any(greaterThan(s.xy, vec2(1.0)))) continue;
        float d = texture(depthtex1, s.xy).r;
        if (isHandDepth(d)) continue;
        float diff = -p.z - linearizeDepth(d);
        // 遠いほど深度の精度が落ちるので閾値を距離に比例させる
        float bias = 0.02 - viewPos.z * 0.004;
        // 半径より大きく手前にある物は別の物体なので遮蔽に数えない
        occlusion += step(bias, diff) * saturate(1.0 - (diff - AO_RADIUS) / AO_RADIUS);
    }
    return 1.0 - occlusion / float(SSAO_SAMPLES);
}
#endif

#if GI_MODE == 1 && defined HAS_SUN_SHADOWS
vec3 rsmIndirect(vec3 playerPos, vec3 normal, float rotation) {
    LightSample sun = getCelestialLight();
    if (maxOf(sun.irradiance) <= 0.0) return vec3(0.0);
    const int count = GI_SAMPLES * 8;
    vec3 clip = playerToShadowClip(playerPos + normal * 0.25);
    vec2 clipPerBlock = shadowClipPerBlock();
    vec3 sum = vec3(0.0);
    for (int i = 0; i < count; i++) {
        vec2 c = clip.xy + vogelDisk(i, count, rotation) * RSM_RADIUS * clipPerBlock;
        vec2 uv = shadowClipToUv(c);
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) continue;
        vec4 kind = textureLod(shadowcolor1, uv, 0.0);
        // 半透明・水の面は shadowcolor0 の色が下の不透明面と一致しないので VPL にしない
        if (kind.a > 0.25) continue;
        float d = textureLod(shadowtex1, uv, 0.0).r;
        if (d >= 1.0) continue;
        float clipZ = (d - 0.5) * 2.0 / SHADOW_DEPTH_SCALE;
        vec4 sv = shadowProjectionInverse * vec4(c, clipZ, 1.0);
        vec3 vpl = (shadowModelViewInverse * vec4(sv.xyz / sv.w, 1.0)).xyz;
        vec3 dv = playerPos - vpl;
        float dist2 = dot(dv, dv);
        if (dist2 < 1e-4) continue;
        vec3 dir = dv * inversesqrt(dist2);
        vec3 nV = octDecode(kind.rg);
        float cosV = saturate(dot(nV, dir));
        float cosR = saturate(-dot(normal, dir));
        vec3 albedo = srgbToLinear(textureLod(shadowcolor0, uv, 0.0).rgb);
        sum += albedo * (cosV * cosR / max(dist2, RSM_MIN_DIST2));
    }
    // 影マップ上の 1 サンプルが受け持つ面積 (光源方向への投影面積なので太陽の照度をそのまま掛けられる)
    float area = PI * RSM_RADIUS * RSM_RADIUS / float(count);
    return sum * sun.irradiance * area * RCP_PI * getCloudShadow(playerPos);
}
#endif

#if GI_MODE == 2
vec3 ssgiIndirect(vec3 viewPos, vec3 normal, vec4 noise) {
    mat3 basis = tbnFromNormal(normal);
    vec3 start = viewPos + playerToViewDir(normal) * (0.05 - viewPos.z * 0.002);
    vec3 sum = vec3(0.0);
    for (int i = 0; i < GI_SAMPLES; i++) {
        vec3 dir = basis * cosineHemisphere(fract(noise.xy + r2Sequence(i)));
        vec4 hit = traceScreenRay(start, playerToViewDir(dir), SSGI_DISTANCE, SSGI_STEPS, fract(noise.z + r1Sequence(i)));
        if (hit.w < 0.5) continue;
        ivec2 ht = ivec2(hit.xy * viewSize());
        GBufferData h = readGBuffer(ht);
        if (dot(h.normal, dir) >= 0.0) continue;
        vec3 hitPlayer = screenToPlayer(hit.xyz);
        sum += shadeSecondaryHit(hitPlayer, h.normal, h.albedo, h.lightmap.y)
            + h.albedo * RCP_PI * secondaryHitBlockLight(hitPlayer, h.normal, ht) * SECONDARY_BLOCKLIGHT_GAIN
            + h.albedo * h.emission * EMISSION_LUMINANCE * EMISSION_STRENGTH;
    }
    // 余弦重みサンプルの照度の推定量 E = pi / N * sum(L)
    return sum * PI / float(GI_SAMPLES);
}
#endif

#if GI_MODE == 3
vec3 voxelIndirect(vec3 playerPos, vec3 normal, vec3 geoNormal, float skyLm, vec4 noise) {
    mat3 basis = tbnFromNormal(normal);
    vec3 origin = voxelRayOrigin(playerPos, geoNormal);
    vec3 sum = vec3(0.0);
    for (int i = 0; i < GI_SAMPLES; i++) {
        vec3 dir = basis * cosineHemisphere(fract(noise.xy + r2Sequence(i)));
        if (dot(dir, geoNormal) <= 0.0) continue;
        sum += traceVoxelRadiance(origin, dir, VOXEL_GI_DISTANCE, skyLm, false).rgb;
    }
    return sum * PI / float(GI_SAMPLES);
}
#endif

void main() {
    ivec2 low = ivec2(gl_GlobalInvocationID.xy);
    ivec2 screen = ivec2(viewSize());
#if GI_RES == 1
    ivec2 lowSize = screen;
    ivec2 texel = low;
#else
    ivec2 lowSize = (screen + 1) / 2;
    ivec2 texel = min(low * 2 + lowResOffset(frameCounter), screen - 1);
#endif
    if (any(greaterThanEqual(low, lowSize))) return;

    float depth = texelFetch(depthtex1, texel, 0).r;
    if (depth >= 1.0 || isHandDepth(depth)) {
        imageStore(giRawImg, low, vec4(0.0, 0.0, 0.0, 1.0));
        return;
    }
    vec2 uv = (vec2(texel) + 0.5) / viewSize();
    vec3 viewPos = screenToView(vec3(uv, depth));
    vec3 playerPos = viewToPlayer(viewPos);
    GBufferData g = readGBuffer(texel);
    vec4 noise = blueNoise(texel);

    /*
     * AO と GI の半球は幾何法線で張る。テクスチャ法線 (特に自動生成法線) はテクセルごとに向きが飛ぶので
     * - サンプルが面の裏に潜って全部遮蔽と数えられ黒い斑になる (SSAO)
     * - テクセルごとに違うノイズになり、deferred11 の空間フィルタも効かず静止していてもちらつく
     * 細かい凹凸の陰影は直接光 (deferred30) がテクスチャ法線で付ける
     */
    float ao = 1.0;
#if AO_MODE == 2
    ao = gtao(viewPos, playerToViewDir(g.geoNormal), noise.xy);
#elif AO_MODE == 1
    ao = ssao(viewPos, playerToViewDir(g.geoNormal), noise);
#endif
    ao = pow(ao, AO_STRENGTH);

    vec3 gi = vec3(0.0);
#if GI_MODE == 1 && defined HAS_SUN_SHADOWS
    // RSM は可視性を見ないので、空の見えない屋内・洞窟へ壁越しに漏れないようスカイライトで絞る
    gi = rsmIndirect(playerPos, g.geoNormal, noise.z * TAU) * smoothstep(0.1, 0.6, g.lightmap.y);
#elif GI_MODE == 2
    gi = ssgiIndirect(viewPos, g.geoNormal, noise);
#elif GI_MODE == 3
    gi = voxelIndirect(playerPos, g.geoNormal, g.geoNormal, g.lightmap.y, noise);
#endif
    gi *= GI_STRENGTH;

    imageStore(giRawImg, low, vec4(max(gi, 0.0), ao));
}
