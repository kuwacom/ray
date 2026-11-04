/*
 * バニラの形の雲の密度・光の見積もり・雲影 (CLOUD_VANILLA_SHAPE, sky モジュール。cloud_march.glsl が読む)
 * バニラの雲と同じ高さ (Iris の cloudHeight)・模様・流れ (Iris の cloudTime) に置く、角を丸めた体積雲。格子はバニラの 12 ブロックの VANILLA_CLOUD_CELL_SCALE 倍。
 * 模様はバニラの雲のテクスチャ (リソースパックのものに従う) を customTexture で読み、1 画素 = 1 マスとして置く。
 * 雲はマスごとの直方体の柱で、面はすべて軸に平行 (曲面・ノイズの凹凸を持たない)。柱の頭の高さは塊の奥ほど段階的に高く、
 * 柱の表 (cloudWeatherImg) に入れて prepare2 が毎フレーム作る。形は変えずに、表に出ている面の近くだけ密度を下げて縁を透かす
 * 雷雨のときは、表に塔 (柱の積み上げ) と金床 (浮いた板) も書く
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
const float VANILLA_CLOUD_CORNER_RADIUS = 6.0;      // ブロック: 直方体の辺と角を丸める半径。0 で四角いまま
const float VANILLA_CLOUD_SOFT_MAX = 6.0;          // ブロック: 柔らかさの上限 (マスの半分。これを超えると小さな塊の芯まで薄くなる)
const float VANILLA_CLOUD_OCCLUSION = 0.25;        // 段差の根元で空の光が減る最大の割合
const float VANILLA_CLOUD_OCCLUSION_REACH = 2.0;   // ブロック: 壁の遮りの距離の減衰の下駄
const float VANILLA_CLOUD_OCCLUSION_FULL = 2.0;    // 壁の高さ / (距離 + 下駄) がこの値で遮りが最大になる
const float VANILLA_CLOUD_MOTTLE_MIN = 0.6;        // 光源方向の濃さに掛けるむらの下限
const float VANILLA_CLOUD_MOTTLE_CELLS = 12.0;     // マス: むらのノイズ (cloudNoiseTex の滑らかな fbm) 1 周の長さ。マスの大きさに比例させて、模様の大きさが変わってもむらの見え方を保つ
const float VANILLA_CLOUD_TOP_MOTTLE = 0.25;       // 光源の光にかけるむらの深さ (0 でむらなし)。面は平らなまま、上から見たときの一様な白さに緩い明暗を付ける
const float VANILLA_CLOUD_TOP_MOTTLE_CELLS = 3.0;  // マス: 同じむらの 1 周の長さ
const float VANILLA_CLOUD_TOP_MOTTLE_DEPTH = 3.0;  // ブロック: 柱の頭からこの深さまでだけにかける (側面に縦縞が出ない)
const float VANILLA_CLOUD_SIGMA = 0.275 * CLOUD_LOW_DENSITY;   // 1 / 参照 m。既定の濃さで 1 ブロックあたり約 1 (参照 m への換算は VANILLA_CLOUD_KREF)
const float VANILLA_CLOUD_OPACITY = 1.3;           // 視線方向の消散の倍率 (陰の光学的深さには掛けない)。縁の 2 ブロックは半透明になり、光が透けて柔らかく見える
const float VANILLA_CLOUD_INSIDE_OPACITY = 0.05;   // 同じく、カメラが柱の中にいるときの倍率 (中の見通しは雲の中の霧が決めるので、柱の消散で地形が白く閉じたり暗い影になったりしない)
const float VANILLA_CLOUD_INSIDE_DEPTH = 0.5;      // ブロック: カメラが柱の面からこの深さまで入ると、倍率が INSIDE_OPACITY になる
// 陰と内散乱の濃さは既定の濃さで頭打ち (柱はすでに光を通さないので、濃さを上げても底がさらに暗く青灰色になるだけ)
const float VANILLA_CLOUD_SHADE_SIGMA = 0.275 * min(CLOUD_LOW_DENSITY, 0.25);
const float VANILLA_CLOUD_LIGHT_REACH = 12.0;      // ブロック: 光源方向の影を数える距離
const int VANILLA_CLOUD_LIGHT_CELLS = 3;           // その間に渡るマスの最大数 (マスは 13 ブロック以上なので、REACH の間に渡るのは 2 つ)
// 真上の陰を数える高さ。塔の側面は外の空に開いているので、頭までの長さを丸ごと数えると塔が真っ暗になる (低い柱は頭までの長さがこれ以下)
const float VANILLA_CLOUD_SKY_REACH = 30.0;
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

// 上の段。高さは下段の底からのブロック (案 0 = 高い: 中段 約 368・上段 約 592 / 案 1 = 建築の上限以下: 約 256・約 304)。
// 格子は下段 (24 ブロック) に見合う大きさで、遠くの段ほど見かけが小さくなる分だけ粗くする
const float VANILLA_TIER_MID_BOTTOM = CLOUD_VANILLA_TIER_HEIGHT == 0 ? 176.0 : 64.0;
const float VANILLA_TIER_HIGH_BOTTOM = CLOUD_VANILLA_TIER_HEIGHT == 0 ? 400.0 : 112.0;
const float VANILLA_TIER_MID_THICKNESS = 8.0;
const float VANILLA_TIER_HIGH_THICKNESS = 3.0;
const vec2 VANILLA_TIER_MID_CELL = vec2(36.0);               // 見かけの幅 約 7 度 (案 0)
const vec2 VANILLA_TIER_HIGH_CELL = vec2(144.0, 36.0);       // 横に 4 倍引き伸ばした細長いマス
const vec2 VANILLA_TIER_MID_SHIFT = vec2(128.0, 64.0) * VANILLA_TIER_MID_CELL;   // 下段と同じ模様に見えないよう、マス単位でずらす
const vec2 VANILLA_TIER_HIGH_SHIFT = vec2(64.0, 192.0) * VANILLA_TIER_HIGH_CELL;
// 流れの向きと、下段に対する速さの倍率 (上の段ほど遠いので、見かけの速さは下段より遅い)
const vec2 VANILLA_TIER_MID_FLOW = 1.6 * vec2(0.9063, 0.4226);
const vec2 VANILLA_TIER_HIGH_FLOW = 2.5 * vec2(0.6428, 0.7660);
const float VANILLA_TIER_MID_FAR = 2560.0;                   // ブロック: この距離で空へ溶かし切る
const float VANILLA_TIER_HIGH_FAR = 4096.0;
// 視線の消散と陰の濃さの、下段に対する倍率。鉛直の光学的深さは中段 約 2.5、上段 約 0.5
const float VANILLA_TIER_MID_SIGMA = 0.25;
const float VANILLA_TIER_HIGH_SIGMA = 0.13;
const float VANILLA_TIER_MID_BASE_DEPTH = 14.0;   // 底の暗さが 1 に戻る高さ。厚さより大きく取って、薄い段の下面を灰色にする
const float VANILLA_TIER_HIGH_BASE_DEPTH = 6.0;
const float VANILLA_TIER_MID_SHADE = 1.0;
const float VANILLA_TIER_HIGH_SHADE = 0.8;
const float VANILLA_TIER_KEEP_HIGH = 0.8;                    // 上段は中段より更に間引く
const vec2 VANILLA_TIER_RAIN_HIDE = vec2(0.1, 0.6);          // 雨雲の層の下にいる度合いがこの間で、上の段が見えなくなる
const float VANILLA_TIER_SHADOW = 0.5;                       // 上の段が下の雲や地面に落とす影の強さ
const float VANILLA_TIER_SHADOW_MIN_Y = 0.08;                // 影を落とす光源の高さの下限

#ifdef CLOUD_CUMULONIMBUS
const int VANILLA_CB_REGION = 16;                 // マス: 塔の候補を置く区画の一辺
const int VANILLA_CB_MARGIN = 2;                  // マス: 区画の端から塔の中心までの下限 (塔は中心から 2 マス)
const int VANILLA_CB_TRIES = 8;                   // 塔の中心の候補を試す回数 (周り 8 マスがすべて雲のマスは少ない)
const int VANILLA_CB_REACH = 12;                  // マス: 塔の中心から金床の端までの最大
const float VANILLA_CB_CHANCE = 0.5;             // 塔が立つ区画の割合
const float VANILLA_CB_TOWER_STEP = 4.0;          // ブロック: 塔の高さを丸める段
const ivec2 VANILLA_CB_ANVIL_SHIFT = ivec2(3, 0); // マス: 金床の中心の塔の中心からのずれ (下段の流れの向き)
const float VANILLA_CB_ANVIL_RADIUS = 6.0;        // マス: 金床の半径 (チェビシェフ距離)
const float VANILLA_CB_ANVIL_MANHATTAN = 9.0;     // マス: 金床の角を落とす距離 (マンハッタン距離)
const float VANILLA_CB_ANVIL_HOLES = 0.15;        // 金床のいちばん外の周から抜くマスの割合
const float VANILLA_CB_ANVIL_EDGE = 12.0;         // ブロック: 金床の縁の厚さ
const float VANILLA_CB_ANVIL_SLOPE = 4.0;         // ブロック: 中心へ 1 マス寄るごとに下面が下がる量
#endif

struct VanillaTier {
    int index;        // 0 下段 / 1 中段 / 2 上段
    float bottom;     // 底の高さ (ワールド y)
    float envelope;   // 外形の厚さ (ブロック)
    vec2 cell;        // マスの大きさ (ブロック)
    vec2 shift;       // 格子の座標のずらし (ブロック)
    vec2 flow;        // 流れ (cloudTime あたりのブロック)
    int turn;         // 1 で模様を 90 度回して鏡映しにする (整数のマスを整数のマスに写す)
    float keep;       // 間引きで残す割合
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
    t.envelope = low ? vanillaCloudEnvelope() : mid ? VANILLA_TIER_MID_THICKNESS : VANILLA_TIER_HIGH_THICKNESS;
    t.cell = low ? vec2(VANILLA_CLOUD_CELL) : mid ? VANILLA_TIER_MID_CELL : VANILLA_TIER_HIGH_CELL;
    t.shift = low ? vec2(0.0) : mid ? VANILLA_TIER_MID_SHIFT : VANILLA_TIER_HIGH_SHIFT;
    t.flow = low ? vec2(1.0, 0.0) : mid ? VANILLA_TIER_MID_FLOW : VANILLA_TIER_HIGH_FLOW;
    t.turn = mid ? 1 : 0;
    t.keep = low ? 1.0 : mid ? CLOUD_VANILLA_TIER_COVERAGE : CLOUD_VANILLA_TIER_COVERAGE * VANILLA_TIER_KEEP_HIGH;
    t.sigma = low ? 1.0 : mid ? VANILLA_TIER_MID_SIGMA : VANILLA_TIER_HIGH_SIGMA;
    t.shade = low ? 1.0 : mid ? VANILLA_TIER_MID_SHADE : VANILLA_TIER_HIGH_SHADE;
    t.far = low ? VANILLA_CLOUD_FAR : mid ? VANILLA_TIER_MID_FAR : VANILLA_TIER_HIGH_FAR;
    t.baseDepth = low ? VANILLA_CLOUD_BASE_DEPTH : mid ? VANILLA_TIER_MID_BASE_DEPTH : VANILLA_TIER_HIGH_BASE_DEPTH;
    t.radius = low ? VANILLA_CLOUD_CORNER_RADIUS : min(VANILLA_CLOUD_CORNER_RADIUS, 0.5 * t.envelope);
    t.soft = low ? vec3(VANILLA_CLOUD_SOFT_SIDE, VANILLA_CLOUD_SOFT_TOP, VANILLA_CLOUD_SOFT_BOTTOM)
                 : mid ? vec3(4.0, 2.5, 2.5) * CLOUD_EDGE_SOFTNESS : vec3(4.0, 1.0, 1.0) * CLOUD_EDGE_SOFTNESS;
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

// 模様のマスに雲があるか
bool vanillaCloudPattern(ivec2 c) {
    return texelFetch(vanillaCloudTex, vanillaCloudWrap(c), 0).a >= VANILLA_CLOUD_ALPHA_CUT;
}

/*
 * 列 (マス 1 つ) の中身。x = 下の柱の頭の高さ (底からのブロック。0 は雲のないマス), y = 金床の下面, z = 金床の上面 (0 は金床なし), w = 4x4 マスの区画に雲があるか
 * 下段は柱の表 (cloudWeatherImg) から読む。prepare2 が毎フレーム、模様のマスごとに作る (vanillaCloudTableTexel)
 * 上の段は表を使わず、模様を回転・間引いて外形の厚さの柱にする。間引きは回転前の模様のマス番号で決めるので、流れても粒が点滅しない
 */
