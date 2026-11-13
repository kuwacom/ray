/*
 * テクスチャの輝度を高さとみなした自動法線 (PBR テクスチャが無いリソースパック用。surface モジュール)
 * G バッファ経路 (gbuffers_solid.fsh) と、半透明の経路で描かれる金属の防具 (gbuffers_translucent.fsh) が使う
 * tileMid / tileHalf: スプライト (エンティティは面) の UV の中心と半幅。近傍の参照をその範囲に収める
 */
#ifndef SURFACE_GENERATED_NORMAL_GLSL
#define SURFACE_GENERATED_NORMAL_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/samplers.glsl"
const float GENERATED_NORMAL_GAIN = 1.2;         // 16 テクセル/ブロックで、隣の輝度差 1 あたりの勾配
const float GENERATED_NORMAL_MAX_SLOPE = 1.5;    // 勾配の頭打ち (強い縁だけが立ちすぎないように、これに向けて滑らかに圧縮する)
const float GENERATED_NORMAL_BASE_DENSITY = 16.0; // 勾配の基準のテクセル密度 (テクセル/ブロック)
const float GENERATED_NORMAL_MAX_STEP_LOG2 = 5.0; // 差を取る幅の上限 (2^5 = 32 テクセル = 512 px パック)
const float GENERATED_NORMAL_MAX_LOD = 0.25; // 差を取る幅が画素とほぼ同じ大きさ (lod 0) を超えると勾配がジッターでちらつくので消す
const vec2 GENERATED_FLAT_DIFF = vec2(0.01, 0.04); // 隣の輝度差がこの範囲で、一色の面に足す起伏を消していく
const float GENERATED_FLAT_BUMP = 0.1;      // 一色の面に足す起伏の強さ (テクセルごとの高さ -0.5〜0.5 に対する輝度差)

// 近傍のテクセル。ブロックは繰り返し模様なので範囲で折り返し、エンティティの面は繰り返さないので端で止める
ivec2 generatedTap(ivec2 t, ivec2 tmin, ivec2 tsize) {
#if defined GBUF_ENTITIES || defined GBUF_ENTITIES_TRANSLUCENT
    return clamp(t, tmin, tmin + tsize - 1);
#else
    return tmin + ((t - tmin) % tsize + tsize) % tsize;
#endif
}

float generatedTexelHeight(ivec2 t) {
    return hash3(uvec3(uvec2(t), 0u)).x - 0.5;
}

