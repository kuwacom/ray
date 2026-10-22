/*
 * composite1: 半透明の合成 (屈折・水中の吸収・反射を適用して colortex4 を colortex0 に重ねる)
 * surface モジュール (lib/surface)
 *
 * 不透明面: 環境光の鏡面 (反射バッファ or 空) x 方向アルベド x 鏡面遮蔽 を足す
 * 水面: 屈折 (WATER_REFRACTION 1 = 屈折方向に水深分進めて投影 + 深度検証, 2 = 屈折方向のレイマーチ)
 *       上から見た水面の屈折の方式 (WATER_REFRACTION_MODE): A = 波で曲がった分だけ / B = 屈折のまま画面の端で弱める /
 *       D = 屈折のまま、画面に無い屈折先はボクセルで辿る (水底が浅く見える)
 *       屈折した経路長で Jerlov の吸収と内散乱 / 厳密フレネル (水中からは全反射とスネルの窓) / 反射 / 太陽の鏡面 / 岸の泡
 *       側面 (滝・水槽): 水の厚みはボクセルで水を出る所まで / 出る面で空気へもう一度屈折 / 滝の気泡の白さと着水点の泡
 *       水中から見上げた水面より上は空気なので吸収しない (カメラと水面の間の水中フォグは sky の composite11)
 * ガラス等: 透過分 (1 - a) に透過色 (block_data の tints) と (1 - F) を掛け、前方で照らした拡散 (colortex4) と反射を足す
 *       平らな板ガラスは光線が平行にずれるだけなので屈折させない。厚い氷・スライムだけ少し歪める
 * それ以外 (パーティクル・手持ちの半透明・雨): 乗算済みアルファでそのまま重ねる
 */
#include "/lib/common/common.glsl"
#include "/lib/surface/surface.glsl"
#include "/lib/sky/sky.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/screen_trace.glsl"
#include "/lib/surface/lighting.glsl"
#include "/lib/surface/reflection.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

const float WATER_REFRACT_MAX_DISTANCE = 8.0;  // 屈折先を探す最大距離 (ブロック)
const int WATER_REFRACT_STEPS = 16;
const float WATER_SKY_PATH = 64.0;             // 屈折先が空 (描画距離の外) の時に仮定する水の経路長
const float WATER_ROUGHNESS = 0.02;            // 太陽の鏡面の alpha (波の法線が細部を受け持つ)
const float WATER_MULTI_SCATTER = 2.0;         // 内散乱の多重散乱分の持ち上げ
// 上から見た水の内散乱は、水面から入った光が視線側 (上) へ戻る後方散乱だけ。海の粒子の位相関数は前方に強く尖っていて
// 後方散乱は散乱全体の数 % しかないので、等方散乱のままだと深い所が明るい水色に浮く (iterationT は暗い紺)
const float WATER_BACKSCATTER = 0.08;
/*
 * 岸の泡は「視線に沿った水の厚み」が薄い所に出す。鉛直の水深で測ると、岸のブロックの側面 (水深 0 から下へ続く壁) が
 * 水際に沿って必ず泡になり、水面の外へ白い帯が光って見えた (バニラの地形では水底は水面の 0.89 下なので、
 * 浅い床の泡はほとんど出ず、帯だけが出ていた)。量は波の高さに比例させ、凪いだ湖では出さない
 * -> 水際の水面の白い表現は要らないので岸の泡はやめた。同じ厚みの帯では白波も出さない
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
 * 滝の泡: 全体の薄い濁り (筋の外の割合) と、筋の模様 (0-1) がこの範囲で濃い泡になる。量 (不透明度)
 * -> 側面全体に白い縦筋を塗ると、すりガラスに白いペンキを垂らしたように見えた。筋はやめ、次の 2 つにした (WATER_FALL_FOAM)
 *    - 気泡の白さ: 落ちる水は落ちた高さとともに空気を巻き込んで白む。側面の上の水のセルの数 (落ちた高さ) で薄いもやを足す
 *    - 着水点の泡: 上の段から水が落ちてくる水面 (1 段上の隣のセルが水) の周りに泡を出す
 * -> どちらもやめた。日向の泡の白 (アルベド 0.8) は 2-3 割混ぜるだけで側面が白く濁り、着水点の泡は水際の白い
 *    しぶきに見えた。側面は上面と同じく吸収・散乱・反射だけの水にし、流れは側面の波 (waterFallNormal) で見せる
 */
