/*
 * GI / AO の参照口 (surface モジュール)
 */
#ifndef SURFACE_GI_GLSL
#define SURFACE_GI_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/dimension.glsl"
//@include "/lib/common/frame_offset.glsl"
//@include "/lib/common/look_presets.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/samplers.glsl"

/*
 * deferred11 のデノイズ済み結果 (colortex8)
 * rgb = 間接光の照度 (空・ブロックライトの拡散に加算), a = AO (空の照度に掛ける)
 */
vec4 getIndirectLight(ivec2 texel) {
#if GI_MODE > 0 || AO_MODE > 0
    return texelFetch(colortex8, texel, 0);
#else
    return vec4(0.0, 0.0, 0.0, 1.0);
#endif
}

/*
 * 方式ごとの GI_STRENGTH の効き。既定の GI_STRENGTH = 2 で、どの方式でも日陰・地面を向く面が近い明るさになるように合わせる
 * - ボクセル RT: 1 (2 倍)
 * - RSM: 0.75 (1.5 倍)。可視性を見ないので、2 倍では壁越しの照り返し (箱の奥の壁) と草の照り返しの緑の濃さが強くなりすぎる
 * - SSGI: 0.5 (1 倍)。地面を向く面のレイの多くが画面外へ出て灰色の遠くの地面になり、2 倍では軒下が明るくなりすぎる
 */
#if GI_MODE == 1
    const float GI_MODE_GAIN = 0.75;
#elif GI_MODE == 2
    const float GI_MODE_GAIN = 0.5;
#else
    const float GI_MODE_GAIN = 1.0;
#endif
const float GI_EFFECTIVE_STRENGTH = GI_STRENGTH * GI_MODE_GAIN;

/*
 * ルックの照り返し (LK_GI_BOUNCE / LK_GI_BOUNCE_SAT)。レイが当たった面からの照り返しだけを強め、輝度を保ったまま彩度を上げる
 * 空へ抜けたレイ (空の光) は変えないので、日陰の空の光の強さは方式によらず LK_SKY_AMBIENT だけで決まる
 * 照り返しの光は空の光と同じくらいの明るさで混ざるので、そのままでは日の当たる草の照り返しが空の青と打ち消し合い、
 * 洞窟の入り口・白樺の幹が青緑の灰色にしかならない
 * 多重反射の履歴は強さで割ってから返すので (giHistoryAtPlayer)、強さは 1 回だけ掛かり発散しない
 * RSM は影マップの色 (shadowcolor0) が G バッファより緑が濃い (照り返しの G/R が草の 1.75 に対して 1.97) ので、彩度は半分だけ上げる
 */
#if GI_MODE == 1
    const float GI_BOUNCE_SAT = mix(1.0, LK_GI_BOUNCE_SAT, 0.5);
#else
    const float GI_BOUNCE_SAT = LK_GI_BOUNCE_SAT;
#endif
vec3 giBounceGrade(vec3 c) {
    if (LK_GI_BOUNCE == 1.0 && GI_BOUNCE_SAT == 1.0) return c;
    return max(mix(vec3(luminance(c)), c, GI_BOUNCE_SAT), 0.0) * LK_GI_BOUNCE;
}

/*
 * GI のレイが空の光も運ぶ (SSGI / ボクセル RT, 空のあるディメンション)
 * 空へ抜けたレイが方向ごとの空の色を返し、deferred30 は空の環境光 (方向の無いスカイライト x AO の遮蔽) をこれで置き換える。
 * 抜けたレイを 0 にして当たったレイの照り返しを空の光に足すと、軒下・洞窟の入り口・森の中で空の光の向きが無く、
 * 照り返しも二重になる。RSM (GI_MODE=1) は可視性を見ないので、空の環境光はスカイライトと AO のまま
 */
#if (GI_MODE == 2 || GI_MODE == 3) && defined HAS_SKY
    #define GI_TRACES_SKY
#endif
/*
 * ボクセル RT の空へ抜けたレイに掛けるスカイライトの絞り。遮蔽はレイが見るので、スカイライトは
 * 届く距離 (VOXEL_GI_DISTANCE) より大きな洞窟の奥へ空の光が漏れるのを止めるだけに使う (スカイライト 0 で 0、5 段で 1)
 */
const float GI_SKY_GATE_LIGHTMAP = 0.35;
float giVoxelSkyGate(float skyLm) { return smoothstep(0.0, GI_SKY_GATE_LIGHTMAP, skyLm); }

// RSM は可視性を見ないので、スカイライトがこの範囲で 0 -> 1 になるように絞る (deferred10)。deferred30 が SH から引く地面の分も同じ絞り
const float RSM_SKYLIGHT_MIN = 0.1;
const float RSM_SKYLIGHT_MAX = 0.6;

/*
 * バニラのスカイライト [0,1] -> 空の照度に掛ける可視率
 * バニラは 1 段 = 1/15 の線形だが、実際の空の見え方は開口部から離れると急に落ちる。
 * 3 乗寄りの曲線で洞窟の奥を暗くしつつ、開口部付近 (0.8 以上) はほぼ 1 に保つ
 */
float skylightCurve(float lm) {
#ifndef HAS_SKYLIGHT
    // ネザー・エンドはスカイライトが常に 0 なので、掛けると環境光 (prepare の一様な SH) が全部消えて真っ黒になる
    // バニラのディメンションの環境光と同じく、場所によらず一様に当てる
    return 1.0;
#else
    float x = saturate(lm);
    return x * x * (0.25 + 0.75 * x);
#endif
}

/*
 * 低解像度パス (GI_RES / 反射) のジッター: 2x2 ブロックの中の 1 ピクセルを 4 フレームで巡回する
 * デノイズ側はこのオフセットで低解像度テクセルが表すフル解像度のピクセルを復元する
 */
const ivec2 LOW_RES_OFFSETS[4] = BAYER2_ORDER;

ivec2 lowResOffset(int frame) { return LOW_RES_OFFSETS[frame & 3]; }

#endif
