/*
 * 水面の屈折 (composite1) と合成 (composite2): 屈折 (方式 A / B / D)・水中の内散乱・水面の反射・側面の水の厚み・太陽のきらめき・白波の泡
 * surface モジュール。texcoord は composite_specular.glsl が宣言する
 */
#ifndef SURFACE_WATER_SHADING_GLSL
#define SURFACE_WATER_SHADING_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/exposure.glsl"
//@include "/lib/common/gbuffer.glsl"
//@include "/lib/common/joint_bilateral.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/shading_types.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/voxel_space.glsl"
//@include "/lib/common/water.glsl"
//@include "/lib/buffers/images.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/ids/material_ids.glsl"
//@include "/lib/light/block_data.glsl"
//@include "/lib/light/trace.glsl"
//@include "/lib/light/voxel.glsl"
//@include "/lib/light/voxel_read.glsl"
//@include "/lib/surface/brdf.glsl"
//@include "/lib/surface/composite_specular.glsl"
//@include "/lib/surface/gi.glsl"
//@include "/lib/surface/lighting.glsl"
//@include "/lib/surface/reflection.glsl"
//@include "/lib/surface/surface_lights.glsl"

const float WATER_REFRACT_MAX_DISTANCE = 8.0;  // 屈折先を探す最大距離 (ブロック)
const int WATER_REFRACT_STEPS = 16;
const float WATER_SKY_PATH = 64.0;             // 屈折先が空 (描画距離の外) の時に仮定する水の経路長
const float WATER_F0 = 0.02;                   // 水の垂直入射の反射率
const float WATER_ROUGHNESS = 0.02;            // 側面の水の太陽の鏡面の alpha
const float WATER_SUN_ROUGHNESS = MIN_ROUGHNESS; // 上面の水は表面張力波より細かい所では光学的に滑らか
const float WATER_MULTI_SCATTER = 2.0;         // 内散乱の多重散乱分の持ち上げ
// 上から見た水の内散乱は、水面から入った光が視線側 (上) へ戻る後方散乱だけ。海の粒子の位相関数は前方に強く尖っていて
// 後方散乱は散乱全体の数 % しかないので、等方散乱のままだと深い所が暗い紺にならず明るい水色に浮く
const float WATER_BACKSCATTER = 0.08;
/*
 * 水際の水面の白い表現は要らないので岸の泡は出さず、水の厚みが薄い帯では白波も出さない
 * 厚みは「視線に沿った水の厚み」で測る。鉛直の水深で測ると、岸のブロックの側面 (水深 0 から下へ続く壁) が
 * 水際に沿って必ず白くなり、水面の外へ白い帯が光って見える (バニラの地形では水底は水面の 0.89 下)
 */
const float FOAM_SHORE_WIDTH = 1.5;            // 白波を出さない水際の水の厚み (ブロック)
const float FOAM_ALBEDO = 0.8;
const float FOAM_OPACITY = 0.7;
// 白波: 波頭を寄せた Jacobian がこの範囲まで下がると崩れて泡立つ。風速 (m/s) がこの範囲で増える (Monahan: 4 m/s 前後から)
const float WHITECAP_J0 = 0.55;
const float WHITECAP_J1 = 0.3;
const float WHITECAP_WIND0 = 4.0;
const float WHITECAP_WIND1 = 10.0;
/*
 * 滝には泡を描かない。側面全体に白い縦筋を塗るとすりガラスに白いペンキを垂らしたように見え、落ちた高さで足す気泡の白さは
 * 日向の泡の白 (アルベド 0.8) を 2-3 割混ぜるだけで側面が白く濁り、着水点の泡は水際の白いしぶきに見える
 * 側面は上面と同じく吸収・散乱・反射だけの水にし、流れは側面の波 (waterFallNormal) で見せる
 */
