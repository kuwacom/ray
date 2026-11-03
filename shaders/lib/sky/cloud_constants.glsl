/*
 * 体積雲の定数 (ノイズのサンプラー・スタイル・寸法・消散係数・位相・形状・光・歩数)
 * 形と光の考え方は cloud_volume.glsl
 * sky モジュール (cloud_volume.glsl が読む)
 */
#ifndef SKY_CLOUD_CONSTANTS_GLSL
#define SKY_CLOUD_CONSTANTS_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/noise.glsl"
//@include "/lib/common/phase.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/images.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/atmosphere.glsl"
//@include "/lib/sky/climate.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/sky_color.glsl"
//@include "/lib/sky/cloud_styles.glsl"

uniform sampler3D cloudShapeTex;
uniform sampler3D cloudDetailTex;
uniform sampler2D cloudNoiseTex;

// 中層は品質によらず描く (品質で変えるのは歩数だけにして、雲の形と陰影をそろえる)
// バニラの形は写実の雲 (中層・上層・積乱雲と雨脚) を一切描かない。上の雲はバニラの形の段だけ
#if CLOUDS == 3 && !defined CLOUD_VANILLA_SHAPE
    #define CLOUD_MID_LAYER
#endif
#if CLOUDS == 3 && defined CLOUD_CUMULONIMBUS && !defined CLOUD_VANILLA_SHAPE
    #define CLOUD_CB
#endif
#if defined CLOUD_CIRRUS && !defined CLOUD_VANILLA_SHAPE
    #define CLOUD_HIGH_LAYER
#endif

// 定数
// 天気図: カメラ中心の 512^2。テクセル単位に原点を丸めて、カメラが動いても値がちらつかないようにする
const float CLOUD_MAP_RES = 512.0;
const float CLOUD_MAP_TEXEL = 256.0; // m
// 被覆は 1/CLOUD_COVER_RANGE 倍して RGBA8 に入れる (1 を超えると隙間なく全天を覆う)
const float CLOUD_COVER_RANGE = 1.4;

// 大きさ。既定の CLOUD_SCALE 1.6 を基準 1.0 とする
const float CLOUD_SCALE_FACTOR = CLOUD_SCALE / 1.6;
// 層ごとのノイズ周期の公倍数 (m)。カメラ - 風をこれで畳んでからサンプル位置に足すと、遠い座標でも精度が落ちず畳み目で継ぎ目も出ない
// CLOUD_LOW_SIZE: 低層の雲ひとつひとつの大きさ (セル・塊・ロール) の倍率。縁の浸食・curl・断片雲は現実のこぶの寸法のまま保つ
// (周期を割り切るため 32 / 160 / 640 x CLOUD_LOW_SIZE は整数にする)
const float CLOUD_LOW_SIZE = 1.25;
const float CLOUD_LOW_TILE = 92160.0 * CLOUD_LOW_SIZE * CLOUD_SCALE_FACTOR * CLOUD_LOW_SCALE * CS_SIZE;
// 積雲のセル: r = 大 (8 個 / 周期, 雲 1.5-3 km), b = 中 (18 個, 0.7-1.4 km), a = 小 (32 個, 0.3-0.8 km)
const float CLOUD_CELL_PERIOD = CLOUD_LOW_TILE / 4.0;
const vec2 CLOUD_ROLL_PERIOD = CLOUD_LOW_TILE / vec2(5.0, 9.0);   // 層積雲: x に少し長いロール (2.3 x 1.3 km 前後)
const float CLOUD_SHAPE_PERIOD = CLOUD_LOW_TILE / 20.0;           // 4.6 km: 塊 0.2-1.1 km
const float CLOUD_CURL_PERIOD = CLOUD_LOW_TILE / (32.0 * CLOUD_LOW_SIZE);           // 2.9 km
const float CLOUD_DETAIL_PERIOD = CLOUD_LOW_TILE / (640.0 * CLOUD_LOW_SIZE);         // 既定 480 m: 縁の浸食 30-120 m (塊の大きさとは別に現実のこぶの寸法に合わせる)
const float CLOUD_MID_TILE = 64000.0 * CLOUD_SCALE_FACTOR * CLOUD_MID_SCALE;
// 高積雲の粒 350 m 前後、まとまり 1.5-3 km (粒が画素に近い大きさだと陰影の無い白い点に見えるので、粒を画素より十分大きくする)
const float CLOUD_MID_PERIOD = CLOUD_MID_TILE / 6.0;
const float CLOUD_MID_SHAPE_PERIOD = CLOUD_MID_TILE / 40.0;       // 1.6 km
const float CLOUD_MID_DETAIL_PERIOD = CLOUD_MID_TILE / 128.0;     // 500 m
const float CLOUD_HIGH_TILE = 96000.0 * CLOUD_SCALE_FACTOR * CLOUD_HIGH_SCALE;
const float CLOUD_HIGH_PATCH_PERIOD = CLOUD_HIGH_TILE / 2.0;      // 48 km: 巻雲の群れ
const float CLOUD_CC_PERIOD = CLOUD_HIGH_TILE / 16.0;             // 6 km: 巻積雲の粒 100-190 m
// 巻雲の房 (風向きの座標 (2, 1) で読む 3D Perlin-Worley): 風下に 2 倍長い幅の広い刷毛 (細い長い房は下から放射状の筋に見える)
const float CLOUD_CIRRUS_ALONG = CLOUD_HIGH_TILE / 6.0;
const float CLOUD_CIRRUS_ACROSS = CLOUD_HIGH_TILE / 12.0;
const float CLOUD_CIRRUS_VERTICAL = 6000.0;
// 巻雲の繊維 (3D Worley を風下に 2.7 倍伸ばして房の形で曲げる): 長さ 1 km x 幅 300 m 前後
const float CLOUD_CIRRUS_FIBER_ALONG = CLOUD_HIGH_TILE / 96.0;
const float CLOUD_CIRRUS_FIBER_ACROSS = CLOUD_HIGH_TILE / 256.0;
const float CLOUD_CIRRUS_FIBER_VERTICAL = 1500.0;
const float CLOUD_CIRRUS_FIBER_CURL = 1.2;  // 繊維の座標を curl で曲げる量 (繊維の周期単位)
// 落下筋のシア (m): 房 (層の上端) から層の下端までに、筋が風下へずれる長さ。下から見ると房から鉤状の尾が伸びる (uncinus)
const float CLOUD_CIRRUS_FALL_SHEAR = 1500.0;
// 繊維の谷の濃さ (山に対する割合)。小さいと平行な細い筋が並んで刷毛目のように見える
const float CLOUD_CIRRUS_FIBER_MIN = 0.6;
const float CLOUD_CIRRUS_FIBER_DIST = 50000.0;       // m: これより遠くは繊維を省く
const float CLOUD_CIRRUS_FIBER_FADE_NEAR = 12000.0; // m: ここから繊維を均し始め、CLOUD_CIRRUS_FIBER_DIST で完全に均す
const float CLOUD_CC_GRAIN_FADE_NEAR = 5000.0;      // m: 巻積雲の粒を均し始める距離
const float CLOUD_CC_GRAIN_FADE_FAR = 20000.0;

