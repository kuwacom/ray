/*
 * バニラの形の雲の密度・光の見積もり・雲影 (CLOUD_VANILLA_SHAPE, sky モジュール。cloud_march.glsl が読む)
 * バニラの雲と同じ高さ (Iris の cloudHeight)・12 ブロックの格子・模様・流れ (Iris の cloudTime) に置く、角ばった体積雲。
 * 模様はバニラの雲のテクスチャ (リソースパックのものに従う) を customTexture で読み、1 画素 = 1 マスとして置く。
 * 雲はマスごとの直方体の柱で、面はすべて軸に平行 (曲面・ノイズの凹凸を持たない)。柱の頭の高さは塊の奥ほど段階的に高く、
 * 柱の表 (cloudWeatherImg) に入れて prepare2 が毎フレーム作る。形は変えずに、表に出ている面の近くだけ密度を下げて縁を透かす
 * 長さは参照空間の縮尺 VANILLA_CLOUD_KREF (参照 m / ブロック) で測るので、高さテンプレートによらず同じ透け方になる
 */
#ifndef SKY_CLOUD_VANILLA_GLSL
#define SKY_CLOUD_VANILLA_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
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
const float VANILLA_CLOUD_CORNER_RADIUS = 2.5;      // ブロック: 直方体の辺と角を丸める半径。0 で四角いまま
const float VANILLA_CLOUD_SOFT_MAX = 6.0;          // ブロック: 柔らかさの上限 (マスの半分。これを超えると小さな塊の芯まで薄くなる)
const float VANILLA_CLOUD_OCCLUSION = 0.25;        // 段差の根元で空の光が減る最大の割合
const float VANILLA_CLOUD_OCCLUSION_REACH = 2.0;   // ブロック: 壁の遮りの距離の減衰の下駄
const float VANILLA_CLOUD_OCCLUSION_FULL = 2.0;    // 壁の高さ / (距離 + 下駄) がこの値で遮りが最大になる
const float VANILLA_CLOUD_MOTTLE_MIN = 0.6;        // 光源方向の濃さに掛けるむらの下限
const float VANILLA_CLOUD_MOTTLE_PERIOD = 160.0;   // ブロック: むらのノイズ (cloudNoiseTex の滑らかな fbm) 1 周の長さ
const float VANILLA_CLOUD_SIGMA = 0.275 * CLOUD_LOW_DENSITY;   // 1 / 参照 m。既定の濃さで 1 ブロックあたり約 1 (参照 m への換算は VANILLA_CLOUD_KREF)
const float VANILLA_CLOUD_OPACITY = 1.3;           // 視線方向の消散の倍率 (陰の光学的深さには掛けない)。縁の 2 ブロックは半透明になり、光が透けて柔らかく見える
const float VANILLA_CLOUD_INSIDE_OPACITY = 0.05;   // 同じく、カメラが柱の中にいるときの倍率 (中の見通しは雲の中の霧が決めるので、柱の消散で地形が白く閉じたり暗い影になったりしない)
const float VANILLA_CLOUD_INSIDE_DEPTH = 0.5;      // ブロック: カメラが柱の面からこの深さまで入ると、倍率が INSIDE_OPACITY になる
// 陰と内散乱の濃さは既定の濃さで頭打ち (柱はすでに光を通さないので、濃さを上げても底がさらに暗く青灰色になるだけ)
const float VANILLA_CLOUD_SHADE_SIGMA = 0.275 * min(CLOUD_LOW_DENSITY, 0.25);
const float VANILLA_CLOUD_MIN_LIGHT_Y = 0.05;      // 光源の高さの下限 (地平線すれすれで陰の長さが発散しない)
const float VANILLA_CLOUD_LIGHT_STEP0 = 0.75;      // ブロック: 光源方向の最初の歩幅 (毎回 2 倍)
const float VANILLA_CLOUD_STEP_REL = 0.004;        // 視線の歩幅 (距離に対する割合)。ブロック
const float VANILLA_CLOUD_STEP_MIN = 0.3;          // 雲の近くの歩幅は縁の柔らかさの 1/6 以下 (柔らかさの層を何歩かで渡り、等高線の縞を青ノイズに崩す)
const float VANILLA_CLOUD_STEP_MAX = 6.0;
const float VANILLA_CLOUD_SKIP_MARGIN = 0.02;      // ブロック: 箱を出る位置からこの分進んで、次の箱に入る (境目の浮動小数の誤差で止まらない)
const int VANILLA_CLOUD_SHADOW_STEPS = 6;
const float VANILLA_CLOUD_SHADOW_DEPTH = 4.0;      // ブロック: 地面の雲影の暗さの上限を決める厚み。厚い雲でも影を真っ黒にしない
// 光源方向と空の光は、日向の頭と日陰の底・側面の差を出すために絞る (CS_* の光の値はスタイルごとの微調整で、これはどのスタイルでもバニラの形に掛かる)
const float VANILLA_CLOUD_SUN = 1.0;
const float VANILLA_CLOUD_MS_GAIN = 1.2;
const float VANILLA_CLOUD_SILVER = 0.35;
const float VANILLA_CLOUD_POWDER = 0.8;
const float VANILLA_CLOUD_AMBIENT = 0.8;
const float VANILLA_CLOUD_BASE_SHADE = 1.5;     // 底の暗さの倍率 (CS_BASE_SHADE に掛かる。4 で底の直達光と多重散乱が 0 になり、空の色だけの暗い底になる)
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