// 側面から入った光が水を出る所をボクセルで探す最大のセル数
const int WATER_EXIT_STEPS = 12;
// 波頭の透過光 (太陽へ向かって見た時に薄い波頭を抜けた光が水の散乱色で光る, Sea of Thieves 2018)
const float WATER_CREST_SSS = 0.04;
const vec2 WATER_CREST_GRAZE = vec2(0.05, 0.35); // 平均水面と視線の cos がこの範囲で透過光を 1 -> 0 へ (低く見た時だけ)
const float WATER_CREST_HEIGHT = 0.3;          // 透過光が最大になる波頭の高さの下限 (ブロック)。波の小さい湖は波頭が低いので弱い
// 屈折先が水面よりこれ以上高ければ水の外 (岸のブロックの水面から出た部分)
const float WATER_REFRACT_SURFACE_EPS = 0.02;
const int WATER_REFRACT_RETRY = 3;             // 水の外を指した屈折を手前へ半分ずつ寄せ直す回数
// 屈折先を画面の端からこの UV だけ内側に収める (端の画素を引き伸ばさないため)
const float WATER_REFRACT_EDGE = 0.002;
/*
 * 屈折の方式 D (WATER_REFRACTION_MODE 2): 上から見た水面は屈折した向きそのもので水底を探す (水底が浅く見える)
 * 画面の像は画面の端からこの幅 (UV) でボクセルの色へ溶かす。端の数行で急に切り替えると、テクスチャのある像と
 * ボクセルの近似の色の境が横の線になる
 */
const float WATER_REFRACT_D_BLEND = 0.08;
const float WATER_REFRACT_D_DISTANCE = 32.0;    // 屈折先を探す最大距離 (ブロック)。澄んだ水でも 32 で青の透過は 4 割台まで落ちる
const float WATER_REFRACT_D_MATCH = 0.6;        // 画面の点が屈折した光線からこれ以内なら同じ屈折先 (ブロック, 距離 1 あたり 1% を足す)
const float WATER_REFRACT_D_REF_RADIUS = 6.0;   // ボクセルの色の基準にする水底の平均を取る半径 (画素)
const float WATER_REFRACT_D_REF_MATCH = 2.0;    // 基準の平均に入れる水底の点の、まっすぐ見た水底からの距離 (ブロック)
const vec2 WATER_REFRACT_D_TONE_CLAMP = vec2(0.5, 2.0); // 表の色に掛ける明るさの補正の範囲

// 屈折先 tuv を画面の内側へ収める (元の画素 uv からのずれを縮める)
vec2 clampRefractUv(vec2 uv, vec2 tuv) {
    vec2 d = tuv - uv;
    vec2 room = mix(uv - WATER_REFRACT_EDGE, 1.0 - WATER_REFRACT_EDGE - uv, step(0.0, d));
    vec2 s = mix(vec2(1.0), room / max(abs(d), vec2(1e-6)), greaterThan(abs(d), vec2(1e-6)));
    return uv + d * saturate(min(s.x, s.y));
}

/*
 * 方式 B: 屈折のずれを画面の端へ近いほど弱める。端までの余白 room に対して room * tanh(ずれ / room) に縮めるので、
 * 余白に比べて小さいずれはそのまま、端を越えるずれは端の手前で止まる。元の画素の位置に対して単調なので、
 * clampRefractUv のように端の数行へ多くの画素が集まって縦に引き伸ばされることが無い
 */
vec2 softClampRefractUv(vec2 uv, vec2 tuv) {
    vec2 d = tuv - uv;
    vec2 room = max(mix(uv - WATER_REFRACT_EDGE, 1.0 - WATER_REFRACT_EDGE - uv, step(0.0, d)), vec2(1e-5));
    return uv + sign(d) * room * tanh(abs(d) / room);
}

#if WATER_REFRACTION_MODE == 2
/*
 * 方式 D で画面の像を使う重み。屈折先 tuv がずれの向きの画面の端へ近いほど 0 (ボクセルの色) へ寄せる
 * ずれの小さい軸の端は関係しない (屈折のずれは大抵画面の下向きで、左右の端の像までぼかさないため)
 */
float waterRefractScreenWeight(vec2 uv, vec2 tuv) {
    vec2 d = tuv - uv;
    vec2 room = mix(tuv, 1.0 - tuv, step(0.0, d));
    vec2 w = mix(vec2(1.0), saturate(room / WATER_REFRACT_D_BLEND), saturate(abs(d) / WATER_REFRACT_D_BLEND));
    return w.x * w.y;
}

