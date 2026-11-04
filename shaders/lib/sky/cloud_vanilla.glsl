/*
 * バニラの形の雲の密度・光の見積もり・雲影 (CLOUD_VANILLA_SHAPE, sky モジュール。cloud_march.glsl が読む)
 * バニラの雲と同じ高さ (Iris の cloudHeight)・模様・流れ (Iris の cloudTime) に置く、角を丸めた体積雲。格子はバニラの 12 ブロックの VANILLA_CLOUD_CELL_SCALE 倍。
 * 模様はバニラの雲のテクスチャ (リソースパックのものに従う) を customTexture で読み、1 画素 = 1 マスとして置く。
 * 雲はマスごとの同じ厚みの柱 (板雲) で、面はすべて軸に平行 (曲面・ノイズの凹凸を持たない)。辺と角だけ小さく丸める。
 * 柱の表 (cloudWeatherImg) に入れて prepare2 が毎フレーム作る (雨では模様の外のマスも埋めて空を覆う)。形は変えずに、表に出ている面の近くだけ密度を下げて縁を透かす
 * 下段の上に、同じ模様を回転・ずらし・間引き・引き伸ばしで別の雲に見せた上の段 (中段・上段。薄い直方体の層) を重ねる。上の段の列は表を使わず模様から直接求める
 * 長さは参照空間の縮尺 VANILLA_CLOUD_KREF (参照 m / ブロック) で測るので、高さテンプレートによらず同じ透け方になる
 */
#ifndef SKY_CLOUD_VANILLA_GLSL
#define SKY_CLOUD_VANILLA_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/sky/cloud_constants.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/cloud_weather.glsl"

#ifdef CLOUD_VANILLA_SHAPE

uniform sampler2D vanillaCloudTex; // バニラの雲のテクスチャ (shaders.properties の customTexture)