vec4 vanillaCloudColumn(VanillaTier t, ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    if (t.index == 0) {
        if (max(size.x, size.y) > VANILLA_CLOUD_TABLE_SIZE) return vec4(vanillaCloudPattern(c) ? VANILLA_CLOUD_EDGE_HEIGHT : 0.0, 0.0, 0.0, 1.0);
        vec4 v = texelFetch(cloudWeatherSampler, vanillaCloudWrap(c), 0);
        return vec4(round(v.rgb * 255.0), v.a);
    }
    ivec2 w = vanillaCloudWrap(t.turn == 1 ? ivec2(c.y, -c.x) : c);
    bool has = texelFetch(vanillaCloudTex, w, 0).a >= VANILLA_CLOUD_ALPHA_CUT && hash3(uvec3(uvec2(w), 91u + uint(t.index))).x < t.keep;
    return vec4(has ? t.envelope : 0.0, 0.0, 0.0, 1.0);
}

// 底からの高さ h の点が列の中にあるか
bool vanillaCloudInside(vec4 col, float h) {
    return (h > 0.0 && h < col.x) || (col.y > 0.0 && h >= col.y && h < col.z);
}

// 点がいる区間 (下端, 上端)。列の外なら (0, 0)
vec2 vanillaCloudSpan(vec4 col, float h) {
    if (col.y > 0.0 && h >= col.y && h < col.z) return col.yz;
    if (h > 0.0 && h < col.x) return vec2(0.0, col.x);
    return vec2(0.0);
}