/*
 * 方式 D: 上から見た水面の屈折先をボクセルで辿る (画面外・手前の物の陰の水底)
 * 当たりが画面に映っていればその色。映っていなければ、面に沿って整数ブロックずらした同じブロックの同じ面の画面の色を借りる
 * (borrowVoxelFaceColor)。それも無ければ、ボクセル反射と同じ照明の近似 (太陽の影の 1 タップ・雲影・floodfill・空, shadeSecondaryHit)
 * でブロックの平均の色の表を照らす。表の色は、この画素からまっすぐ見た水底の周りの平均との明るさの比で、画面の像との段を消す
 * (まっすぐ見た水底の像そのものを使うと、屈折先が画面に無い所が屈折していない像になる)
 * 戻り値 false = ボクセルの範囲外で分からない。true で何にも当たらなければ深い水 (pathLen = WATER_SKY_PATH, 色は 0)
 */
bool waterRefractVoxel(vec3 surfPlayer, vec3 dir, vec3 floorPlayer, float d1, float skyLm, out vec3 color, out float pathLen) {
    color = vec3(0.0);
    pathLen = WATER_SKY_PATH;
    // 水面のすぐ下 (水のセル) から辿る。traceVoxelRay は始点のセルを判定しない
    vec3 o = playerToVoxel(surfPlayer + dir * (0.02 + length(surfPlayer) * 0.002));
    if (!isInVoxelVolume(o)) return false;
    vec3 hitVoxel, hitNormal;
    int hitBlock;
    if (!traceVoxelRay(o, dir, WATER_REFRACT_D_DISTANCE, hitVoxel, hitNormal, hitBlock)) {
        return isInVoxelVolume(o + dir * WATER_REFRACT_D_DISTANCE);
    }
    vec3 hitPlayer = voxelToPlayer(hitVoxel);
    pathLen = distance(hitPlayer, surfPlayer);

    vec3 screenColor = vec3(0.0);
    float wS = 0.0;
    ivec2 hitTexel;
    vec3 hitScene;
    if (voxelHitOnScreen(hitPlayer, hitNormal, hitTexel, hitScene)) {
        screenColor = texelFetch(colortex0, hitTexel, 0).rgb;
        wS = waterRefractScreenWeight(texcoord, (vec2(hitTexel) + 0.5) / viewSize());
    }
    if (wS >= 1.0) {
        color = screenColor;
        return true;
    }

    /*
     * 水底の点はコースティクス (1 点に波テクスチャ 9 回) が照明の費用の大半を占め、画面の外を指す近景の下端と遠景の帯の
     * 画素ごとに 3 回解いていた。借りる色 (同じ面の画面の画素) には借りた点のコースティクスが既に入っていて、比で
     * 当たりの点の模様へ移す必要は無い (数ブロックずれた同じ模様になるだけ) ので、比と明るさの基準はコースティクス抜きで照らす
     */
    vec3 voxelColor;
    vec3 unitE = shadeSecondaryHit(hitPlayer, hitNormal, vec3(1.0), skyLm, false);
    bool hasRef = borrowVoxelFaceColor(hitPlayer, hitNormal, hitBlock, skyLm, unitE, true, false, voxelColor);
    if (!hasRef) {
        // まっすぐ見た水底の像をそのまま使うと、屈折先が画面に無い所が屈折していない像になった
        // 像は明るさの基準にだけ使い、色はブロックの表の色を照らして作る (模様は写さない)
        unitE = shadeSecondaryHit(hitPlayer, hitNormal, vec3(1.0), skyLm, true);
        voxelColor = shadeSecondaryHitReflectedFrom(unitE, hitPlayer, hitNormal, getBlockAlbedo(hitBlock, hitNormal), ivec2(-1));
    }
    if (!hasRef && d1 < 1.0 && floorPlayer.y < surfPlayer.y) {
        GBufferData g = readGBuffer(ivec2(gl_FragCoord.xy));
        // 周りの水底の平均 (模様を落とした明るさの基準)
        vec2 r = WATER_REFRACT_D_REF_RADIUS / viewSize();
        float matchDist = WATER_REFRACT_D_REF_MATCH + length(floorPlayer) * 0.02;
        vec3 sum = vec3(0.0);
        float n = 0.0;
        for (int k = 0; k < 5; k++) {
            vec2 off = k == 0 ? vec2(0.0) : vec2(k == 1 || k == 2 ? -1.0 : 1.0, k == 1 || k == 3 ? -1.0 : 1.0);
            vec2 uv = clamp(texcoord + off * r, vec2(0.0), vec2(1.0));
            float dk = texture(depthtex1, uv).r;
            if (dk >= 1.0 || isHandDepth(dk) || distance(screenToPlayer(vec3(uv, dk)), floorPlayer) > matchDist) continue;
            sum += texture(colortex0, uv).rgb;
            n += 1.0;
        }
        // 水底のセルのブロック (表の色の基準)
        ivec3 floorCell = ivec3(floor(playerToVoxel(floorPlayer - g.geoNormal * VOXEL_HIT_INSET)));
        int floorBlock = isInVoxelVolume(floorCell) ? fetchVoxelBlockId(floorCell) : hitBlock;
        // 5 タップの平均でコースティクスの模様はならされているので、基準の側もコースティクス抜きで照らす
        vec3 Efloor = shadeSecondaryHitReflected(floorPlayer, g.geoNormal, getBlockAlbedo(floorBlock, g.geoNormal), g.lightmap.y, ivec2(-1), false);
        if (n > 0.0 && luminance(Efloor) > 1e-6) {
            // 輝度の比だけ (色ごとの比にすると影の 1 タップの色の差で染まる)。表の色と画面の像の明るさの段を消す
            float tone = clamp(luminance(sum / n) / luminance(Efloor), WATER_REFRACT_D_TONE_CLAMP.x, WATER_REFRACT_D_TONE_CLAMP.y);
            voxelColor *= tone;
        }
    }
    color = mix(voxelColor, screenColor, wS);
    return true;
}
#endif

