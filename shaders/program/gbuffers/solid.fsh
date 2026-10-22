/*
 * 不透明ジオメトリ共通のフラグメントシェーダー (G バッファへ書く)
 * マテリアル: labPBR v1.3 (PBR_FORMAT=1) または ID + 色からの推定 (PBR_FORMAT=0)
 * 法線: labPBR 法線マップ / 輝度勾配からの自動生成、POM (+ 自己影)、雨の濡れと水たまり
 * surface モジュール (lib/surface)
 */
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/post/post.glsl"

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 viewPos;
in vec3 normalPlayer;
in vec4 tangentPlayer;
in vec2 tileMid;
in vec2 tileHalf;
flat in int blockId;

/* RENDERTARGETS: 1,2,3,15 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outMaterial;
layout(location = 3) out vec4 outVelocity;

#if PBR_FORMAT == 1 && !defined GBUF_BASIC && !defined GBUF_LINE
    #define USE_LABPBR
#endif
#if defined POM && defined USE_LABPBR && defined GBUF_TERRAIN
    #define USE_POM
#endif
#if defined GENERATED_NORMALS && PBR_FORMAT == 0 && defined GBUF_TERRAIN
    #define USE_GENERATED_NORMALS
#endif

const float POM_DISTANCE = 32.0;         // POM を掛ける距離 (ブロック)。この手前 30% で滑らかに消す
const int POM_SHADOW_STEPS = 12;
const float POM_SHADOW_SOFTNESS = 6.0;   // 自己影の縁の柔らかさ (高さ差に対する倍率)
const float GENERATED_NORMAL_STRENGTH = 1.2;
const float GENERATED_NORMAL_MAX_LOD = 0.25; // テクセルが画素とほぼ同じ大きさ (lod 0) を超えると勾配がジッターでちらつくので消す
const float FRONT_FACING_MIN_NOV = 0.05;     // テクスチャ法線と視線の内積の下限
const float VANILLA_AO_SOFTEN = 0.6;     // GTAO 併用時はバニラ AO を弱めて二重に暗くならないように
/*
 * 水たまりの模様。以前は Iris 既定の noisetex (白色ノイズ) を 0.05/ブロックで読んでいて、
 * 1 ブロックに 13 テクセルの砂目になり、小さな水たまりがまばらに散っていた
 * 勾配ノイズの fbm を基本の大きさ PUDDLE_SCALE x PUDDLE_SIZE で敷き、上位 PUDDLE_AMOUNT の割合を水たまりにする
 * 3.5 ブロック・割合 0.3 で、1 つが中央値 3 ブロック^2・100 ブロック^2 あたり 3 個 (Nostalgia の再現では 2.4 ブロック^2・3.4 個、割合 0.37)
 */
const float PUDDLE_SCALE = 3.5;
const float PUDDLE_NOISE_SIGMA = 0.129;  // puddleNoise の標準偏差 (割合 -> しきい値の換算用)
const float PUDDLE_EDGE = 0.05;          // 水たまりの縁のぼかし幅 (ノイズの値)
const float PUDDLE_FRINGE = 0.08;        // 水たまりの周りの湿った帯の幅 (ノイズの値)
const float PUDDLE_FRINGE_SOAK = 0.4;
const vec2 PUDDLE_GROWTH = vec2(0.3, 0.95); // wetness (半減期 10 秒) がこの範囲で水たまりが育つ。実測で降り始めの 20 秒ほどで出始めて 45-60 秒で揃い、止んで 60-90 秒で消える
const vec2 PUDDLE_SKYLIGHT = vec2(0.93, 0.965); // スカイライト 15 (0.97) だけ。屋根の下 (14 = 0.91) には溜めない
const float PUDDLE_FRINGE_GLOSS = 0.8;
const float PUDDLE_SMOOTHNESS = 0.99;     // 鏡面 (0.93 は MIRROR_ROUGHNESS ぎりぎりで、8 bit の量子化で VNDF 側に落ちる画素があった)
const float PUDDLE_SOAK = 0.7;
// 水の f0 (0.02) より強くする。地面の暗い緑・灰色の上では 0.02 の映り込みは近くで見るとほとんど見えず、水たまりと分からなかった
// 0.08 でも映り込みがくすんでマットに見えた。鏡のように映る見た目を優先する
const float PUDDLE_F0 = 0.2;
const float WET_GLOSS = 0.7;             // 水たまりから離れた濡れた面の艶の強さ (x (1 - 多孔度))
const float WET_SMOOTHNESS = 0.8;
const float WET_DARKEN = 0.45;           // 濡れた多孔質の面のアルベド低下 (Lagarde 2013 の測定に近い値)