// 風 (m/s)。上空ほど強く、向きも少し回る (温度風)。層ごとに違う速さで流れて奥行きが出る
const float CLOUD_WIND_SPEED = CLOUD_LOW_WIND;
const vec2 CLOUD_WIND_DIR = vec2(cos(radians(float(CLOUD_LOW_WIND_ANGLE))), sin(radians(float(CLOUD_LOW_WIND_ANGLE))));
const float CLOUD_MID_WIND_SPEED = CLOUD_MID_WIND;
const vec2 CLOUD_MID_WIND_DIR = vec2(cos(radians(float(CLOUD_MID_WIND_ANGLE))), sin(radians(float(CLOUD_MID_WIND_ANGLE))));
const float CLOUD_HIGH_WIND_SPEED = CLOUD_HIGH_WIND;
// 巻雲の筋の向き。整数の回転 (2, 1) などに丸める (畳みの周期 CLOUD_HIGH_TILE の整数倍が整数倍に写り、繰り返しの継ぎ目が出ない)
const vec2 CLOUD_HIGH_WIND_ROT = vec2(round(2.0 * cos(radians(float(CLOUD_HIGH_WIND_ANGLE)))), round(2.0 * sin(radians(float(CLOUD_HIGH_WIND_ANGLE)))));
const vec2 CLOUD_HIGH_WIND_DIR = normalize(CLOUD_HIGH_WIND_ROT);
// 形状ノイズを被覆より少し速く流し、ゆっくり持ち上げる (雲が形を変えながら進み、湧き上がる)
const float CLOUD_EVOLVE = 0.2;   // 風速に対する割合
const float CLOUD_UPDRAFT = 0.6;  // m/s
// 風のシア: 雲頂ほど風下へずれる (高さ 1 m あたりの水平のずれ)
const float CLOUD_SHEAR = 0.1;

// 消散係数 (1/m, 密度 1 あたり)。積雲の実測 0.05-0.1 (液水量 0.5 g/m3, 有効半径 10 um で 0.075)。
// 縁は混合 (entrainment) で密度が下がるので、平均ではなく芯の値
// 0.07 (芯の実測値) では縁まで不透明な粘土の塊に見えるので、晴天の雲は 1/3 にして縁を淡く透かし、
// 雨雲・雷雨は CloudContext.densityScale で濃くする。
// 設定の濃さ CLOUD_LOW_DENSITY の既定は 0.25 (晴天の芯 0.024 x 0.25。ふわっと透ける雲になる)
#if CLOUDS == 3
    const float CLOUD_LOW_SIGMA = 0.024 * CLOUD_LOW_DENSITY;
    // 光源・空の方向の光学的深さ (自己遮蔽の陰) の消散係数。濃さ 1 未満では視線の sqrt でしか薄めない (
    // 濃さ 0.25 で陰まで 1/4 にすると雲の中が一様に明るい平板なもやになり、こぶごとの陰と暗い底が消える)
    const float CLOUD_LOW_SHADE_SIGMA = 0.024 * max(CLOUD_LOW_DENSITY, sqrt(CLOUD_LOW_DENSITY));
#else
    // 2D 押し出しの雲は係数を 3D の 4 倍にして、既定の濃さ 0.25 で 3D の 1.0 相当の濃さにする
    const float CLOUD_LOW_SIGMA = 0.32 * CLOUD_LOW_DENSITY;
    const float CLOUD_LOW_SHADE_SIGMA = CLOUD_LOW_SIGMA;