/*
 * 水の上から見た水中の内散乱 (水面の太陽 + 空)。水中フォグ (B) と同じ係数 (lib/common/water.glsl) を使う
 * 水面から入った光は深さ z で E0 exp(-Kd z) に弱まる (太陽は水中で屈折した向きに沿って Kd = c / mu_sun、空の光は Kd = c で、
 * 水中フォグの marchWaterFog と同じ)。屈折した視線に沿って s 進んだ点の深さは s mu_view で、そこから戻る光は exp(-c s) で弱まるので、
 * 経路 [0, S] の積分は E0 b (1 - exp(-(c + Kd mu_view) S)) / (c + Kd mu_view) で閉じる
 * 光源の照度を深さによらず一定にすると、深い所ほど内散乱が水面の明るさのまま飽和し、浅瀬 (底の照り返し) との差が出ない
 * muView: 屈折した視線の下向きの cos (側面から入る水平の視線は 0 で深さが変わらない), pathLen: 水の中の経路長
 * localE: 水面に届くブロックライト (floodfill) と手持ち光源の照度。向きは持たないので空の光と同じ減衰で扱う
 */
vec3 waterInscatter(float skyLm, vec3 sunVis, vec3 localE, float muView, float pathLen) {
    LightSample sun = unshadowedSun();
    vec3 ext = waterExtinction();
    float sunY = saturate(sun.direction.y);
    float muSun = sqrt(max(1.0 - (1.0 - sunY * sunY) / sqr(WATER_IOR), 0.0));
    vec3 sunE = sun.irradiance * sunY * sunVis;
    vec3 skyE = secondaryHitSky(vec3(0.0), vec3(0.0, 1.0, 0.0), skyLm) + localE;
    vec3 kSun = ext * (1.0 + muView / muSun);
    vec3 kSky = ext * (1.0 + muView);
    vec3 E = sunE * (1.0 - exp(-kSun * pathLen)) / kSun + skyE * (1.0 - exp(-kSky * pathLen)) / kSky;
    // 等方散乱 1/(4 pi) を多重散乱分だけ持ち上げ、上へ戻る (後方散乱の) 割合を掛ける
    return E * waterScattering() * ((0.25 * RCP_PI) * WATER_MULTI_SCATTER * WATER_BACKSCATTER);
}