const float LAVA_EMISSION_MIN = 0.12;
// 明るい筋も 1.0 では AgX の肩に入って彩度が抜け、溶岩の滝が白っぽいサーモン色になった。AgX は明るい橙の青を持ち上げるので、橙を残すには暗めに置く (0.5 でもまだ薄い橙)
const float LAVA_EMISSION_MAX = 0.3;

// マテリアル ID 別の発光推定 (labPBR の _s.a がある時はそちらと max を取る)。光源ブロックは明るい画素だけ光らせる
float estimateEmission(vec3 albedoSrgb, int materialId) {
    // 溶岩は暗い殻の部分まで全力で光らせると、ネザーの溶岩の滝が AgX で白く飛んで橙色が残らない
    // 明るい黄色の筋だけ強く (LAVA_EMISSION_MAX) 光らせ、橙〜暗赤の部分は LAVA_EMISSION_MIN まで落とす
    if (materialId == MAT_LAVA) return mix(LAVA_EMISSION_MIN, LAVA_EMISSION_MAX, smoothstep(0.3, 0.8, luminance(albedoSrgb)));
    if (materialId == MAT_BEACON_BEAM || materialId == MAT_LIGHTNING) return 1.0;
    if (materialId == MAT_EMISSIVE_BLOCK || materialId == MAT_EMISSIVE_ENTITY || materialId == MAT_HAND_EMISSIVE) {
        return smoothstep(0.55, 0.9, maxOf(albedoSrgb));
    }
    return 0.0;
}

const float DECOR_EMISSION = 0.3;

// スプライト内で UV を折り返す (POM でスプライトの外を読まないため)
vec2 wrapTile(vec2 uv) {
    vec2 size = max(tileHalf * 2.0, vec2(1e-6));
    vec2 origin = tileMid - tileHalf;
    return origin + fract((uv - origin) / size) * size;
}

vec2 clampTile(vec2 uv) { return clamp(uv, tileMid - tileHalf, tileMid + tileHalf); }

#if defined RAIN_PUDDLES && defined HAS_SKY && defined GBUF_TERRAIN
// 2D の勾配ノイズ (格子点ごとにランダムな向きの勾配)。値ノイズより格子に沿った角が出にくく、水たまりの輪郭が丸くなる
float puddleGradientNoise(vec2 p, uint seed) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    uvec2 c = uvec2(ivec2(i) + 32768);
    float a00 = hash3(uvec3(c, seed)).x * TAU;
    float a10 = hash3(uvec3(c + uvec2(1, 0), seed)).x * TAU;
    float a01 = hash3(uvec3(c + uvec2(0, 1), seed)).x * TAU;
    float a11 = hash3(uvec3(c + uvec2(1, 1), seed)).x * TAU;
    float n00 = dot(vec2(cos(a00), sin(a00)), f);
    float n10 = dot(vec2(cos(a10), sin(a10)), f - vec2(1.0, 0.0));
    float n01 = dot(vec2(cos(a01), sin(a01)), f - vec2(0.0, 1.0));
    float n11 = dot(vec2(cos(a11), sin(a11)), f - vec2(1.0, 1.0));
    return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y);
}

const mat2 PUDDLE_OCTAVE_ROT = mat2(0.8, 0.6, -0.6, 0.8);

// 水たまりの模様 (平均 0.5, 標準偏差 PUDDLE_NOISE_SIGMA)。3 オクターブ + 7 倍の大きさの地域差 (水たまりの多い窪地と少ない所)
float puddleNoise(vec2 xz) {
    vec2 p = xz / (PUDDLE_SCALE * PUDDLE_SIZE);
    float n = puddleGradientNoise(p, 1u);
    vec2 q = PUDDLE_OCTAVE_ROT * p * 2.03 + 17.1;
    n += puddleGradientNoise(q, 2u) * 0.5;
    q = PUDDLE_OCTAVE_ROT * q * 2.07 + 31.7;
    n += puddleGradientNoise(q, 3u) * 0.25;
    n += puddleGradientNoise(p / 7.0 + vec2(5.3, 9.1), 4u) * 0.35;
    return 0.5 + 0.5 * n;
}