const vec2 VANILLA_CLOUD_ORIGIN = vec2(0.0, 3.96); // 格子の座標 = ワールドの xz + これ (x にはさらに cloudTime)
const float VANILLA_CLOUD_ALPHA_CUT = 0.5;         // 雲のあるマスの不透明度のしきい値
// 柱の表 (cloudWeatherImg) に収まるテクスチャの大きさ。これより大きいリソースパックは表を使わず、模様を直接読んで全マスを同じ厚みにする
const int VANILLA_CLOUD_TABLE_SIZE = 512;
const int VANILLA_CLOUD_BLOCK = 4;                 // 空の区画を飛ばす単位 (マス)
const float VANILLA_CLOUD_KREF = 14.0;             // 参照 m / ブロック
// 表に出ている面の近くだけ密度を下げる幅 (ブロック)。形 (外形) は変えず、縁の内側だけが透ける。底は頭より少し硬めにして、下から見た平らな底を保つ (底と側面の境が細い縞にならない幅は残す)
const float VANILLA_CLOUD_SOFT_SIDE = 2.0 * CLOUD_EDGE_SOFTNESS;
const float VANILLA_CLOUD_SOFT_TOP = 2.0 * CLOUD_EDGE_SOFTNESS;
const float VANILLA_CLOUD_SOFT_BOTTOM = 1.8 * CLOUD_EDGE_SOFTNESS;
const float VANILLA_CLOUD_SOFT_PIXELS = 1.5;       // 頭と底の柔らかさの下限 (画素の大きさの倍率)。遠くの角の階段のぎざぎざが時間方向に揺れて見えるのを防ぐ
// 側面の柔らかさの下限。近くは SOFT_SIDE が勝つので変わらず、遠くだけ画素の大きさに比例して広がる (近くをピンぼけにせず、遠くの硬い箱を和らげる)
const float VANILLA_CLOUD_SOFT_SIDE_PIXELS = 4.5;
const float VANILLA_CLOUD_CORNER_RADIUS = 3.0;      // ブロック: 直方体の辺と角を丸める半径。0 で四角いまま
const float VANILLA_CLOUD_RAIN_COVER = 0.95;       // 雨の最大で雲に埋まるマスの割合 (模様の外のマスを含めた全体。残りは所々の隙間)
const float VANILLA_CLOUD_SOFT_MAX = 6.0;          // ブロック: 柔らかさの上限 (マスの半分。これを超えると小さな塊の芯まで薄くなる)
const float VANILLA_CLOUD_MOTTLE_MIN = 0.6;        // 光源方向の濃さに掛けるむらの下限
const float VANILLA_CLOUD_MOTTLE_CELLS = 12.0;     // マス: むらのノイズ (cloudNoiseTex の滑らかな fbm) 1 周の長さ。マスの大きさに比例させて、模様の大きさが変わってもむらの見え方を保つ
const float VANILLA_CLOUD_TOP_MOTTLE = 0.25;       // 光源の光にかけるむらの深さ (0 でむらなし)。面は平らなまま、上から見たときの一様な白さに緩い明暗を付ける
const float VANILLA_CLOUD_TOP_MOTTLE_CELLS = 3.0;  // マス: 同じむらの 1 周の長さ
const float VANILLA_CLOUD_TOP_MOTTLE_DEPTH = 3.0;  // ブロック: 柱の頭からこの深さまでだけにかける (側面に縦縞が出ない)
const float VANILLA_CLOUD_SIGMA = 0.275 * CLOUD_LOW_DENSITY;   // 1 / 参照 m。既定の濃さで 1 ブロックあたり約 1 (参照 m への換算は VANILLA_CLOUD_KREF)
const float VANILLA_CLOUD_OPACITY = 1.3;           // 視線方向の消散の倍率 (陰の光学的深さには掛けない)。縁の 2 ブロックは半透明になり、光が透けて柔らかく見える
const float VANILLA_CLOUD_INSIDE_DEPTH = 3.0;      // ブロック: カメラが柱の面からこの深さまで入ると、倍率が 0 になる (中の見通しは雲の中の霧が決めるので、柱の消散で地形が白く閉じたり暗い影になったりしない。縁の透ける幅と、霧が立ち上がる深さに合わせる)
// 陰と内散乱の濃さは既定の濃さで頭打ち (柱はすでに光を通さないので、濃さを上げても底がさらに暗く青灰色になるだけ)
const float VANILLA_CLOUD_SHADE_SIGMA = 0.275 * min(CLOUD_LOW_DENSITY, 0.25);
const float VANILLA_CLOUD_LIGHT_REACH = 12.0;      // ブロック: 光源方向の影を数える距離
const int VANILLA_CLOUD_LIGHT_CELLS = 3;           // その間に渡るマスの最大数 (マスは 13 ブロック以上なので、REACH の間に渡るのは 2 つ)
const float VANILLA_CLOUD_MIN_LIGHT_Y = 0.05;      // 光源の高さの下限 (地平線すれすれで陰の長さが発散しない)
const float VANILLA_CLOUD_STEP_REL = 0.004;        // 視線の歩幅 (距離に対する割合)。ブロック
const float VANILLA_CLOUD_STEP_MIN = 0.3;          // 雲の近くの歩幅は縁の柔らかさの 1/6 以下 (柔らかさの層を何歩かで渡り、等高線の縞を青ノイズに崩す)
const float VANILLA_CLOUD_STEP_MAX = 6.0;
const float VANILLA_CLOUD_STEP_THIN = 0.35;        // 薄い段の歩幅の上限 (厚さに対する割合。段を数歩で渡る)
const float VANILLA_CLOUD_SKIP_MARGIN = 0.02;      // ブロック: 箱を出る位置からこの分進んで、次の箱に入る (境目の浮動小数の誤差で止まらない)
const int VANILLA_CLOUD_SHADOW_STEPS = 10;
const float VANILLA_CLOUD_SHADOW_DEPTH = 4.0;      // ブロック: 地面の雲影の暗さの上限を決める厚み。厚い雲でも影を真っ黒にしない
// 光源方向と空の光は、日向の頭と日陰の底・側面の差を出すために絞る (CS_* の光の値はスタイルごとの微調整で、これはどのスタイルでもバニラの形に掛かる)
const float VANILLA_CLOUD_SUN = 1.0;
const float VANILLA_CLOUD_MS_GAIN = 1.2;
const float VANILLA_CLOUD_SILVER = 0.35;
const float VANILLA_CLOUD_POWDER = 0.8;
const float VANILLA_CLOUD_AMBIENT = 0.8;
const float VANILLA_CLOUD_BASE_SHADE = 1.8;     // 底の暗さの倍率 (CS_BASE_SHADE に掛かる。4 で底の直達光と多重散乱が 0 になり、空の色だけの暗い底になる)
const float VANILLA_CLOUD_DENSE_LIFT = 0.08;    // 濃さが既定の何倍かに掛けて、底の暗さを弱める割合
const float VANILLA_CLOUD_BASE_DEPTH = 4.0;     // ブロック: 底の暗さが 1 に戻る高さ (底の暗さと地面の照り返しは底から数ブロックだけ)
const float VANILLA_CLOUD_BASE_LIFT = 0.1;      // 底の暗さを掛け始める高さ (BASE_DEPTH の割合)
const float VANILLA_CLOUD_DUSK_SUN_GAIN = -0.4; // 光源が低い (朝夕) ときの直達光の増減 (厚い柱の側面は横からの橙の光で明るくなりすぎるので絞る)
const float VANILLA_CLOUD_DUSK_SUN_DESAT = 0.3; // 同じく直達光の彩度を抜く割合 (橙一色にならず白寄りの桃色になる)
const float VANILLA_CLOUD_DUSK_SUN_Y = 0.3;     // 増減が消える光源の高さ (sin 高度)
const float VANILLA_CLOUD_DUSK_SATURATION = 0.7; // 同じく空の光の彩度 (日陰の面に空の青紫を残す)
const float VANILLA_CLOUD_SKY_SATURATION = 0.7; // 空の光の彩度 (1 で空の色のまま。陰の青みはこの光の色で決まる。底が空と同じ青にならないよう青みを抜く)
// 雨雲の層の中から見る柱は、層の下から見た曇天の暗さ (見えない雨雲の層の灰色) に合わせる
const float VANILLA_CLOUD_RAIN_SUN = 0.2;         // 直達光の倍率
const float VANILLA_CLOUD_RAIN_AMBIENT = 1.0;     // 空の光の倍率
const float VANILLA_CLOUD_RAIN_BASE = 0.8;        // 底の暗さを無くす割合 (層の中から見下ろす底が、霧や地形より暗い影にならないように)
const float VANILLA_CLOUD_RAIN_FLOOR = 0.9;       // 柱の明るさの下限 (雲の向こうの曇天の灰色の倍率)。日陰の側面や底が真っ黒な影絵にならず、暗い灰色までに収まる。空中遠近で雲の上に戻す灰色の分と合わせて、雲の隙間から見える曇天の灰色と同じ明るさになる値 (ずれると、隙間が明るい・暗い小片に見える)
// 曇天の下では光が何度も散乱して向きを失うので、散乱の向きを横から見た値へ寄せる割合 (寄せないと、太陽の方向の雲の底が前方散乱の山で白く光る)
const float VANILLA_CLOUD_RAIN_DIFFUSE = 1.0;
const float VANILLA_CLOUD_RAIN_SKY = 0.7;          // 雨の空で、雲の上に戻す空の色 (雲の上の空の光 skyRadiance の倍率)