// 側面から入った光が水を出る所をボクセルで探す最大のセル数
const int WATER_EXIT_STEPS = 12;
// 波頭の透過光 (太陽へ向かって見た時に薄い波頭を抜けた光が水の散乱色で光る, Sea of Thieves 2018)
const float WATER_CREST_SSS = 0.04;
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
const int WATER_REFRACT_D_BORROW_TRIES = 4;     // 色を借りる隣のブロックを探す回数 (奥へ 1, 2 / 横へ 1 / 奥へ 3)
const float WATER_REFRACT_D_BORROW_MATCH = 0.3; // 借りる点が画面の深度の点とこれ以内なら映っている (ブロック, 距離 1 あたり 1% を足す)
const float WATER_REFRACT_D_REF_RADIUS = 6.0;   // ボクセルの色の基準にする水底の平均を取る半径 (画素)
const float WATER_REFRACT_D_REF_MATCH = 2.0;    // 基準の平均に入れる水底の点の、まっすぐ見た水底からの距離 (ブロック)
// 照り返しのうち輝点に回す割合の上限 (WATER_GLINT = 1 の時)。残りは滑らかなローブのまま光の道の下地の淡い光にする
const float WATER_GLINT_POINT_SHARE = 0.85;
const float GLASS_IOR = 1.5;
const float ICE_IOR = 1.31;
const float THICK_TRANSLUCENT_REFRACTION = 0.02; // 氷・スライムの屈折の UV オフセット
const float GLASS_TINT_STRENGTH = 0.65;        // 透過色の濃さ (1 で tints 表そのまま)

vec3 reflectionAt(ivec2 texel, float dist, vec3 R, float skyLm, float roughness, vec3 normal) {
    vec3 fallback = skyReflectionFallback(R, skyLm, roughness);
#if REFLECTIONS > 0
    vec4 r = sampleReflection(texel, dist, normal);
    return mix(fallback, r.rgb, saturate(r.a * 4.0));
#else
    return fallback;
#endif
}

/*
 * 鏡面 (水・水たまり・ガラス) の物の映り込みはフル解像度で辿り直す。氷は粗さが MIRROR_ROUGHNESS 以上なので対象外。composite.csh の半分の解像度の結果を
 * 2x2 で引き伸ばすと、映り込みの輪郭がぼけて角張り、鏡のはずの面がつやの無い面に見えた
 * 外れた画素 (空・画面外・ボクセルの当たり) は半分の解像度の結果 refl のまま
 */
vec3 mirrorReflection(vec3 refl, vec3 viewPos, vec3 playerPos, vec3 Ng, vec3 R, float dist, bool opaque, bool waterTop, float dither) {
#if REFLECTIONS > 0
    vec4 hit = traceReflectionHit(viewPos, playerPos, Ng, R, dist, mirrorTraceDistance(), opaque, waterTop, dither);
    if (hit.w > 0.5) refl = mix(refl, reflectionHitRadiance(hit.xy), hit.z);
#endif
    return refl;
}

// 不透明面の環境光の鏡面
vec3 opaqueEnvSpecular(ivec2 texel, float depth) {
    GBufferData g = readGBuffer(texel);
    Material m = decodeMaterial(g);
    bool hand = isHandDepth(depth);
    vec3 playerPos = screenToPlayer(vec3(texcoord, fixHandDepth(depth)));
    float dist = length(playerPos);
    vec3 V = -playerPos / max(dist, 1e-4);
    float NoV = max(dot(g.normal, V), 1e-3);
    vec3 R = reflect(-V, g.normal);
    vec3 refl = hand ? skyReflectionFallback(R, g.lightmap.y, m.perceptualRoughness)
        : reflectionAt(texel, dist, R, g.lightmap.y, m.perceptualRoughness, g.normal);
    if (!hand && m.perceptualRoughness < MIRROR_ROUGHNESS) {
        // composite.csh と同じ反射方向 (視線側へ倒した法線で反射し、幾何面より上へ折り返す)
        vec3 Ng = dot(g.geoNormal, V) < 0.0 ? -g.geoNormal : g.geoNormal;
        vec3 Rm = reflect(-V, frontFacingNormal(g.normal, V, REFLECT_MIN_NOV));
        float e = dot(Rm, Ng);
        Rm = normalize(Rm + Ng * (max(abs(e), REFLECT_MIN_ELEVATION) - e));
        refl = mirrorReflection(refl, playerToView(playerPos), playerPos, Ng, Rm, dist, true, false,
            interleavedGradientNoise(gl_FragCoord.xy, frameCounter));
    }
    float ao = g.ao * getIndirectLight(texel).a;
    return refl * envSpecularWeight(m, NoV) * specularOcclusion(NoV, ao, m.roughness);
}

// 面での太陽の可視率 (影 + 雲影)。PCSS は重いので 1 ピクセル 1 回にして鏡面・内散乱・泡で使い回す
vec3 surfaceSunVisibility(vec3 playerPos, vec3 geoNormal, float dither) {
    return getSunShadow(playerPos, geoNormal, dither) * getCloudShadow(playerPos);
}

