/*
 * 水面の距離の判断 (LOD): 法線で描く層の振幅・粗さへ回す傾き・画素の中の傾きの揺れ・フレネルと空の映り込みを均す割合・
 * 視差の段・映り込みを鏡のまま辿る重みを、水面の 1 画素の大きさ (footprint) から 1 か所で決める
 * 距離で何かを変える時はここ (waterLod) に足し、呼ぶ側は結果を使うだけにする
 * 別の射影で描く遠景の水も、その射影の 1 画素の角度を pixelAngle に渡して同じ waterLod を呼ぶ
 * lib/common/water.glsl が読む
 */
#ifndef COMMON_WATER_LOD_GLSL
#define COMMON_WATER_LOD_GLSL

//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/water_waves.glsl"

/*
 * 水面上の 1 画素の大きさ (ブロック)。かすめ角では視線方向に伸びるので、伸びた辺 (1 / NoV) 寄りで測る
 * 波は全方向を向くので、視線方向に伸びた辺で 2 画素を切る波は画面の縦に折り返す。幾何平均 (NoV^-0.5) では
 * 中景 (かすめ角 0.05-0.1) で縦に 2 画素ほどの波が残り、反射が画素ごとに空と水の色で斑になる白い砂目になった
 */
const float WATER_FOOTPRINT_STRETCH = 1.0;

// 1 画素の角度 (ラジアン)。画面の縦の画角から
float waterPixelAngle() { return 2.0 / (gbufferProjection[1][1] * viewSize().y); }

float waterFootprint(float dist, float NoV, float pixelAngle) {
    return dist * pixelAngle * pow(max(NoV, 0.02), -WATER_FOOTPRINT_STRETCH);
}

float waterFootprint(float dist, float NoV) { return waterFootprint(dist, NoV, waterPixelAngle()); }

/*
 * フレネルを均すのは水面の 1 画素 (waterFootprint) がこの範囲 (ブロック) より大きい所だけ。近景・中景まで均すと、層を落とし始める
 * 10-30 ブロックからフレネルが 0.7 -> 0.45 に下がり、つやの無いマットな水面になった。遠くは像を残したまま暗くして、
 * 地平線の手前の明るい帯 (水面が地平線の空と同じ明るさになり水平線が消える) を抑える
 * 画素の大きさで決めるので、描画距離を変えても同じ水面の見え方は変わらない (目の高さ 2 ブロックで 100-270 ブロック先)
 */
const vec2 WATER_ROUGH_FRESNEL_RANGE = vec2(8.0, 64.0);

/*
 * 表面張力波 1 層の (粗さへ回す傾きの分散, 曲率の 2 乗)。層は 2 つなので、配列をループの添字で引かず定数の添字で 2 回呼ぶ
 * (添字のループで引く形では、ドライバの最適化の違いで、画面の中心を通る直線の上だけ水面が映り込みで鏡のように光り、ほかの水面の映り込みが
 * 弱まることがあった。コードの上の未定義の値は見つかっていない)
 */
vec2 waterCapillaryUnresolved(float amp, float tile, float footprint) {
    float r = waterTileResolved(tile, footprint);
    return sqr(amp) * vec2(1.0 - (1.0 - WATER_CAPILLARY_NEAR_ROUGH) * r * r, sqr(TAU * WATER_BAND_CENTER / tile));
}

/*
 * 表せた層の、画素の中と露光の間での法線 (傾き) の揺れの分散。1 層の傾きは波長 lambda で振幅 a の正弦に近く、画素の幅 f の中で
 * a x 2 pi f / lambda ほど変わる (画素の中の一様な位置の標準偏差は幅の 1 / sqrt(12))
 * GGX の alpha^2 に足すと、細い鋭いローブが画素の当たり外れにならず、エネルギーを保ったままジッターのちらつきが消える
 * 画面微分は使わず (gbuffers_solid.fsh の鏡面 AA を入れない理由と同じ)、層ごとの解析式で足す
 */
const float WATER_PIXEL_SLOPE_SCALE = TAU / sqrt(12.0);

/*
 * 同じ式で、1 フレームの露光の間の法線の変化も足す (シャッターの時間積分)。層の傾きは時間の最も遅い倍音の周期
 * P (= ループの周期 / WATER_TIME_HARMONIC_LO) で回り、露光 dt の間に a x 2 pi dt / P ほど変わる (一様な時刻の標準偏差も 1 / sqrt(12))
 * さざ波の照り返しがフレームごとに別の画素へ跳ばず、露光の間の軌跡に沿ってエネルギーを保ったまま広がる。細かく速い層ほど効く
 * 画素の幅と露光の間の変化は独立なので分散の和 (層ごとの係数は定数に畳まれる)
 */
const float WATER_EXPOSURE_SHUTTER = 0.5;   // 1 フレームのうち露光している割合 (モーションブラーのシャッターと同じ)
const float WATER_EXPOSURE_MAX_DT = 0.05;   // 低いフレームレートで照り返しが流れすぎない上限 (秒)

float waterLayerSlopeChange(float tile, float footprint, float dt) {
    return sqr(footprint * WATER_BAND_CENTER / tile) + sqr(dt * WATER_TIME_HARMONIC_LO / waterLayerPeriod(tile));
}