// 上の段。高さは下段の底からのブロック (案 0 = 高い: 中段 約 368・上段 約 592 / 案 1 = 建築の上限以下: 約 256・約 304)。
// 格子は下段 (24 ブロック) に見合う大きさで、遠くの段ほど見かけが小さくなる分だけ粗くする
const float VANILLA_TIER_MID_BOTTOM = CLOUD_VANILLA_TIER_HEIGHT == 0 ? 176.0 : 64.0;
const float VANILLA_TIER_HIGH_BOTTOM = CLOUD_VANILLA_TIER_HEIGHT == 0 ? 400.0 : 112.0;
const float VANILLA_TIER_MID_THICKNESS = 8.0;
const float VANILLA_TIER_HIGH_THICKNESS = 3.0;
const vec2 VANILLA_TIER_MID_CELL = vec2(36.0);               // 見かけの幅 約 7 度 (案 0)
const vec2 VANILLA_TIER_HIGH_CELL = vec2(96.0, 24.0);        // 横に 4 倍引き伸ばした細長いマス。小さいほど斜めの辺の階段が細かくなる
const vec2 VANILLA_TIER_MID_SHIFT = vec2(128.0, 64.0) * VANILLA_TIER_MID_CELL;   // 下段と同じ模様に見えないよう、マス単位でずらす
const vec2 VANILLA_TIER_HIGH_SHIFT = vec2(64.0, 192.0) * VANILLA_TIER_HIGH_CELL;
// 流れの向きと、下段に対する速さの倍率 (上の段ほど遠いので、見かけの速さは下段より遅い)
const vec2 VANILLA_TIER_MID_FLOW = 1.6 * vec2(0.9063, 0.4226);
const vec2 VANILLA_TIER_HIGH_FLOW = 2.5 * vec2(0.6428, 0.7660);
const float VANILLA_TIER_MID_FAR = 2560.0;                   // ブロック: この距離で空へ溶かし切る
const float VANILLA_TIER_HIGH_FAR = 4096.0;
// 視線の消散と陰の濃さの、下段に対する倍率。鉛直の光学的深さは中段 約 2.5、上段 約 0.5
const float VANILLA_TIER_MID_SIGMA = 0.25;
const float VANILLA_TIER_HIGH_SIGMA = 0.09;
const float VANILLA_TIER_MID_BASE_DEPTH = 14.0;   // 底の暗さが 1 に戻る高さ。厚さより大きく取って、薄い段の下面を灰色にする
const float VANILLA_TIER_HIGH_BASE_DEPTH = 6.0;
const float VANILLA_TIER_MID_SHADE = 1.0;
const float VANILLA_TIER_HIGH_SHADE = 0.8;
const float VANILLA_TIER_KEEP_HIGH = 0.8;                    // 上段は中段より更に間引く
// 上段は間引きを数マスの塊ごとに決める。1 マスずつ抜くと、細長いマスの欠けが不規則に並んで模様のあるガラス板に見える
const int VANILLA_TIER_HIGH_KEEP_BLOCK = 3;
const float VANILLA_TIER_HIGH_SOFT_SIDE = 22.0;              // 上段の側面の柔らかさ (ブロック)。斜めの辺の階段のぎざぎざを薄い縁にぼかす
// 光のむら (面の上の明暗) は下段だけ。薄い上の段に掛けると、薄い板にまだら模様が出る
const int VANILLA_TIER_UPPER_MOTTLE = 0;
// 夜は上の段を暗く薄くする (月明かりの分だけ見え、星空より目立たない)。太陽の高さ (sin 高度) がこの範囲で昼から夜へ移る
const float VANILLA_TIER_NIGHT_GAIN = 0.15;                  // 夜の明るさの倍率
const float VANILLA_TIER_NIGHT_THIN = 0.5;                   // 夜の濃さの倍率
const vec2 VANILLA_TIER_NIGHT_SUN = vec2(-0.25, -0.02);
const vec2 VANILLA_TIER_RAIN_HIDE = vec2(0.1, 0.6);          // 雨雲の層の下にいる度合いがこの間で、上の段が見えなくなる
const float VANILLA_TIER_SHADOW = 0.5;                       // 上の段が下の雲や地面に落とす影の強さ
const float VANILLA_TIER_SHADOW_MIN_Y = 0.08;                // 影を落とす光源の高さの下限