// 地面を覆う割合 -> puddleNoise のしきい値 (正規分布とみなし、逆関数はロジスティック近似)
float puddleThreshold(float coverage) {
    float p = clamp(1.0 - coverage, 0.001, 0.999);
    return 0.5 + PUDDLE_NOISE_SIGMA * log(p / (1.0 - p)) / 1.702;
}
#endif

#ifdef USE_POM
/*
 * 視差オクルージョンマッピング (Tatarchuk 2006)。viewTs: 接空間の視線 (カメラ -> 面, z < 0)
 * 高さは labPBR の _n.a (1 = 表面, 0 = POM_DEPTH の深さ)。戻り値 xy = UV, z = 深さ [0,1]
 */
vec3 parallaxMapping(vec2 uv, vec3 viewTs, vec2 dx, vec2 dy, float depthScale, float dither) {
    vec2 perDepth = viewTs.xy / max(-viewTs.z, 0.05) * depthScale * tileHalf * 2.0;
    float layer = 1.0 / float(POM_SAMPLES);
    float depth = layer * dither;
    float prevDepth = 0.0;
    float h = textureGrad(normals, wrapTile(uv), dx, dy).a;
    float prevH = h;
    for (int i = 0; i < POM_SAMPLES; i++) {
        if (1.0 - h <= depth) break;
        prevDepth = depth;
        prevH = h;
        depth += layer;
        h = textureGrad(normals, wrapTile(uv + perDepth * depth), dx, dy).a;
    }
    // 直前の層との線形補間で段差を消す
    float a = (1.0 - h) - depth;
    float b = (1.0 - prevH) - prevDepth;
    float t = saturate(b / max(b - a, 1e-5));
    float hitDepth = mix(prevDepth, depth, t);
    return vec3(wrapTile(uv + perDepth * hitDepth), hitDepth);
}

// 光源方向に高さ場を辿る自己影 (1 = 遮蔽なし)
float parallaxShadow(vec2 hitUv, float hitDepth, vec3 lightTs, vec2 dx, vec2 dy, float depthScale) {
    if (lightTs.z <= 0.0) return 0.0;
    if (hitDepth <= 0.0) return 1.0;
    vec2 perDepth = lightTs.xy / lightTs.z * depthScale * tileHalf * 2.0;
    float shadow = 1.0;
    for (int i = 1; i <= POM_SHADOW_STEPS; i++) {
        float d = hitDepth * (1.0 - float(i) / float(POM_SHADOW_STEPS));
        vec2 uv = wrapTile(hitUv + perDepth * (hitDepth - d));
        float surfaceDepth = 1.0 - textureGrad(normals, uv, dx, dy).a;
        shadow = min(shadow, saturate(1.0 - (d - surfaceDepth) * POM_SHADOW_SOFTNESS * float(POM_SAMPLES) / 16.0));
    }
    return shadow;
}
#endif