#endif
// 高積雲 (光学的厚さ 1-10)。薄すぎると陰影の無い白い粒になる。
// 低層の濃さに合わせる (0.025 では既定の低層より 4 倍濃く、薄い積雲越しに硬い白い小石の粒が透けて見える)
const float CLOUD_MID_SIGMA_BASE = 0.007;
const float CLOUD_MID_SIGMA = CLOUD_MID_SIGMA_BASE * CLOUD_MID_DENSITY;
// 単散乱アルベド: 可視域の水・氷の吸収はほぼ 0 (0.999 以上)。数オクターブで打ち切る多重散乱の取りこぼしは CLOUD_MS_GAIN で補う
const float CLOUD_ALBEDO = 0.99;
// 上層の消散係数 (1/m, 密度 1 あたり)。巻雲は光学的厚さ 0.1-0.5 の半透明 (氷水量 0.01-0.1 g/m3)。
// 層の厚み 1.4 km のうち房と筋が通るのは半分ほどなので、濃い房で鉛直 0.3 前後
const float CLOUD_CIRRUS_SIGMA = 4.0e-4 * CLOUD_HIGH_DENSITY;
const float CLOUD_CC_SIGMA = 3.0e-4 * CLOUD_HIGH_DENSITY;
const float CLOUD_CS_SIGMA = 1.6e-4 * CLOUD_HIGH_DENSITY;
// 氷晶の位相 (六角柱・板の集合体。液滴より前方ピークが弱い)
const float CLOUD_ICE_G = 0.75;
const float CLOUD_ICE_BACK = 0.15;
// 22 度ハロ (巻層雲の六角柱の氷晶による屈折)。強さは位相関数 (1/sr) への加算。控えめ (円環は完成しないことが多い)
const float CLOUD_HALO_ANGLE = 0.384;
const float CLOUD_HALO_WIDTH = 0.02;
const float CLOUD_HALO_STRENGTH = 0.12;
// 地面の照り返し。雲底は地面の半球のうち雲の影の中も見るので、地表のアルベドより低めにする (底を灰色に沈める)
const float CLOUD_GROUND_ALBEDO = 0.12;
const vec3 CLOUD_OVERCAST_TINT = vec3(0.92, 0.98, 1.1); // 雨天の雲の中の光の色 (輝度 1 あたり)
const float CLOUD_LIGHTNING_FLASH = 0.06; // 雷の閃光で雲に足す上向き照度
// 雨雲の層を拡散で抜けてくる光源の光 (等方位相 x 拡散透過) の重み。オクターブの下限 CLOUD_MS_DIFFUSION は
// 吸収込みで厚い層をほぼ真っ暗にするので、足さないと曇天の夜は空が地面より暗い黒い面になる
const float CLOUD_OVERCAST_DIFFUSE = 1.0;
// 雨の日の雲 (形と量はスタイルのまま) は、雲の上の見えない雨雲の層の下にあるとして光を絞る。
// 雲に当たる直達光の減衰 (地面の直達光の減衰より強め。雲は層のすぐ下にある) と、
// 雲の向こうの空 (雲の隙間) を層の下面の灰色に置き換える明るさ: 空の光 + 層を拡散で抜けた光源の光 (CLOUD_RAIN_VEIL_SUN 倍)
const float CLOUD_RAIN_SUN_DIMMING = 0.7;
const float CLOUD_RAIN_VEIL_SUN = 0.5;
const float CLOUD_RAIN_VEIL_GAIN = 0.7;
// 雲の空中遠近: 雲までの大気 (atmosphere.glsl の指数大気) の透過率と、その方向の空の内散乱の取り分で空へ溶かす。
// 固定の消散係数で青く霞ませると、夕方も地平線の雲が青白いまま空から浮く (iterationT の GetSkyRadianceToPoint 相当)
// 実大気のままだと地表近くのもや (境界層のエアロゾル) が無いぶん遠い雲が残りすぎるので、Mie を濃くする
const float CLOUD_AERIAL_RAYLEIGH = 1.6;
const float CLOUD_AERIAL_MIE = 5.0;
const float CLOUD_AERIAL_RAIN = 1.0;  // 雨の日のもやの増え方 (Mie の倍率への加算)
const float CLOUD_MAX_DISTANCE = CLOUD_DRAW_DISTANCE * 1000.0;
const float CLOUD_HIGH_MAX_DISTANCE = 160000.0;
const float CLOUD_MIN_TRANSMITTANCE = 0.02;
const float CLOUD_STEP_SCALE_MAX = 3.0;  // 水平に近い視線で歩数を増やす倍率の上限
const float CLOUD_SEG_NONE = 1e30;      // 区間なしの開始距離 (並べ替えで最後になる)
const float CLOUD_SEG_NONE_TEST = 1e29;

// 水滴の Mie の近似 (Jendersie & d'Eon 2023, 式 4-7)。液滴の直径 (um) から HG と Draine の混合を決める。
// 20 um (有効半径 10 um の積雲): gHG 0.995 (回折の鋭いピーク), gD 0.59, alpha 27, wD 0.50
const float CLOUD_DROPLET_DIAMETER = 20.0;
const float CLOUD_MIE_G_HG = exp(-0.0990567 / (CLOUD_DROPLET_DIAMETER - 1.67154));
const float CLOUD_MIE_G_D = exp(-2.20679 / (CLOUD_DROPLET_DIAMETER + 3.91029) - 0.428934);
const float CLOUD_MIE_ALPHA = exp(3.62489 - 8.29288 / (CLOUD_DROPLET_DIAMETER + 5.52825));
const float CLOUD_MIE_W_D = exp(-0.599085 / (CLOUD_DROPLET_DIAMETER - 0.641583) - 0.665888);
// グローリー (対日点の小さな輪)。上の近似は後方の鋭いピークを持たないので、雲の上から見た時用に弱いローブを足す
const float CLOUD_GLORY_G = -0.92;
const float CLOUD_GLORY_WEIGHT = 0.0015;

