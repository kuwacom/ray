/*
 * 反射の共有部 (surface モジュール: composite.csh が書き、composite1 が読む)
 *
 * reflectionImg のレイアウト: 画面の半分の解像度 (lowSize = 画面 / 2) を 2 面持ち、フレームの偶奇で書く面を入れ替える
 *   偶数フレーム: 左の面 [0, lowSize), 奇数フレーム: 右の面 [lowSize.x, 2 lowSize.x)
 *   もう片方の面が前フレームの結果 (ラフ反射の時間蓄積に使う)。同じイメージの別の領域なので読み書きが衝突しない
 *   rgb = 反射の放射輝度 (フレネル前), a = 反射した面のカメラからの距離 (0 = 無効)。距離はアップサンプルと再投影の判定に使う
 * 低解像度の 1 テクセルはフル解像度の (2L + lowResOffset(frameCounter)) を表す (GI と同じジッター)
 */
#ifndef SURFACE_REFLECTION_GLSL
#define SURFACE_REFLECTION_GLSL

// これより粗い面は SSR を飛ばさず空のフォールバックだけ (ほぼ拡散なので見た目が変わらない)
const float SSR_MAX_ROUGHNESS = 0.75;
// これより滑らかな面は鏡面反射として扱う (VNDF のノイズと時間蓄積のにじみを避ける)
const float MIRROR_ROUGHNESS = 0.08;

bool isReflectiveTranslucent(int mat) {
    return mat == MAT_WATER || mat == MAT_GLASS || mat == MAT_STAINED_GLASS || mat == MAT_ICE
        || mat == MAT_SLIME_HONEY || mat == MAT_TRANSLUCENT;
}

// 半透明の知覚的ラフネス (半透明は labPBR を読まないので材質ごとの固定値)
float translucentRoughness(int mat) {
    if (mat == MAT_WATER) return 0.0;
    // 氷は PBR の質感を残して鏡にしない (0.02 の鏡面では氷の質感が失われた)
    if (mat == MAT_ICE) return 0.1;
    if (mat == MAT_SLIME_HONEY) return 0.35;
    if (mat == MAT_TRANSLUCENT) return 0.15;
    return 0.03;
}

struct ReflectSurface {
    bool valid;
    bool translucent;
    int materialId;
    vec3 viewPos;
    vec3 normal;              // player 空間
    vec3 geoNormal;           // 幾何法線 (player 空間)。半透明は normal と同じ
    float perceptualRoughness;
    float skyLm;
    float depth;              // スクリーン深度 (再投影用)
};

ReflectSurface getReflectSurface(ivec2 texel) {
    ReflectSurface s;
    s.valid = false;
    s.translucent = false;
    s.materialId = MAT_NONE;
    s.viewPos = vec3(0.0);
    s.normal = vec3(0.0, 1.0, 0.0);
    s.geoNormal = s.normal;
    s.perceptualRoughness = 1.0;
    s.skyLm = 0.0;
    s.depth = 1.0;

    vec2 uv = (vec2(texel) + 0.5) / viewSize();
    float d0 = texelFetch(depthtex0, texel, 0).r;
    float d1 = texelFetch(depthtex1, texel, 0).r;
    vec3 nT;
    vec2 lmT;
    int matT;
    decodeTranslucentData(texelFetch(colortex5, texel, 0), nT, lmT, matT);

    if (d0 < d1 && !isHandDepth(d0) && isReflectiveTranslucent(matT)) {
        s.valid = true;
        s.translucent = true;
        s.materialId = matT;
        s.depth = d0;
        s.viewPos = screenToView(vec3(uv, d0));
        s.normal = nT;
        s.geoNormal = nT;
        s.perceptualRoughness = translucentRoughness(matT);
        s.skyLm = lmT.y;
    } else if (d1 < 1.0 && !isHandDepth(d1)) {
        GBufferData g = readGBuffer(texel);
        s.valid = true;
        s.materialId = g.materialId;
        s.depth = d1;
        s.viewPos = screenToView(vec3(uv, d1));
        s.normal = g.normal;
        s.geoNormal = g.geoNormal;
        s.perceptualRoughness = 1.0 - g.smoothness;
        s.skyLm = g.lightmap.y;
    }
    return s;
}

const float SKY_REFLECTION_MAX_RATIO = 6.0;   // 画面の空の画素を映す時の上限 (LUT の空の何倍まで。雲は通し、太陽円盤は抑える)
const float SKY_EXTRAPOLATION_FALLOFF = 4.0;  // 画面外の反射方向で画面端の空の明暗を借りる強さの減衰 (UV 距離 0.25 で 1/e)

/*
 * 何にも当たらず空へ抜けた鏡面の反射 (player 空間の方向 R)。空は無限遠なので面の位置によらず、カメラから見た R 方向の
 * 空の画素 (雲込み) と同じ。lut は同じ方向の LUT の空 (skyReflectionFallback)。地形に隠れた方向は lut のまま
 * LUT の空 (雲なし) のままだと、昼の水面の遠くが一様な水色の帯になり雲の映り込みが無かった
 */