// 屈折先の UV が水面の向こう側の物を指しているか (手前の地形を水に引き込まないため)
bool validRefraction(vec2 uv, float surfaceDepth) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return false;
    float d = texture(depthtex1, uv).r;
    return d > surfaceDepth && !isHandDepth(d);
}

/*
 * 水面の屈折先が水の中か。深度が水面より奥でも、岸のブロックの水面から出た側面は水の外で、そこを拾うと
 * 吸収されない明るい岸の色が水際に沿って帯になる。上向きの水面を上から見た時だけ高さで確かめる
 */
bool refractionInWater(vec2 uv, float surfaceDepth, float surfaceY, bool checkHeight) {
    if (!validRefraction(uv, surfaceDepth)) return false;
    if (!checkHeight) return true;
    float d = texture(depthtex1, uv).r;
    return d >= 1.0 || screenToPlayer(vec3(uv, d)).y < surfaceY + WATER_REFRACT_SURFACE_EPS;
}

#if REFLECTIONS > 0
/*
 * 水面の反射の 2x2 アップサンプル (lib/surface/reflection.glsl の sampleReflection と同じ重み)。水でない近傍は混ぜない
 * 岸のブロックの側面は水際の水面と同じ距離にあるので、距離の重みだけでは壁の (粗い面の) 反射が水際に明るい線になって入る
 * 空へ抜けた近傍 (距離が負) は色を混ぜず重みだけ skyWeight に返す。呼び出し側がこの画素の反射方向で空を引き直す
 * 戻り値 rgb = 物に当たった近傍の加重和 (重みで割っていない), a = 重みの合計 (空の分を含む)
 */
vec4 sampleWaterReflection(ivec2 texel, float dist, out float skyWeight) {
    ivec2 lowSize = reflectionLowResSize();
    ivec2 region = reflectionRegion(frameCounter);
    ivec2 offset = lowResOffset(frameCounter);
    ivec2 base = (texel - offset) >> 1;
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    skyWeight = 0.0;
    for (int j = 0; j <= 1; j++) {
        for (int i = 0; i <= 1; i++) {
            ivec2 L = clamp(base + ivec2(i, j), ivec2(0), lowSize - 1);
            vec4 r = texelFetch(reflectionSampler, L + region, 0);
            if (r.a == 0.0) continue;
            bool sky = r.a < 0.0;
            r.a = abs(r.a);
            ivec2 src = min(L * 2 + offset, ivec2(viewSize()) - 1);
            vec3 n;
            vec2 lm;
            int mat;
            decodeTranslucentData(texelFetch(colortex5, src, 0), n, lm, mat);
            if (mat != MAT_WATER) continue;
            vec2 delta = abs(vec2(src - texel)) * 0.5;
            float w = max(1.0 - delta.x, REFLECTION_UPSAMPLE_MIN_WEIGHT) * max(1.0 - delta.y, REFLECTION_UPSAMPLE_MIN_WEIGHT) * bilateralDepthWeight(r.a, dist, dist * REFLECTION_UPSAMPLE_DEPTH_REL + REFLECTION_UPSAMPLE_DEPTH_ABS);
            if (sky) skyWeight += w;
            else sum += r.rgb * w;
            wsum += w;
        }
    }
    return vec4(sum, wsum);
}
#endif

/*
 * 粗い水面の空の反射 (R0 = 持ち上げる前の反射方向, slopeVar = 均す傾きの分散)。持ち上げた仰角の上下に傾きの広がりの分ずらした
 * 3 方向の空の平均。1 方向だけだと、かすめ角では持ち上げた仰角が R0 によらずほぼ一定になり、同じ高さの空の 1 行が縦に
 * 引き伸ばされて、地平線の手前に雲の縁で切れた四角い縦縞が並んだ
 */
const float WATER_SKY_SPREAD = 1.2;             // 傾きの RMS あたりの上下のずらし幅 (仰角の sin)