// 形状
const float CLOUD_COVER_SOFTNESS = 0.3;   // 被覆のしきい値からの立ち上がり幅 (セルの縁ほど薄く背が低い)
const float CLOUD_FOOTPRINT_WARP = 450.0; // m: 2D の被覆を高さごとにずらす量 (小さいと背の高い雲の側面が縦の幕の筋に見える)
// 積雲の背の高さがセルの値の幅いくつで最大になるか (大きいほど丸いドーム)
// (0.7 では背の高い雲が中心の 1 点へ細る尖った塔になる。頂を広く丸くして、こぶは CLOUD_TURRET で作る)
const float CLOUD_DOME_WIDTH = 0.5;
const float CLOUD_BASE_TUCK = 0.05;       // 積雲の底の近くで被覆から引く量 (底の縁が巻き上がる)
const float CLOUD_BASE_RAMP = 60.0;       // m: 雲底の立ち上がり (持ち上げ凝結高度で一斉に雲になるので底が平ら)
// 雲底の高さの地域差 (m)。凝結高度は湿りで変わるので、遠くの雲ほど底の高さがずれて、平らな底が段々に並んで見えない
const float CLOUD_BASE_VARIATION = 110.0;
// 雲底の乱流 (m): curl で雲底の高さを上下に揺らし、下だけちぎれた底にする (雲頂ほど弱い)
const float CLOUD_BASE_RAGGED = 70.0 * CS_BASE_RAGGED;
const float CLOUD_STRATUS_UNDULATION = 150.0; // m: 層状の雲の底の波打ち
// 積雲の大きさの分布 (べき乗則): 被覆を大中小のセルに分ける割合。小さい雲ほど数が多く (セルが 2.3 倍 / 4 倍細かい)、
// 面積の割合は小さい。全部同じ大きさの綿が並ぶのが一番偽物に見える
// 大 0.9 では湿った日 (被覆 0.5-0.78) に大きなセルどうしがつながり、横に長いソーセージ状の雲が並ぶ。
// 大を減らして中を増やし、間の空いた個々の積雲にする (iterationT の雲の並び)
// 大きな雲の幅を詰め、背丈が幅と同じくらいの並雲・雄大雲を増やす
const vec3 CLOUD_CU_SHARE = vec3(0.55, 0.55, 0.3);
// 大中小の雲の背の高さの割合 (小さいものほど扁平雲)。中小のセルは幅 0.7-1.7 km なので、0.8 では
// 幅の 2 倍の細い炎のような塔が大きな雲から突き出る。頂を広く丸くしている (CLOUD_DOME_BASE) ので 0.65 / 0.4 でも塔にならない
// (中 0.5 では飛んで低層の中ほど y 300 から見ても、雲頂がどれも目の高さより下に揃う)
const vec3 CLOUD_CU_HEIGHT = vec3(1.0, 0.65, 0.4);
// 積雲の背丈 (低層の厚みに対する割合): 対流の強さ 0 / 1 での基準と、隣どうしのばらつき (なめらかな fbm で x (1 +- SPREAD / 2))。
// 並雲が主で、時々雄大雲寄りに背の高い雲が混ざるようにする (下限が低いと並の日の積雲が扁平雲の平たい帯ばかりになる)。
// 層 4.5 km に対して 0.5, 1.0・ばらつき 1.0 で、シュークリームのようにもっこりと背の高い雲を混ぜる
// (並の日の大きな雲の頂は 1.7-4.1 km、低い雲と背の高い雲が混ざる)
const vec2 CLOUD_CU_TOP = vec2(0.5, 1.0);
const float CLOUD_CU_TOP_SPREAD = 1.0;
// 背丈の上限。層の上端 (h = 1) で頂が平らに切れないよう、この手前でなめらかに頭打ちにする (雲底の持ち上げ 0.05 の分も空ける)
const float CLOUD_CU_TOP_MAX = 0.92;
// 層積雲の頂の高さ (低層の厚みに対する割合): 晴れ / 雨。層 4.5 km で 660 m / 1.5 km (現実は 0.2-1 km)。
// 350 m 程度では湿った日・夕方の層積雲が薄い板に見える
const vec2 CLOUD_SC_TOP = vec2(0.15, 0.33);
// ドームの細り方の指数 (大きいほど側面が立ち、頂の近くで丸まる)。2 でふくらんだ側面と丸い頂にする
// (2.4 では 2D の足跡を縦に伸ばした側面が縦の幕の筋になる)
const float CLOUD_DOME_POW = 2.0;
// ドームの雲量 (浸食前) の倍率。1 では浸食 (形状・塔・こぶ・細かい浸食で計 0.7 前後) が
// ドームの雲量と同じ桁で、見える頂がドームの 2/3 の高さで止まり、中も縁と同じ淡さの平たいもやに見える。
// 2 倍して見える頂を上げ、中を芯の濃さまで詰める (縁の外のもやの幅は変えない)
const float CLOUD_DOME_GAIN = 2.0;
// セルの縁での背の高さの割合 (中心で 1)。0.42 では背の高さが中心の 1 点へ向かって伸び、頂が尖った炎のような塔になる
const float CLOUD_DOME_BASE = 0.7;
// 倍率で外へ広がった輪郭を戻す量 (浸食の平均程度。0 では晴れの日の雲量が 1.5 倍になり、空がほぼ埋まる)
// 芯が濃い (CLOUD_CORE_DENSITY) 分、同じ輪郭でも不透明に見える所が増えるので、輪郭を少し内へ戻して塊の間の青空を残す
const float CLOUD_DOME_OFFSET = 0.7;
// 3D の塔の塊のノイズでセルの値を揺らす量。2D のセルの値だけで側面を決めると、ドームが濃いので縦に伸ばした
// 平らな壁と縦の筋 (望遠で目立つ) になる。高さごとに張り出しの違うこぶの側面にする
const float CLOUD_LUMP_V = 0.2;
// セルの値から背の高さへの曲線の指数 (1 で中心へ一直線に高くなる円錐、小さいほど縁から早く立ち上がる丸い頂)
const float CLOUD_DOME_ROUND = 0.5;
// 大きな雲の周りは補償の下降流で晴れる: しきい値の手前の幅 CLOUD_CU_CLEARING_WIDTH で小さな雲を減らす割合
const float CLOUD_CU_CLEARING = min(0.8 * CS_SPACING, 1.0);
const float CLOUD_CU_CLEARING_WIDTH = 0.2 * CS_SPACING;
const float CLOUD_CELL_MIN_COVER = 0.12;  // 積雲のセルの形を作る最小の被覆 (これ未満は形を保って薄める)
// 断片雲 (ちぎれ雲・層積雲の切れ端): 雲底の近くの薄い層に、3D 形状ノイズの小片 (150-450 m) を群れの中だけに置く
const float CLOUD_FRACTUS_TOP = 0.1;                     // 層の上端 (低層の厚みに対する割合, 450 m)
const float CLOUD_FRACTUS_PERIOD = CLOUD_LOW_TILE / (160.0 * CLOUD_LOW_SIZE); // 1.1 km
// 小片を風下の軸 (x か z の近い方) に 1.5 倍伸ばす (ちぎれて流された形。等方だと小さな綿のポップコーンに見える。
// 2 倍では全天の小片が同じ向きの筋になり、透視で消失点へ集まる流し撮りのような縞に見える)
const vec3 CLOUD_FRACTUS_STRETCH = abs(CLOUD_WIND_DIR.x) >= abs(CLOUD_WIND_DIR.y) ? vec3(0.67, 1.0, 1.0) : vec3(1.0, 1.0, 0.67);
// 群れの中の小片の被覆。形状ノイズの上側の裾は狭く、閾値 1 - 被覆の 0.05 の差で量が大きく変わる
// (0.45 で空を覆う筋、0.225 でほぼ無し) ので、CLOUD_FRACTUS は被覆には弱く (0.75 + 0.25 x)、濃さに 1 以下で効かせる
const float CLOUD_FRACTUS_COVER = 0.38;
const float CLOUD_FRACTUS_AMOUNT = CLOUD_FRACTUS * CS_FRACTUS;
const vec2 CLOUD_FRACTUS_GROUP = vec2(0.48, 0.68);       // 群れを置く fbm の範囲 (高いほどまばら)
const vec2 CLOUD_FRACTUS_DENSITY = vec2(0.05, 0.25);      // 群れの中の濃さのばらつき (積雲の芯に対する割合)
const float CLOUD_AC_BASE = 0.2;          // 中層の中での高積雲の底 (相対高度)
const float CLOUD_MID_SHADOW = 0.5;       // 中層が下の層に落とす影の強さ (中層の厚みに対する光路の割合)
// 削りすぎると中景の雲が小さな破片に分かれたポップコーン状になるので、丸くまとまった積雲 (iterationT の雲の見え方) を狙い、
// こぶ (BILLOW) は残して形と縁の浸食は控えめにする
const float CLOUD_SHAPE_EROSION = 0.6;    // 低周波ノイズで削る量
const float CLOUD_BASE_KEEP = 0.35;        // 雲底での削りの割合 (底を平らで一番広く保つ)
const float CLOUD_BASE_KEEP_REACH = 0.45; // この雲の中の高さで削りの割合が 1 に戻る
const float CLOUD_BILLOW_SCALE = 0.08;    // 中間スケールのこぶの周期 (形状ノイズの周期に対する割合。既定で 1 km 周期 = こぶ 200-400 m)
const float CLOUD_BILLOW_EROSION = 0.8 * CLOUD_LOW_EROSION * CS_LOBES; // 中間スケールのこぶで削る量
// 積雲の塔の塊: 周期 (形状ノイズの周期に対する割合。畳みの周期を割り切る 1/50。既定で 4.3 km 周期 = 塊 0.4-0.8 km) と削る量
const float CLOUD_TURRET_SCALE = 0.4;
const vec3 CLOUD_TURRET_NOISE_OFFSET = vec3(0.13, 0.57, 0.31);
const float CLOUD_TURRET_EROSION = 0.5 * CS_LOBES;
const float CLOUD_TURRET_BASE = 0.4;  // 雲底での削りの割合 (底の近くの側面も 3D の塊で区切り、2D の足跡の縦の壁にしない)
const vec2 CLOUD_BILLOW_PROFILE = vec2(0.7, 1.5);  // こぶで削る量の雲底 / 雲頂での倍率
// 塔の塊とこぶの削りの輪郭の鋭さ。削る量を (1 - Worley) の CLOUD_LOBE_SHARPNESS 乗にし、平均の削りが一次と同じになるよう
// CLOUD_LOBE_SHARP_GAIN を掛ける (g の分布で E[1-g] / E[(1-g)^2] = 1.68)。一次ではこぶの真ん中まで薄く削れて、
// こぶどうしの境目が浅い起伏にしか見えない。2 乗にするとこぶの中は丸く残り、境目の谷だけが深く切れて段がはっきりする
const float CLOUD_LOBE_SHARPNESS = 2.0;
const float CLOUD_LOBE_SHARP_GAIN = 1.68;
const float CLOUD_DETAIL_EROSION = 0.55 * CLOUD_LOW_EROSION * CS_EROSION; // 高周波ノイズで削る量
const float CLOUD_DETAIL_REACH = 0.9;     // 高周波ノイズが効く縁の深さ (形状ノイズで削った後の密度で測る)
// m: curl ノイズで侵食ノイズを歪める量。雲底に集中させ (iterationT: 底 100 m / 頂 0)、底はちぎれて巻き上がり上面はなめらかにする
const float CLOUD_CURL_AMOUNT = 200.0;
const float CLOUD_CURL_TOP = 0.15;        // 雲頂での歪みの残り (底に対する割合)
// 縁の浸食の距離 LOD (m)。細かいオクターブほど近くで消す (画素より細かい浸食は縁のざらつき・ちらつきになる)
const vec2 CLOUD_DETAIL_FADE_FINE = vec2(2000.0, 6000.0);
const vec2 CLOUD_DETAIL_FADE = vec2(6000.0, 18000.0);
const float CLOUD_MID_PATCH_SOFTNESS = 0.45; // 中層の群れの被覆の立ち上がり幅
const float CLOUD_MID_EDGE_WIDTH = 0.85;  // 中層の密度の立ち上がり幅 (薄い小塊なので低層より柔らかく。狭いと粒の輪郭が硬く見える)
const float CLOUD_MID_GRAIN_THIN = 0.25;  // 小さな粒 (群れの縁) の密度の割合
const float CLOUD_MID_GRAIN_SHADE = 0.25; // 粒の底の沈め (雲の中の高さの下限)
// 形状ノイズ / 細かいノイズで削る量。0.5 / 0.25 では大きな粒がなめらかなドームのまま残り、薄い低層越しに
// 逆光の縁だけ光る泡のような輪郭が見える
const vec2 CLOUD_MID_ERODE = vec2(0.75, 0.4);
const vec2 CLOUD_MID_RAIN_VEIL = vec2(0.05, 0.4); // 雲の中の雨天度 (rainLight) のこの範囲で中層を高層雲へ移す
// 縁の密度勾配: 縁は周りの乾いた空気と混ざって薄く、上昇流の芯ほど濃い。
// 縁の立ち上がり CLOUD_EDGE_WIDTH の間に CLOUD_EDGE_DENSITY まで、そこから CLOUD_CORE_DEPTH かけて 1 へ
// (立ち上がりの 3 乗で一気に飽和させると、どの雲も輪郭のはっきりした硬い綿に見える)
// 消散係数が芯の実測の 1/3 なので幅を広めにして、縁の淡い所を厚くし、ふわっとした輪郭と中の濃淡を出す
const float CLOUD_EDGE_SOFT = CLOUD_EDGE_SOFTNESS * CS_EDGE;
const float CLOUD_EDGE_WIDTH = 0.35 * CLOUD_EDGE_SOFT;
const float CLOUD_EDGE_DENSITY = 0.25;
const float CLOUD_CORE_DEPTH = 0.9 * CLOUD_EDGE_SOFT;
// 外殻のもや: 縁の外へ、浸食前の雲量が負の所まで薄いもやを広げる (縁の混合で薄まった雲粒の層)。
// 輪郭で密度が 0 から立ち上がると、どの積雲も境界のはっきりした綿の物体に見える。
// CLOUD_HAZE_REACH: 雲量 (浸食後) の負側へ伸ばす幅, CLOUD_HAZE_DENSITY: 輪郭 (雲量 0) でのもやの密度,
// CLOUD_HAZE_SWELL: 粗い形状ノイズで外殻の厚みを場所ごとに変える量 (一様な厚みの殻だと輪郭をなぞった縁取りに見える)。
// 晴天の積雲だけに付ける (雨天・層積雲・積乱雲は輪郭で打ち切る)。幅を 1.4 / 指数 1 まで広げると、足跡の縁 (2D のセルを縦に
// 伸ばした面) がもやの幕の垂直な切り口として見える
// 芯が濃く塊の輪郭がはっきりしているので、1.2 では塊の間がもやで埋まる。塊の間に青空 (上空の 45-68% 程度) が残る 0.8 にし、
// 輪郭の外のもやは狭めるだけで残す
const float CLOUD_HAZE_REACH = 0.8 * CLOUD_EDGE_SOFT;
const float CLOUD_HAZE_DENSITY = 0.15 * CLOUD_EDGE_HAZE * CS_HAZE;
const float CLOUD_HAZE_SWELL = 0.7;
const float CLOUD_HAZE_FALLOFF = 1.75; // もやが外へ消える曲線の指数 (大きいほど輪郭の近くに寄る)
// 雨天度 (CloudContext.rain) のこの範囲で、晴天の積雲の見た目 (もや・芯の上限・濃さ) から雨雲の見た目へなめらかに移す。
// 0-0.4 で一気に移すと、雨上がりの rainWetness が残る間 (雨天度 0.1-0.4) に小さな雲だけが濃く縁のくっきりした白い欠片になる
const vec2 CLOUD_HAZE_RAIN = vec2(0.15, 0.75);
// 雨天の濃さの倍率 (CloudContext.densityScale) を効かせ始める雨天度の範囲
const vec2 CLOUD_RAIN_DENSITY = vec2(0.0, 0.5);
// 晴天の積雲の立ち上がりと芯までの幅 (外殻のもやに合わせて広げる。雨天・層積雲・積乱雲は上の値のまま)
// (幅が広いと濃さ 0.25 では雲の中がどこも縁と同じ淡さになり、塊の輪郭が無いもやに見える。
// 芯の上限 CLOUD_CORE_DENSITY とは別に、塊の表面から芯までを詰めてこぶの輪郭を出す。外のもやは別に持つ)
const float CLOUD_CU_EDGE_WIDTH = 0.25 * CLOUD_EDGE_SOFT;
const float CLOUD_CU_CORE_DEPTH = 0.5 * CLOUD_EDGE_SOFT;
// 積雲の芯の密度の上限と、芯の中のこぶ単位の濃淡 (芯まで 1 で飽和させると、中まで一様に白い塊になる)。
// 層積雲・積乱雲は上限を 1 のまま (雨天・雷雨の暗く重い雲を保つ)
// 0.7: 0.35 ではこぶ 1 つ (200-400 m) を抜ける光学的厚さが 1 前後で、視線が日の当たる表面で止まらず奥の陰と
// 後ろの空まで透け、どのこぶも同じ灰色のもやに見える。芯だけを濃くし、縁の立ち上がり・外殻のもや・CLOUD_LOW_DENSITY とは別に持つ。
// 設定は平方根で効かせる (一次では 1.5 以上が上限 1 に張り付いて同じ見た目になる。0.25 で芯 0.35)
const float CLOUD_CORE_DENSITY = min(0.7 * sqrt(CLOUD_CORE_STRENGTH * CS_CORE), 1.0);
// 芯を濃くするのは浸食前の雲量 (ドーム) がこの範囲で十分ある塊の中だけ。浸食で切り離された小片・小さな雲・セルの縁は
// 芯の半分の CLOUD_CORE_DENSITY_THIN (既定で 0.35) のまま淡く残す (全部を濃くすると、夕方の順光で縁の小片が白い粒の群れになる)
const float CLOUD_CORE_DENSITY_THIN = 0.5 * CLOUD_CORE_DENSITY;
const vec2 CLOUD_CORE_BODY = vec2(0.3, 0.8);
const float CLOUD_CORE_MOTTLE = 0.5;
// 光源方向の光学的深さ (と地面の雲影) で使う芯の上限。視線の密度と同じだけ下げると、芯の陰が浅くなり
// 下側の灰色が消えて平板に見える (CLOUD_LIGHT_OD_SCALE と同じく、陰影は芯の実測の消散係数に合わせる)
const float CLOUD_CORE_DENSITY_LIGHT = 1.0;