// 水面の視差 (lib/common/water_normal.glsl の waterParallax) の探す幅 (高さの RMS の倍率)
const float WATER_PARALLAX_RANGE = 2.5;
const float WATER_PARALLAX_MAX = 1.5;          // 視線に沿って探す最大距離 (ブロック)
// 視差に使う長い層の数。3 番目 (波長 1-8 ブロック) の高さは 0.03 ブロック前後で、足すと全画面の水で 1 ms 近く重くなる (GTX 1070, 1080p)
const int WATER_PARALLAX_LAYERS = 2;
/*
 * 高さの差が画素のこの倍率 (x = 0, y = 全部) の間で視差を 0 へ寄せる。画素に満たない所で打ち切るだけだと、その距離の弧を境に
 * 法線を引く位置が最大 WATER_PARALLAX_MAX 跳び、うねりの山と谷の所で波の模様が弧の線で食い違った
 */
const vec2 WATER_PARALLAX_FADE = vec2(0.5, 1.0);

struct WaterLod {
    float footprint;            // 水面の 1 画素の大きさ (ブロック)
    float amp[WATER_LAYERS];    // 層ごとに法線で描く傾きの RMS
    vec2 unresolved;            // 粗さへ回す傾きの分散 (GGX の alpha^2 に足す), 曲率の 2 乗の和 (WATER_GLITTER の点の数)
    float pixelSlopeVar;        // 法線で描いた層の、画素の中と露光の間の傾きの揺れの分散 (照り返しの alpha^2 に足す)
    float roughFar;             // フレネルと空の映り込みを画素より細かい波の粗さで均す割合
    float parallaxRange;        // 視差の探す幅 (高さ, ブロック。縮めた後)
    float parallaxScale;        // 視差で波の高さに掛ける縮め
    float parallax;             // 視差を効かせる割合 (0 で探さない)
    float mirror;               // フル解像度の鏡の映り込みの重み (1 で鏡のまま、0 で散らした映り込みだけ)
};

/*
 * sea: waterSeaState、dist: カメラからの距離 (ブロック)、NoV: 視線と幾何の面の cos、pixelAngle: 1 画素の角度 (ラジアン)
 */
WaterLod waterLod(WaterSea sea, float dist, float NoV, float pixelAngle) {
    WaterLod lod;
    float footprint = waterFootprint(dist, NoV, pixelAngle);
    lod.footprint = footprint;
    /*
     * 法線で表せなかった傾きの分散 (GGX の alpha^2 に足す)。画素の中で平均された波は面を粗くする (LEAN / Toksvig と同じ考え)
     * 遠くの水面で太陽の照り返しが縦に広がる帯になるのはこの分
     */
    /*
     * y は同じ層の曲率の 2 乗の和。1 層を振幅 (傾きの RMS) a・波数 k の正弦とみなした (a k)^2 を足す。画素より細かい波が太陽を映す
     * 点の数 (傾きの確率密度 x ガウス曲率の絶対値の平均) に使う (WATER_GLITTER)。使わない呼び出しでは消える
     */
    vec2 unresolved = vec2(0.0);
    float dt = min(frameTime, WATER_EXPOSURE_MAX_DT) * WATER_EXPOSURE_SHUTTER;
    float pixelVar = 0.0;
    for (int i = 0; i < WATER_LAYERS; i++) {
        float tile = waterLayerTile(i);
        float r = waterLayerResolved(i, footprint);
        lod.amp[i] = r * sea.amp[i];
        // 法線側に r 倍を残すので、分散の合計が保たれるよう 1 - r^2 を回す
        float w = (1.0 - r * r) * sqr(sea.amp[i]);
        unresolved += w * vec2(1.0, sqr(TAU * WATER_BAND_CENTER / tile));
        pixelVar += sqr(lod.amp[i] * WATER_PIXEL_SLOPE_SCALE) * waterLayerSlopeChange(tile, footprint, dt);
    }
    /*
     * 表面張力波は法線で描かないので、どの距離でも粗さになる。ただし画素がその波より小さい近くでは、1 画素が見るのは波の一部の
     * 面だけなので、傾きの分散を WATER_CAPILLARY_NEAR_ROUGH まで減らす (全部を回すと、近くの太陽の照り返しが表した波と無関係な
     * ぼやけた白い塊になった)。曲率 (y、WATER_GLITTER の点の数) は減らさない。近くの点は細くなったローブ (表した波の斜面) に集まる
     */
    unresolved += waterCapillaryUnresolved(sea.capAmp[0], waterCapillaryTile(0), footprint);
    unresolved += waterCapillaryUnresolved(sea.capAmp[1], waterCapillaryTile(1), footprint);
    lod.unresolved = unresolved;
    lod.pixelSlopeVar = pixelVar;
    lod.roughFar = smoothstep(WATER_ROUGH_FRESNEL_RANGE.x, WATER_ROUGH_FRESNEL_RANGE.y, footprint);

    float h2 = 0.0;
    for (int i = 0; i < WATER_PARALLAX_LAYERS; i++) h2 += sqr(sea.amp[i] * waterLayerTile(i) * WATER_TEX_HEIGHT_SIGMA);
    float range = WATER_PARALLAX_RANGE * sqrt(h2);
    lod.parallaxScale = min(1.0, WATER_PARALLAX_MAX * NoV / max(range, 1e-5));
    lod.parallaxRange = range * lod.parallaxScale;
    // 高さの差が画素に満たなければ探さない
    lod.parallax = smoothstep(WATER_PARALLAX_FADE.x, WATER_PARALLAX_FADE.y, lod.parallaxRange / max(footprint, 1e-6));

    lod.mirror = waterReflectMirror(unresolved.x);
    return lod;
}

WaterLod waterLod(WaterSea sea, float dist, float NoV) { return waterLod(sea, dist, NoV, waterPixelAngle()); }

#endif
