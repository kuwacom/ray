/*
 * ブルームのタイル配置 (colortex14 に 1/2 .. 1/128 の縮小画像を並べる)
 * レベル 1 (1/2) は左下、レベル 2 以降はその上の行に左から並べる。隙間は BLOOM_PADDING ピクセル
 * composite23 (縮小) -> composite24 (ぼかし) -> final (アップサンプルして合成) が同じ配置を使う
 */
#ifndef POST_BLOOM_GLSL
#define POST_BLOOM_GLSL

// xy = タイルの左下 (ピクセル), zw = タイルの大きさ (ピクセル)
ivec4 bloomTileRectPx(int level) {
    ivec2 screen = ivec2(viewSize());
    ivec2 size = max((screen + (1 << level) - 1) >> level, ivec2(1));
    if (level == 1) return ivec4(0, 0, size);
    ivec2 level1 = (screen + 1) >> 1;
    int x = 0;
    for (int i = 2; i < level; i++) {
        x += max((screen.x + (1 << i) - 1) >> i, 1) + BLOOM_PADDING;
    }
    return ivec4(x, level1.y + BLOOM_PADDING, size);
}

// ピクセル p が属するタイルのレベル (どれにも属さなければ 0)
int bloomTileLevelAt(ivec2 p, out ivec4 rect) {
    for (int level = 1; level <= BLOOM_LEVELS; level++) {
        rect = bloomTileRectPx(level);
        if (all(greaterThanEqual(p, rect.xy)) && all(lessThan(p, rect.xy + rect.zw))) return level;
    }
    rect = ivec4(0);
    return 0;
}

// レベル level のタイルを画面 UV uv で双三次サンプル。a は溶岩の発光の輝度 (composite23)
vec4 sampleBloomTile4(int level, vec2 uv) {
    vec2 screen = viewSize();
    vec4 rect = vec4(bloomTileRectPx(level));
    vec2 tileUv = (rect.xy + uv * rect.zw) / screen;
    vec2 rectMin = (rect.xy + 0.5) / screen;
    vec2 rectMax = (rect.xy + rect.zw - 0.5) / screen;
    return sampleBSplineClamped4(colortex14, tileUv, screen, rectMin, rectMax);
}

/*
 * タイルの色から溶岩の分の倍率 (LAVA_BLOOM_GAIN, composite23) を外す。溶岩を明るくするのは本体のブルームだけで、
 * レンズの効果 (球面収差・ハレーション・ベーリンググレア・画面のフレア) は従来の明るさのまま
 * (古いレンズのプリセットで溶岩の上に 6 倍の滲みが重なり、溶岩が淡いサーモン色に抜け、ゴーストが出た)
 * 溶岩の分の輝度 a は元の輝度 x 倍率なので、色を 1 - (a / 輝度) x (倍率 - 1) / 倍率 倍すると元に戻る
 */
vec3 bloomWithoutLavaGain(vec4 c) {
    float share = saturate(c.a / max(luminance(c.rgb), 1e-6));
    return c.rgb * (1.0 - share * (LAVA_BLOOM_GAIN - 1.0) / LAVA_BLOOM_GAIN);
}

vec3 sampleBloomTile(int level, vec2 uv) { return bloomWithoutLavaGain(sampleBloomTile4(level, uv)); }

float bloomLevelWeight(int level) { return pow(BLOOM_LEVEL_DECAY, float(level - 1)); }

// レンズの効果に使う帯域 (どれも重みの和で正規化した PSF)
struct BloomBands {
    vec3 narrow;  // レベル 1-3: 球面収差の滲み
    vec3 mid;     // レベル 2-4: ハレーション
    vec3 wide;    // レベル 4 以降: ブルーミーフォグ・汚れ
    vec3 widest;  // レベル 6 以降: ベーリンググレアのヘイズ
    float lava;   // 全レベルの合成のうち溶岩の発光の輝度 (溶岩の滲みの色を保つトーンマップの割合に使う)
};

/*
 * 全レベルを幾何級数の重みで合成 (重みの和で正規化 = エネルギー保存の PSF)
 * bands にはレンズ効果用の帯域ごとの合成を返す (溶岩の倍率は本体の合成だけに掛ける)
 */
vec3 sampleBloom(vec2 uv, out BloomBands bands) {
    vec3 sum = vec3(0.0);
    float wSum = 0.0;
    bands.narrow = vec3(0.0);
    bands.mid = vec3(0.0);
    bands.wide = vec3(0.0);
    bands.widest = vec3(0.0);
    bands.lava = 0.0;
    for (int level = 1; level <= BLOOM_LEVELS; level++) {
        vec4 c4 = sampleBloomTile4(level, uv);
        vec3 c = bloomWithoutLavaGain(c4);
        float w = bloomLevelWeight(level);
        sum += c4.rgb * w;
        bands.lava += c4.a * w;
        wSum += w;
        if (level <= 3) bands.narrow += c * (1.0 / 3.0);
        if (level >= 2 && level <= 4) bands.mid += c * (1.0 / 3.0);
        if (level >= 4) bands.wide += c * (1.0 / float(BLOOM_LEVELS - 3));
        if (level >= 6) bands.widest += c * (1.0 / float(BLOOM_LEVELS - 5));
    }
    bands.lava /= wSum;
    return sum / wSum;
}

/*
 * 画面のレンズフレア (明るい画素のゴーストと横ストリーク) の 1/4 解像度タイル
 * レベル 1 のタイルの右 (ブルームのどのタイルとも重ならない空き) に置く。composite24 が書き final が読む
 */
ivec4 flareTileRectPx() {
    ivec2 screen = ivec2(viewSize());
    ivec2 size = max((screen + 3) >> 2, ivec2(1));
    return ivec4(((screen.x + 1) >> 1) + BLOOM_PADDING, 0, size);
}

vec3 sampleFlareTile(vec2 uv) {
    vec2 screen = viewSize();
    vec4 rect = vec4(flareTileRectPx());
    vec2 tileUv = (rect.xy + uv * rect.zw) / screen;
    vec2 rectMin = (rect.xy + 0.5) / screen;
    vec2 rectMax = (rect.xy + rect.zw - 0.5) / screen;
    return sampleBSplineClamped(colortex14, tileUv, screen, rectMin, rectMax);
}

// レベル level のタイルを双線形で読む (画面フレアのゴースト用。双三次ほどの滑らかさは要らない)
vec3 sampleBloomTileLinear(int level, vec2 uv) {
    vec2 screen = viewSize();
    vec4 rect = vec4(bloomTileRectPx(level));
    vec2 p = clamp(rect.xy + uv * rect.zw, rect.xy + 0.5, rect.xy + rect.zw - 0.5);
    return bloomWithoutLavaGain(textureLod(colortex14, p / screen, 0.0));
}

#endif