// 積乱雲 (参照空間の高さの割合 hc = 雲底 0 / CLOUD_R_CB_TOP 1)
const float CLOUD_CB_ANVIL_BASE = 0.8;    // かなとこの下面
const float CLOUD_CB_ANVIL_TOP = 0.93;    // かなとこの上面 (対流圏界面)
const float CLOUD_CB_ANVIL_LENGTH = 9000.0 * CLOUD_CB_ANVIL; // m: かなとこが風下へ伸びる長さ
const float CLOUD_CB_MAMMA = 0.06;        // 乳房雲がかなとこの下面から垂れる深さ
// 塔の芯の液水量 (積雲に対する倍率)。晴天の積雲を薄くしたぶん高くして、晴れた日の遠い積乱雲は濃い塔のまま
const float CLOUD_CB_WATER = 2.5 * CLOUD_CB_DENSITY;
const float CLOUD_CB_WARP = 1200.0;       // m: 嵐の芯を読む位置の揺らし (塔の側面のうねり)
const float CLOUD_CB_LUMP_SCALE = 0.35;   // 塔の側面の大きなこぶの周期 (形状ノイズの周期に対する割合)
const float CLOUD_CB_LUMP_EROSION = 0.55;
// 降水の柱 (雨脚)。雲底から地面まで、嵐の芯の下に濃い灰色の幕
const float CLOUD_SHAFT_SIGMA = 6.0e-4 * CLOUD_CB_RAIN_SHAFTS; // 1/m: 5 km 抜けて光学的厚さ 3
const float CLOUD_SHAFT_NEAR = 1500.0;    // m: これより手前の雨はバニラの雨と霧に任せる
const float CLOUD_SHAFT_FAR = 60000.0;
const float CLOUD_SHAFT_SLANT = 0.35;     // 雨が風に流されて斜めに落ちる (落下 1 m あたりの水平のずれ)