// テクスチャの輝度を高さとみなした勾配から接空間の法線を作る (PBR テクスチャが無いリソースパック用)
vec3 generatedNormal(vec2 uv, vec3 playerPos, vec2 tileMid, vec2 tileHalf) {
    ivec2 size = textureSize(gtexture, 0);
    /*
     * textureQueryLod は異方性フィルタが効くと短い方の軸の LOD を返すので、かすめ角の床では縦方向にテクセルが
     * 画素より細かくなっても消えず横縞になる。画面上で長い方の軸 (最も縮小される方向) で判定する
     */
    vec2 dx = dFdx(uv * vec2(size));
    vec2 dy = dFdy(uv * vec2(size));
    float texelDx = dot(dx, dx);
    float texelDy = dot(dy, dy);
    /*
     * 輝度差は 1 テクセルあたりの値なので、同じ絵でも解像度が高いほど勾配が弱くなる。面の 1 ブロックあたりのテクセル数を
     * 画面微分の比で測り (向きや遠近に依らない。エンティティの 64x64 も 128x128 もこれで揃う)、基準 (16) に対する比 ratio の分だけ
     * 勾配を強め、差を取る幅も 2 の冪に丸めた ratio テクセルに広げる。幅を広げずに掛けるだけだと、細かい絵のノイズまで増幅される
     */
    vec3 pdx = dFdx(playerPos);
    vec3 pdy = dFdy(playerPos);
    float ratio = sqrt((texelDx + texelDy) / max(dot(pdx, pdx) + dot(pdy, pdy), 1e-10)) / GENERATED_NORMAL_BASE_DENSITY;
    ratio = clamp(ratio, 0.25, exp2(GENERATED_NORMAL_MAX_STEP_LOG2));
    float stepLog2 = round(max(log2(ratio), 0.0));
    float gain = ratio / exp2(stepLog2);
    /*
     * 差を取る幅が画素より小さくなる距離では、TAA のジッターで毎フレーム別のテクセルの勾配を拾い、静止していてもちらつく
     * (テクスチャ法線は直接光・鏡面に効くので明るい所ほど目立つ)。幅が 2 画素 (lod -1) より小さくなり始めたら弱め、
     * 幅 = 画素の手前 (GENERATED_NORMAL_MAX_LOD) で消す。勾配はテクセルの中心で取り、画素内の位置で値が変わらないようにする
     */
    float lod = 0.5 * log2(max(max(texelDx, texelDy), 1e-8)) - stepLog2;
    float fade = 1.0 - smoothstep(-1.0, GENERATED_NORMAL_MAX_LOD, lod);
    if (fade <= 0.0) return vec3(0.0, 0.0, 1.0);
    ivec2 c = ivec2(floor(uv * vec2(size)));
    // 近傍はスプライト (エンティティは面) の外の絵を読まないよう、その範囲 (テクセル) に収める
    // 端で範囲に収める (片側差分) と縁の 1 テクセルだけ勾配が変わり、ブロックの継ぎ目に法線の段差の線が出る。
    // ブロックのテクスチャは繰り返し模様なので、折り返すと隣のブロックの縁と同じ値になって継ぎ目が消える
    ivec2 tmin = ivec2(floor((tileMid - tileHalf) * vec2(size) + 0.5));
    ivec2 tsize = max(ivec2(floor((tileMid + tileHalf) * vec2(size) - 0.5)) - tmin + 1, ivec2(1));
    c = clamp(c, tmin, tmin + tsize - 1);
    ivec2 stp = ivec2(1 << int(stepLog2));
    ivec2 cl = generatedTap(c - ivec2(stp.x, 0), tmin, tsize);
    ivec2 cr = generatedTap(c + ivec2(stp.x, 0), tmin, tsize);
    ivec2 cu = generatedTap(c - ivec2(0, stp.y), tmin, tsize);
    ivec2 cd = generatedTap(c + ivec2(0, stp.y), tmin, tsize);
    vec4 l = texelFetch(gtexture, cl, 0);
    vec4 r = texelFetch(gtexture, cr, 0);
    vec4 u = texelFetch(gtexture, cu, 0);
    vec4 d = texelFetch(gtexture, cd, 0);
    // 抜き部分 (葉の穴) を低い所として扱うと縁が立体的に見える
    float hl = luminance(l.rgb) * l.a;
    float hr = luminance(r.rgb) * r.a;
    float hu = luminance(u.rgb) * u.a;
    float hd = luminance(d.rgb) * d.a;
    vec2 diff = vec2(hr - hl, hd - hu);
#if defined GBUF_ENTITIES || defined GBUF_ENTITIES_TRANSLUCENT
    /*
     * 一色の面 (ラヴェジャーの鼻・角など) は輝度差が 0 で凹凸が出ない。輝度差が小さい所にだけ、テクセルの位置から決まる弱い起伏を足す
     * テクセルに固定した値なので画素や時間で変わらずちらつかず、距離で差を取る幅が画素に近づくと上の fade で一緒に消える
     * ブロックには掛けない。模様のあるブロックは元の輝度差で足り、コンクリートのような無地のブロックは粒が出て、たいまつの光の下で漆喰のように荒れる
     */
    float flatness = 1.0 - smoothstep(GENERATED_FLAT_DIFF.x, GENERATED_FLAT_DIFF.y, max(abs(diff.x), abs(diff.y)));
    vec2 bump = vec2(generatedTexelHeight(cr) - generatedTexelHeight(cl), generatedTexelHeight(cd) - generatedTexelHeight(cu));
    diff += bump * (GENERATED_FLAT_BUMP * flatness);
#endif
    vec2 grad = diff * (GENERATED_NORMAL_GAIN * GENERATED_NORMAL_STRENGTH * gain * fade);
    grad /= sqrt(1.0 + dot(grad, grad) / (GENERATED_NORMAL_MAX_SLOPE * GENERATED_NORMAL_MAX_SLOPE));
    return normalize(vec3(-grad, 1.0));
}

#endif