// 格子の座標 (ブロック) でのカメラの位置。テクスチャの一周で先に畳むので、遠い座標でも精度が落ちない
vec2 vanillaCloudOrigin() {
    vec2 tile = vec2(textureSize(vanillaCloudTex, 0)) * VANILLA_CLOUD_CELL;
    return mod(mod(cameraPosition.xz, tile) + VANILLA_CLOUD_ORIGIN + vec2(cloudTime * CLOUD_SPEED, 0.0), tile);
}

ivec2 vanillaCloudCellOf(vec2 q) { return ivec2(floor(q / VANILLA_CLOUD_CELL)); }

// 模様のマスに雲があるか。負の整数の % は未定義なので、床で畳む
bool vanillaCloudPattern(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    return texelFetch(vanillaCloudTex, c - size * ivec2(floor(vec2(c) / vec2(size))), 0).a >= VANILLA_CLOUD_ALPHA_CUT;
}

/*
 * 柱の表 (cloudWeatherImg) の 1 マス。prepare2 が毎フレーム、模様のマスごとに作る (vanillaCloudTableTexel)
 * x = 柱の頭の高さ (底からのブロック。0 は雲のないマス), y = 金床の下面, z = 金床の上面 (どちらも底からのブロック。0 は金床なし), w = このマスを含む 4x4 マスの区画に雲があるか
 */
vec4 vanillaCloudColumn(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    if (max(size.x, size.y) > VANILLA_CLOUD_TABLE_SIZE) return vec4(vanillaCloudPattern(c) ? VANILLA_CLOUD_EDGE_HEIGHT : 0.0, 0.0, 0.0, 1.0);
    vec4 t = texelFetch(cloudWeatherSampler, c - size * ivec2(floor(vec2(c) / vec2(size))), 0);
    return vec4(round(t.rgb * 255.0), t.a);
}

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
    return vec4(vec3(height, 0.0, 0.0) / 255.0, occupied);
}

/*
 * 点 (格子の座標 q, 高さ y) から、柱の表に出ている面までの距離 (ブロック)
 * side: 側面 (x 一定の面までが x、z 一定の面までが y。隣の柱がその高さまで雲なら、その面は表に出ていない。出ていない側は 1e3), up: 頭の面, down: 底の面。柱の外は up か down が 0 以下
 * min と max だけで組むので、等高線は四角い (角と辺の丸めは vanillaCloudRound)
 * occlusion: 空の光の遮り [0, VANILLA_CLOUD_OCCLUSION]。頭が隣の高い柱の壁に接する所は、壁に空の一部を遮られる (段差の根元の陰)
 */