// 太陽の鏡面だけ。f0 と alpha を与えた誘電体として
vec3 sunSpecular(vec3 N, vec3 V, float f0, float roughness, vec3 sunVis) {
    LightSample sun = getCelestialLight();
    sun.irradiance *= sunVis;
    GBufferData g = gbufferDefault();
    g.f0 = f0;
    g.smoothness = 1.0 - sqrt(roughness);
    g.albedo = vec3(0.0);
    return evalDirectSpecular(decodeMaterial(g), N, V, sun);
}

/*
 * 水面の太陽 (月) の照り返しのきらめき。滑らかなローブ x 輝点の倍率 (lib/surface/water.glsl の waterSunGlint)
 * slopeVar: 画素より細かい波の傾きの分散。戻り値 rgb = 足す放射輝度, a = そのうち輝点の輝度 (TAA を通さずに足す分)
 */
vec4 sunGlint(vec3 surfPlayer, vec3 N, vec3 V, float slopeVar, vec3 sunVis, float dist, float NoVGeo) {
    LightSample sun = getCelestialLight();
    vec3 lobe = sunSpecular(N, V, 0.02, sqrt(sqr(WATER_ROUGHNESS) + slopeVar), sunVis);
    if (maxOf(lobe) <= 0.0) return vec4(0.0);
    float pixelWorld = dist * 2.0 / (gbufferProjection[1][1] * viewSize().y);
    vec2 gl = waterSunGlint(surfPlayer.xz + cameraPosition.xz, N, V, sun.direction, slopeVar, sun.angularSize, pixelWorld, NoVGeo);
    vec3 point = lobe * gl.y;
    // 1 枚の面が映す明るさは太陽の円盤の鏡像まで (GGX の裾と正規分布の裾の違いで出る極端な値を抑える)
    vec3 H = normalize(V + sun.direction);
    vec3 mirror = sun.irradiance * sunVis * fresnelSchlick(vec3(0.02), dot(V, H)) / (PI * sqr(sun.angularSize));
    point = min(point, mirror);
    return vec4(lobe * (gl.x - gl.y) + point, luminance(point));
}

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
 * 当たりが画面に映っていればその色。映っていなければ、ボクセル反射と同じ照明の近似 (太陽の影の 1 タップ・雲影・floodfill・空,
 * shadeSecondaryHit) で照らす。ボクセルにはブロックの色が無いので、この画素からまっすぐ見た水底 (画面に映っている同じ水の底)
 * の周りの平均の色を、照明の近似の比 (当たり / まっすぐ見た水底) で明るさと向きの分だけ直して使う
 * (一定のアルベド VOXEL_HIT_ALBEDO で照らすと、砂の水底で画面の像との境に色と明るさの段が出る)
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
    vec3 hitView = playerToView(hitPlayer);
    vec3 s = viewToScreen(hitView);
    if (hitView.z < 0.0 && all(greaterThan(s.xy, vec2(0.0))) && all(lessThan(s.xy, vec2(1.0)))) {
        float d = texture(depthtex1, s.xy).r;
        if (!isHandDepth(d) && distance(screenToPlayer(vec3(s.xy, d)), hitPlayer) < VOXEL_TRACE_SCREEN_MATCH) {
            screenColor = texture(colortex0, s.xy).rgb;
            wS = waterRefractScreenWeight(texcoord, s.xy);
        }
    }
    if (wS >= 1.0) {
        color = screenColor;
        return true;
    }

    vec3 voxelColor;
    bool hasRef = false;
    /*
     * ブロックのテクスチャはブロックごとに繰り返すので、当たりから面に沿って整数ブロックずらした点 (同じブロックの同じ位置) が
     * 画面に映っていればその色を借りる。水底の模様とブロックの境目が画面の像と揃ったまま続く (周りの平均だとぼけた帯になった)
     * カメラから遠ざかる向きにずらす (手前の岸に隠れた水底は、奥ほど画面に映っている)
     */
    vec3 nAbs = abs(hitNormal);
    ivec2 tAxes = nAbs.x > 0.5 ? ivec2(2, 1) : nAbs.y > 0.5 ? ivec2(0, 2) : ivec2(0, 1);
    if (abs(hitPlayer[tAxes.y]) > abs(hitPlayer[tAxes.x])) tAxes = tAxes.yx;
    vec3 awaySign = vec3(sign(hitPlayer.x), -sign(hitPlayer.y), sign(hitPlayer.z));
    for (int k = 0; k < WATER_REFRACT_D_BORROW_TRIES && !hasRef; k++) {
        int axis = k == 2 ? tAxes.y : tAxes.x;
        float steps = k == 2 ? 1.0 : float(k < 2 ? k + 1 : k);
        vec3 offset = vec3(0.0);
        offset[axis] = awaySign[axis] * steps;
        vec3 q = hitPlayer + offset;
        ivec3 qCell = ivec3(floor(playerToVoxel(q - hitNormal * 0.5)));
        if (!isInVoxelVolume(qCell) || unpackVoxelBlockId(readVoxelBlock(qCell)) != hitBlock) continue;
        vec3 qView = playerToView(q);
        vec3 qs = viewToScreen(qView);
        if (qView.z >= 0.0 || any(lessThan(qs.xy, vec2(0.0))) || any(greaterThan(qs.xy, vec2(1.0)))) continue;
        float dq = texture(depthtex1, qs.xy).r;
        // 水越しに映っている点だけ (岸の草ブロックの側面の縁など、水面より上の色を水底に借りない)
        if (texture(depthtex0, qs.xy).r >= dq) continue;
        if (isHandDepth(dq) || distance(screenToPlayer(vec3(qs.xy, dq)), q) > WATER_REFRACT_D_BORROW_MATCH * (1.0 + length(q) * 0.01)) continue;
        vec3 Eq = shadeSecondaryHit(q, hitNormal, vec3(1.0), skyLm);
        if (luminance(Eq) <= 1e-6) continue;
        vec3 Ehit = shadeSecondaryHit(hitPlayer, hitNormal, vec3(1.0), skyLm);
        voxelColor = texture(colortex0, qs.xy).rgb * clamp(luminance(Ehit) / luminance(Eq), 0.0, 4.0);
        hasRef = true;
    }
    if (!hasRef && d1 < 1.0 && floorPlayer.y < surfPlayer.y) {
        GBufferData g = readGBuffer(ivec2(gl_FragCoord.xy));
        // 周りの水底の平均 (テクスチャの細部を落とす。画面の像との境で模様が二重に見えないように)
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
        vec3 Eref = shadeSecondaryHit(floorPlayer, g.geoNormal, vec3(1.0), g.lightmap.y);
        if (n > 0.0 && luminance(Eref) > 1e-6) {
            vec3 Ehit = shadeSecondaryHit(hitPlayer, hitNormal, vec3(1.0), g.lightmap.y);
            // 明るさだけ直す (色ごとの比にすると、色付きの影の 1 タップの差で当たりの所々が青く染まった)
            voxelColor = sum / n * clamp(luminance(Ehit) / luminance(Eref), 0.0, 4.0);
            hasRef = true;
        }
    }
    if (!hasRef) voxelColor = shadeSecondaryHit(hitPlayer, hitNormal, vec3(VOXEL_HIT_ALBEDO), skyLm);
    color = mix(voxelColor, screenColor, wS);
    return true;
}
#endif