#ifdef USE_GENERATED_NORMALS
// テクスチャの輝度を高さとみなした勾配から接空間の法線を作る (PBR テクスチャが無いリソースパック用)
vec3 generatedNormal(vec2 uv) {
    /*
     * テクセルが画素より小さくなる距離では、TAA のジッターで毎フレーム別のテクセルの勾配を拾い、静止していてもちらつく
     * (テクスチャ法線は直接光・鏡面に効くので明るい所ほど目立つ)。テクセルが 2 画素 (lod -1) より小さくなり始めたら弱め、
     * 1 テクセル = 画素の手前 (GENERATED_NORMAL_MAX_LOD) で消す。勾配はテクセルの中心で取り、画素内の位置で値が変わらないようにする
     */
    ivec2 size = textureSize(gtexture, 0);
    /*
     * textureQueryLod は異方性フィルタが効くと短い方の軸の LOD を返すので、かすめ角の床では縦方向にテクセルが
     * 画素より細かくなっても消えず横縞になる。画面上で長い方の軸 (最も縮小される方向) で判定する
     */
    vec2 dx = dFdx(uv * vec2(size));
    vec2 dy = dFdy(uv * vec2(size));
    float lod = 0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8));
    float fade = 1.0 - smoothstep(-1.0, GENERATED_NORMAL_MAX_LOD, lod);
    if (fade <= 0.0) return vec3(0.0, 0.0, 1.0);
    ivec2 c = ivec2(floor(uv * vec2(size)));
    // 近傍はスプライトの外 (アトラスの隣の絵) を読まないよう、スプライトの範囲 (テクセル) で折り返す
    // 端で範囲に収める (片側差分) と縁の 1 テクセルだけ勾配が変わり、ブロックの継ぎ目に法線の段差の線が出る。
    // ブロックのテクスチャは繰り返し模様なので、折り返すと隣のブロックの縁と同じ値になって継ぎ目が消える
    ivec2 tmin = ivec2(floor((tileMid - tileHalf) * vec2(size) + 0.5));
    ivec2 tsize = max(ivec2(floor((tileMid + tileHalf) * vec2(size) - 0.5)) - tmin + 1, ivec2(1));
    c = clamp(c, tmin, tmin + tsize - 1);
    vec4 l = texelFetch(gtexture, tmin + (c - tmin - ivec2(1, 0) + tsize) % tsize, 0);
    vec4 r = texelFetch(gtexture, tmin + (c - tmin + ivec2(1, 0)) % tsize, 0);
    vec4 u = texelFetch(gtexture, tmin + (c - tmin - ivec2(0, 1) + tsize) % tsize, 0);
    vec4 d = texelFetch(gtexture, tmin + (c - tmin + ivec2(0, 1)) % tsize, 0);
    // 抜き部分 (葉の穴) を低い所として扱うと縁が立体的に見える
    float hl = luminance(l.rgb) * l.a;
    float hr = luminance(r.rgb) * r.a;
    float hu = luminance(u.rgb) * u.a;
    float hd = luminance(d.rgb) * d.a;
    vec2 grad = vec2(hr - hl, hd - hu) * GENERATED_NORMAL_STRENGTH * fade;
    return normalize(vec3(-grad, 1.0));
}
#endif

void main() {
#ifdef GBUF_LINE
    // 釣り糸も gbuffers_line で来るので、消すのはブロック選択枠だけ
    #ifndef SELECTION_OUTLINE
        if (renderStage == MC_RENDER_STAGE_OUTLINE) discard;
    #endif
#endif
#ifdef GBUF_ENTITIES
    if (entityId == ENTITY_SHADOW) discard;
#endif

    vec3 geoN = normalize(normalPlayer);
    vec3 T = normalize(tangentPlayer.xyz - geoN * dot(geoN, tangentPlayer.xyz));
    // labPBR の法線は DirectX 形式 (+Y = テクスチャの下 = +v)。この B が +v を向く
    vec3 B = cross(T, geoN) * (tangentPlayer.w < 0.0 ? -1.0 : 1.0);
    mat3 tbn = mat3(T, B, geoN);
    vec3 playerPos = viewToPlayer(viewPos);
    vec3 viewDirPlayer = normalize(playerPos);
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec2 uv = texcoord;
    float pomShadow = 1.0;
    float pomDepth = 0.0;
#ifdef USE_POM
    vec2 dx = dFdx(texcoord);
    vec2 dy = dFdy(texcoord);
    float pomFade = 1.0 - smoothstep(POM_DISTANCE * 0.7, POM_DISTANCE, length(playerPos));
    if (pomFade > 0.0) {
        float depthScale = POM_DEPTH * pomFade;
        vec3 viewTs = viewDirPlayer * tbn;
        vec3 pom = parallaxMapping(texcoord, viewTs, dx, dy, depthScale, dither);
        uv = pom.xy;
        pomDepth = pom.z;
        #if defined HAS_SUN_SHADOWS && defined POM_SHADOW
            vec3 lightTs = getShadowLightDir() * tbn;
            pomShadow = mix(1.0, parallaxShadow(uv, pomDepth, lightTs, dx, dy, depthScale), pomFade);
        #endif
    }
    #define SAMPLE_ATLAS(tex) textureGrad(tex, uv, dx, dy)
#else
    #define SAMPLE_ATLAS(tex) texture(tex, uv)
#endif

#if defined GBUF_BASIC || defined GBUF_LINE
    vec4 albedo = glcolor;
#elif defined GBUF_TERRAIN
    // separateAo=true なので頂点色の a はバニラ AO
    vec4 albedo = SAMPLE_ATLAS(gtexture) * vec4(glcolor.rgb, 1.0);
#else
    vec4 albedo = SAMPLE_ATLAS(gtexture) * glcolor;
#endif
    if (albedo.a < alphaTestRef) discard;

    int materialId = MAT_TERRAIN;
#if defined GBUF_TERRAIN
    materialId = blockIdToMaterial(blockId);
#elif defined GBUF_ENTITIES
    materialId = entityIdToMaterial(entityId, currentRenderedItemId);
    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);