vec3 skyPixelReflection(vec3 R, float skyLm, vec3 lut) {
    vec3 Rv = playerToViewDir(R);
    if (Rv.z >= -1e-3) return lut;
    /*
     * 反射方向が画面の外 (見下ろした時の画面の左右端・上端) を指す時も、画面端の最寄りの空の画素から
     * LUT の空との比 (雲の明暗と色) を借りて外挿する。LUT の空 (雲なし) へ溶かすだけだと、
     * 夕方の海で雲の照り返しが画面の端に向かって消えていた
     * 画面内の方向では edgeUv = skyUv なので、比を掛けた結果はその空の画素そのものになる
     */
    vec2 skyUv = viewToScreen(Rv * 1e4).xy;
    vec2 margin = 1.5 / viewSize();
    vec2 edgeUv = clamp(skyUv, margin, 1.0 - margin);
    if (textureLod(depthtex0, edgeUv, 0.0).r < 1.0) return lut;
    vec3 edgeDir = normalize(viewToPlayerDir(screenToView(vec3(edgeUv, 1.0))));
    vec3 edgeLut = skyReflectionFallback(edgeDir, skyLm, 0.0);
    vec3 sky = textureLod(colortex0, edgeUv, 0.0).rgb * skylightCurve(skyLm);
    // 太陽円盤は水面の太陽の鏡面 (sunSpecular) が別に描くので、雲の明るさまでで頭を抑える
    float lumRatio = luminance(sky) / max(luminance(edgeLut), 1e-6);
    if (lumRatio > SKY_REFLECTION_MAX_RATIO) {
        sky *= SKY_REFLECTION_MAX_RATIO / lumRatio;
        lumRatio = SKY_REFLECTION_MAX_RATIO;
    }
    // 画面から離れた方向ほど借りた明暗は当てにならないので LUT の空へ戻す。色味は明るさより早く LUT へ戻す
    // (チャンネルごとの比にすると、夕方の LUT の青のような小さい成分で比が発散する)
    float offDist = length(skyUv - edgeUv);
    float borrow = exp(-offDist * SKY_EXTRAPOLATION_FALLOFF);
    vec3 chroma = mix(lut / max(luminance(lut), 1e-6), sky / max(luminance(sky), 1e-6),
        exp(-offDist * SKY_EXTRAPOLATION_FALLOFF * 4.0));
    return chroma * luminance(lut) * mix(1.0, lumRatio, borrow);
}

const float SSR_MAX_DISTANCE = 128.0;
const float REFLECTION_MAX_LUMINANCE = 64.0; // VNDF のホタル (太陽の当たった鏡面を拾った 1 サンプル) を抑える
const float SSR_BACKFACE_EPS = 0.1;          // ヒット面の幾何法線と光線の内積がこれを超えたら裏面とみなす (oct 8 bit の量子化と深度の誤差の余裕)
const float SSR_SELF_PLANE_COS = 0.99;       // ヒット面と始点の幾何法線がこれ以上揃っていれば同じ向きの面
const float REFLECT_MIN_NOV = 0.05;          // 反射に使うテクスチャ法線と視線の内積の下限
const float REFLECT_MIN_ELEVATION = 0.02;    // 不透明面の反射の幾何面からの最低限の仰角 (cos)
const float WATER_REFLECT_HIT_EPS = 0.15;    // 水面の反射が水面よりこれ以上下の物に当たったら誤検出 (ブロック)

// 鏡面の SSR を辿る最大距離。遠くの島や岸も映るよう描画距離まで辿る。ステップは画面上で刻むので遠くでも密度は落ちにくい
float mirrorTraceDistance() { return max(SSR_MAX_DISTANCE, far * 1.5); }

/*
 * 反射の SSR の当たり (composite.csh の半分の解像度と、composite1 の鏡面のフル解像度で共有)
 * viewPos / playerPos: 反射面, Ng: 視線側を向いた幾何法線 (始点を浮かせる), opaque: 不透明面 (自己交差の判定),
 * waterTop: 上から見た水面 (水面より下の物への誤検出の判定)
 * 戻り値 xy = 当たりの UV, z = 画面端の重み, w = 1 なら当たり
 */