// 水中の内散乱の光源 (水面の太陽 + 空)。水中フォグ (B) と同じ係数 (lib/surface/water.glsl) を使う
vec3 waterInscatterSource(float skyLm, vec3 sunVis) {
    LightSample sun = getCelestialLight();
    vec3 sunE = sun.irradiance * saturate(sun.direction.y) * sunVis;
    vec3 skyE = getSkyIrradiance(vec3(0.0, 1.0, 0.0)) * skylightCurve(skyLm);
    // 等方散乱 1/(4 pi) を多重散乱分だけ持ち上げ、上へ戻る (後方散乱の) 割合を掛ける
    return (sunE + skyE) * (0.25 * RCP_PI) * WATER_MULTI_SCATTER * WATER_BACKSCATTER;
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
    ivec2 lowSize = reflectionLowSize();
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
            float w = max(1.0 - delta.x, 0.05) * max(1.0 - delta.y, 0.05) * exp(-abs(r.a - dist) / (dist * 0.02 + 0.05));
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

// 泡 (拡散の白) の放射輝度。n は泡の面の向き (水面なら真上、滝なら側面)
vec3 foamRadiance(vec3 surfPlayer, vec3 n, vec2 lm, vec3 sunVis) {
    LightSample sun = getCelestialLight();
    vec3 E = sun.irradiance * saturate(dot(n, sun.direction)) * sunVis
        + getSkyIrradiance(n) * skylightCurve(lm.y)
        + getBlockLightForward(surfPlayer, n, lm.x);
    return vec3(FOAM_ALBEDO) * RCP_PI * E;
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec3 scene = texelFetch(colortex0, texel, 0).rgb;
    vec4 translucent = texelFetch(colortex4, texel, 0);
    float d0 = texelFetch(depthtex0, texel, 0).r;
    float d1 = texelFetch(depthtex1, texel, 0).r;
    vec4 data = texelFetch(colortex5, texel, 0);
    vec3 nT;
    vec2 lmT;
    int matT;
    decodeTranslucentData(data, nT, lmT, matT);
    int tintIndex = int(round(unpack2x8(data.a).y * 255.0));
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    bool hasSurface = d0 < d1 && !isHandDepth(d0) && (matT == MAT_WATER || isReflectiveTranslucent(matT));
    if (!hasSurface) {
        vec3 color = scene;
        if (d1 < 1.0) color += opaqueEnvSpecular(texel, d1);
        outColor = vec4(color * (1.0 - translucent.a) + translucent.rgb, 1.0);
        return;
    }

    vec3 surfView = screenToView(vec3(texcoord, d0));
    vec3 surfPlayer = viewToPlayer(surfView);
    float dist = length(surfPlayer);
    vec3 V = -surfPlayer / max(dist, 1e-4);
    vec3 N = dot(nT, V) < 0.0 ? -nT : nT;
    float NoV = saturate(dot(N, V));
    vec3 floorPlayer = screenToPlayer(vec3(texcoord, d1));
    vec3 color;
    // 水面の輝点の輝度。TAA (composite20) は輝点を近傍の箱で潰すので、割合を a = 1 + 割合で渡して TAA の後に足させる
    float glintLum = 0.0;

    if (matT == MAT_WATER) {
        bool below = isEyeInWater == 1;
        float eta = below ? 1.0 / WATER_IOR : WATER_IOR;
        WaterSea sea = waterSeaState(lmT.y);
        // 側面 (滝・流れの段差・水槽): 幾何の向きは面の軸。波は側面専用の落ちる水の乱れ (lib/surface/water.glsl の waterFallNormal)
        bool side = abs(N.y) < 0.5;
        vec3 faceN = side ? waterSideFaceNormal(N) : vec3(0.0, 1.0, 0.0);
        float NoVGeo = abs(dot(V, faceN));
        float footprint = waterFootprint(dist, NoVGeo);
        // 側面で上向きの水面の NoV (|V.y|) を使うと、真横から見た側面で画素が無限に大きいとみなされ、海の波の分散が全部
        // 太陽の鏡面の粗さへ回って側面に白っぽい幅広のつやが乗っていた
        float unresolvedVar = side ? waterFallUnresolvedSlopeVar(footprint) : waterUnresolvedSlopeVar(sea, footprint);
        // 上から見た上向きの水面だけ、画素より細かい波の粗さでフレネルと反射方向を均す (composite.csh と同じ)
        float roughVar = !below && N.y > 0.5 ? unresolvedVar : 0.0;
        float F = fresnelDielectric(waterRoughNoV(NoV, roughVar, dist), eta);
        vec3 refrDir = refract(-V, N, 1.0 / eta);
        if (dot(refrDir, refrDir) < 0.5) F = 1.0;
        /*
         * 側面の日向はスカイライトと雲影で近似する (影マップは滝の水柱自身の影に掛かり、PCSS のノイズが泡の白に出て砂嵐のようにざらついた)
         */
        vec3 sunVis = below ? vec3(0.0)
            : side ? vec3(smoothstep(0.6, 0.95, lmT.y)) * getCloudShadow(surfPlayer)
            : surfaceSunVisibility(surfPlayer, vec3(0.0, 1.0, 0.0), dither);

        // ---- 側面から入った光が水を出る所 (水の厚み) ----
        vec3 exitOutward = vec3(0.0);
        float exitDist = -1.0;
        // 面のすぐ内側 (水のセル)。深度の精度の分だけ遠いほど深く入れる
        vec3 insidePlayer = surfPlayer - faceN * (0.01 + dist * 0.002);
        if (!below && side && dot(refrDir, refrDir) > 0.5) exitDist = waterExitDistance(insidePlayer, refrDir, exitOutward);

        // ---- 屈折 ----
        vec2 refrUv = texcoord;
        float pathLen = d1 >= 1.0 ? WATER_SKY_PATH : distance(floorPlayer, surfPlayer);
        if (exitDist > 0.0) pathLen = min(pathLen, exitDist);
        vec3 behind = vec3(0.0);
        bool refrDone = false;  // 方式 D で屈折先の色と経路長が決まった
#if WATER_REFRACTION >= 1
        if (F < 1.0) {
            bool checkHeight = !below && N.y > 0.5;
            vec3 flatRefr = refract(-V, vec3(0.0, 1.0, 0.0), 1.0 / eta);
    #if WATER_REFRACTION_MODE == 2
            /*
             * 方式 D: 上から見た水面は屈折した向きそのもので水底を探す。平らな水面でも視線は水へ入ると下へ折れるので、
             * 水底は手前 (画面の下側) にずれて浅く見える。画面の像で見つかればその色、画面の外・手前の物の陰・岸の水面より上を
             * 指した時はボクセルで辿った水底 (waterRefractVoxel)。画面の端に近い屈折先はボクセルの色へ溶かす
             * 経路長は屈折した光線に沿った水底までの実際の長さ
             */
            if (checkHeight) {
                vec3 refrViewD = playerToViewDir(refrDir);
                vec2 sUv = texcoord;
                bool sValid = false;
        #if WATER_REFRACTION == 2
                vec4 hitD = traceScreenRay(surfView, refrViewD, WATER_REFRACT_D_DISTANCE, WATER_REFRACT_STEPS, dither);
                sValid = hitD.w > 0.5;
                sUv = hitD.xy;
        #else
                // 水底が平らだとして、まっすぐ見た水底の高さまで屈折した向きに進めて投影する (外れは下の光線との距離で落とす)
                float depthBelow = d1 >= 1.0 ? WATER_REFRACT_D_DISTANCE : max(surfPlayer.y - floorPlayer.y, 0.0);
                sUv = viewToScreen(surfView + refrViewD * min(depthBelow / max(-refrDir.y, 0.05), WATER_REFRACT_D_DISTANCE)).xy;
                sValid = true;
        #endif
                float sPath = WATER_SKY_PATH;
                if (sValid) sValid = refractionInWater(sUv, d0, surfPlayer.y, true);
                if (sValid) {
                    float ds = texture(depthtex1, sUv).r;
                    if (ds < 1.0) {
                        // 画面の点が屈折した光線の上にあるか (投影の平らな水底の仮定が外れた所・手前の物を拾わない)
                        vec3 rel = screenToPlayer(vec3(sUv, ds)) - surfPlayer;
                        float along = dot(rel, refrDir);
                        sValid = along > 0.0 && length(rel - refrDir * along) < WATER_REFRACT_D_MATCH * (1.0 + dist * 0.01);
                        sPath = length(rel);
                    }
                }
                float wS = sValid ? waterRefractScreenWeight(texcoord, sUv) : 0.0;
                vec3 vColor = vec3(0.0);
                float vPath = WATER_SKY_PATH;
                if (wS < 1.0 && waterRefractVoxel(surfPlayer, refrDir, floorPlayer, d1, lmT.y, vColor, vPath)) {
                    vec3 sColor = wS > 0.0 ? texture(colortex0, sUv).rgb : vec3(0.0);
                    behind = mix(vColor, sColor, wS);
                    pathLen = mix(vPath, sPath, wS);
                    refrDone = true;
                } else if (sValid) {
                    // ボクセルの範囲外 (遠景): 画面の像は 1 対 1 の対応なので端でも引き伸ばされない
                    behind = texture(colortex0, sUv).rgb;
                    pathLen = sPath;
                    refrDone = true;
                }
                // どちらも無ければ方式 A で写す
            }
    #endif
            if (!refrDone) {
                /*
                 * 方式 A: 上から見た水面は、波で曲がった分だけを画面へ写す。平らな水面でも視線は水へ入ると下へ折れ、水底は
                 * 画面の下側 (手前) へ大きくずれる。画面の下端ではそのずれが画面の外を指し、映っていない所を描けずに
                 * 端の画素を寄せ直した帯が引き伸ばされて縞に並んでいた。平らな水面の分 (見かけの浅さ) は落として水底を
                 * 見えている位置のまま波で歪ませ、吸収の経路長だけ屈折した向きの物理的な長さ (水深 / cos) で測る
                 * 方式 B: 屈折した向きそのままで写し、画面の端へ近いほどずれを弱める (softClampRefractUv)
                 * 水中から見上げた時 (スネルの窓) と側面の水は従来どおり屈折した向きそのもの
                 */
    #if WATER_REFRACTION_MODE == 1
                vec3 bendDir = refrDir;
    #else
                vec3 bendDir = checkHeight ? normalize(-V + (refrDir - flatRefr)) : refrDir;
    #endif
                vec3 refrView = playerToViewDir(bendDir);
                bool found = false;
    #if WATER_REFRACTION == 2
                // 水を出る所が分かった側面は下の板の近似で写す (屈折した向きのまま奥まで辿ると、薄い滝の向こうが厚い水のように大きくずれる)
                if (exitDist <= 0.0) {
                    vec4 hit = traceScreenRay(surfView, refrView, WATER_REFRACT_MAX_DISTANCE * 4.0, WATER_REFRACT_STEPS, dither);
                    if (hit.w > 0.5 && refractionInWater(hit.xy, d0, surfPlayer.y, checkHeight)) {
                        refrUv = hit.xy;
                        found = true;
                    }
                }
    #endif
                if (!found) {
                    // 曲げた向きは視線とほぼ同じなので、まっすぐ見た水底までの距離で投影する
                    float reach = checkHeight ? (d1 >= 1.0 ? WATER_SKY_PATH : distance(floorPlayer, surfPlayer)) : pathLen;
                    vec3 target = surfView + refrView * min(reach, WATER_REFRACT_MAX_DISTANCE);
                    if (exitDist > 0.0) {
                        /*
                         * 側面の水を出た光は出る面で空気へもう一度屈折する (板・柱の水)。平らな面同士なら視線と平行に戻り、
                         * 波で傾いた分だけ向きがずれる (薄いプリズム)。奥の物は出た所からその向きに、まっすぐ見た距離の残りだけ進めて写す
                         */
                        vec3 exitPos = surfPlayer + refrDir * exitDist;
                        vec3 exitDir = refract(refrDir, -exitOutward, WATER_IOR);
                        if (dot(exitDir, exitDir) < 0.5) exitDir = refrDir;
                        float rest = d1 >= 1.0 ? WATER_SKY_PATH : max(distance(floorPlayer, surfPlayer) - exitDist, 0.0);
                        target = playerToView(exitPos + exitDir * min(rest, WATER_REFRACT_MAX_DISTANCE));
                    }
                    // 画面の外は描けないので、ずれを画面の内側に収まるまで縮める (端の画素を引き伸ばさない)
    #if WATER_REFRACTION_MODE == 1
                    vec2 tuv = softClampRefractUv(texcoord, viewToScreen(target).xy);
    #else
                    vec2 tuv = clampRefractUv(texcoord, viewToScreen(target).xy);
    #endif
                    // 水の外を指したら元の画素の側へ寄せ直す (水際でも少しは歪み、岸の水面より上は拾わない)
                    for (int k = 0; k < WATER_REFRACT_RETRY; k++) {
                        if (refractionInWater(tuv, d0, surfPlayer.y, checkHeight)) {
                            refrUv = tuv;
                            break;
                        }
                        tuv = mix(texcoord, tuv, 0.5);
                    }
                }
                float dr = texture(depthtex1, refrUv).r;
                if (dr >= 1.0) {
                    pathLen = WATER_SKY_PATH;
                } else {
                    vec3 refrPlayer = screenToPlayer(vec3(refrUv, dr));
                    // 上から見た水面は、水底から水面まで屈折した向きに進む長さ (水深 / cos(屈折角))
                    pathLen = checkHeight ? max(surfPlayer.y - refrPlayer.y, 0.0) / max(-flatRefr.y, 0.05)
                        : distance(refrPlayer, surfPlayer);
                }
                if (exitDist > 0.0) pathLen = min(pathLen, exitDist);
            }
        }
#endif
        if (!refrDone) behind = texture(colortex0, refrUv).rgb;

        // ---- 吸収と内散乱 (水の上から見た時だけ。水中側は sky のフォグ) ----
        if (!below) {
            vec3 ext = waterExtinction();
            vec3 T = exp(-ext * pathLen);
            vec3 inscatter = waterInscatterSource(lmT.y, sunVis) * waterScattering() / ext * (1.0 - T);
            behind = behind * T + inscatter;
        }

        // ---- 反射と太陽 ----
        vec3 R = reflect(-V, below ? N : waterReflectNormal(N, V));
        /*
         * composite.csh と同じく、下向きの反射は平均水面でもう一度反射させる。上向きの水面だけ
         * (側面で折り返すと、少し上から見た滝が足元の地面ではなく空を映し、側面全体が白っぽく光っていた)
         */
        if (!below && !side) R.y = abs(R.y);
        // 空を引く方向だけ持ち上げる (物に当たった反射は composite.csh が持ち上げない方向で辿った結果)
        vec3 R0 = R;
        R = waterRoughReflectDir(R, roughVar);
        vec3 refl;
#if REFLECTIONS > 0
        float skyWeight;
        vec4 rs = sampleWaterReflection(texel, dist, skyWeight);
        vec3 fallback = below ? vec3(0.0) : skyReflectionFallback(R, lmT.y, 0.0);
        if (rs.a > 0.0) {
            vec3 sky = skyWeight > 0.0 && R.y > 0.0 ? waterSkyReflection(R0, roughVar, lmT.y, dist) : fallback;
            refl = mix(fallback, (rs.rgb + sky * skyWeight) / rs.a, saturate(rs.a * 4.0));
        } else {
            refl = fallback;
        }
        refl = mirrorReflection(refl, surfView, surfPlayer, N, R0, dist, false, !below && !side, dither);
#else
        refl = below ? vec3(0.0) : skyReflectionFallback(R, lmT.y, 0.0);
#endif
        color = behind * (1.0 - F) + refl * F;
        if (!below) {
            float sunAlpha = sqrt(sqr(WATER_ROUGHNESS) + unresolvedVar);
            // 上向きの水面は照り返しの一部を輝点にする。輝点の傾きの分布は画素より細かい波の全部 (表面張力波を含む)
            float g = N.y > 0.5 ? WATER_GLINT * WATER_GLINT_POINT_SHARE : 0.0;
            color += sunSpecular(N, V, 0.02, sunAlpha, sunVis) * (1.0 - g);
            if (g > 0.0) {
                float glintVar = unresolvedVar + sea.microVar * (1.0 - WATER_MICRO_ROUGHNESS);
                vec4 glint = sunGlint(surfPlayer, N, V, glintVar, sunVis, dist, NoVGeo);
                color += glint.rgb * g;
                glintLum = glint.a * g;
            }

            // 上向きの面だけ: 長い 3 層の高さと Jacobian (波頭の透過光と泡)。視差の位置ずれは長い波では画素未満
            if (N.y > 0.5) {
                vec3 surfWorld = surfPlayer + cameraPosition;
                vec4 waves = waterWaveSum(sea, surfWorld.xz, 0, 3, footprint);
                float crest = smoothstep(0.0, 2.0 * sea.heightRms, waves.x);
                LightSample sun = getCelestialLight();

                // ---- 波頭の透過光: 太陽の側を向いて見た時だけ。真上の太陽では横から波頭へ入る光が無い ----
                vec2 toSun = sun.direction.xz;
                float back = dot(toSun, toSun) > 1e-4 ? saturate(dot(normalize(-V.xz), normalize(toSun))) : 0.0;
                float sss = WATER_CREST_SSS * crest * sqr(sqr(back)) * (1.0 - sqr(sun.direction.y)) * (1.0 - F);
                color += sun.irradiance * sunVis * waterScattering() / waterExtinction() * sss;

                // ---- 泡: 崩れかけた波頭の白波 (沖だけ。視線に沿った水の厚みが薄い水際には出さない) ----
                float t = frameTimeCounter;
                float pattern = valueNoise3d(vec3(surfWorld.xz * 3.0, t * 0.4)) * 0.6
                    + valueNoise3d(vec3(surfWorld.xz * 9.0, t * 0.9)) * 0.4;
                float offshore = d1 < 1.0 ? smoothstep(0.0, FOAM_SHORE_WIDTH, distance(floorPlayer, surfPlayer)) : 1.0;
                float J = waterJacobian(waves);
                float cap = smoothstep(WHITECAP_J0, WHITECAP_J1, J) * smoothstep(WHITECAP_WIND0, WHITECAP_WIND1, sea.wind)
                    * smoothstep(0.3, 0.6, pattern) * offshore;
                float foam = saturate(cap * WATER_FOAM) * FOAM_OPACITY;
                if (foam > 0.0) color = mix(color, foamRadiance(surfPlayer, vec3(0.0, 1.0, 0.0), lmT, sunVis), foam);
            }
        }
    } else {
        // ---- ガラス・氷・スライム等 ----
        float ior = matT == MAT_ICE ? ICE_IOR : GLASS_IOR;
        float F = fresnelDielectric(NoV, ior);
        vec2 refrUv = texcoord;
#if WATER_REFRACTION >= 1
        if (matT == MAT_ICE || matT == MAT_SLIME_HONEY) {
            vec2 tuv = texcoord + playerToViewDir(N).xy * THICK_TRANSLUCENT_REFRACTION;
            if (validRefraction(tuv, d0)) refrUv = tuv;
        }
#endif
        vec3 behind = texture(colortex0, refrUv).rgb;
        if (d1 < 1.0) behind += opaqueEnvSpecular(texel, d1);
        vec3 transmit = vec3(1.0 - translucent.a);
        if (tintIndex > 0) {
            vec4 tint = getTint(tintIndex - 1);
            transmit *= mix(vec3(1.0), tint.rgb, tint.a * GLASS_TINT_STRENGTH);
        }
        float roughness = translucentRoughness(matT);
        vec3 R = reflect(-V, N);
        vec3 refl = reflectionAt(texel, dist, R, lmT.y, roughness, vec3(0.0));
        if (roughness < MIRROR_ROUGHNESS) refl = mirrorReflection(refl, surfView, surfPlayer, N, R, dist, false, false, dither);
        color = behind * transmit * (1.0 - F) + translucent.rgb + refl * F
            + sunSpecular(N, V, 0.04, max(roughness * roughness, WATER_ROUGHNESS), surfaceSunVisibility(surfPlayer, N, dither));
        outColor = vec4(color, 1.0);
        return;
    }

    // 水の上に重なった物 (WATER_TEXTURE の水テクスチャ・パーティクル・雨) を重ねる
    vec3 result = color * (1.0 - translucent.a) + translucent.rgb;
    float glintShare = saturate(glintLum * (1.0 - translucent.a) / max(luminance(result), 1e-6));
    outColor = vec4(result, 1.0 + glintShare);
}
