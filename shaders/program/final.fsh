/*
 * final: 歪曲・色収差・シャープ (CAS)・ブルーム合成・球面収差・ベーリンググレア・レンズフレア・口径食・ハレーション・Purkinje・ビネット・露出・
 *        ホワイトバランス・コントラスト・彩度・トーンマップ・グレイン・ディザ・デバッグ表示
 * 色に掛ける処理は物理的な順 (レンズ -> センサー -> 現像) に並べる
 * post モジュール
 */
#include "/lib/common/common.glsl"
#include "/lib/post/post_internal.glsl"
#include "/lib/light/light.glsl"
#include "/lib/buffers/formats.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

vec3 debugView(ivec2 texel, vec3 color) {
#if DEBUG_VIEW == 1
    return linearToSrgb(readGBuffer(texel).albedo);
#elif DEBUG_VIEW == 2
    return readGBufferNormal(texel) * 0.5 + 0.5;
#elif DEBUG_VIEW == 3
    return vec3(readGBuffer(texel).lightmap, 0.0);
#elif DEBUG_VIEW == 4
    return linearToSrgb(tonemap(texelFetch(colortex6, texel, 0).rgb));
#elif DEBUG_VIEW == 5
    float depth = texelFetch(depthtex0, texel, 0).r;
    vec3 playerPos = screenToPlayer(vec3(texcoord, depth));
    return linearToSrgb(tonemap(sampleFloodfillVolume(playerPos - normalize(playerPos) * 0.5)));
#elif DEBUG_VIEW == 6
    vec4 gi = texelFetch(colortex8, texel, 0);
    return linearToSrgb(tonemap(gi.rgb)) * gi.a;
#elif DEBUG_VIEW == 7
    // 雲の散乱光に露出を掛けて見る (掛けないと夜や薄明では真っ黒になる)
    return linearToSrgb(tonemap(texelFetch(colortex11, texel, 0).rgb * getExposure()));
#elif DEBUG_VIEW == 8
    return linearToSrgb(tonemap(texelFetch(colortex12, texel, 0).rgb));
#elif DEBUG_VIEW == 9
    return linearToSrgb(tonemap(texture(skyViewSampler, texcoord).rgb));
#elif DEBUG_VIEW == 10
    // 目の高さのボクセル断面 (固体=白, エンティティ=赤, 光源=黄)
    ivec2 xz = ivec2(texcoord * vec2(VOXEL_SIZE.xz));
    ivec3 cell = ivec3(xz.x, VOXEL_HALF.y, xz.y);
    int id = unpackVoxelBlockId(readVoxelBlock(cell));
    bool ent = readVoxelEntity(cell) != 0u;
    return ent ? vec3(1.0, 0.2, 0.2) : (getBlockLightIndex(id) != 0 ? vec3(1.0, 0.9, 0.2) : vec3(id != 0 ? 0.8 : 0.05));
#elif DEBUG_VIEW == 11
    // 最終的に TAA・モーションブラーが使う速度 (ピクセル単位, 1 px で 0.25)。b は colortex15 (エンティティ・手) の有効フラグ
    vec2 vel = (getPreviousUv(texcoord, texelFetch(depthtex0, texel, 0).r) - texcoord) * viewSize();
    return vec3(abs(vel) * 0.25, texelFetch(colortex15, texel, 0).a * 0.5);
#elif DEBUG_VIEW == 12
    return texelFetch(debugSampler, texel, 0).rgb;
#else
    return color;
#endif
}

vec3 fetchScene(ivec2 p) {
    return sanitizeColor(texelFetch(colortex0, clamp(p, ivec2(0), ivec2(viewSize()) - 1), 0).rgb);
}

// CAS を掛ける知覚空間 (露出込みのチャンネル別 Reinhard, 可逆)
vec3 casEncode(vec3 c, float exposure) { c *= exposure; return c / (1.0 + c); }
vec3 casDecode(vec3 c, float exposure) { c = min(c, 0.999); return c / (1.0 - c) / exposure; }

/*
 * AMD FidelityFX CAS (5 タップ版): 近傍の最小 / 最大から、リンギングが出ない範囲でだけ鋭くする
 * TAA のにじみを戻す最後の一押し。HDR のまま掛けると明るい縁に白フチが出るので知覚空間で掛ける
 * 戻り値はシーン線形での差分 (色収差を掛けた中心にも足せるように)
 */
vec3 casDelta(ivec2 texel, vec3 center, float exposure) {
    // 設定値は小数なのでプリプロセッサでは比べられない (定数畳み込みで分岐は消える)
    if (CAS_STRENGTH <= 0.0) return vec3(0.0);
    vec3 c = casEncode(center, exposure);
    vec3 n = casEncode(fetchScene(texel + ivec2(0, 1)), exposure);
    vec3 s = casEncode(fetchScene(texel + ivec2(0, -1)), exposure);
    vec3 e = casEncode(fetchScene(texel + ivec2(1, 0)), exposure);
    vec3 w = casEncode(fetchScene(texel + ivec2(-1, 0)), exposure);
    vec3 mn = min(c, min(min(n, s), min(e, w)));
    vec3 mx = max(c, max(max(n, s), max(e, w)));
    vec3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
    vec3 wgt = amp * (-1.0 / mix(8.0, 5.0, CAS_STRENGTH));
    vec3 sharp = saturate((c + (n + s + e + w) * wgt) / (1.0 + 4.0 * wgt));
    return casDecode(sharp, exposure) - center;
}