struct VanillaTier {
    int index;        // 0 下段 / 1 中段 / 2 上段
    float bottom;     // 底の高さ (ワールド y)
    float envelope;   // 外形の厚さ (ブロック)
    vec2 cell;        // マスの大きさ (ブロック)
    vec2 shift;       // 格子の座標のずらし (ブロック)
    vec2 flow;        // 流れ (cloudTime あたりのブロック)
    int turn;         // 1 で模様を 90 度回して鏡映しにする (整数のマスを整数のマスに写す)
    float keep;       // 間引きで残す割合
    int keepBlock;    // 間引きを決める塊の一辺 (マス)
    float sigma;      // 視線の消散の倍率 (下段 = 1)
    float shade;      // 陰 (光源・空方向の光学的深さ) の倍率。薄い段でも底が灰色に見えるよう、消散ほどは薄めない
    float far;        // 描く距離 (ブロック)
    float baseDepth;  // 底の暗さが 1 に戻る高さ
    float radius;     // 辺と角を丸める半径
    vec3 soft;        // 側面・頭・底の柔らかさ
};

VanillaTier vanillaTier(int i) {
    VanillaTier t;
    bool low = i == 0;
    bool mid = i == 1;
    t.index = i;
    t.bottom = vanillaCloudBottom() + (low ? 0.0 : mid ? VANILLA_TIER_MID_BOTTOM : VANILLA_TIER_HIGH_BOTTOM);
    t.envelope = low ? VANILLA_CLOUD_ENVELOPE : mid ? VANILLA_TIER_MID_THICKNESS : VANILLA_TIER_HIGH_THICKNESS;
    t.cell = low ? vec2(VANILLA_CLOUD_CELL) : mid ? VANILLA_TIER_MID_CELL : VANILLA_TIER_HIGH_CELL;
    t.shift = low ? vec2(0.0) : mid ? VANILLA_TIER_MID_SHIFT : VANILLA_TIER_HIGH_SHIFT;
    t.flow = low ? vec2(1.0, 0.0) : mid ? VANILLA_TIER_MID_FLOW : VANILLA_TIER_HIGH_FLOW;
    t.turn = mid ? 1 : 0;
    t.keep = low ? 1.0 : mid ? CLOUD_VANILLA_TIER_COVERAGE : CLOUD_VANILLA_TIER_COVERAGE * VANILLA_TIER_KEEP_HIGH;
    t.keepBlock = low || mid ? 1 : VANILLA_TIER_HIGH_KEEP_BLOCK;
    t.sigma = low ? 1.0 : mid ? VANILLA_TIER_MID_SIGMA : VANILLA_TIER_HIGH_SIGMA;
    t.shade = low ? 1.0 : mid ? VANILLA_TIER_MID_SHADE : VANILLA_TIER_HIGH_SHADE;
    t.far = low ? VANILLA_CLOUD_FAR : mid ? VANILLA_TIER_MID_FAR : VANILLA_TIER_HIGH_FAR;
    t.baseDepth = low ? VANILLA_CLOUD_BASE_DEPTH : mid ? VANILLA_TIER_MID_BASE_DEPTH : VANILLA_TIER_HIGH_BASE_DEPTH;
    t.radius = low ? VANILLA_CLOUD_CORNER_RADIUS : min(VANILLA_CLOUD_CORNER_RADIUS, 0.5 * t.envelope);
    t.soft = low ? vec3(VANILLA_CLOUD_SOFT_SIDE, VANILLA_CLOUD_SOFT_TOP, VANILLA_CLOUD_SOFT_BOTTOM)
                 : mid ? vec3(4.0, 2.5, 2.5) * CLOUD_EDGE_SOFTNESS : vec3(VANILLA_TIER_HIGH_SOFT_SIDE, 1.0, 1.0) * CLOUD_EDGE_SOFTNESS;
    return t;
}