void vanillaCloudFaces(vec2 q, float y, out vec2 side, out float up, out float down, out float occlusion) {
    vec2 g = q / VANILLA_CLOUD_CELL;
    ivec2 c = ivec2(floor(g));
    vec2 f = g - vec2(c);
    float bottom = vanillaCloudBottom();
    float head = vanillaCloudColumn(c).x;
    up = bottom + head - y;
    down = y - bottom;
    side = vec2(1e3);
    occlusion = 0.0;
    if (head <= 0.0 || up <= 0.0 || down <= 0.0) return;
    // 近い側の隣 (x, z) と斜めの隣の頭の高さ
    ivec2 n = ivec2(f.x < 0.5 ? -1 : 1, f.y < 0.5 ? -1 : 1);
    float headX = vanillaCloudColumn(c + ivec2(n.x, 0)).x;
    float headZ = vanillaCloudColumn(c + ivec2(0, n.y)).x;
    float headD = vanillaCloudColumn(c + n).x;
    float ex = (f.x < 0.5 ? f.x : 1.0 - f.x) * VANILLA_CLOUD_CELL;
    float ez = (f.y < 0.5 ? f.y : 1.0 - f.y) * VANILLA_CLOUD_CELL;
    bool openX = y > bottom + headX;
    bool openZ = y > bottom + headZ;
    if (openX) side.x = ex;
    if (openZ) side.y = ez;
    // へこんだ角: 斜めの隣だけが空きのときは角の柱 (四角い等高線のまま)
    if (!openX && !openZ && y > bottom + headD) side.x = max(ex, ez);
    // 頭より上へ出ている隣の壁の高さ / (壁までの距離 + 頭から潜った深さ + 2)。壁に近く浅いほど強い
    float wall = max(headX - head, 0.0) / (ex + up + VANILLA_CLOUD_OCCLUSION_REACH) + max(headZ - head, 0.0) / (ez + up + VANILLA_CLOUD_OCCLUSION_REACH);
    occlusion = VANILLA_CLOUD_OCCLUSION * saturate(wall / VANILLA_CLOUD_OCCLUSION_FULL);
}

/*
 * 密度 [0,1] と空の光の遮り。形はマスの直方体のままで、表に出ている面から数ブロックだけ密度を下げる
 * footprint: その点での画素の大きさ (ブロック)。柔らかさを画素より細かくしない (遠くの縁が時間方向に揺れて見えない)
 */
/*
 * 直方体の辺と角を半径 VANILLA_CLOUD_CORNER_RADIUS (ブロック) で丸める。面までの 4 つの距離が半径より小さい所だけ、丸めた形 (角の球・辺の円柱) との差を
 * 4 つの距離から引く。面の上と、隣と同じ高さでつながる所 (面が表に出ていない所) は変わらず、こぶやふくらみは作らない。半径 0 で四角いまま
 */
void vanillaCloudRound(inout vec2 side, inout float up, inout float down) {
    float radius = VANILLA_CLOUD_CORNER_RADIUS;
    float nearest = min(min(side.x, side.y), min(up, down));
    if (nearest >= radius) return;
    float rounded = radius - length(max(vec4(radius) - vec4(side, up, down), 0.0));
    float shortage = nearest - rounded;
    side -= shortage;
    up -= shortage;
    down -= shortage;
}

float vanillaCloudDensity(vec2 q, float y, float footprint, out float occlusion) {
    vec2 side;
    float up, down;
    vanillaCloudFaces(q, y, side, up, down, occlusion);
    if (up <= 0.0 || down <= 0.0) return 0.0;
    vanillaCloudRound(side, up, down);
    float pixel = VANILLA_CLOUD_SOFT_PIXELS * footprint;
    float pixelSide = VANILLA_CLOUD_SOFT_SIDE_PIXELS * footprint;
    return smoothstep(0.0, min(max(VANILLA_CLOUD_SOFT_SIDE, pixelSide), VANILLA_CLOUD_SOFT_MAX), min(side.x, side.y))
         * smoothstep(0.0, min(max(VANILLA_CLOUD_SOFT_TOP, pixel), VANILLA_CLOUD_SOFT_MAX), up)
         * smoothstep(0.0, min(max(VANILLA_CLOUD_SOFT_BOTTOM, pixel), VANILLA_CLOUD_SOFT_MAX), down);
}

float vanillaCloudDensity(vec2 q, float y) {
    float occlusion;
    return vanillaCloudDensity(q, y, 0.0, occlusion);
}