#if defined LENS_FLARE && defined HAS_SKY
// フレアの光源 (昼は太陽, 夜は月) の見え具合。composite25 が光源の円盤内を 256 点調べて平滑化した値
float flareVisibility() {
    float v = frameData.postParams[2].x;
    return isnan(v) ? 0.0 : saturate(v);
}
#endif

/*
 * 溶岩の画素の割合 (十字の 5 画素)。溶岩だけ色相を保つトーンマップにする
 * G バッファは TAA のジッター付きで縁の 1 画素が毎フレーム入れ替わるので、近傍で均して切り替えのちらつきを抑える
 */
float lavaToneMask(ivec2 texel) {
    const ivec2 offsets[5] = ivec2[5](ivec2(0), ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
    ivec2 maxTexel = ivec2(viewSize()) - 1;
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        if (readMaterialId(clamp(texel + offsets[i], ivec2(0), maxTexel)) == MAT_LAVA) sum += 1.0;
    }
    return sum / 5.0;
}

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy);
    vec2 uv = texcoord;
    float exposure = getExposure();

    // ---- レンズ: 歪曲 (以降のシーンの読み出しは全て歪曲後の位置 uvL で行う) ----
#ifdef LENS_DISTORTION
    const bool distort = LP_K1 != 0.0 || LP_K2 != 0.0;
#else
    const bool distort = false;
#endif
    vec2 uvL = distort ? lensDistortUv(uv) : uv;
    ivec2 texelL = distort ? ivec2(uvL * viewSize()) : texel;

    vec3 center = distort ? sanitizeColor(sampleCatmullRom(colortex0, uvL, viewSize())) : fetchScene(texel);
    vec3 hdr = center;

    // ---- レンズ: 倍率色収差 (波長ごとに倍率が違い、画面の隅ほど縁が虹色にずれる) ----
#ifdef LENS_CHROMATIC
    if (LP_CA > 0.0) hdr = lensChromaticSample(colortex0, uvL, LP_CA);
#endif
    hdr = max(hdr + casDelta(texelL, center, exposure), 0.0);

    float lava = lavaToneMask(texelL);
    // 溶岩のブルームの滲みが占める割合。溶岩と同じ色を保つトーンマップに寄せる (AgX では周りの煙・壁の滲みが淡いサーモン色に抜けた)
    float lavaGlowShare = 0.0;

    // ---- レンズ: ブルーム (PSF の畳み込みとして mix。総エネルギーは変えない) ----
#ifdef BLOOM
    BloomBands bands;
    vec3 bloom = sampleBloom(uvL, bands);
    #ifdef LENS_SOFT_FOCUS
        // 球面収差: ピントが合っていても低い周波数の滲みが乗る (開放ほど強い)
        hdr = mix(hdr, bands.narrow, saturate(LP_SOFT_FOCUS * LENS_SOFT_FOCUS_AMOUNT * lensApertureFactor()));
    #endif
    /*
     * 溶岩の上は自分のブルーム (LAVA_BLOOM_GAIN 倍) が一様に乗って暗い殻が持ち上がり、模様が平らになる
     * 溶岩の画素だけ混合率を下げ、滲みは周りに出す
     */
    float bloomMix = saturate(BLOOM_STRENGTH * BLOOM_AMOUNT) * (1.0 - LAVA_SELF_BLOOM_CUT * lava);
    hdr = mix(hdr, bloom, bloomMix);
    lavaGlowShare = saturate(bloomMix * bands.lava / max(luminance(hdr), 1e-6));

    // ブルーミーフォグ: 遠くと雨・水中ほど広いブルームで霞ませる (全面の滲みは弱く)
    float depth = texelFetch(depthtex0, texelL, 0).r;
    float dist = depth >= 1.0 ? far : linearizeDepth(fixHandDepth(depth));
    float fogFactor = (1.0 - exp(-dist / BLOOM_FOG_DISTANCE)) * (0.35 + 0.65 * rainStrength);
    float water = isEyeInWater == 1 ? 1.0 : 0.0;
    float wideAmount = BLOOM_FOG * mix(fogFactor, 1.0, water)
                     + BLOOM_STRENGTH * BLOOM_AMOUNT * (rainStrength * BLOOM_RAIN_BOOST + water * BLOOM_WATER_BOOST);
    hdr = mix(hdr, bands.wide, saturate(wideAmount));

    #ifdef LENS_VEILING_GLARE
        // ベーリンググレア: レンズ面と鏡筒の散乱で画面全体に薄いヘイズが乗り、暗部が持ち上がる
        hdr = mix(hdr, bands.widest, saturate(LP_VEILING_GLARE * LENS_VEIL_HAZE));
    #endif
    #ifdef LENS_DIRT
        // 汚れは近くの明るい光を散乱して光る (明るい物の周りだけ模様が浮かぶ)
        if (LP_DIRT > 0.0) {
            vec3 lit = max(bands.wide - LENS_SCREEN_THRESHOLD * 0.3 / exposure, 0.0);
            hdr += lit * (lensDirt(uvL) * LP_DIRT * LENS_DIRT_BLOOM_GAIN * LENS_FLARE_STRENGTH);
        }
    #endif
    #if defined LENS_SCREEN_FLARE && defined LENS_FLARE
        // 明るい画素のゴーストと横ストリーク (composite24)
        hdr += sampleFlareTile(uvL);
    #endif