#ifdef CLOUD_CUMULONIMBUS
// 区画の塔の中心がある所の周り 8 マスがすべて雲か
bool vanillaCloudTowerOk(ivec2 center) {
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (!vanillaCloudPattern(center + ivec2(x, y))) return false;
        }
    }
    return true;
}

/*
 * 雷雨の塔と金床をマス c に書き足す。模様を 16 マス四方の区画に分け、区画の番号のハッシュで一部の区画に塔の中心を置く
 * (模様のマス番号で決めるので、塔は雲と一緒に流れ、毎回同じ所に立つ)。塔は中心から 2 マスまでの雲のマスを高くした階段状の柱、
 * 金床は塔の中心から流れの向きに 3 マスずらした所の、角を落とした八角形の板 (いちばん外の周は一部のマスを抜く)。下面は中心ほど下がる
 */
void vanillaCloudStorm(ivec2 c, ivec2 block, inout float height, inout float anvilLow, inout float anvilHigh, inout float occupied) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    float anvilGrow = vanillaCloudAnvilGrow();
    int ring = int(floor(VANILLA_CB_ANVIL_RADIUS * anvilGrow + 1e-3));
    int reach = int(floor(VANILLA_CB_ANVIL_MANHATTAN * anvilGrow + 1e-3));
    ivec2 regions = max(size / VANILLA_CB_REGION, ivec2(1));
    ivec2 base = c / VANILLA_CB_REGION;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 r = base + ivec2(dx, dy);
            // 金床の端 (塔の中心から最大 12 マス) が c に届く区画だけ
            ivec2 lo = r * VANILLA_CB_REGION - VANILLA_CB_REACH;
            if (any(lessThan(c, lo)) || any(greaterThan(c, lo + (VANILLA_CB_REGION + 2 * VANILLA_CB_REACH)))) continue;
            ivec2 rw = r - regions * ivec2(floor(vec2(r) / vec2(regions)));
            if (hash3(uvec3(uvec2(rw), 313u)).x >= VANILLA_CB_CHANCE) continue;
            // 周り 8 マスがすべて雲のマスが見つかるまで、区画の中の候補を順に試す
            ivec2 center = ivec2(-1000);
            for (int k = 0; k < VANILLA_CB_TRIES; k++) {
                vec3 hk = hash3(uvec3(uvec2(rw), 400u + uint(k)));
                ivec2 candidate = r * VANILLA_CB_REGION + VANILLA_CB_MARGIN + ivec2(hk.xy * float(VANILLA_CB_REGION - 2 * VANILLA_CB_MARGIN));
                if (vanillaCloudTowerOk(candidate)) {
                    center = candidate;
                    break;
                }
            }
            if (center.x < -500) continue;
            ivec2 anvil = center + VANILLA_CB_ANVIL_SHIFT;
            // 区画の印: 金床がかかりうる区画は空にしない (塔は模様の中なので模様が持つ)
            ivec2 gap = max(max(block - anvil, anvil - (block + (VANILLA_CLOUD_BLOCK - 1))), ivec2(0));
            if (max(gap.x, gap.y) <= ring) occupied = 1.0;
            ivec2 dT = abs(c - center);
            ivec2 dA = abs(c - anvil);
            int towerD = max(dT.x, dT.y);
            int anvilD = max(dA.x, dA.y);
            int anvilM = dA.x + dA.y;
            bool inTower = towerD <= 2;
            bool inAnvil = ring > 0 && anvilD <= ring && anvilM <= reach;
            if (!(inTower || inAnvil)) continue;
            if (inTower && vanillaCloudPattern(c)) {
                float shape = towerD == 0 ? 1.0 : towerD == 1 ? 0.8 : 0.55;
                float jitter = floor(hash3(uvec3(uvec2(c), 17u)).x * 3.0) - 1.0;
                height = max(height, (round(VANILLA_CB_TOWER * vanillaCloudTowerGrow() * shape / VANILLA_CB_TOWER_STEP) + jitter) * VANILLA_CB_TOWER_STEP);
            }
            bool rim = anvilD == ring || anvilM == reach;
            if (inAnvil && !(rim && hash3(uvec3(uvec2(c), 29u)).x < VANILLA_CB_ANVIL_HOLES)) {
                float low = VANILLA_CB_ANVIL_TOP - (VANILLA_CB_ANVIL_EDGE + VANILLA_CB_ANVIL_SLOPE * float(ring - anvilD));
                anvilLow = anvilLow > 0.0 ? min(anvilLow, low) : low;
                anvilHigh = VANILLA_CB_ANVIL_TOP;
            }
        }
    }
    // 塔が金床の下面まで届いていれば、ひと続きの柱にする
    if (anvilLow > 0.0 && height >= anvilLow) {
        height = max(height, anvilHigh);
        anvilLow = 0.0;
        anvilHigh = 0.0;
    }
}
#endif