vec3 waterSkyReflection(vec3 R0, float slopeVar, float skyLm, float dist) {
    vec3 R = waterRoughReflectDir(R0, slopeVar);
    // 近景・中景の雲の映り込みはぼかさない (フレネルを均す範囲と揃える)
    float spread = WATER_SKY_SPREAD * sqrt(slopeVar) * smoothstep(WATER_ROUGH_FRESNEL_RANGE.x, WATER_ROUGH_FRESNEL_RANGE.y, dist / far);
    if (spread < 0.005) return skyPixelReflection(R, skyLm, skyReflectionFallback(R, skyLm, 0.0));
    vec3 sum = vec3(0.0);
    for (int k = -1; k <= 1; k++) {
        vec3 Rk = normalize(vec3(R.x, max(R.y + spread * float(k), 0.01), R.z));
        sum += skyPixelReflection(Rk, skyLm, skyReflectionFallback(Rk, skyLm, 0.0));
    }
    return sum / 3.0;
}

/*
 * 側面の幾何の向き (視線側)。波で揺れた法線の主軸 (x か z) で取る
 * (面内の座標を波で揺れた法線から取ると、大きなワールド座標に掛かって画素ごとの砂目になった)
 */
vec3 waterSideFaceNormal(vec3 N) {
    return abs(N.x) > abs(N.z) ? vec3(sign(N.x), 0.0, 0.0) : vec3(0.0, 0.0, sign(N.z));
}

// 水のセルか (海草・コンブは水の中にある)
bool isWaterCell(ivec3 cell) {
    int id = unpackVoxelBlockId(readVoxelBlock(cell));
    return id == BLOCK_WATER || id == BLOCK_UNDERWATER_PLANT;
}

/*
 * 水の側面から入った光線 (originPlayer から dir) が水を出るまでの距離。ボクセルで辿り、水でないセル (空気・ガラス・地形) に入った所
 * outward = 出る面の外向きの法線。見つからない (体積の外・WATER_EXIT_STEPS より厚い) 時は -1
 * 深度 (depthtex1) は水の裏の面を持たないので、側面の水の厚みを奥の地形までの距離で測ると、ガラスの水槽 (厚み 3) の向こうに
 * 遠くの山があるだけで数十ブロックの水として吸収され、真っ暗な紺になっていた
 */
float waterExitDistance(vec3 originPlayer, vec3 dir, out vec3 outward) {
    outward = vec3(0.0);
    vec3 p = playerToVoxel(originPlayer);
    ivec3 cell = ivec3(floor(p));
    if (!isInVoxelVolume(cell) || !isWaterCell(cell)) return -1.0;
    ivec3 stepDir = ivec3(greaterThanEqual(dir, vec3(0.0))) * 2 - 1;
    vec3 tDelta = 1.0 / max(abs(dir), vec3(1e-7));
    vec3 fr = p - vec3(cell);
    vec3 tMax = mix(fr, 1.0 - fr, vec3(greaterThan(stepDir, ivec3(0)))) * tDelta;
    for (int i = 0; i < WATER_EXIT_STEPS; i++) {
        float t = minOf(tMax);
        vec3 axis;
        if (tMax.x == t) { cell.x += stepDir.x; tMax.x += tDelta.x; axis = vec3(float(stepDir.x), 0.0, 0.0); }
        else if (tMax.y == t) { cell.y += stepDir.y; tMax.y += tDelta.y; axis = vec3(0.0, float(stepDir.y), 0.0); }
        else { cell.z += stepDir.z; tMax.z += tDelta.z; axis = vec3(0.0, 0.0, float(stepDir.z)); }
        if (!isInVoxelVolume(cell)) return -1.0;
        if (!isWaterCell(cell)) {
            outward = axis;
            return t;
        }
    }
    return -1.0;
}

// 泡 (拡散の白) の放射輝度。n は泡の面の向き (水面なら真上、滝なら側面)。hand は手持ち光源を集めた SurfaceLights
vec3 foamRadiance(vec3 surfPlayer, vec3 n, vec2 lm, vec3 sunVis, SurfaceLights hand) {
    LightSample sun = unshadowedSun();
    SurfacePoint p = surfacePoint(surfPlayer, n);
    p.lightmap = lm;
    SurfaceLights L = gatherSurfaceLights(p, SL_SUN_NONE, SL_BLOCK_FORWARD, SL_SKY);
    vec3 E = sun.irradiance * saturate(dot(n, sun.direction)) * sunVis + L.sky + L.block + handIrradiance(hand, n);
    return vec3(FOAM_ALBEDO) * RCP_PI * E;
}

#endif