#elif defined GBUF_BLOCK
    materialId = MAT_BLOCK_ENTITY;
#elif defined GBUF_HAND
    materialId = (heldBlockLightValue > 0 || heldBlockLightValue2 > 0) ? MAT_HAND_EMISSIVE : MAT_HAND;
#elif defined GBUF_BEACON
    materialId = MAT_BEACON_BEAM;
#elif defined GBUF_PARTICLES
    materialId = MAT_PARTICLE;
#elif defined GBUF_BASIC || defined GBUF_LINE
    materialId = MAT_BASIC;
#endif

    // ---- マテリアル ----
#ifdef USE_LABPBR
    vec4 normalTex = SAMPLE_ATLAS(normals);
    vec4 specTex = SAMPLE_ATLAS(specular);
    SurfaceParams sp = decodeLabPbr(specTex, normalTex);
    // _s が無いテクスチャ (Iris の既定は全 0) は ID からの推定で埋める。AO と高さは _n のまま
    if (dot(specTex, specTex) <= 0.0) {
        SurfaceParams est = estimateSurfaceParams(materialId, albedo.rgb);
        est.ao = sp.ao;
        est.height = sp.height;
        sp = est;
    }
#else
    SurfaceParams sp = estimateSurfaceParams(materialId, albedo.rgb);
#endif

    // ---- 法線 ----
    bool isPlant = materialId == MAT_PLANT || materialId == MAT_UNDERWATER_PLANT;
    vec3 normalTs = vec3(0.0, 0.0, 1.0);
#if defined USE_LABPBR && defined NORMAL_MAPPING
    vec2 nxy = normalTex.xy * 2.0 - 1.0;
    normalTs = vec3(nxy, sqrt(saturate(1.0 - dot(nxy, nxy))));
#elif defined USE_GENERATED_NORMALS
    if (!isPlant) normalTs = generatedNormal(uv);
#endif
    vec3 normal = normalize(tbn * normalTs);
    vec3 geoNormal = geoN;
    if (isPlant) {
        // 十字の植物は面の向きがばらばらなので上向きにして地面と同じ明るさで照らす (裏からの光は透過で表す)
        normal = vec3(0.0, 1.0, 0.0);
        geoNormal = normal;
    }

    // ---- 雨の濡れと水たまり (Lagarde 2013: 空隙が水で満ちると暗くなり、表面に水膜ができて滑らかになる) ----
    float puddle = 0.0;
    float wetAmount = 0.0;