// 格子の座標 (ブロック) でのカメラの位置。テクスチャの一周で先に畳むので、遠い座標でも精度が落ちない
vec2 vanillaCloudOrigin(VanillaTier t) {
    vec2 tile = vec2(textureSize(vanillaCloudTex, 0)) * t.cell;
    vec2 base = t.index == 0 ? VANILLA_CLOUD_ORIGIN : vec2(0.0);
    return mod(mod(cameraPosition.xz, tile) + base + t.shift + t.flow * (cloudTime * CLOUD_SPEED), tile);
}

ivec2 vanillaCloudCellOf(VanillaTier t, vec2 q) { return ivec2(floor(q / t.cell)); }

// 負の整数の % は未定義なので、床で畳む
ivec2 vanillaCloudWrap(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    return c - size * ivec2(floor(vec2(c) / vec2(size)));
}

// 模様のマスに雲があるか。雨ではマスごとのハッシュの順に模様の外のマスも埋まり、雲が空を覆う
bool vanillaCloudPattern(ivec2 c) {
    ivec2 w = vanillaCloudWrap(c);
    if (texelFetch(vanillaCloudTex, w, 0).a >= VANILLA_CLOUD_ALPHA_CUT) return true;
    return hash3(uvec3(uvec2(w), 61u)).x < VANILLA_CLOUD_RAIN_COVER * smoothstep(0.0, 1.0, cloudRainAmount());
}

/*
 * 列 (マス 1 つ) の中身。x = 柱の頭の高さ (底からのブロック。0 は雲のないマス), y = 4x4 マスの区画に雲があるか
 * 下段は柱の表 (cloudWeatherImg) から読む。prepare2 が毎フレーム、マスごとに作る (vanillaCloudTableTexel)
 * 上の段は表を使わず、模様を回転・間引いて外形の厚さの柱にする。間引きは回転前の模様のマス番号で決めるので、流れても粒が点滅しない
 */