vec4 traceReflectionHit(vec3 viewPos, vec3 playerPos, vec3 Ng, vec3 R, float dist, float maxDist, bool opaque, bool waterTop, float dither) {
    // 始点は幾何法線で浮かせる (テクスチャ法線で浮かせると傾いた分だけ面に近いまま始まる)
    vec3 start = viewPos + playerToViewDir(Ng) * (0.02 + dist * 0.002);
    vec4 hit = traceScreenRay(start, playerToViewDir(R), maxDist, SSR_STEPS, dither);
    if (hit.w < 0.5) return vec4(0.0);
    /*
     * 面の裏側に当たったものは誤検出 (カリングされて裏面は描かれない)。かすめ角の面では深度の勾配が大きく、
     * 光線が自分自身の隣の画素に当たったと判定され、金属の側面に自分の (拡散の無い暗い) 色が映って黒くなっていた
     * 裏面の判定は幾何法線で行う。テクスチャ法線は自動生成法線でテクセルごとに大きく傾き、表の面に当たった
     * 光線までテクセル単位で捨てられて、反射が SSR とフォールバックの斑になっていた
     */
    ivec2 ht = ivec2(hit.xy * viewSize());
    vec3 hitGeo = octDecode(unpack2x8(texelFetch(colortex2, ht, 0).b));
    vec3 hitPlayer = screenToPlayer(hit.xyz);
    bool backface = dot(hitGeo, R) > SSR_BACKFACE_EPS;
    // 始点と同じ平面 (隣の画素・隣の床ブロック) に当たったものは自己交差。上へ出た光線は同じ平面に戻らない
    bool selfPlane = opaque && dot(hitGeo, Ng) > SSR_SELF_PLANE_COS && abs(dot(hitPlayer - playerPos, Ng)) < 0.05 + dist * 0.004;
    /*
     * 水面から上へ出た反射は水面より下の物に当たらない。深度 (depthtex1) は水を除いた水底なので、地平線の近くへ
     * ほぼ水平に出た光線が、遠くの水底 (水を通して見えている位置) に当たったと判定され、水底の明るい色が
     * 地平線の手前に四角い斑になって並んでいた
     */
    bool belowWater = waterTop && hitPlayer.y < playerPos.y - WATER_REFLECT_HIT_EPS;
    if (backface || selfPlane || belowWater) return vec4(0.0);
    return vec4(hit.xy, screenEdgeFade(hit.xy), 1.0);
}

// 当たった画素の放射輝度 (明るさの上限付き)
vec3 reflectionHitRadiance(vec2 uv) {
    vec3 c = textureLod(colortex0, uv, 0.0).rgb;
    float lum = luminance(c);
    return lum > REFLECTION_MAX_LUMINANCE ? c * (REFLECTION_MAX_LUMINANCE / lum) : c;
}

ivec2 reflectionLowSize() { return ivec2(viewSize()) / 2; }
ivec2 reflectionRegion(int frame) { return (frame & 1) == 0 ? ivec2(0) : ivec2(reflectionLowSize().x, 0); }

// アップサンプルの法線の重み (不透明面のみ)。下限があるのは、全近傍の法線が違う時に反射が空のフォールバックへ落ちないため
const float REFLECTION_NORMAL_POWER = 16.0;
const float REFLECTION_NORMAL_WEIGHT_MIN = 0.02;

/*
 * フル解像度のピクセル texel の反射 (低解像度の 2x2 近傍を距離の近さで重み付け)
 * dist: このピクセルの反射面のカメラからの距離。戻り値 a = 重みの合計 (0 なら呼び出し側がフォールバック)
 * normal: 不透明面のテクスチャ法線 (G バッファ)。0 ベクトルなら法線の重みを使わない (半透明)
 */
vec4 sampleReflection(ivec2 texel, float dist, vec3 normal) {
    ivec2 lowSize = reflectionLowSize();
    ivec2 region = reflectionRegion(frameCounter);
    ivec2 offset = lowResOffset(frameCounter);
    ivec2 base = (texel - offset) >> 1;
    bool useNormal = dot(normal, normal) > 0.5;
    vec3 sum = vec3(0.0);
    float csum = 0.0;
    float wsum = 0.0;
    for (int j = 0; j <= 1; j++) {
        for (int i = 0; i <= 1; i++) {
            ivec2 L = clamp(base + ivec2(i, j), ivec2(0), lowSize - 1);
            vec4 r = texelFetch(reflectionSampler, L + region, 0);
            if (r.a <= 0.0) continue;
            ivec2 src = L * 2 + offset;
            vec2 delta = abs(vec2(src - texel)) * 0.5;
            float wBilinear = max(1.0 - delta.x, 0.05) * max(1.0 - delta.y, 0.05);
            float wDepth = exp(-abs(r.a - dist) / (dist * 0.02 + 0.05));
            float w = wBilinear * wDepth;
            /*
             * 低解像度の 1 テクセルは隣のピクセルの法線で反射を求めている。自動生成法線はテクセルごとに向きが違うので
             * 距離だけで混ぜると反射の模様がテクスチャから 1 画素ずれ、ジッターで毎フレーム位置が変わる
             * 色の重みだけ同じ向きの近傍を優先し、合計 (呼び出し側のフォールバック判定) は従来どおり距離で決める
             */
            float wc = w;
            if (useNormal) {
                vec3 ns = readGBufferNormal(min(src, ivec2(viewSize()) - 1));
                wc *= REFLECTION_NORMAL_WEIGHT_MIN + pow(saturate(dot(normal, ns)), REFLECTION_NORMAL_POWER);
            }
            sum += r.rgb * wc;
            csum += wc;
            wsum += w;
        }
    }
    return vec4(csum > 0.0 ? sum / csum : vec3(0.0), wsum);
}

#endif