#if defined RAIN_PUDDLES && defined HAS_SKY && defined GBUF_TERRAIN
    if (wetness > 0.001 && biome_precipitation == 1 && !isPlant) {
        float exposure = smoothstep(0.88, 0.97, lmcoord.y);
        wetAmount = wetness * exposure;
        if (wetAmount > 0.0) {
            vec3 worldPos = playerPos + cameraPosition;
            float wetStrength = saturate(wetAmount * RAIN_WETNESS);
            // 水たまりは真上が空の所 (スカイライト 15) の上向きの面だけ。葉・溶岩の上には溜めない
            float growth = smoothstep(PUDDLE_GROWTH.x, PUDDLE_GROWTH.y, wetness);
            float puddleArea = smoothstep(0.7, 0.95, geoN.y) * smoothstep(PUDDLE_SKYLIGHT.x, PUDDLE_SKYLIGHT.y, lmcoord.y) * growth;
            if (materialId == MAT_LEAVES || materialId == MAT_LAVA) puddleArea = 0.0;
            float fringe = 0.0;
            if (puddleArea > 0.0) {
                // 降り始めは模様の一番低い所 (ノイズの山) から溜まり、雨が続くほど PUDDLE_AMOUNT まで広がる。乾く時はその逆。POM の窪みには先に溜まる
                float n = puddleNoise(worldPos.xz) + pomDepth * 0.15;
                float th = puddleThreshold(PUDDLE_AMOUNT * growth);
                puddle = smoothstep(th - PUDDLE_EDGE * 0.5, th + PUDDLE_EDGE * 0.5, n) * puddleArea;
                fringe = smoothstep(th - PUDDLE_FRINGE, th, n) * puddleArea;
            }

            // 水たまりの底は空隙が水で満ちきっているので、多孔度によらず暗くする (暗い底の上に空が映って水たまりが見える)
            // 周りの帯は水がしみて少し暗い (水たまりの縁が地面からいきなり切り替わらないように)
            float soak = max(max(wetStrength * sp.porosity, fringe * PUDDLE_FRINGE_SOAK), puddle * PUDDLE_SOAK);
            albedo.rgb *= mix(1.0, WET_DARKEN, soak);
            // 雨が降り続くと空隙が満ちて表面に水膜が張るので、多孔質の面も艶が出る (水を吸う分だけ弱め)
            // 地面全体を水たまり並みに光らせると水たまりとの差が無くなって見えなくなった。艶は水たまりの周りの帯で強める
            float gloss = max(wetStrength * WET_GLOSS * (1.0 - sp.porosity), fringe * PUDDLE_FRINGE_GLOSS);
            sp.smoothness = mix(sp.smoothness, max(sp.smoothness, WET_SMOOTHNESS), gloss);
            sp.smoothness = mix(sp.smoothness, PUDDLE_SMOOTHNESS, puddle);
            if (labPbrMetalId(sp.f0) == METAL_NONE) sp.f0 = mix(sp.f0, PUDDLE_F0, puddle);
            if (puddle > 0.0) {
                vec2 ripple = rainRipples(worldPos.xz, rainStrength * PUDDLE_RIPPLES);
                vec3 puddleNormal = normalize(vec3(-ripple.x, 1.0, -ripple.y));
                // 縁の半分から内側は自動法線の凹凸を残さない (映り込みがテクセルごとに散ってマットに見えた)
                normal = normalize(mix(normal, puddleNormal, saturate(puddle * 2.0)));
            }
            wetAmount = max(wetStrength, fringe * PUDDLE_FRINGE_SOAK);
        }
    }
#endif

    // ---- 鏡面のちらつき対策 ----
    // テクスチャ法線が視線の裏を向くと NoV が 0 に張り付き、かすめ角の照り返しがテクセル単位で明滅する
    if (!isPlant && dot(geoNormal, -viewDirPlayer) > 0.0) normal = frontFacingNormal(normal, -viewDirPlayer, FRONT_FACING_MIN_NOV);
    // 鏡面 AA (法線の画面微分で alpha^2 を広げる) は実機で逆効果だったので入れていない。自動法線はテクセル内で一定のため
    // 微分がテクセルの境目の 2x2 だけ大きくなり、ジッターでその画素の粗さが毎フレーム変わってちらつきが増えた (ice_dusk p99 3.7 -> 3.9)

    GBufferData g = gbufferDefault();
    g.albedo = srgbToLinear(albedo.rgb);
    g.materialId = materialId;
    g.geoNormal = geoNormal;
    g.normal = normal;
    g.lightmap = lmcoord;
    g.smoothness = sp.smoothness;
    g.f0 = sp.f0;
    g.sss = sp.sss;
#ifdef GBUF_TERRAIN
    float vanillaAo = glcolor.a;
    #if AO_MODE > 0
        vanillaAo = pow(vanillaAo, VANILLA_AO_SOFTEN);
    #endif
    g.ao = vanillaAo * sp.ao;
#else
    g.ao = sp.ao;
#endif
    g.wetness = max(wetAmount, puddle);
    g.emission = max(estimateEmission(albedo.rgb, materialId), sp.emission);
#if defined GBUF_TERRAIN && DECORATIVE_BLOCK_LIGHTS > 0
    // 鉱物ブロック (DECORATIVE_BLOCK_LIGHTS)。光源ブロックより弱く、模様の明るい所ほど光らせる
    if (isDecorativeBlock(blockId)) g.emission = max(g.emission, DECOR_EMISSION * smoothstep(0.15, 0.85, maxOf(albedo.rgb)));
#endif
    encodeGBuffer(g, outAlbedo, outNormal, outMaterial);
    outMaterial.a = encodeSurfaceExtra(pomShadow, puddle);

#if defined GBUF_ENTITIES
    outVelocity = encodeVelocity(viewPos);
#elif defined GBUF_HAND
    outVelocity = encodeHandVelocity();
#else
    outVelocity = vec4(0.0);
#endif
}