// 光
// べき乗則透過率 (1 + od/k)^-k の k。小さいほど厚い雲の奥まで光が届く。消散係数が芯の実測の 1/3 なので、陰の側が締まるよう 3
const float CLOUD_HETEROGENEITY = 3.0;
// m: 多重散乱が育つのに要る局所の厚み (縁を暗くする powder の効き)。光学的厚さで同じ効きになるよう消散係数に反比例させる (実測の消散係数で 120)
const float CLOUD_MS_LENGTH = 360.0;
const float CLOUD_MS_ATTENUATION = 0.45;  // オクターブごとの光学的深さの倍率 (Wrenninge の a)
const float CLOUD_MS_CONTRIBUTION = 0.55; // オクターブごとの寄与 (b)
const float CLOUD_MS_ECCENTRICITY = 0.5;  // オクターブごとの位相の非対称性 (c)
const float CLOUD_MS_DIFFUSION = 0.1;     // 光学的深さの倍率の下限 (拡散近似の減衰 sqrt(3(1-g)(1-albedo)) 程度)
// 見た目の基準のオクターブ数。CLOUD_MULTISCATTER がこれより少ない時は、残りの寄与を最後のオクターブにまとめる
// (オクターブ数で厚い雲の奥の明るさが変わらないようにして、品質で変えるのを重さだけにする)
const int CLOUD_MS_REF_OCTAVES = 8;
// 高次の散乱のエネルギー。単散乱 + 数オクターブでは厚い雲の日なたが暗すぎるので、局所の厚みに応じて
// 残りの次数の和 (アルベドの等比級数) を見込んで底上げする (Hillaire 2016 のエネルギー補正と同じ考え方)
// 小さいと晴天の雲が全体に暗く、日向の頂も白くならず灰色寄りになる。環境光の底上げ (CLOUD_AMBIENT_MS)・雲底の残り (CLOUD_BOTTOM_*)・
// powder と合わせて、日向の頂が白く見える明るさにする
const float CLOUD_MS_GAIN = 6.0;
const float CLOUD_ANISO_DECAY = 0.15;     // 光学的深さ 1 あたりの位相の非対称性の減り方
const float CLOUD_AMBIENT_MS = 1.2;       // 環境光の多重散乱による底上げ
// 空の光の拡散透過 1 / (1 + k od) の k (保存散乱の 2 流近似 0.75(1-g))。
// べき乗則のままだと厚い雲の底で空の光がほぼ 0 になり、夕方は暗い橙の太陽光だけが残って茶色い塊に見える
const float CLOUD_AMBIENT_DIFFUSION = 0.2;
// 光源方向の光学的深さの倍率。消散係数を芯の実測の 1/3 にしても、雲の陰の側と底の陰影 (立体感) を残す
// (視線方向だけ薄くして縁を透かし、自己遮蔽は濃いまま。1 では夜の雲が陰の無い平板な白になる)。
// 3 で、濃さ 0.25 の既定でも塊の日の当たる頂と陰の側・底の明暗でもっこりした立体に見える
const float CLOUD_LIGHT_OD_SCALE = 3.0;
// 光源方向と視線方向の消散係数の比 (スタイルの濃さ CS_DENSITY が視線をこれ以上濃くした時だけ、光源方向も濃くする)
const float CLOUD_STYLE_LIGHT_SIGMA_RATIO = CLOUD_LOW_SHADE_SIGMA * CLOUD_LIGHT_OD_SCALE / CLOUD_LOW_SIGMA;
// 低層の真上 (空の光) 方向の光学的深さの倍率。光源方向 (CLOUD_LIGHT_OD_SCALE) と同じく、雲の中へ入るほど空の青い光が減って
// 塊の下側と奥が沈むようにする (1 では濃さ 0.25 の雲の陰の側が空の光で明るく均され、立体感が出ない)
const float CLOUD_SKY_OD_SCALE = 2.5;
const float CLOUD_LIGHT_STEP0 = 24.0;     // m: 光方向マーチの最初の歩幅 (毎回 2 倍)
// こぶの陰。多重散乱のオクターブは光学的深さを 0.45 倍ずつ薄めて読むので、こぶ 1 つ分の自己遮蔽がほぼ消え、
// 日の当たるこぶと陰のこぶが同じ灰色に均される。光源方向の先頭 CLOUD_LOBE_STEPS 歩 (24 + 48 + 96 + 192 m = こぶの大きさ)
// の光学的深さ odNear で、多重散乱にも exp(-CLOUD_LOBE_SHADE x odNear) の陰を付ける。遠くの厚み (雲全体の陰) はオクターブごとに薄めて読む
const int CLOUD_LOBE_STEPS = 4;
// 雲の暗い側 (p10) が明るい側の 0.3-0.46 程度の浅い陰を狙う (Bliss の普通のワールドの雲の見え方)。
// 0.5 では 0.18-0.35 と深すぎ、望遠で背の高いこぶの側面に縦の明暗の境も出やすい
const float CLOUD_LOBE_SHADE = CS_LOBE_SHADE;
// 銀の縁: 太陽方向の光を後段で 1 + k HG(g) 倍する (iterationT の (hg*2+1))。位相関数の和だけでは
// 光学的に薄い逆光の縁が際立たない。単散乱には全量、多重散乱には CLOUD_SILVER_MS の割合だけ掛ける
const float CLOUD_SILVER_BOOST = 2.0 * CLOUD_SILVER_LINING;
const float CLOUD_SILVER_G = 0.7;
const float CLOUD_SILVER_MS = 0.4;
// 密度キーの powder: 散乱体の少ない縁は内側からの多重散乱を受けないので、順光で見ると暗い縁取りになる
// m。100 では芯でも exp(-0.4) 程度で、縁だけでなく雲全体が一様に暗くなる。
// 芯 (密度 0.7) で効きがほぼ 0、縁のもや (0.15) で半分残る長さにして、順光で日の当たるこぶは白く、こぶの縁だけ灰色に縁取る
const float CLOUD_POWDER_LENGTH = 700.0;
const float CLOUD_POWDER_STRENGTH = min(0.4 * CLOUD_POWDER, 1.0); // 順光 (太陽を背にした時) での効き
// 暗く重い底: その雲の中の高さ (底 0 / 頂 1) で多重散乱と空の光を落とす。底の光は厚い雲を何度も散乱して
// 横へ逃げながら届くので、光方向の光学的深さだけで見積もるより暗い (iterationT の底 0.15 + pow(h, 0.75) 相当)
const float CLOUD_BOTTOM_REACH = 0.6;    // この高さで 1 に戻る