// 点が柱の面から内側へ何ブロック入っているか (柱の外は 0)。カメラが柱の中にいるかの判定に使う
float vanillaCloudInsideDepth(vec2 q, float y) {
    vec2 side;
    float up, down, occlusion;
    vanillaCloudFaces(q, y, side, up, down, occlusion);
    return max(min(min(side.x, side.y), min(up, down)), 0.0);
}

// 光源方向の光学的深さに掛ける、周期の大きいむら [MOTTLE_MIN, 1]。視線の消散 (形・透け) には掛けないので、形は変わらず、面の上の明るさだけがゆるくむらになる
float vanillaCloudMottle(vec2 q) {
    return mix(VANILLA_CLOUD_MOTTLE_MIN, 1.0, textureLod(cloudNoiseTex, q / VANILLA_CLOUD_MOTTLE_PERIOD, 0.0).g);
}

// 光源方向の光学的深さ。歩幅を毎回 2 倍にして、柱の上端 (外形の上端) を出るまで積む。1 歩は表の 1 マスだけ読み、その歩が頭より下にある長さの割合を数える
// jitter: 各歩の中での読む位置 [0,1)。青ノイズで揺らすと、隣の柱の影の境目が柱の列でそろって出るぎざぎざにならず、時間方向に均される
float vanillaCloudLightOD(vec2 q, float y, vec3 lightDir, float jitter) {
    vec3 d = normalize(vec3(lightDir.x, max(lightDir.y, VANILLA_CLOUD_MIN_LIGHT_Y), lightDir.z));
    float bottom = vanillaCloudBottom();
    float top = bottom + VANILLA_CLOUD_ENVELOPE;
    float od = 0.0;
    float t = 0.0;
    float stepLength = VANILLA_CLOUD_LIGHT_STEP0;
    for (int i = 0; i < VANILLA_CLOUD_LIGHT_STEPS; i++) {
        float yLow = y + d.y * t;
        if (yLow >= top) break;
        float head = bottom + vanillaCloudColumn(vanillaCloudCellOf(q + d.xz * (t + jitter * stepLength))).x;
        od += saturate((head - yLow) / (d.y * stepLength)) * stepLength;
        t += stepLength;
        stepLength *= 2.0;
    }
    return od * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA);
}

// 真上 (空の光) 方向の光学的深さ: いるマスの頭までの長さ
float vanillaCloudSkyOD(vec2 q, float y) {
    float head = vanillaCloudBottom() + vanillaCloudColumn(vanillaCloudCellOf(q)).x;
    return max(head - y, 0.0) * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SHADE_SIGMA);
}

/*
 * 雲影マップの点 relWorld (CLOUD_BASE の面の、カメラ基準のワールド xz) から光源方向に外形を抜けるまでの透過率
 * weight: 濃さの倍率 (雨の日は雨の濃さの倍率で濃くする)
 * 光学的深さは、厚み VANILLA_CLOUD_SHADOW_DEPTH の柱を抜けた値を上限にする (柱を厚くしても、地面の雲影は同じ濃さのまま)
 */
float vanillaCloudShadowTransmittance(vec2 relWorld, vec3 lightDir, float weight) {
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    float bottom = vanillaCloudBottom();
    vec2 origin = vanillaCloudOrigin();
    float dh = VANILLA_CLOUD_ENVELOPE / float(VANILLA_CLOUD_SHADOW_STEPS);
    float depth = 0.0;
    for (int i = 0; i < VANILLA_CLOUD_SHADOW_STEPS; i++) {
        float h = (float(i) + 0.5) * dh;
        vec2 p = relWorld + lightDir.xz * ((bottom + h - CLOUD_BASE) / ly);
        if (h < vanillaCloudColumn(vanillaCloudCellOf(origin + p)).x) depth += dh;
    }
    float od = min(depth, VANILLA_CLOUD_SHADOW_DEPTH) / ly * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA) * weight;
    // 多重散乱で厚い雲の下にも光が少し抜ける (低層の雲影と同じ)
    return max(exp(-od), 0.25 * exp(-od * 0.25));
}

#endif

#endif