/*
 * 表のテクセル c に書く値 (prepare2 の各スレッドが 1 マスずつ)。模様の外のテクセルと大きなテクスチャは使わない
 * 頭の高さ = 縁の厚み + 塊の奥ゆき (周りのマスがすべて雲の周の数。縁のマスは 0) x 段の高さ。奥ゆきは TERRACE まで
 */
vec4 vanillaCloudTableTexel(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    if (any(greaterThanEqual(c, size)) || max(size.x, size.y) > VANILLA_CLOUD_TABLE_SIZE) return vec4(0.0);
    float height = 0.0;
    if (vanillaCloudPattern(c)) {
        int depth = 0;
        for (int r = 1; r <= VANILLA_CLOUD_TERRACE; r++) {
            // 距離 r の周 (チェビシェフ距離) がすべて雲なら 1 周深い
            bool ring = true;
            for (int y = -r; y <= r; y++) {
                for (int x = -r; x <= r; x++) {
                    if (max(abs(x), abs(y)) == r && !vanillaCloudPattern(c + ivec2(x, y))) ring = false;
                }
            }
            if (!ring) break;
            depth = r;
        }
        height = VANILLA_CLOUD_EDGE_HEIGHT + float(depth) * VANILLA_CLOUD_TERRACE_STEP;
    }
    // 空の区画を飛ばすための印: 4x4 マスの区画に雲が 1 つでもあるか
    ivec2 block = c - c % VANILLA_CLOUD_BLOCK;
    float occupied = 0.0;
    for (int y = 0; y < VANILLA_CLOUD_BLOCK; y++) {
        for (int x = 0; x < VANILLA_CLOUD_BLOCK; x++) occupied = max(occupied, vanillaCloudPattern(block + ivec2(x, y)) ? 1.0 : 0.0);
    }
    float anvilLow = 0.0;
    float anvilHigh = 0.0;
#ifdef CLOUD_CUMULONIMBUS
    if (VANILLA_THUNDER > 0.001) vanillaCloudStorm(c, block, height, anvilLow, anvilHigh, occupied);
#endif
    return vec4(vec3(height, anvilLow, anvilHigh) / 255.0, occupied);
}