#if CLOUD_QUALITY == 0
    const int CLOUD_LOW_STEPS = 24;
    const int CLOUD_MID_STEPS = 8;
    // 光源方向と真上方向の歩数は 1 と同じ (減らすと厚い雲の奥と陰の側が明るくなり、形と陰影が品質で変わる)。減らすのは視線方向だけ
    const int CLOUD_LIGHT_STEPS = 6;
    const int CLOUD_SKY_STEPS = 2;
    const int CLOUD_HIGH_STEPS = 3;
    const int CLOUD_SHAFT_STEPS = 6;
    const int VANILLA_CLOUD_STEPS = 24;
    const int VANILLA_CLOUD_MAX_ITER = 64;
    const int VANILLA_CLOUD_LIGHT_STEPS = 3;
#elif CLOUD_QUALITY == 1
    const int CLOUD_LOW_STEPS = 36;
    const int CLOUD_MID_STEPS = 12;
    const int CLOUD_LIGHT_STEPS = 6;
    const int CLOUD_SKY_STEPS = 2;
    const int CLOUD_HIGH_STEPS = 3;
    const int CLOUD_SHAFT_STEPS = 8;
    const int VANILLA_CLOUD_STEPS = 32;
    const int VANILLA_CLOUD_MAX_ITER = 80;
    const int VANILLA_CLOUD_LIGHT_STEPS = 4;
#elif CLOUD_QUALITY == 2
    const int CLOUD_LOW_STEPS = 48;
    const int CLOUD_MID_STEPS = 16;
    const int CLOUD_LIGHT_STEPS = 6;
    const int CLOUD_SKY_STEPS = 2;
    const int CLOUD_HIGH_STEPS = 4;
    const int CLOUD_SHAFT_STEPS = 10;
    const int VANILLA_CLOUD_STEPS = 48;
    const int VANILLA_CLOUD_MAX_ITER = 96;
    const int VANILLA_CLOUD_LIGHT_STEPS = 5;
#else
    const int CLOUD_LOW_STEPS = 64;
    const int CLOUD_MID_STEPS = 24;
    const int CLOUD_LIGHT_STEPS = 7;
    const int CLOUD_SKY_STEPS = 3;
    const int CLOUD_HIGH_STEPS = 6;
    const int CLOUD_SHAFT_STEPS = 12;
    const int VANILLA_CLOUD_STEPS = 64;
    const int VANILLA_CLOUD_MAX_ITER = 128;
    const int VANILLA_CLOUD_LIGHT_STEPS = 5;
#endif
const int CLOUD_MID_LIGHT_STEPS = CLOUD_QUALITY >= 2 ? 4 : 3;

#endif