vec2 vanillaCloudColumn(VanillaTier t, ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    if (t.index == 0) {
        if (max(size.x, size.y) > VANILLA_CLOUD_TABLE_SIZE) return vec2(vanillaCloudPattern(c) ? VANILLA_CLOUD_ENVELOPE : 0.0, 1.0);
        vec4 v = texelFetch(cloudWeatherSampler, vanillaCloudWrap(c), 0);
        return vec2(round(v.r * 255.0), v.a);
    }
    ivec2 w = vanillaCloudWrap(t.turn == 1 ? ivec2(c.y, -c.x) : c);
    bool has = texelFetch(vanillaCloudTex, w, 0).a >= VANILLA_CLOUD_ALPHA_CUT && hash3(uvec3(uvec2(w / t.keepBlock), 91u + uint(t.index))).x < t.keep;
    return vec2(has ? t.envelope : 0.0, 1.0);
}

// 底からの高さ h の点が列の中にあるか
bool vanillaCloudInside(vec2 col, float h) {
    return h > 0.0 && h < col.x;
}

// 点がいる区間 (下端, 上端)。列の外なら (0, 0)
vec2 vanillaCloudSpan(vec2 col, float h) {
    return vanillaCloudInside(col, h) ? vec2(0.0, col.x) : vec2(0.0);
}

/*
 * 表のテクセル c に書く値 (prepare2 の各スレッドが 1 マスずつ)。模様の外のテクセルと大きなテクスチャは使わない
 * r = 柱の頭の高さ (どのマスも同じ厚み), a = 空の区画を飛ばすための印 (4x4 マスの区画に雲が 1 つでもあるか)
 */
vec4 vanillaCloudTableTexel(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    if (any(greaterThanEqual(c, size)) || max(size.x, size.y) > VANILLA_CLOUD_TABLE_SIZE) return vec4(0.0);
    ivec2 block = c - c % VANILLA_CLOUD_BLOCK;
    float occupied = 0.0;
    for (int y = 0; y < VANILLA_CLOUD_BLOCK; y++) {
        for (int x = 0; x < VANILLA_CLOUD_BLOCK; x++) occupied = max(occupied, vanillaCloudPattern(block + ivec2(x, y)) ? 1.0 : 0.0);
    }
    return vec4(vanillaCloudPattern(c) ? VANILLA_CLOUD_ENVELOPE / 255.0 : 0.0, 0.0, 0.0, occupied);
}

/*
 * 点 (格子の座標 q, 高さ y) から、列の表に出ている面までの距離 (ブロック)
 * side: 側面 (x 一定の面までが x、z 一定の面までが y。隣の列がその高さまで雲なら、その面は表に出ていない。出ていない側は 1e3), up: 頭の面, down: 底の面。列の外は up か down が 0 以下
 * min と max だけで組むので、等高線は四角い (角と辺の丸めは vanillaCloudRound)
 */
void vanillaCloudFaces(VanillaTier t, vec2 q, float y, out vec2 side, out float up, out float down) {
    vec2 g = q / t.cell;
    ivec2 c = ivec2(floor(g));
    vec2 f = g - vec2(c);
    float h = y - t.bottom;
    vec2 span = vanillaCloudSpan(vanillaCloudColumn(t, c), h);
    up = span.y - h;
    down = h - span.x;
    side = vec2(1e3);
    if (up <= 0.0 || down <= 0.0) return;
    // 近い側の隣 (x, z) と斜めの隣
    ivec2 n = ivec2(f.x < 0.5 ? -1 : 1, f.y < 0.5 ? -1 : 1);
    float ex = (f.x < 0.5 ? f.x : 1.0 - f.x) * t.cell.x;
    float ez = (f.y < 0.5 ? f.y : 1.0 - f.y) * t.cell.y;
    bool openX = !vanillaCloudInside(vanillaCloudColumn(t, c + ivec2(n.x, 0)), h);
    bool openZ = !vanillaCloudInside(vanillaCloudColumn(t, c + ivec2(0, n.y)), h);
    if (openX) side.x = ex;
    if (openZ) side.y = ez;
    // へこんだ角: 斜めの隣だけが空きのときは角の柱 (四角い等高線のまま)
    if (!openX && !openZ && !vanillaCloudInside(vanillaCloudColumn(t, c + n), h)) side.x = max(ex, ez);
}

/*
 * 直方体の辺と角を半径 radius (ブロック) で丸める。面までの 4 つの距離が半径より小さい所だけ、丸めた形 (角の球・辺の円柱) との差を
 * 4 つの距離から引く。面の上と、隣と同じ高さでつながる所 (面が表に出ていない所) は変わらず、こぶやふくらみは作らない。半径 0 で四角いまま
 */