/*
 * 点 (格子の座標 q, 高さ y) から、列の表に出ている面までの距離 (ブロック)
 * side: 側面 (x 一定の面までが x、z 一定の面までが y。隣の列がその高さまで雲なら、その面は表に出ていない。出ていない側は 1e3), up: 頭の面, down: 底の面。列の外は up か down が 0 以下
 * min と max だけで組むので、等高線は四角い (角と辺の丸めは vanillaCloudRound)
 * occlusion: 空の光の遮り [0, VANILLA_CLOUD_OCCLUSION]。頭が隣の高い柱の壁に接する所は、壁に空の一部を遮られる (段差の根元の陰)
 */
void vanillaCloudFaces(VanillaTier t, vec2 q, float y, out vec2 side, out float up, out float down, out float occlusion) {
    vec2 g = q / t.cell;
    ivec2 c = ivec2(floor(g));
    vec2 f = g - vec2(c);
    float h = y - t.bottom;
    vec4 col = vanillaCloudColumn(t, c);
    vec2 span = vanillaCloudSpan(col, h);
    up = span.y - h;
    down = h - span.x;
    side = vec2(1e3);
    occlusion = 0.0;
    if (up <= 0.0 || down <= 0.0) return;
    // 近い側の隣 (x, z) と斜めの隣
    ivec2 n = ivec2(f.x < 0.5 ? -1 : 1, f.y < 0.5 ? -1 : 1);
    vec4 colX = vanillaCloudColumn(t, c + ivec2(n.x, 0));
    vec4 colZ = vanillaCloudColumn(t, c + ivec2(0, n.y));
    float ex = (f.x < 0.5 ? f.x : 1.0 - f.x) * t.cell.x;
    float ez = (f.y < 0.5 ? f.y : 1.0 - f.y) * t.cell.y;
    bool openX = !vanillaCloudInside(colX, h);
    bool openZ = !vanillaCloudInside(colZ, h);
    if (openX) side.x = ex;
    if (openZ) side.y = ez;
    // へこんだ角: 斜めの隣だけが空きのときは角の柱 (四角い等高線のまま)
    if (!openX && !openZ && !vanillaCloudInside(vanillaCloudColumn(t, c + n), h)) side.x = max(ex, ez);
    if (t.index != 0 || span.x > 0.0) return;
    // 頭より上へ出ている隣の壁の高さ / (壁までの距離 + 頭から潜った深さ + 2)。壁に近く浅いほど強い
    // 近い側だけを見ると、マスの中央で見る壁が入れ替わって明るさが段になる。反対側の壁も足して、マスの中でなめらかにつなぐ
    float head = col.x;
    float headX2 = vanillaCloudColumn(t, c - ivec2(n.x, 0)).x;
    float headZ2 = vanillaCloudColumn(t, c - ivec2(0, n.y)).x;
    float reach = up + VANILLA_CLOUD_OCCLUSION_REACH;
    float wall = max(colX.x - head, 0.0) / (ex + reach) + max(headX2 - head, 0.0) / (t.cell.x - ex + reach)
               + max(colZ.x - head, 0.0) / (ez + reach) + max(headZ2 - head, 0.0) / (t.cell.y - ez + reach);
    occlusion = VANILLA_CLOUD_OCCLUSION * saturate(wall / VANILLA_CLOUD_OCCLUSION_FULL);
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
 * 密度 [0,1] と空の光の遮り。形はマスの直方体のままで、表に出ている面から数ブロックだけ密度を下げる
 * footprint: その点での画素の大きさ (ブロック)。柔らかさを画素より細かくしない (遠くの縁が時間方向に揺れて見えない)
 */
float vanillaCloudDensity(VanillaTier t, vec2 q, float y, float footprint, out float occlusion) {
    vec2 side;
    float up, down;
    vanillaCloudFaces(t, q, y, side, up, down, occlusion);
    if (up <= 0.0 || down <= 0.0) return 0.0;
    vanillaCloudRound(t.radius, side, up, down);
    float pixel = VANILLA_CLOUD_SOFT_PIXELS * footprint;
    float pixelSide = VANILLA_CLOUD_SOFT_SIDE_PIXELS * footprint;
    float softMax = min(VANILLA_CLOUD_SOFT_MAX, 0.45 * t.envelope);
    return smoothstep(0.0, min(max(t.soft.x, pixelSide), VANILLA_CLOUD_SOFT_MAX), min(side.x, side.y))
         * smoothstep(0.0, min(max(t.soft.y, pixel), softMax), up)
         * smoothstep(0.0, min(max(t.soft.z, pixel), softMax), down);
}

float vanillaCloudDensity(VanillaTier t, vec2 q, float y) {
    float occlusion;
    return vanillaCloudDensity(t, q, y, 0.0, occlusion);
}

// 点が列の面から内側へ何ブロック入っているか (列の外は 0)。カメラが柱の中にいるかの判定に使う
float vanillaCloudInsideDepth(VanillaTier t, vec2 q, float y) {
    vec2 side;
    float up, down, occlusion;
    vanillaCloudFaces(t, q, y, side, up, down, occlusion);
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

// 光源方向の光学的深さ。光源の向きへ表のマスを 1 つずつ渡り、柱の頭より下 (と金床の中) を通る長さを足す (柱は直方体なので長さは厳密。
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
        vec4 col = vanillaCloudColumn(t, cell);
        float end = min(next, tTop);
        od += max(min(end, (t.bottom + col.x - y) / d.y) - s, 0.0);
        if (col.y > 0.0) od += max(min(end, (t.bottom + col.z - y) / d.y) - max(s, (t.bottom + col.y - y) / d.y), 0.0);
        s = next;
    }
    return od * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA * t.shade);
}

// 真上 (空の光) 方向の光学的深さ: いる区間の頭までの長さ
float vanillaCloudSkyOD(VanillaTier t, vec2 q, float y) {
    float h = y - t.bottom;
    vec2 span = vanillaCloudSpan(vanillaCloudColumn(t, vanillaCloudCellOf(t, q)), h);
    return min(max(span.y - h, 0.0), VANILLA_CLOUD_SKY_REACH) * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA * t.shade);
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