#endif

    // ---- レンズ: 太陽・月のフレア (ゴースト・スターバースト・ハロー・グレア・汚れ・ストリーク) ----
#if defined LENS_FLARE && defined HAS_SKY
    if (shadowLightPosition.z < 0.0) {
        float vis = flareVisibility();
        if (vis > 0.0) {
            vec2 lightUv = viewToScreen(shadowLightPosition).xy;
            vec3 lightColor = sanitizeColor(frameData.shadowLightIrradiance.rgb);
            vec3 lightTint = lightColor / max(luminance(lightColor), 1e-6);
            // 太陽が沈むと光源は月に切り替わる (薄明は照度が小さいので境目は目立たない)
            float day = smoothstep(-0.1, 0.1, getSunDir().y);
            float gain = mix(LENS_MOON_FLARE, 1.0, day);
            float starGain = mix(LENS_MOON_STARBURST, 1.0, day);
            hdr += lensFlare(uvL, lightUv, lightTint, starGain) * lightColor * (vis * gain * LENS_FLARE_STRENGTH);
        }
    }
#endif

    // ---- レンズ: トリウムガラスの黄変 (青を吸う。明るさは変えない) ----
    if (LP_YELLOWING > 0.0) {
        vec3 tint = mix(vec3(1.0), LENS_YELLOWING_TINT, LP_YELLOWING);
        hdr *= tint / luminance(tint);
    }

    // ---- レンズ: 周辺減光 (演出のビネット + 口径食) ----
    hdr *= vignette(uv);
#ifdef LENS_OPTICAL_VIGNETTING
    if (LP_CATS_EYE > 0.0) hdr *= lensOpticalVignette(uv);
#endif

    // ---- フィルム: ハレーション (フィルムベースで反射した光が赤い層だけを感光させる。レンズの後段) ----
#if defined BLOOM && defined LENS_HALATION
    if (LP_HALATION > 0.0) {
        float halation = max(luminance(bands.mid) * exposure - LENS_HALATION_THRESHOLD, 0.0) / exposure;
        hdr += LENS_HALATION_TINT / luminance(LENS_HALATION_TINT) * (halation * LP_HALATION * LENS_HALATION_GAIN);
    }
#endif

    // ---- 目 / センサー: Purkinje 効果 -> 露出 ----
    hdr = applyPurkinje(hdr, frameData.averageLuminance, exposure);
    vec3 color = hdr * exposure;

    // ---- 現像: ホワイトバランス -> コントラスト -> 彩度 -> トーンマップ ----
#if WHITE_BALANCE != 6500
    color = applyWhiteBalance(color, float(WHITE_BALANCE));
#endif
    color = applyContrast(color, CONTRAST);
    color = applySaturation(color, SATURATION);
    /*
     * 溶岩の見た目の明るさ。表示の段でだけ上げ、露出の測光・ブルーム・反射・周りへの光は変えない
     * 赤はほぼ上限なので、明るさは tonemapEmissive で緑 (と少し青) が持ち上がる形で出る (暗い殻 -> 橙 -> 黄の割れ目)
     */
    color *= 1.0 + LAVA_BRIGHTNESS * lava;
    lava = max(lava, lavaGlowShare);
    color = lava > 0.0 ? mix(tonemap(color), tonemapEmissive(color), lava) : tonemap(color);
    color = linearToSrgb(color);
    // CDL はグレーディング用の表示値 (sRGB エンコード後) に掛ける。ASC の想定する扱いに近く、効き方が直感的
    // 既定値では恒等変換 (プリプロセッサで浮動小数の比較ができないので常に掛ける)
    color = saturate(applyCdl(color, vec3(CDL_SLOPE), vec3(CDL_OFFSET), vec3(CDL_POWER), CDL_SATURATION));
    color = applyGrain(color, gl_FragCoord.xy);

    color = debugView(texel, color);
    // 8bit 出力のバンディング対策
    color += (interleavedGradientNoise(gl_FragCoord.xy, frameCounter) - 0.5) / 255.0;
    outColor = vec4(color, 1.0);
}