void vanillaCloudRound(float radius, inout vec2 side, inout float up, inout float down) {
    float nearest = min(min(side.x, side.y), min(up, down));
    if (nearest >= radius) return;
    float rounded = radius - length(max(vec4(radius) - vec4(side, up, down), 0.0));
    float shortage = nearest - rounded;
    side -= shortage;
    up -= shortage;
    down -= shortage;
}

/*
 * 密度 [0,1]。形はマスの直方体のままで、表に出ている面から数ブロックだけ密度を下げる
 * footprint: その点での画素の大きさ (ブロック)。柔らかさを画素より細かくしない (遠くの縁が時間方向に揺れて見えない)
 */
float vanillaCloudDensity(VanillaTier t, vec2 q, float y, float footprint) {
    vec2 side;
    float up, down;
    vanillaCloudFaces(t, q, y, side, up, down);
    if (up <= 0.0 || down <= 0.0) return 0.0;
    vanillaCloudRound(t.radius, side, up, down);
    float pixel = VANILLA_CLOUD_SOFT_PIXELS * footprint;
    float pixelSide = VANILLA_CLOUD_SOFT_SIDE_PIXELS * footprint;
    float softMax = min(VANILLA_CLOUD_SOFT_MAX, 0.45 * t.envelope);
    return smoothstep(0.0, min(max(t.soft.x, pixelSide), max(VANILLA_CLOUD_SOFT_MAX, t.soft.x)), min(side.x, side.y))
         * smoothstep(0.0, min(max(t.soft.y, pixel), softMax), up)
         * smoothstep(0.0, min(max(t.soft.z, pixel), softMax), down);
}

float vanillaCloudDensity(VanillaTier t, vec2 q, float y) {
    return vanillaCloudDensity(t, q, y, 0.0);
}

// 点が列の面から内側へ何ブロック入っているか (列の外は 0)。カメラが柱の中にいるかの判定に使う
float vanillaCloudInsideDepth(VanillaTier t, vec2 q, float y) {
    vec2 side;
    float up, down;
    vanillaCloudFaces(t, q, y, side, up, down);
    return max(min(min(side.x, side.y), min(up, down)), 0.0);
}

// 光源方向の光学的深さに掛ける、周期の大きいむら [MOTTLE_MIN, 1]。視線の消散 (形・透け) には掛けないので、形は変わらず、面の上の明るさだけがゆるくむらになる
float vanillaCloudMottle(vec2 q) {
    return mix(VANILLA_CLOUD_MOTTLE_MIN, 1.0, textureLod(cloudNoiseTex, q / (VANILLA_CLOUD_MOTTLE_CELLS * VANILLA_CLOUD_CELL), 0.0).g);
}

// 光源の光にかけるむら [1 - TOP_MOTTLE, 1 + TOP_MOTTLE] (平均は 1)。光源方向のむらとは別の周期と位置で読み、面の上の明暗が光の通り道のむらと重ならないようにする
float vanillaCloudTopMottle(vec2 q) {
    float g = textureLod(cloudNoiseTex, q / (VANILLA_CLOUD_TOP_MOTTLE_CELLS * VANILLA_CLOUD_CELL) + vec2(0.37, 0.71), 0.0).g;
    return 1.0 + VANILLA_CLOUD_TOP_MOTTLE * (2.0 * g - 1.0);
}

/*
 * 視線が xz の箱 [lo, lo + size) を出るまでの距離 (ブロック)。xz の 2 軸の「次の境目までの距離 / 方向の成分」の小さいほう (Amanatides & Woo の DDA の 1 歩)
 * q: 視線上の今の点の xz, dxz: 視線の方向の xz 成分
 */
float vanillaCloudBoxExit(vec2 q, vec2 dxz, vec2 lo, vec2 size) {
    vec2 edge = lo + vec2(dxz.x > 0.0 ? size.x : 0.0, dxz.y > 0.0 ? size.y : 0.0);
    vec2 axis = vec2(abs(dxz.x) < 1e-6 ? 1e-6 : dxz.x, abs(dxz.y) < 1e-6 ? 1e-6 : dxz.y);
    vec2 t = (edge - q) / axis;
    return max(min(t.x, t.y), 0.0) + VANILLA_CLOUD_SKIP_MARGIN;
}

// 光源方向の光学的深さ。光源の向きへ表のマスを 1 つずつ渡り、柱の頭より下を通る長さを足す (柱は直方体なので長さは厳密。
// 点で読むと、隣の柱の影の境目が柱の列でそろったぎざぎざになる)。上端 (外形の上端) を出るか、LIGHT_REACH ブロック進んだら止める
// (遠くの柱まで数えると、低い日の雲が真っ暗になる。光は雲の奥から何度も散乱して届くので、近くの柱だけが影を作る)
float vanillaCloudLightOD(VanillaTier t, vec2 q, float y, vec3 lightDir) {
    vec3 d = normalize(vec3(lightDir.x, max(lightDir.y, VANILLA_CLOUD_MIN_LIGHT_Y), lightDir.z));
    float tTop = min((t.bottom + t.envelope - y) / d.y, VANILLA_CLOUD_LIGHT_REACH);
    float od = 0.0;
    float s = 0.0;
    for (int i = 0; i < VANILLA_CLOUD_LIGHT_CELLS && s < tTop; i++) {
        vec2 p = q + d.xz * s;
        ivec2 cell = vanillaCloudCellOf(t, p);
        float next = s + vanillaCloudBoxExit(p, d.xz, vec2(cell) * t.cell, t.cell);
        vec2 col = vanillaCloudColumn(t, cell);
        float end = min(next, tTop);
        od += max(min(end, (t.bottom + col.x - y) / d.y) - s, 0.0);
        s = next;
    }
    return od * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA * t.shade);
}

// 真上 (空の光) 方向の光学的深さ: いる区間の頭までの長さ
float vanillaCloudSkyOD(VanillaTier t, vec2 q, float y) {
    float h = y - t.bottom;
    vec2 span = vanillaCloudSpan(vanillaCloudColumn(t, vanillaCloudCellOf(t, q)), h);
    return max(span.y - h, 0.0) * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA * t.shade);
}

/*
 * 上の段が、高さ y の点 (カメラ基準のワールド xz は rel) から光源方向へ落とす影の透過率。各段の中ほどの高さの 1 点だけで見積もる
 * weight: 濃さの倍率 (雨の日は雨の濃さの倍率で濃くする)
 */
float vanillaCloudUpperTransmittance(vec2 rel, float y, vec3 lightDir, float weight) {
    float ly = max(lightDir.y, VANILLA_TIER_SHADOW_MIN_Y);
    float transmittance = 1.0;
    for (int i = 1; i <= CLOUD_VANILLA_TIER_COUNT; i++) {
        VanillaTier u = vanillaTier(i);
        if (y >= u.bottom) continue;
        float mid = u.bottom + 0.5 * u.envelope;
        vec2 p = vanillaCloudOrigin(u) + rel + lightDir.xz * ((mid - y) / ly);
        float od = vanillaCloudDensity(u, p, mid) * u.envelope * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA * u.sigma) * weight / ly;
        transmittance *= exp(-od * VANILLA_TIER_SHADOW);
    }
    return transmittance;
}

/*
 * 雲影マップの点 relWorld (CLOUD_BASE の面の、カメラ基準のワールド xz) から光源方向に外形を抜けるまでの透過率
 * weight: 濃さの倍率 (雨の日は雨の濃さの倍率で濃くする)
 * 光学的深さは、厚み VANILLA_CLOUD_SHADOW_DEPTH の柱を抜けた値を上限にする (柱を厚くしても、地面の雲影は同じ濃さのまま)
 */
float vanillaCloudShadowTransmittance(vec2 relWorld, vec3 lightDir, float weight) {
    VanillaTier t = vanillaTier(0);
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    vec2 origin = vanillaCloudOrigin(t);
    float dh = t.envelope / float(VANILLA_CLOUD_SHADOW_STEPS);
    float depth = 0.0;
    for (int i = 0; i < VANILLA_CLOUD_SHADOW_STEPS; i++) {
        float h = (float(i) + 0.5) * dh;
        vec2 p = relWorld + lightDir.xz * ((t.bottom + h - CLOUD_BASE) / ly);
        if (vanillaCloudInside(vanillaCloudColumn(t, vanillaCloudCellOf(t, origin + p)), h)) depth += dh;
    }
    float od = min(depth, VANILLA_CLOUD_SHADOW_DEPTH) / ly * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA) * weight;
    // 多重散乱で厚い雲の下にも光が少し抜ける (低層の雲影と同じ)
    float transmittance = max(exp(-od), 0.25 * exp(-od * 0.25));
    return transmittance * vanillaCloudUpperTransmittance(relWorld, CLOUD_BASE, lightDir, weight);
}

#endif

#endif
