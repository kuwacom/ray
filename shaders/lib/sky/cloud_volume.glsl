/*
 * 体積雲の形状・ライティング・レイマーチ (sky モジュール, prepare2 / deferred20 だけが include する)
 *
 * 層 (高さは clouds.glsl。形と光はすべて「参照空間」= 現実の雲の寸法 (m) で決め、高さテンプレートは写像だけを変える)
 *   低層: 積雲 (扁平雲 -> 並雲 -> 雄大雲。大中小のセルをべき乗則の割合で重ねる) / 層積雲 / 雨天の乱層雲
 *         / 積乱雲 (CLOUD_CUMULONIMBUS。雷雨と熱帯の午後。塔・かなとこ・オーバーシュート・乳房雲・降水の柱)
 *         / 断片雲 (CLOUD_FRACTUS。濃い雲の周りに群れで散らばる薄いちぎれ雲)
 *   層ごとの量・濃さ・大きさ・浸食・風は settings.glsl の CLOUD_LOW_* / CLOUD_MID_* / CLOUD_HIGH_* / CLOUD_CB_*
 *   中層: 高積雲 (うろこ状の小塊) / 高層雲 (一様なベール)。CLOUDS=3 かつ CLOUD_QUALITY>=1 (CLOUD_MID_LAYER)
 *   上層: 巻雲 (薄い体積。房から落ちる氷晶の筋を風のシアで傾ける) / 巻積雲 / 巻層雲 (ベールと控えめな 22 度ハロ) (CLOUD_CIRRUS)
 *
 * 形状 = 天気図 (被覆と雲種) x 2D のセル x 雲種ごとの高さプロファイル - 低周波 3D Perlin-Worley - 高周波 3D Worley (curl で歪める)
 *   cloudWeatherImg (512^2 RGBA8, prepare2 がカメラ中心に毎フレーム作る非周期の天気図, 1 テクセル 256 m)
 *     r = 低層の被覆, g = 低層の雲種 (0 層状 / 0.5 積雲 / 0.75-1 積乱雲 (1 が嵐の中心)), b = 中層の被覆, a = 上層の被覆 (被覆は 1/CLOUD_COVER_RANGE 倍)
 *   静的ノイズ (tools/gen_cloud_noise.py, shaders.properties の customTexture)
 *     cloudShapeTex  128^3 RG8   r = Perlin-Worley, g = Worley fbm
 *     cloudDetailTex  64^3 RGBA8 r = 高周波 Worley fbm, gba = curl ノイズ
 *     cloudNoiseTex  512^2 RGBA8 r = 積雲のセル (大), g = なめらかな fbm, b = 積雲のセル (中), a = 細かいセル (各チャンネルは一様分布)
 *   周期ノイズの繰り返しは、非周期の天気図による地域差と層ごとに異なる周期・風で目立たなくする
 *
 * 光: 指数的に伸ばす光方向マーチ (Kappa) + 多重散乱のオクターブ和 (Wrenninge 2015)
 *   位相関数は水滴の Mie の近似 HG + Draine (Jendersie & d'Eon 2023, 液滴径 20 um) + 弱いグローリー。
 *   前方の鋭い回折ピークが逆光の銀の縁を、Draine の後方の盛り上がりが順光の明るさを作る。
 *   各オクターブの透過率は指数ではなくべき乗則 (1 + od/k)^-k (未解像の密度ムラがある媒質の透過率。Nostalgia の 1/(1+od) の一般化) で、
 *   厚い雲の奥や底が真っ黒にならない。位相の非対称性は光学的深さとともに弱める (Kappa / Nostalgia)
 *   局所の厚みが無い縁では多重散乱が育たないので暗くなる (powder の物理的な解釈)
 *   環境光は空の SH (上) と地面の照り返し (下)。上の層は下の層に影を落とす
 *   見た目の押し出し (iterationT を参考): 前方の光の後段ブースト (銀の縁) / 密度キーの powder / 雲の中の高さで沈める暗い底
 *   空中遠近は雲までの指数大気の透過率と、空の色 (SkyView LUT) のうち雲より手前の取り分で溶かす (時刻・方位の色になる)
 *
 * マーチはワールドの視線で歩き、各サンプルの位置・歩幅・光の向きを参照空間へ写す (clouds.glsl の cloudRef*)。
 * 関数の rel / altitude / 距離は特に断りがなければ参照空間 (m)
 */
#ifndef SKY_CLOUD_VOLUME_GLSL
#define SKY_CLOUD_VOLUME_GLSL

uniform sampler3D cloudShapeTex;
uniform sampler3D cloudDetailTex;
uniform sampler2D cloudNoiseTex;

#if CLOUDS == 3 && CLOUD_QUALITY >= 1
    #define CLOUD_MID_LAYER
#endif
#if CLOUDS == 3 && defined CLOUD_CUMULONIMBUS
    #define CLOUD_CB
#endif

/*------------------------------------------------------------------------------
  定数
------------------------------------------------------------------------------*/
// 天気図: カメラ中心の 512^2。テクセル単位に原点を丸めて、カメラが動いても値がちらつかないようにする
const float CLOUD_MAP_RES = 512.0;
const float CLOUD_MAP_TEXEL = 256.0; // m
// 被覆は 1/CLOUD_COVER_RANGE 倍して RGBA8 に入れる (1 を超えると隙間なく全天を覆う)
const float CLOUD_COVER_RANGE = 1.4;

// 大きさ。既定の CLOUD_SCALE 1.6 を基準 1.0 とする
const float CLOUD_SCALE_FACTOR = CLOUD_SCALE / 1.6;
// 層ごとのノイズ周期の公倍数 (m)。カメラ - 風をこれで畳んでからサンプル位置に足すと、遠い座標でも精度が落ちず畳み目で継ぎ目も出ない
// CLOUD_LOW_SIZE: 低層の雲ひとつひとつの大きさ (セル・塊・ロール) の倍率。縁の浸食・curl・断片雲は現実のこぶの寸法のまま保つ
// (1 -> 1.25。周期を割り切るため 32 / 160 / 640 x CLOUD_LOW_SIZE は整数にする)
const float CLOUD_LOW_SIZE = 1.25;
const float CLOUD_LOW_TILE = 92160.0 * CLOUD_LOW_SIZE * CLOUD_SCALE_FACTOR * CLOUD_LOW_SCALE;
// 積雲のセル: r = 大 (8 個 / 周期, 雲 1.5-3 km), b = 中 (18 個, 0.7-1.4 km), a = 小 (32 個, 0.3-0.8 km)
const float CLOUD_CELL_PERIOD = CLOUD_LOW_TILE / 4.0;
const vec2 CLOUD_ROLL_PERIOD = CLOUD_LOW_TILE / vec2(5.0, 9.0);   // 層積雲: x に少し長いロール (2.3 x 1.3 km 前後)
const float CLOUD_SHAPE_PERIOD = CLOUD_LOW_TILE / 20.0;           // 4.6 km: 塊 0.2-1.1 km
const float CLOUD_CURL_PERIOD = CLOUD_LOW_TILE / (32.0 * CLOUD_LOW_SIZE);           // 2.9 km
const float CLOUD_DETAIL_PERIOD = CLOUD_LOW_TILE / (640.0 * CLOUD_LOW_SIZE);         // 既定 480 m: 縁の浸食 30-120 m (塊の大きさとは別に現実のこぶの寸法に合わせる)
const float CLOUD_MID_TILE = 64000.0 * CLOUD_SCALE_FACTOR * CLOUD_MID_SCALE;
// 高積雲の粒 350 m 前後、まとまり 1.5-3 km (粒が画素に近い大きさだと陰影の無い白い点に見えたので、以前の 8 分の 1 から広げた)
const float CLOUD_MID_PERIOD = CLOUD_MID_TILE / 6.0;
const float CLOUD_MID_SHAPE_PERIOD = CLOUD_MID_TILE / 40.0;       // 1.6 km
const float CLOUD_MID_DETAIL_PERIOD = CLOUD_MID_TILE / 128.0;     // 500 m
const float CLOUD_HIGH_TILE = 96000.0 * CLOUD_SCALE_FACTOR * CLOUD_HIGH_SCALE;
const float CLOUD_HIGH_PATCH_PERIOD = CLOUD_HIGH_TILE / 2.0;      // 48 km: 巻雲の群れ
const float CLOUD_CC_PERIOD = CLOUD_HIGH_TILE / 16.0;             // 6 km: 巻積雲の粒 100-190 m
// 巻雲の房 (風向きの座標 (2, 1) で読む 3D Perlin-Worley): 風下に 2 倍長い幅の広い刷毛 (細い長い房は下から放射状の筋に見えた)
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
// 0.07 (芯の実測値) では縁まで不透明な粘土の塊に見えた。晴天の雲は 1/3 にして縁を淡く透かし、
// 雨雲・雷雨は CloudContext.densityScale で以前の濃さへ戻す。
// 設定の濃さ CLOUD_LOW_DENSITY の既定は 1.0 -> 0.25 (今の最低値がちょうど良い。晴天の芯 0.024 x 0.25)
#if CLOUDS == 3
    const float CLOUD_LOW_SIGMA = 0.024 * CLOUD_LOW_DENSITY;
    // 光源・空の方向の光学的深さ (自己遮蔽の陰) の消散係数。濃さ 1 未満では視線の sqrt でしか薄めない (
    // 濃さ 0.25 を既定にした時、陰まで 1/4 にすると雲の中が一様に明るい平板なもやになり、こぶごとの陰と暗い底が消えた)
    const float CLOUD_LOW_SHADE_SIGMA = 0.024 * max(CLOUD_LOW_DENSITY, sqrt(CLOUD_LOW_DENSITY));
#else
    // 2D 押し出しの雲は濃さの既定を 1.0 -> 0.25 にした時に係数を 4 倍にして、既定の見た目を変えない
    const float CLOUD_LOW_SIGMA = 0.32 * CLOUD_LOW_DENSITY;
    const float CLOUD_LOW_SHADE_SIGMA = CLOUD_LOW_SIGMA;
#endif
// 高積雲 (光学的厚さ 1-10)。薄すぎると陰影の無い白い粒になる。
// 低層の濃さの既定を 1/4 にした後は 0.025 では低層より 4 倍濃く、薄い積雲越しに硬い白い小石の粒が透けて見えたので 0.007
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
// 吸収込みで厚い層をほぼ真っ暗にするので、曇天の夜は空が地面より暗い黒い面になった
const float CLOUD_OVERCAST_DIFFUSE = 1.0;
// 雲の空中遠近: 雲までの大気 (atmosphere.glsl の指数大気) の透過率と、その方向の空の内散乱の取り分で空へ溶かす。
// 固定の消散係数で青く霞ませていた時は、夕方も地平線の雲が青白いまま空から浮いていた (iterationT の GetSkyRadianceToPoint 相当)
// 実大気のままだと地表近くのもや (境界層のエアロゾル) が無いぶん遠い雲が残りすぎるので、Mie を濃くする
const float CLOUD_AERIAL_RAYLEIGH = 1.6;
const float CLOUD_AERIAL_MIE = 5.0;
const float CLOUD_AERIAL_RAIN = 1.0;  // 雨の日のもやの増え方 (Mie の倍率への加算)
const float CLOUD_MAX_DISTANCE = CLOUD_DRAW_DISTANCE * 1000.0;
const float CLOUD_HIGH_MAX_DISTANCE = 160000.0;
const float CLOUD_MIN_TRANSMITTANCE = 0.02;

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
const float CLOUD_FOOTPRINT_WARP = 450.0; // m: 2D の被覆を高さごとにずらす量 (層を 3 km に厚くした時に 300 から。背の高い雲の側面が縦の幕の筋に見えた)
// 積雲の背の高さがセルの値の幅いくつで最大になるか (大きいほど丸いドーム)。0.7 -> 0.5
// (0.7 では背の高い雲が中心の 1 点へ細る尖った塔になった。頂を広く丸くして、こぶは CLOUD_TURRET で作る)
const float CLOUD_DOME_WIDTH = 0.5;
const float CLOUD_BASE_TUCK = 0.05;       // 積雲の底の近くで被覆から引く量 (底の縁が巻き上がる)
const float CLOUD_BASE_RAMP = 60.0;       // m: 雲底の立ち上がり (持ち上げ凝結高度で一斉に雲になるので底が平ら)
// 雲底の高さの地域差 (m)。凝結高度は湿りで変わるので、遠くの雲ほど底の高さがずれて、平らな底が段々に並んで見えない
const float CLOUD_BASE_VARIATION = 110.0;
// 雲底の乱流 (m): curl で雲底の高さを上下に揺らし、下だけちぎれた底にする (雲頂ほど弱い)
const float CLOUD_BASE_RAGGED = 70.0;
const float CLOUD_STRATUS_UNDULATION = 150.0; // m: 層状の雲の底の波打ち
// 積雲の大きさの分布 (べき乗則): 被覆を大中小のセルに分ける割合。小さい雲ほど数が多く (セルが 2.3 倍 / 4 倍細かい)、
// 面積の割合は小さい。全部同じ大きさの綿が並ぶのが一番偽物に見える (real-clouds.md 3.3)
// 大 0.9 では湿った日 (被覆 0.5-0.78) に大きなセルどうしがつながり、横に長いソーセージ状の雲が並んだ。
// 大を減らして中を増やし、間の空いた個々の積雲にする (iterationT の雲の並び)
// 大 0.7 -> 0.55 / 中 0.5 -> 0.55 / 小 0.25 -> 0.3 (大きな雲の幅を詰め、背丈が幅と同じくらいの並雲・雄大雲を増やす)
const vec3 CLOUD_CU_SHARE = vec3(0.55, 0.55, 0.3);
// 大中小の雲の背の高さの割合 (小さいものほど扁平雲)。最下層の雲に厚みを持たせた時に 0.6 / 0.35 から上げた。
// 層を 4.5 km にした時に中 0.8 -> 0.5 / 小 0.55 -> 0.3 (中小のセルは幅 0.7-1.7 km なので、0.8 のままでは
// 幅の 2 倍の細い炎のような塔が大きな雲から突き出た。中小は背丈が幅と同じくらいまで)
// 実機確認で頂を広く丸くした (CLOUD_DOME_BASE) 後は炎のような塔にならないので、中 0.5 -> 0.65 / 小 0.3 -> 0.4 に戻した
// (0.5 では飛んで低層の中ほど y 300 から見ても、雲頂がどれも目の高さより下に揃っていた)
const vec3 CLOUD_CU_HEIGHT = vec3(1.0, 0.65, 0.4);
// 積雲の背丈 (低層の厚みに対する割合): 対流の強さ 0 / 1 での基準と、隣どうしのばらつき (なめらかな fbm で x (1 +- SPREAD / 2))。
// 下限 0.4 -> 0.6・ばらつき 0.5 -> 0.8 (並の日の積雲が扁平雲の平たい帯ばかりで厚みが無かった。並雲が主で、時々雄大雲寄りに背の高い雲が混ざる)。
// シュークリームのようにもっこりと背の高い雲にするため層を 3 -> 4.5 km にし、0.5, 0.95 -> 0.5, 1.0・ばらつき 0.8 -> 1.0
// (並の日の大きな雲の頂は 1.7-4.1 km、低い雲と背の高い雲が混ざる)
const vec2 CLOUD_CU_TOP = vec2(0.5, 1.0);
const float CLOUD_CU_TOP_SPREAD = 1.0;
// 背丈の上限。層の上端 (h = 1) で頂が平らに切れないよう、この手前でなめらかに頭打ちにする (雲底の持ち上げ 0.05 の分も空ける)
const float CLOUD_CU_TOP_MAX = 0.92;
// 層積雲の頂の高さ (低層の厚みに対する割合): 晴れ / 雨。晴れ 0.16 (350 m) では湿った日・夕方の層積雲が薄い板に見えた (現実は 0.2-1 km)
// (層を 4.5 km にした時に 0.22, 0.5 から、高さ 660 m / 1.5 km のまま割合だけ直した)
const vec2 CLOUD_SC_TOP = vec2(0.15, 0.33);
// ドームの細り方の指数 (大きいほど側面が立ち、頂の近くで丸まる)。1.6 -> 2 (ふくらんだ側面と丸い頂。
// 2.4 では 2D の足跡を縦に伸ばした側面が縦の幕の筋になった)
const float CLOUD_DOME_POW = 2.0;
// ドームの雲量 (浸食前) の倍率 (実機確認)。1 では浸食 (形状・塔・こぶ・細かい浸食で計 0.7 前後) が
// ドームの雲量と同じ桁で、見える頂がドームの 2/3 の高さで止まり、中も縁と同じ淡さの平たいもやに見えた。
// 2 倍して見える頂を上げ、中を芯の濃さまで詰める (縁の外のもやの幅は変えない)
const float CLOUD_DOME_GAIN = 2.0;
// セルの縁での背の高さの割合 (中心で 1)。0.42 では背の高さが中心の 1 点へ向かって伸び、頂が尖った炎のような塔になった
const float CLOUD_DOME_BASE = 0.7;
// 倍率で外へ広がった輪郭を戻す量 (浸食の平均程度。0 では晴れの日の雲量が 1.5 倍になり、空がほぼ埋まった)
const float CLOUD_DOME_OFFSET = 0.5;
// 3D の塔の塊のノイズでセルの値を揺らす量。2D のセルの値だけで側面を決めると、ドームを濃くした時に縦に伸ばした
// 平らな壁と縦の筋 (望遠で目立つ) になったので、高さごとに張り出しの違うこぶの側面にする
const float CLOUD_LUMP_V = 0.2;
// セルの値から背の高さへの曲線の指数 (1 で中心へ一直線に高くなる円錐、小さいほど縁から早く立ち上がる丸い頂)
const float CLOUD_DOME_ROUND = 0.5;
// 大きな雲の周りは補償の下降流で晴れる: しきい値の手前の幅 CLOUD_CU_CLEARING_WIDTH で小さな雲を減らす割合
const float CLOUD_CU_CLEARING = 0.8;
const float CLOUD_CU_CLEARING_WIDTH = 0.2;
const float CLOUD_CELL_MIN_COVER = 0.12;  // 積雲のセルの形を作る最小の被覆 (これ未満は形を保って薄める)
// 断片雲 (ちぎれ雲・層積雲の切れ端): 雲底の近くの薄い層に、3D 形状ノイズの小片 (150-450 m) を群れの中だけに置く
const float CLOUD_FRACTUS_TOP = 0.1;                     // 層の上端 (低層の厚みに対する割合, 450 m。層を 4.5 km にした時に 0.15 から)
const float CLOUD_FRACTUS_PERIOD = CLOUD_LOW_TILE / (160.0 * CLOUD_LOW_SIZE); // 1.1 km
// 小片を風下の軸 (x か z の近い方) に 1.5 倍伸ばす (ちぎれて流された形。等方だと小さな綿のポップコーンに見えた。
// 2 倍では実機で全天の小片が同じ向きの筋になり、透視で消失点へ集まる流し撮りのような縞に見えた)
const vec3 CLOUD_FRACTUS_STRETCH = abs(CLOUD_WIND_DIR.x) >= abs(CLOUD_WIND_DIR.y) ? vec3(0.67, 1.0, 1.0) : vec3(1.0, 1.0, 0.67);
// 群れの中の小片の被覆。形状ノイズの上側の裾は狭く、閾値 1 - 被覆の 0.05 の差で量が大きく変わる
// (0.45 で空を覆う筋、0.225 でほぼ無し) ので、CLOUD_FRACTUS は被覆には弱く (0.75 + 0.25 x)、濃さに 1 以下で効かせる
const float CLOUD_FRACTUS_COVER = 0.38;
const vec2 CLOUD_FRACTUS_GROUP = vec2(0.48, 0.68);       // 群れを置く fbm の範囲 (高いほどまばら)
const vec2 CLOUD_FRACTUS_DENSITY = vec2(0.05, 0.25);      // 群れの中の濃さのばらつき (積雲の芯に対する割合)
const float CLOUD_AC_BASE = 0.2;          // 中層の中での高積雲の底 (相対高度)
const float CLOUD_MID_SHADOW = 0.5;       // 中層が下の層に落とす影の強さ (中層の厚みに対する光路の割合)
// 以前の 0.7 / 0.7 / 1.2 (近い雲の刷毛の滲み対策) では中景の雲が小さな破片に分かれたポップコーン状になり、
// iterationT の丸くまとまった積雲から遠ざかった。こぶ (BILLOW) は残し、形と縁の浸食だけ少し戻す
const float CLOUD_SHAPE_EROSION = 0.6;    // 低周波ノイズで削る量
const float CLOUD_BASE_KEEP = 0.35;        // 雲底での削りの割合 (底を平らで一番広く保つ)
const float CLOUD_BASE_KEEP_REACH = 0.45; // この雲の中の高さで削りの割合が 1 に戻る
const float CLOUD_BILLOW_SCALE = 0.08;    // 中間スケールのこぶの周期 (形状ノイズの周期に対する割合。既定で 1 km 周期 = こぶ 200-400 m)
const float CLOUD_BILLOW_EROSION = 0.8 * CLOUD_LOW_EROSION; // 中間スケールのこぶで削る量
// 積雲の塔の塊: 周期 (形状ノイズの周期に対する割合。畳みの周期を割り切る 1/50。既定で 4.3 km 周期 = 塊 0.4-0.8 km) と削る量
const float CLOUD_TURRET_SCALE = 0.4;
const float CLOUD_TURRET_EROSION = 0.5;
const float CLOUD_TURRET_BASE = 0.4;  // 雲底での削りの割合 (底の近くの側面も 3D の塊で区切り、2D の足跡の縦の壁にしない)
const vec2 CLOUD_BILLOW_PROFILE = vec2(0.7, 1.5);  // こぶで削る量の雲底 / 雲頂での倍率
const float CLOUD_DETAIL_EROSION = 0.55 * CLOUD_LOW_EROSION; // 高周波ノイズで削る量
const float CLOUD_DETAIL_REACH = 0.9;     // 高周波ノイズが効く縁の深さ (形状ノイズで削った後の密度で測る)
// m: curl ノイズで侵食ノイズを歪める量。雲底に集中させ (iterationT: 底 100 m / 頂 0)、底はちぎれて巻き上がり上面はなめらかにする
const float CLOUD_CURL_AMOUNT = 200.0;
const float CLOUD_CURL_TOP = 0.15;        // 雲頂での歪みの残り (底に対する割合)
// 縁の浸食の距離 LOD (m)。細かいオクターブほど近くで消す (画素より細かい浸食は縁のざらつき・ちらつきになる)
const vec2 CLOUD_DETAIL_FADE_FINE = vec2(2000.0, 6000.0);
const vec2 CLOUD_DETAIL_FADE = vec2(6000.0, 18000.0);
const float CLOUD_MID_PATCH_SOFTNESS = 0.45; // 中層の群れの被覆の立ち上がり幅
const float CLOUD_MID_EDGE_WIDTH = 0.85;  // 中層の密度の立ち上がり幅 (薄い小塊なので低層より柔らかく。粒の輪郭が硬く見えたので 0.55 から)
const float CLOUD_MID_GRAIN_THIN = 0.25;  // 小さな粒 (群れの縁) の密度の割合
const float CLOUD_MID_GRAIN_SHADE = 0.25; // 粒の底の沈め (雲の中の高さの下限)
// 形状ノイズ / 細かいノイズで削る量。0.5 / 0.25 では大きな粒がなめらかなドームのまま残り、薄くした低層越しに
// 逆光の縁だけ光る泡のような輪郭が見えた
const vec2 CLOUD_MID_ERODE = vec2(0.75, 0.4);
const vec2 CLOUD_MID_RAIN_VEIL = vec2(0.05, 0.4); // 雲の中の雨天度 (rainLight) のこの範囲で中層を高層雲へ移す
// 縁の密度勾配: 縁は周りの乾いた空気と混ざって薄く、上昇流の芯ほど濃い。
// 縁の立ち上がり CLOUD_EDGE_WIDTH の間に CLOUD_EDGE_DENSITY まで、そこから CLOUD_CORE_DEPTH かけて 1 へ
// (立ち上がりの 3 乗で一気に飽和させていた時は、どの雲も輪郭のはっきりした硬い綿に見えた)
// 消散係数を 1/3 にした時に 0.2 / 0.35 / 0.6 から広げた (縁の淡い所を厚くして、ふわっとした輪郭と中の濃淡を出す)
const float CLOUD_EDGE_WIDTH = 0.35 * CLOUD_EDGE_SOFTNESS;
const float CLOUD_EDGE_DENSITY = 0.25;
const float CLOUD_CORE_DEPTH = 0.9 * CLOUD_EDGE_SOFTNESS;
// 外殻のもや: 縁の外へ、浸食前の雲量が負の所まで薄いもやを広げる (縁の混合で薄まった雲粒の層)。
// 輪郭で密度が 0 から立ち上がると、どの積雲も境界のはっきりした綿の物体に見えた。
// CLOUD_HAZE_REACH: 雲量 (浸食後) の負側へ伸ばす幅, CLOUD_HAZE_DENSITY: 輪郭 (雲量 0) でのもやの密度,
// CLOUD_HAZE_SWELL: 粗い形状ノイズで外殻の厚みを場所ごとに変える量 (一様な厚みの殻だと輪郭をなぞった縁取りに見える)。
// 晴天の積雲だけに付ける (雨天・層積雲・積乱雲は従来どおり)。幅を 1.4 / 指数 1 まで広げると、足跡の縁 (2D のセルを縦に
// 伸ばした面) がもやの幕の垂直な切り口として見えた
const float CLOUD_HAZE_REACH = 1.2 * CLOUD_EDGE_SOFTNESS;
const float CLOUD_HAZE_DENSITY = 0.15 * CLOUD_EDGE_HAZE;
const float CLOUD_HAZE_SWELL = 0.7;
const float CLOUD_HAZE_FALLOFF = 1.75; // もやが外へ消える曲線の指数 (大きいほど輪郭の近くに寄る)
// 雨天度 (CloudContext.rain) のこの範囲で、晴天の積雲の見た目 (もや・芯の上限・濃さ) から雨雲の見た目へなめらかに移す。
// 0-0.4 で一気に移すと、雨上がりの wetness が残る間 (雨天度 0.1-0.4) に小さな雲だけが濃く縁のくっきりした白い欠片になった
const vec2 CLOUD_HAZE_RAIN = vec2(0.15, 0.75);
// 雨天の濃さの倍率 (CloudContext.densityScale) を効かせ始める雨天度の範囲
const vec2 CLOUD_RAIN_DENSITY = vec2(0.0, 0.5);
// 晴天の積雲の立ち上がりと芯までの幅 (外殻のもやに合わせて広げる。雨天・層積雲・積乱雲は上の値のまま)
// 0.5 / 1.2 -> 0.25 / 0.5 (濃さ 0.25 では雲の中がどこも縁と同じ淡さになり、塊の輪郭が無いもやに見えた。
// 芯の上限 CLOUD_CORE_DENSITY は変えず、塊の表面から芯までを詰めてこぶの輪郭を出す。外のもやはそのまま)
const float CLOUD_CU_EDGE_WIDTH = 0.25 * CLOUD_EDGE_SOFTNESS;
const float CLOUD_CU_CORE_DEPTH = 0.5 * CLOUD_EDGE_SOFTNESS;
// 積雲の芯の密度の上限と、芯の中のこぶ単位の濃淡 (芯まで 1 で飽和させると、中まで一様に白い塊になった)。
// 層積雲・積乱雲は上限を 1 のまま (雨天・雷雨の暗く重い雲を保つ)
const float CLOUD_CORE_DENSITY = min(0.35 * CLOUD_CORE_STRENGTH, 1.0);
const float CLOUD_CORE_MOTTLE = 0.5;
// 光源方向の光学的深さ (と地面の雲影) で使う芯の上限。視線の密度と同じだけ下げると、芯の陰が浅くなり
// 下側の灰色が消えて平板に見えた (CLOUD_LIGHT_OD_SCALE と同じく、陰影は消散係数を下げる前に合わせる)
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
// べき乗則透過率 (1 + od/k)^-k の k。小さいほど厚い雲の奥まで光が届く。消散係数を 1/3 にした時に 1.5 -> 3 (陰の側の締まり)
const float CLOUD_HETEROGENEITY = 3.0;
// m: 多重散乱が育つのに要る局所の厚み (縁を暗くする powder の効き)。光学的厚さで同じ効きになるよう消散係数に反比例させる (120 -> 360)
const float CLOUD_MS_LENGTH = 360.0;
const float CLOUD_MS_ATTENUATION = 0.45;  // オクターブごとの光学的深さの倍率 (Wrenninge の a)
const float CLOUD_MS_CONTRIBUTION = 0.55; // オクターブごとの寄与 (b)
const float CLOUD_MS_ECCENTRICITY = 0.5;  // オクターブごとの位相の非対称性 (c)
const float CLOUD_MS_DIFFUSION = 0.1;     // 光学的深さの倍率の下限 (拡散近似の減衰 sqrt(3(1-g)(1-albedo)) 程度)
// 高次の散乱のエネルギー。単散乱 + 数オクターブでは厚い雲の日なたが暗すぎるので、局所の厚みに応じて
// 残りの次数の和 (アルベドの等比級数) を見込んで底上げする (Hillaire 2016 のエネルギー補正と同じ考え方)
// 晴天の雲の中央値が iterationT より sRGB で約 40 暗く、日向の頂も白くならず灰色寄りだったので
// 3.2 -> 6.0、環境光の底上げ 0.6 -> 1.2、雲底の残り 0.12 -> 0.2 / 太陽 0.5 -> 0.75、べき乗則の k 3 -> 1.5、powder 0.65 -> 0.4 に
const float CLOUD_MS_GAIN = 6.0;
const float CLOUD_ANISO_DECAY = 0.15;     // 光学的深さ 1 あたりの位相の非対称性の減り方
const float CLOUD_AMBIENT_MS = 1.2;       // 環境光の多重散乱による底上げ
// 空の光の拡散透過 1 / (1 + k od) の k (保存散乱の 2 流近似 0.75(1-g))。
// べき乗則のままだと厚い雲の底で空の光がほぼ 0 になり、夕方は暗い橙の太陽光だけが残って茶色い塊に見えた
const float CLOUD_AMBIENT_DIFFUSION = 0.2;
// 光源方向の光学的深さの倍率。消散係数を 1/3 にしても雲の陰の側と底の陰影 (立体感) は以前に近く残す
// (視線方向だけ薄くして縁を透かし、自己遮蔽は濃いまま。1 では夜の雲が陰の無い平板な白になった)。
// 2 -> 3 (濃さ 0.25 の既定でも、塊の日の当たる頂と陰の側・底の明暗でもっこりした立体に見えるように)
const float CLOUD_LIGHT_OD_SCALE = 3.0;
// 低層の真上 (空の光) 方向の光学的深さの倍率。光源方向 (CLOUD_LIGHT_OD_SCALE) と同じく、雲の中へ入るほど空の青い光が減って
// 塊の下側と奥が沈むようにする (1 では濃さ 0.25 の雲の陰の側が空の光で明るく均され、立体感が出なかった)
const float CLOUD_SKY_OD_SCALE = 2.5;
const float CLOUD_LIGHT_STEP0 = 24.0;     // m: 光方向マーチの最初の歩幅 (毎回 2 倍)
// 銀の縁: 太陽方向の光を後段で 1 + k HG(g) 倍する (iterationT の (hg*2+1))。位相関数の和だけでは
// 光学的に薄い逆光の縁が際立たなかった。単散乱には全量、多重散乱には CLOUD_SILVER_MS の割合だけ掛ける
const float CLOUD_SILVER_BOOST = 2.0 * CLOUD_SILVER_LINING;
const float CLOUD_SILVER_G = 0.7;
const float CLOUD_SILVER_MS = 0.4;
// 密度キーの powder: 散乱体の少ない縁は内側からの多重散乱を受けないので、順光で見ると暗い縁取りになる
const float CLOUD_POWDER_LENGTH = 100.0;  // m (消散係数を 1/3 にした時に 35 -> 100)
const float CLOUD_POWDER_STRENGTH = min(0.4 * CLOUD_POWDER, 1.0); // 順光 (太陽を背にした時) での効き
// 暗く重い底: その雲の中の高さ (底 0 / 頂 1) で多重散乱と空の光を落とす。底の光は厚い雲を何度も散乱して
// 横へ逃げながら届くので、光方向の光学的深さだけで見積もるより暗い (iterationT の底 0.15 + pow(h, 0.75) 相当)
const float CLOUD_BOTTOM_LIGHT = max(1.0 - 0.8 * CLOUD_BASE_SHADE, 0.0); // 雲底での残り
const float CLOUD_BOTTOM_SUN = max(1.0 - 0.25 * CLOUD_BASE_SHADE, 0.0); // 雲底での太陽の光 (単散乱込み) の残り
const float CLOUD_BOTTOM_REACH = 0.6;    // この高さで 1 に戻る

#if CLOUD_QUALITY == 0
    const int CLOUD_LOW_STEPS = 24;
    const int CLOUD_MID_STEPS = 8;
    const int CLOUD_LIGHT_STEPS = 4;
    const int CLOUD_SKY_STEPS = 1;
    const int CLOUD_HIGH_STEPS = 3;
    const int CLOUD_SHAFT_STEPS = 6;
#elif CLOUD_QUALITY == 1
    const int CLOUD_LOW_STEPS = 36;
    const int CLOUD_MID_STEPS = 12;
    const int CLOUD_LIGHT_STEPS = 6;
    const int CLOUD_SKY_STEPS = 2;
    const int CLOUD_HIGH_STEPS = 3;
    const int CLOUD_SHAFT_STEPS = 8;
#elif CLOUD_QUALITY == 2
    const int CLOUD_LOW_STEPS = 48;
    const int CLOUD_MID_STEPS = 16;
    const int CLOUD_LIGHT_STEPS = 6;
    const int CLOUD_SKY_STEPS = 2;
    const int CLOUD_HIGH_STEPS = 4;
    const int CLOUD_SHAFT_STEPS = 10;
#else
    const int CLOUD_LOW_STEPS = 64;
    const int CLOUD_MID_STEPS = 24;
    const int CLOUD_LIGHT_STEPS = 7;
    const int CLOUD_SKY_STEPS = 3;
    const int CLOUD_HIGH_STEPS = 6;
    const int CLOUD_SHAFT_STEPS = 12;
#endif
const int CLOUD_MID_LIGHT_STEPS = CLOUD_QUALITY >= 2 ? 4 : 3;

/*------------------------------------------------------------------------------
  天気図 (水平位置は参照空間)
------------------------------------------------------------------------------*/
vec2 cloudMapCenter() { return floor(cameraPosition.xz * CLOUD_KH / CLOUD_MAP_TEXEL) * CLOUD_MAP_TEXEL; }

// カメラ基準の水平位置 rel の天気図。手動バイリニア (カスタムイメージのサンプラーのフィルタ設定に依存しない)
vec4 cloudMapFetch(vec2 rel) {
    // カメラから天気図の原点までの端数は畳んで求める (CLOUD_KH 倍の大きな座標どうしの引き算で桁落ちさせない)
    vec2 p = (rel + cloudFoldCamera(vec2(0.0), CLOUD_MAP_TEXEL)) / CLOUD_MAP_TEXEL + (CLOUD_MAP_RES * 0.5 - 0.5);
    p = clamp(p, vec2(0.0), vec2(CLOUD_MAP_RES - 1.0));
    ivec2 i = ivec2(p);
    vec2 f = p - vec2(i);
    ivec2 j = min(i + 1, ivec2(CLOUD_MAP_RES - 1.0));
    vec4 a = texelFetch(cloudWeatherSampler, i, 0);
    vec4 b = texelFetch(cloudWeatherSampler, ivec2(j.x, i.y), 0);
    vec4 c = texelFetch(cloudWeatherSampler, ivec2(i.x, j.y), 0);
    vec4 d = texelFetch(cloudWeatherSampler, j, 0);
    vec4 map = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    vec2 edge = abs(p - (CLOUD_MAP_RES * 0.5 - 0.5)) / (CLOUD_MAP_RES * 0.5);
    // 端の外は晴れにするが、雨の日は一面の雨雲のまま (0 にすると地平線の手前に陽の当たる雲と直線の縁の晴れ間が出た)
    vec3 edgeFill = vec3(0.9, 0.85, 0.3) * max(rainStrength, wetness);
    map.rba = mix(map.rba, edgeFill, smoothstep(0.85, 0.99, max(edge.x, edge.y)));
    return map;
}

/*------------------------------------------------------------------------------
  地域テンプレート (CLOUD_REGION_PRESET)・気候 (天気・日替わり・時刻) と風
------------------------------------------------------------------------------*/
struct CloudRegion {
    vec2 humidity;    // 低層の被覆の日替わりの範囲 (乾いた日, 湿った日)
    float convection; // 積雲の発達しやすさ
    float stratus;    // 湿った日・夜に層積雲へ広がる傾向
    float mid;        // 中層の量
    float high;       // 上層の量
    float storms;     // 晴れた日の午後の積乱雲の出やすさ (雷雨とは別)
    float diurnal;    // 対流の日変化の深さ (1 で明け方に対流がほぼ止まる)
};

// 快晴の日の割合と、その日の低層の被覆の倍率 (扁平雲がまばらに浮かぶ程度)
const float CLOUD_CLEAR_DAY_CHANCE = 0.12;
const float CLOUD_CLEAR_DAY_COVER = 0.4;
// 夕方から夜に低層の被覆を増やす割合 (日変化の最小の時)
const float CLOUD_EVENING_SPREAD = 0.35;
// 雷雨で中層・上層のベールを減らす割合と、雲の中の曇天の光 (色の抜け・拡散) を減らす割合
// 0.75 / 0.45 では実機の雷雨の空が明るい灰色に白い綿雲が浮かぶ晴れの日のような見た目になった
const float CLOUD_THUNDER_VEIL_CUT = 0.45;
const float CLOUD_THUNDER_LIGHT_CUT = 0.25;
// 雷雨で雲の空中遠近のもやの雨の分を減らす割合 (遠くの積乱雲の塔が見えるように)
const float CLOUD_THUNDER_HAZE_CUT = 0.6;

// real-clouds.md「地域の雲の組み合わせテンプレート」の組み合わせ (頻度は気候学の一般的な傾向からの提案値)
CloudRegion cloudRegion() {
#if CLOUD_REGION_PRESET == 0
    // 温帯: 晴れの日は扁平雲・並雲と薄い巻雲、湿った日は層積雲。前線の前後に巻層雲・高層雲
    // (乾いた側 0.2 では大半の日が雲 1 つ 2 つの快晴に見えた。快晴の日は CLOUD_CLEAR_DAY_CHANCE で別に作る)
    return CloudRegion(vec2(0.5, 0.78), 1.0, 0.45, 0.65, 1.0, 0.0, 0.7);
#elif CLOUD_REGION_PRESET == 1
    // 熱帯: 朝の扁平雲が午後に雄大雲・積乱雲へ。巻雲は積乱雲のかなとこの名残。層状の雲は少ない
    return CloudRegion(vec2(0.35, 0.75), 1.35, 0.15, 0.4, 1.1, 0.8, 0.9);
#elif CLOUD_REGION_PRESET == 2
    // 乾燥: 雲量 2-3 割。薄い扁平雲の散在と高積雲の波。積乱雲はまれ
    return CloudRegion(vec2(0.03, 0.35), 0.8, 0.1, 0.7, 0.8, 0.15, 0.9);
#elif CLOUD_REGION_PRESET == 3
    // 寒冷・極域: 層状が支配的 (層積雲・高層雲)。対流は弱く、氷晶の巻雲・巻層雲がよく見える
    return CloudRegion(vec2(0.3, 0.95), 0.3, 1.0, 0.8, 1.2, 0.0, 0.25);
#elif CLOUD_REGION_PRESET == 4
    // 海洋: 広い層積雲が最多、晴れ間には大きな水滴のふわふわした積雲。日変化は小さい
    return CloudRegion(vec2(0.4, 0.95), 0.8, 0.85, 0.4, 0.7, 0.1, 0.3);
#else
    return CloudRegion(vec2(max(CLOUD_C_LOW - 0.3, 0.0), min(CLOUD_C_LOW + 0.3, 1.0)), CLOUD_C_CONVECTION, CLOUD_C_STRATUS, CLOUD_C_MID, CLOUD_C_HIGH, CLOUD_C_STORMS, 0.7);
#endif
}

struct CloudClimate {
    float lowCover;   // 低層の基準の被覆 (空に占める割合。1 超で全天)
    float lowType;    // 低層の基準の雲種 (0 層状 / 0.5 積雲 / 1 積乱雲)
    float midCover;
    float highCover;
    float convection; // 対流の強さ (積雲の背の高さ)
    float rain;
    float rainLight;  // 雲の中の光と中層のベールの雨天度 (被覆より早く切り替わる)
    float thunder;
    float storm;      // 晴れた日の積乱雲の出やすさ (遠くだけに立てる)
};

// 日ごとの天気の傾向 [0,1]。夕方から 0 時にかけて次の日の傾向へ移る (worldTime 0 = 6 時)
float cloudDayRandom(uint seed) {
    float t = float(worldDay) + float(worldTime + 6000) / 24000.0;
    float day = floor(t);
    float a = hash1(uint(int(day)) * 7919u + seed);
    float b = hash1(uint(int(day) + 1) * 7919u + seed);
    return mix(a, b, smoothstep(0.7, 1.0, t - day));
}

CloudClimate cloudClimate() {
    CloudClimate c;
    CloudRegion region = cloudRegion();
    float humidity = cloudDayRandom(11u);
    float instability = cloudDayRandom(23u);
    float midMoisture = cloudDayRandom(37u);
    float highMoisture = cloudDayRandom(53u);
    // 日射による対流は 14 時ごろ最大、明け方に最小 (worldTime 8000 = 14 時)
    float diurnal = 0.5 + 0.5 * cos(TAU * (float(worldTime) - 8000.0) / 24000.0);
    // wetness は雨の後もしばらく残るので、雨上がりの雲がゆっくり晴れる
    // 降り始めは rainStrength (約 5 秒で 1) で半分だけ曇らせ、残りは wetness (半減期 10 秒) で数十秒かけて覆う
    // (rainStrength のままだと数秒で空が一気に雨雲に変わった)
    c.rain = max(0.5 * rainStrength, wetness * mix(0.6, 1.0, rainStrength));
    // 雲の中の光 (曇天の色・拡散) と中層・上層のベールは降り始めから早めに切り替える: 低い雲が覆う前に上空の高層雲が陽射しを弱める。
    // 被覆と同じ遅さだと、降り始めの 10 秒ほどは暗い雲に白く陽の当たる縁が残った劇的な空になった
    c.rainLight = max(c.rain, 0.85 * rainStrength);
    c.thunder = thunderStrength;
    // 雷雨は嵐のセルの間が切れるので、中層のベールと雲の中の曇天の光も弱める (塔の日の当たる側面と陰が見えるように)
    float rainVeil = c.rainLight * (1.0 - CLOUD_THUNDER_VEIL_CUT * c.thunder);
    c.rainLight *= 1.0 - CLOUD_THUNDER_LIGHT_CUT * c.thunder;
    c.convection = saturate(instability * region.convection * mix(1.0 - region.diurnal, 1.0, diurnal) + c.thunder);
    // 快晴の日 (高気圧に覆われた乾いた日) は時々だけ。被覆の範囲の下端で作ると大半の日が寂しい空になる
    float clearDay = 1.0 - smoothstep(0.5, 1.0, cloudDayRandom(78u) / CLOUD_CLEAR_DAY_CHANCE);
    float lowBase = mix(region.humidity.x, region.humidity.y, humidity) * mix(1.0, CLOUD_CLEAR_DAY_COVER, clearDay);
    // 対流が弱まる夕方から夜は、積雲が平たく横へ広がって層積雲になる (夕焼けの逆光の雲・月夜の雲が小さな塊だけにならないように)
    lowBase *= 1.0 + CLOUD_EVENING_SPREAD * (1.0 - diurnal);
    c.lowCover = mix(lowBase, 1.25, c.rain) * (CLOUD_COVERAGE * CLOUD_LOW_COVERAGE);
    // 対流の強い昼は積雲、安定した湿った日や夜は層積雲 (積雲が平たく広がる)。雨は乱層雲
    c.lowType = mix(0.12, 0.8, c.convection) - 0.35 * region.stratus * humidity * (1.0 - region.diurnal * diurnal);
    c.lowType = mix(c.lowType, 0.05, c.rain);
    c.midCover = mix(region.mid * midMoisture * midMoisture, 1.15, rainVeil) * (CLOUD_COVERAGE * CLOUD_MID_COVERAGE);
    // 上層の湿りは前線の先触れ。雨の前後は巻層雲が広がる
    c.highCover = mix(0.08, 0.75, highMoisture) * region.high + (CLOUD_CIRRUS_COVERAGE - 0.1) * 2.0 + rainVeil * 0.4;
    // 晴れた日の午後の積乱雲: 不安定な日の午後だけ
    c.storm = region.storms * smoothstep(0.4, 0.8, instability) * sqr(diurnal) * (1.0 - c.rain);
#ifndef CLOUD_CB
    c.storm = 0.0;
#endif
    return c;
}

vec2 cloudWindLow() { return CLOUD_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_WIND_SPEED); }
vec2 cloudWindMid() { return CLOUD_MID_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_MID_WIND_SPEED); }
vec2 cloudWindHigh() { return CLOUD_HIGH_WIND_DIR * (frameTimeCounter * CLOUD_SPEED * CLOUD_HIGH_WIND_SPEED); }

struct CloudContext {
    vec2 lowOrigin;  // 低層のノイズ座標の原点 (カメラ - 風 を CLOUD_LOW_TILE で畳んだもの, m)
    vec2 midOrigin;
    vec2 highOrigin;
    vec3 evolve;     // 形状ノイズの追加の流れ (m)
    float convection;
    float rain;
    float rainLight;
    float densityScale;
    float storm;     // 積乱雲が立ちうるか (雷雨 or 晴れた日の積乱雲)。0 なら低層の上端は積雲の層まで
    float lowTop;    // 低層の上端 (参照 m)
    float lowTopWorld;
    float cameraAltitude; // カメラの参照高度
    float seaAltitude;    // 海面の参照高度 (空中遠近の基準)
};

CloudContext cloudContextSetup(CloudClimate climate) {
    CloudContext ctx;
    vec2 windLow = cloudWindLow();
    ctx.lowOrigin = cloudFoldCamera(windLow, CLOUD_LOW_TILE);
    ctx.midOrigin = cloudFoldCamera(cloudWindMid(), CLOUD_MID_TILE);
    ctx.highOrigin = cloudFoldCamera(cloudWindHigh(), CLOUD_HIGH_TILE, CLOUD_KH_HIGH);
    float time = frameTimeCounter * CLOUD_SPEED;
    ctx.evolve = vec3(-windLow.x * CLOUD_EVOLVE, -time * CLOUD_UPDRAFT, -windLow.y * CLOUD_EVOLVE);
    ctx.convection = climate.convection;
    ctx.rain = climate.rain;
    ctx.rainLight = climate.rainLight;
    // 雷雨の雲は液水量が多く、底が一段暗い (0.4 では実機の雷雨の雲が明るい灰色のままだった)
    // 晴天の消散係数を 1/3 にしたので、雨雲・雷雨はここで以前の濃さの 7 割前後へ戻す (雨の日の重い雲底は残す)
    ctx.densityScale = 1.0 + 2.0 * climate.rain + 3.0 * climate.thunder;
#ifdef CLOUD_CB
    ctx.storm = max(climate.thunder, climate.storm);
#else
    ctx.storm = 0.0;
#endif
    ctx.lowTop = ctx.storm > 1e-3 ? CLOUD_R_CB_TOP : CLOUD_R_TOP;
    ctx.lowTopWorld = ctx.storm > 1e-3 ? CLOUD_CB_TOP : CLOUD_TOP;
    ctx.cameraAltitude = cloudRefAltitude(cameraPosition.y);
    ctx.seaAltitude = cloudRefAltitude(SKY_SEA_LEVEL);
    return ctx;
}

/*------------------------------------------------------------------------------
  密度
------------------------------------------------------------------------------*/
struct CloudColumn {
    float cover;
    float type;
};

CloudColumn cloudLowColumn(vec4 map) {
    CloudColumn col;
    col.cover = map.r * CLOUD_COVER_RANGE;
    col.type = map.g;
    return col;
}

float cloudStratusWeight(float type) { return 1.0 - smoothstep(0.2, 0.45, type); }
float cloudCumulonimbusWeight(float type) { return smoothstep(0.75, 0.95, type); }
// 嵐の中心ほど 1 (塔の太さ・かなとこ・降水の柱の芯)
float cloudStormCore(float type) { return linearStep(0.75, 1.0, type); }

/*
 * 積雲 1 つの大きさのセルの形 (底 0 から測った高さ hb で)。セル値 v のしきい値 1 - cover より上が雲
 * 立ち上がり幅とドームの幅は被覆に比例させる (小さな雲は被覆が小さく、固定幅だと最後まで薄いまま立ち上がらない)
 */
void cloudCumulusCell(float v, float cover, float topScale, float hb, inout float best, inout float bestX, inout float bestSize) {
    if (cover <= 0.0) return;
    // 被覆がごく小さいと雲はセルの頂点の周りの数テクセル (cloudNoiseTex の 1 テクセル = 既定 84 m) だけになり、双一次補間の面が
    // そのまま見えた (雷雨の全天の被覆で小さなセルが晴れ間の抑制 x 0.2 を受け、近くの雲底に直線の縁の明るい四角い面)。
    // 形は最小の被覆で作り、それより小さい分は濃さで薄める
    float fade = saturate(cover / CLOUD_CELL_MIN_COVER);
    cover = max(cover, CLOUD_CELL_MIN_COVER);
    float threshold = 1.0 - cover;
    // 足跡の外側も負の値のまま返す (外殻のもやの幅を測る)。もやの届かない所はここで打ち切る
    float footprint = min((v - threshold) / (CLOUD_COVER_SOFTNESS * min(cover / 0.35, 1.0)), 1.0);
    if (footprint * 1.25 <= -CLOUD_HAZE_REACH) return;
    // 高さは被覆の飽和した footprint ではなく、セルの値そのものから連続に決める (セルの中心へ向かって盛り上がるドーム。
    // footprint で決めると中が一様な高さになり、頂が平らな箱に見えた)
    float tall = linearStep(threshold, threshold + CLOUD_DOME_WIDTH * min(cover / 0.5, 1.0), v);
    float x = hb / (topScale * (CLOUD_DOME_BASE + (1.0 - CLOUD_DOME_BASE) * pow(tall, CLOUD_DOME_ROUND)));
    // 積雲は被覆から高さの形を引く: 上ほど細るドームに加え、底の近くも少し細らせて縁が巻き上がった底にする
    // (掛け算だと底が雲の一番広い所になり、垂直な壁と平らな張り出しの段が重なった形に見えた)
    // 頂の上も負へ下げ続ける (x を 1 で止めると頂の上一面がもやの縁 0 に張り付く)
    float profile = min(footprint * 1.25 - 1.25 * pow(x, CLOUD_DOME_POW) - CLOUD_BASE_TUCK * (1.0 - smoothstep(0.0, 0.25, x)), 1.0);
    // 負側 (もや) は fade で割らない。被覆が 0 に近い所のもやは、天気図の被覆で連続に消す (cloudLowDensity の hazeReach)
    profile = (profile > 0.0 ? profile * CLOUD_DOME_GAIN : profile) - (CLOUD_DOME_GAIN - 1.0) * CLOUD_DOME_OFFSET;
    if (profile > 0.0) profile = min(profile, 1.0) * fade;
    if (profile > best) {
        best = profile;
        bestX = x;
        bestSize = topScale;
    }
}

#ifdef CLOUD_CB
/*
 * 積乱雲の雲量 (浸食前) と雲の中の高さ。core: 嵐の中心ほど 1, hc: 雲底 0 / 対流圏界面 1
 * 塔: 上ほど少し細る柱。かなとこ: 対流圏界面で上昇が止まり、風下へ伸びる平たい氷の層 (風上の芯を読んで広げる)。
 * オーバーシュート: 最も強い芯の上でかなとこを突き抜けるドーム。乳房雲: かなとこの下面から垂れる袋 (細かいセルの高さ場)
 */
float cloudCumulonimbusShape(float core, vec2 rel, float hc, vec4 cells, float shape, out float x) {
    x = hc;
    float pouch = cells.a;
    // 塔は 1 本の円柱ではなく、積雲のセル (大・中) が束になって盛り上がる。上ほど細り (雄大雲の頭)、かなとこの下で止まる
    // 3D の形状ノイズも足して、高さごとに張り出しの違うこぶの側面にする (2D の足跡だけだと垂直な壁の柱に見えた)
    // 塔の輪郭は 3D ノイズで大きく出し入れし、立ち上がりも狭くする (広い立ち上がりだと中が一様に詰まった、なめらかな灰色の球に見えた)
    float lumpy = core + (cells.r - 0.5) * 0.6 + (cells.b - 0.5) * 0.3 + (shape - 0.5) * 1.1;
    float body = linearStep(0.25 + 0.5 * hc, 0.4 + 0.5 * hc, lumpy) * (1.0 - smoothstep(CLOUD_CB_ANVIL_BASE, CLOUD_CB_ANVIL_TOP, hc));
    float dome = CLOUD_CB_ANVIL_TOP + (1.0 - CLOUD_CB_ANVIL_TOP) * sqrt(linearStep(0.65, 1.0, core));
    float overshoot = linearStep(0.55, 0.8, core) * (1.0 - smoothstep(dome - 0.03, dome, hc));
    float cloudiness = max(body, overshoot);
    float anvilBottom = CLOUD_CB_ANVIL_BASE - CLOUD_CB_MAMMA * sqr(pouch);
    if (hc > anvilBottom - 0.02 && hc < CLOUD_CB_ANVIL_TOP) {
        // 風上の芯を読んで風下へ伸ばす (かなとこは輪ではなく風下に長い)
        // 塔から風下の先まで切れ目なく続くよう、風上の 2 点を読む
        float near = cloudStormCore(cloudMapFetch(rel - CLOUD_HIGH_WIND_DIR * (0.4 * CLOUD_CB_ANVIL_LENGTH)).g);
        float upwind = cloudStormCore(cloudMapFetch(rel - CLOUD_HIGH_WIND_DIR * CLOUD_CB_ANVIL_LENGTH).g);
        float spread = max(max(core, near * 0.95), upwind * 0.8) + (cells.g - 0.5) * 0.2;
        float anvil = linearStep(0.25, 0.55, spread) * linearStep(anvilBottom - 0.02, anvilBottom + 0.02, hc)
                    * (1.0 - linearStep(CLOUD_CB_ANVIL_TOP - 0.03, CLOUD_CB_ANVIL_TOP, hc));
        cloudiness = max(cloudiness, anvil);
    }
    return cloudiness;
}
#endif

/*
 * 低層の密度 [0,1] (消散係数 = CLOUD_LOW_SIGMA x 密度)
 * rel: カメラ基準の水平位置 (参照 m), altitude: 参照高度 (m)
 * detail: 縁の浸食の強さ [0,1] (距離の LOD。0 で浸食を省く)
 * cloudHeight: その雲の中の高さ (底 0 / 頂 1)。底を暗く沈める光の計算に使う
 */
float cloudLowDensity(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, float detail, bool lightPath, out float cloudHeight) {
    cloudHeight = 0.5;
    float h = (altitude - CLOUD_R_BASE) / CLOUD_R_DEPTH;
    if (h <= 0.0 || altitude >= ctx.lowTop) return 0.0;
    float wCb = 0.0;
#ifdef CLOUD_CB
    wCb = cloudCumulonimbusWeight(col.type);
#endif
    if (h >= 1.0 && wCb <= 0.0) return 0.0;
    vec2 q = rel + ctx.lowOrigin;

#if CLOUDS == 3
    // 3D の座標。上ほど風下へずらす (風のシアで雲頂が傾く)
    vec3 p = vec3(q.x, altitude, q.y) + ctx.evolve;
    p.xz -= CLOUD_WIND_DIR * (h * CLOUD_R_DEPTH * CLOUD_SHEAR);
    vec3 curl = texture(cloudDetailTex, p / CLOUD_CURL_PERIOD).gba * 2.0 - 1.0;
    // 2D の被覆を高さごとに少しずらして読み、セルの縁が垂直な壁にならないようにする (側面がふくらみながら上る)
    vec4 cells = texture(cloudNoiseTex, (q + curl.xz * CLOUD_FOOTPRINT_WARP) / CLOUD_CELL_PERIOD);
    float wStrat = cloudStratusWeight(col.type);

    // 雲底の高さ: 地域ごとの凝結高度の差 (天気図の規模でゆっくり変わる) + 層状の雲の底の波打ち + 雲底の近くだけの乱流
    // 層状の雲の底は乱流で波打ち、下から見ると濃淡のまだらになる
    // 凝結高度の差はセルのなめらかな fbm (雲の背丈のばらつきと同じ) で、隣り合う雲どうしで少しずつ変える (追加のフェッチ無し)
    float lift = cells.g * (CLOUD_BASE_VARIATION / CLOUD_R_DEPTH);
    lift += wStrat * (1.0 - cells.g) * (CLOUD_STRATUS_UNDULATION * (1.0 + 2.0 * ctx.rain) / CLOUD_R_DEPTH);
    float hb = h - lift;
    if (hb <= 0.0) return 0.0;

    // 底は平ら、上は丸く (積雲) / 平たく (層積雲)
    float bottom = linearStep(0.0, CLOUD_BASE_RAMP / CLOUD_R_DEPTH, hb);
    // 底の凹凸 (100-300 m): 水平位置だけの高さ場で雲底を削る (3D のノイズで底の位置を揺らすと、高さごとに底の位置が変わって
    // 雲の中の高さ (底の暗さ) が斑に乱れ、下から見た底に黒い染みが出た)。雲の中の高さ x は凹凸の前の底から測る。
    // 底の近くの、視線方向のサンプル (detail > 0) だけで読む。ちぎれは雲底に集中させた curl の浸食で作る
    float raggedRange = (2.0 * CLOUD_BASE_RAGGED + CLOUD_BASE_RAMP) / CLOUD_R_DEPTH;
    if (detail > 0.0 && hb < raggedRange) {
        float ragged = texture(cloudNoiseTex, q / (CLOUD_CELL_PERIOD / 16.0) + vec2(0.29, 0.61)).g * (2.0 * CLOUD_BASE_RAGGED / CLOUD_R_DEPTH);
        bottom = linearStep(ragged, ragged + CLOUD_BASE_RAMP / CLOUD_R_DEPTH, hb);
    }

    // 断片雲: 濃い雲の周りに散らばる薄い小片 (ちぎれ雲・層積雲の切れ端)。濃い塊だけが並ぶと作り物に見えるので、
    // 天気図の規模 (10 km 前後) の群れの中にだけまばらに置き、群れの中でも 1 km ほどの単位で濃さをばらつかせる。
    // 積雲の形とは別に最後に濃い方を取る (積雲の縁と混ぜて濃さが飛ばないように)
    float fractus = 0.0, fractusHeight = 0.5;
    float rainLook = smoothstep(CLOUD_HAZE_RAIN.x, CLOUD_HAZE_RAIN.y, ctx.rain);
    // 視線方向のサンプル (detail > 0) だけで作る。薄いので光・空の光学的深さと雲影への寄与は省く (断片雲のコストを半分ほどに)
    if (CLOUD_FRACTUS > 0.0 && detail > 0.0 && h < 1.0 && hb < CLOUD_FRACTUS_TOP) {
        vec4 group = texture(cloudNoiseTex, q / CLOUD_CELL_PERIOD + vec2(0.5, 0.25));
        // 晴れ間の真ん中 (被覆 0) と一面の雲の中には出さない
        float amount = CLOUD_FRACTUS_COVER * (0.75 + 0.25 * CLOUD_FRACTUS) * linearStep(CLOUD_FRACTUS_GROUP.x, CLOUD_FRACTUS_GROUP.y, group.g)
                     * smoothstep(0.03, 0.2, col.cover) * (1.0 - smoothstep(0.8, 1.15, col.cover));
        if (amount > 0.0) {
            float n = texture(cloudShapeTex, p / CLOUD_FRACTUS_PERIOD * CLOUD_FRACTUS_STRETCH + vec3(0.21, 0.47, 0.83)).r * 0.75 + cells.a * 0.25;
            float frag = linearStep(1.0 - amount, 1.0 - amount + 0.2, n);
            // 小片ほど平たい。上へ細りながら消える
            float fractusX = hb / (CLOUD_FRACTUS_TOP * (0.35 + 0.65 * frag));
            float f = frag * (1.0 - smoothstep(0.3, 1.0, fractusX)) * bottom;
            // 薄い小片は中まで光が通るので、積雲の底のようには沈めない
            fractusHeight = mix(0.5, 1.0, saturate(fractusX));
            if (f > 0.0 && detail > 0.0) {
                // 縁は細かい浸食でほつれさせる (底の巻き上がりと同じ curl の歪み)
                float e = texture(cloudDetailTex, (p + curl * CLOUD_CURL_AMOUNT) / CLOUD_DETAIL_PERIOD).r;
                f -= (1.0 - e) * (0.6 * CLOUD_LOW_EROSION) * min(detail * 2.5, 1.0);
            }
            // 縁の浸食が弱まる 8-13 km で消す (遠くで急に途切れないように。12-18 km まで残すと、ほつれの無い滑らかな小片が
            // 地平線の手前で透視に潰され、夕方の逆光で流し撮りのような筋に見えた)
            fractus = saturate(f * 2.0) * mix(CLOUD_FRACTUS_DENSITY.x, CLOUD_FRACTUS_DENSITY.y, group.a) * saturate(detail * 5.0 - 1.0) * mix(1.0, ctx.densityScale, rainLook)
                    * min(CLOUD_FRACTUS, 1.0);
        }
    }

    // 雲量は負にもなる (-CLOUD_HAZE_REACH までは外殻のもや)
    float cloudiness = -CLOUD_HAZE_REACH;
    float x = 1.0;
    float turret = -1.0;
    float size = 1.0; // 積雲の大きさ (CLOUD_CU_HEIGHT の大 / 中 / 小)
    if (h < 1.0) {
        // 積雲: 大中小のセル (r / b / a) を同じフェッチから読み、被覆をべき乗則の割合で分ける。
        // 雲頂は対流の強さ (CLOUD_CU_TOP) x セルの中心ほど高いドーム x 隣どうしのばらつき (なめらかな fbm)
        float cumulus = -CLOUD_HAZE_REACH, cumulusX = 1.0, cumulusSize = 1.0;
        if (wStrat < 1.0) {
            // 塔の塊のノイズはここで読み、下の塔の削りでも使う
            turret = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_TURRET_SCALE) + vec3(0.13, 0.57, 0.31)).g;
            float lumpV = (turret - 0.5) * CLOUD_LUMP_V;
            // 対流の強さの 2 乗で伸ばす: 晴れた日の積雲はふつう背より幅が広い扁平雲・並雲で、雄大雲は対流がかなり強い時だけ
            // (一次だと並の日でも 1.5 km 級の丸い塊が並び、綿玉のように見えた)
            // 2 乗 + 下限 0.22 では並の日の雲が 0.5 km 前後の平たい帯ばかりになり、iterationT の盛り上がった積雲に比べて
            // 立体感が無かった。下限を上げて一次に戻す (大きなセルの割合を減らしたので綿玉の列にはならない)
            float topBase = mix(CLOUD_CU_TOP.x, CLOUD_CU_TOP.y, ctx.convection) * (1.0 + CLOUD_CU_TOP_SPREAD * (cells.g - 0.5));
            float topKnee = max(0.2 - abs(topBase - CLOUD_CU_TOP_MAX), 0.0) / 0.2;
            topBase = min(topBase, CLOUD_CU_TOP_MAX) - sqr(topKnee) * 0.05;
            float coverBig = col.cover * CLOUD_CU_SHARE.x;
            // 大きな雲のすぐ外は補償の下降流で晴れるので、中小の雲を減らして間隔を空ける
            float clearing = 1.0 - CLOUD_CU_CLEARING * smoothstep(1.0 - coverBig - CLOUD_CU_CLEARING_WIDTH, 1.0 - coverBig, cells.r);
            cloudCumulusCell(cells.r + lumpV, coverBig, CLOUD_CU_HEIGHT.x, hb / topBase, cumulus, cumulusX, cumulusSize);
            cloudCumulusCell(cells.b + lumpV, col.cover * CLOUD_CU_SHARE.y * clearing, CLOUD_CU_HEIGHT.y, hb / topBase, cumulus, cumulusX, cumulusSize);
            cloudCumulusCell(cells.a + lumpV, col.cover * CLOUD_CU_SHARE.z * clearing, CLOUD_CU_HEIGHT.z, hb / topBase, cumulus, cumulusX, cumulusSize);
        }
        float stratus = 0.0, stratusX = 0.0;
        if (wStrat > 0.0) {
            // 層積雲: 片方向に引き伸ばしたセルとなめらかな fbm を混ぜ、ロール状の塊とその間の隙間を作る
            // ロールも積雲のセルと同じく高さごとに揺らして読む (2D のままだと側面が垂直な壁になり、
            // 雷雨の日に平らな頂と直線の縁の明るい面が見えた)
            float roll = texture(cloudNoiseTex, (q + curl.xz * CLOUD_FOOTPRINT_WARP) / CLOUD_ROLL_PERIOD).r;
            float v = mix(cells.r, roll * 0.7 + cells.g * 0.3, wStrat);
            float footprint = linearStep(1.0 - col.cover, 1.0 - col.cover + CLOUD_COVER_SOFTNESS, v);
            // 頂は縁ほど低い (足跡のまま一定の高さだと、上から見て垂直な壁の箱が並んだ)。小さなセルで頂を波打たせる
            stratusX = hb / (mix(CLOUD_SC_TOP.x, CLOUD_SC_TOP.y, ctx.rain) * (0.35 + 0.65 * footprint) * (0.75 + 0.5 * cells.a));
            stratus = footprint * (1.0 - smoothstep(0.5, 1.0, stratusX));
        }
        // 外殻のもやは積雲だけ (層積雲は足跡の外を -CLOUD_HAZE_REACH 扱いにして、正側は従来どおり混ぜる)
        float solid = mix(max(cumulus, 0.0), stratus, wStrat);
        cloudiness = solid > 0.0 ? solid : mix(cumulus, -CLOUD_HAZE_REACH, wStrat);
        x = mix(cumulusX, stratusX, wStrat);
        size = mix(cumulusSize, 1.0, wStrat);
    }
#ifdef CLOUD_CB
    float ice = 0.0;
    float stormCore = 0.0;
    vec2 s = vec2(-1.0);
    if (wCb > 0.0) {
        s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
        float hc = (altitude - CLOUD_R_BASE - lift * CLOUD_R_DEPTH) / (CLOUD_R_CB_TOP - CLOUD_R_BASE);
        float xCb;
        // 嵐の芯は天気図 (256 m の格子の双一次補間) のなめらかな面なので、そのまま等値面を取ると塔の側面に直線の縁の平らな面が出た。
        // curl で読む位置を揺らして面をうねらせる
        stormCore = cloudStormCore(cloudMapFetch(rel + curl.xz * CLOUD_CB_WARP).g);
        float cb = cloudCumulonimbusShape(stormCore, rel, hc, cells, s.g, xCb) * wCb;
        // 塔の側面の大きなこぶ (0.6-1.5 km)。積雲のこぶ (200-400 m) は 15 km 先では画素以下になり、遠い塔がなめらかな塊に見えた
        float tower = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_CB_LUMP_SCALE) + vec3(0.61, 0.27, 0.05)).r;
        cb -= (1.0 - tower) * CLOUD_CB_LUMP_EROSION * (1.0 - 0.6 * smoothstep(0.55, 0.8, hc));
        if (cb > max(cloudiness, 0.0)) {
            cloudiness = cb;
            x = xCb;
            size = 1.0;
            // 上部は氷晶化してなめらかな繊維状 (カリフラワーの浸食を弱める)
            ice = smoothstep(0.55, 0.8, hc);
        }
    }
#endif
    cloudHeight = saturate(x);
    // 底より下へはもやを出さない (持ち上げ凝結高度で一斉に雲になる平らな底は保つ)
    cloudiness = cloudiness > 0.0 ? cloudiness * bottom : cloudiness - (1.0 - bottom) * CLOUD_HAZE_REACH;
    // 外殻のもやの幅 (層積雲・積乱雲は 0 = 従来どおり輪郭で打ち切る)
    // 被覆 0 の境界 (天気図の双一次補間の直線) でもやが切れないよう、被覆が小さいほど狭める。
    // 雨天・雷雨は従来の濃さのまま (嵐の穴の縁がもやで埋まり、照らされた縁が鈍った)
    float cumulusShare = (1.0 - wStrat) * (1.0 - wCb) * (1.0 - rainLook);
    float hazeReach = CLOUD_HAZE_REACH * cumulusShare * saturate(col.cover / CLOUD_CELL_MIN_COVER);
    if (cloudiness <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }

#ifdef CLOUD_CB
    if (s.x < 0.0) s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
#else
    vec2 s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
#endif
    // 積雲は Worley 寄りのもこもこ、層積雲は Perlin 寄りのなめらかな塊
    float shape = mix(s.r, s.g, (1.0 - wStrat) * 0.7);
    // 底の近くは削りを弱めて平らで幅のある底を残し、上ほど削って塔状に盛り上がる塊にする
    // (低周波の 3D ノイズで底まで削ると、底だけ削れて上が残った所が下すぼまりのきのこ・牙の形になった。底の近くはほぼ削らない)
    float baseKeep = mix(mix(CLOUD_BASE_KEEP, 1.0, smoothstep(0.0, CLOUD_BASE_KEEP_REACH, x)), 1.0, wStrat);
    // 小さな雲は形状ノイズ (周期 7 km) の塊より小さいので、同じ量を削ると一様に薄くなり、下から見ても陰の無い白い粒になった。
    // 大きさに比例して削る (小さな雲も芯は光学的に厚く、灰色の底を持つ)
    baseKeep *= mix(0.4, 1.0, saturate((size - CLOUD_CU_HEIGHT.z) / (1.0 - CLOUD_CU_HEIGHT.z)));
    float d = cloudiness - (1.0 - shape) * CLOUD_SHAPE_EROSION * baseKeep;
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    // 塔: 積雲の上半分を数百 m の丸い塊 (上昇気流の泡) の積み重なりにする。2D の足跡を縦に伸ばした側面は
    // 縦の幕の筋に見えるので、3D の Worley の塊で側面と頂を区切り、こぶごとに陰を作る (平らな底は残す)
    if (turret < 0.0) turret = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_TURRET_SCALE) + vec3(0.13, 0.57, 0.31)).g;
    d -= (1.0 - turret) * CLOUD_TURRET_EROSION * mix(CLOUD_TURRET_BASE, 1.0, smoothstep(0.0, 0.6, x)) * (1.0 - wStrat) * (1.0 - wCb);
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    // 中間スケールのこぶ (200-400 m): 大きな塊の表面にカリフラワーの段を付ける。
    // 光のマーチにも効くので、こぶごとに陰ができて立体に見える
    float billow = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_BILLOW_SCALE) + vec3(0.37, 0.11, 0.73)).g;
    // 雲頂ほど強く削り、上へ盛り上がるこぶの段を際立たせる (底の近くは平らなまま)
    float billowAmount = CLOUD_BILLOW_EROSION * mix(CLOUD_BILLOW_PROFILE.x, CLOUD_BILLOW_PROFILE.y, smoothstep(0.2, 0.9, x));
#ifdef CLOUD_CB
    billowAmount *= 1.0 - 0.7 * ice;
#endif
    // 底の近くもこぶは残す: 下から見上げた雲の輪郭は底の外周そのもので、底で弱めると 2D のセルのなめらかな輪郭が
    // 斜めに引き伸ばされ、刷毛で伸ばしたような帯に見えた
    d -= (1.0 - billow) * billowAmount * (1.0 - smoothstep(0.0, 0.9, d)) * mix(0.8, 1.0, baseKeep) * mix(1.0, 0.5, wStrat);
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    if (detail > 0.0) {
        // 歪みは雲底に集中させ、底はちぎれて巻き上がり、上面はなめらかなこぶのまま残す
        float curlWeight = mix(1.0, CLOUD_CURL_TOP, smoothstep(0.0, 0.6, x));
        vec3 dp = p + curl * (CLOUD_CURL_AMOUNT * curlWeight);
        // 周期の違う 2 オクターブを重ねて Worley のセルの規則性を崩す。細かいオクターブは近くだけ
        float e = texture(cloudDetailTex, dp / CLOUD_DETAIL_PERIOD).r;
        float fine = saturate(detail * 2.0 - 1.0);
        if (fine > 0.0) e = mix(e, e * 0.7 + texture(cloudDetailTex, dp / (CLOUD_DETAIL_PERIOD / 3.0)).r * 0.3, fine);
        // Worley の谷を削って粒を残す (カリフラワー)。山を削る「ちぎれ」は薄い所に穴の網目 (蜂の巣模様) が透けるので使わず、
        // 底のちぎれは curl の歪みだけで作る
        // 縁 (密度の低い所) だけを削る。中まで削ると斜めの光でセル模様が透けて見える
        float edge = 1.0 - smoothstep(0.0, CLOUD_DETAIL_REACH, d);
        // 雲底の近くは浸食を強めて、歪めた筋のちぎれを際立たせる
        float baseErode = mix(1.3, 1.0, smoothstep(0.0, 0.2, x));
        // 層積雲の細かい浸食は弱める (薄い層に小さな白い粒が散って見えた)
        d -= (1.0 - e) * edge * CLOUD_DETAIL_EROSION * baseErode * mix(0.6, 1.0, smoothstep(0.0, 0.3, x)) * mix(1.0, 0.45, wStrat) * mix(1.6, 1.0, saturate((size - CLOUD_CU_HEIGHT.z) / (1.0 - CLOUD_CU_HEIGHT.z))) * min(detail * 2.0, 1.0);
        if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    }
    // 縁の密度勾配: 輪郭の外は外殻のもや (粗い形状ノイズで厚みを変え、外へ CLOUD_HAZE_FALLOFF 乗で消える)、
    // 内は輪郭のもやの濃さから立ち上がり (edgeWidth)、芯へ向かって coreDepth かけて芯の上限まで濃くなる。
    // 浸食で削った所も真空ではなくもやになるので、ほつれた縁が薄く外へ伸びる
    float hazeEdge = CLOUD_HAZE_DENSITY * hazeReach / CLOUD_HAZE_REACH;
    if (d <= 0.0) {
        float reach = hazeReach * (1.0 - CLOUD_HAZE_SWELL * (1.0 - s.r));
        d = hazeEdge * pow(saturate(1.0 + d / max(reach, 1e-3)), CLOUD_HAZE_FALLOFF);
        if (d <= 0.0) { cloudHeight = fractusHeight; return fractus; }
    } else {
        // 芯の上限と濃淡は積雲だけ
        float coreMax = mix(1.0, (lightPath ? CLOUD_CORE_DENSITY_LIGHT : CLOUD_CORE_DENSITY) * (1.0 - CLOUD_CORE_MOTTLE * (1.0 - billow)), cumulusShare);
        float edgeWidth = mix(CLOUD_EDGE_WIDTH, CLOUD_CU_EDGE_WIDTH, cumulusShare);
        float coreDepth = mix(CLOUD_CORE_DEPTH, CLOUD_CU_CORE_DEPTH, cumulusShare);
        float ramp = (1.0 - sqr(1.0 - saturate(d / edgeWidth))) * mix(CLOUD_EDGE_DENSITY, 1.0, saturate(d / coreDepth));
        d = mix(hazeEdge, coreMax, ramp);
    }
    // 積雲の液水量は高さとともに増える
    // 雨雲は一面に覆っても中の水量にむらがあり、下から濃淡のまだらとして見える
    float rainMottle = mix(1.0, 0.45 + 1.1 * cells.g, ctx.rain * wStrat);
    float water = mix(0.6, 1.0, saturate(x * 1.4));
#ifdef CLOUD_CB
    // 積乱雲の塔は液水量が多い。上部の氷晶の層 (かなとこ) は塔の上で厚く、風下の先ほど薄い半透明になる
    // (一様に厚いと、風下の空一面が暗い灰色の天井になった)
    water *= mix(1.0, mix(CLOUD_CB_WATER, 0.08 + 0.7 * stormCore, ice), wCb);
#endif
    // 雨天の濃さの倍率も見た目と同じ範囲で移す (雨上がりの wetness が残る間に、層積雲の切れ端まで濃い白い欠片にならないように)
    float density = d * water * rainMottle * mix(1.0, ctx.densityScale, smoothstep(CLOUD_RAIN_DENSITY.x, CLOUD_RAIN_DENSITY.y, ctx.rain));
    if (fractus > density) { cloudHeight = fractusHeight; return fractus; }
    return density;
#else
    // 2D 押し出し (Nostalgia 方式): 平面の被覆をそのまま縦に伸ばし、上下の縁だけ立方で削る
    vec4 cells = texture(cloudNoiseTex, q / CLOUD_CELL_PERIOD);
    float footprint = linearStep(1.0 - col.cover, 1.0 - col.cover + CLOUD_COVER_SOFTNESS, cells.r);
    float erodeLow = pow(1.0 - linearStep(0.0, 0.3, h), 3.0);
    float erodeHigh = pow(linearStep(0.6, 1.0, h), 3.0);
    cloudHeight = h;
    float d = footprint - erodeLow - erodeHigh;
    if (detail > 0.0) d -= (1.0 - texture(cloudNoiseTex, q / (CLOUD_CELL_PERIOD / 12.0)).a) * 0.2 * detail;
    return saturate(d * 2.5) * ctx.densityScale;
#endif
}

// 距離 t (参照 m) の縁の浸食の LOD [0,1]: 0.5-1 で細かいオクターブ、0-0.5 で主オクターブを消していく
float cloudDetailLod(float t) {
    return 0.5 * (1.0 - smoothstep(CLOUD_DETAIL_FADE_FINE.x, CLOUD_DETAIL_FADE_FINE.y, t)) + 0.5 * (1.0 - smoothstep(CLOUD_DETAIL_FADE.x, CLOUD_DETAIL_FADE.y, t));
}

float cloudLowDensity(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, bool detail, bool lightPath) {
    float cloudHeight;
    return cloudLowDensity(ctx, col, rel, altitude, detail ? 1.0 : 0.0, lightPath, cloudHeight);
}

/*
 * 中層 (高積雲 / 高層雲) の密度 [0,1]。cover: 天気図の中層の被覆
 * 被覆が小さい時は小さな塊が群れる高積雲、広く覆う時は一様な高層雲
 * grainHeight: 粒 (または層) の中の高さ (底 0 / 頂 1)。粒の下側を沈めて陰影を付ける
 */
float cloudMidDensity(CloudContext ctx, float cover, vec2 rel, float altitude, bool detail, out float grainHeight) {
    grainHeight = 0.5;
    float h = (altitude - CLOUD_R_MID_BASE) / CLOUD_R_MID_DEPTH;
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec2 q = rel + ctx.midOrigin;
    // 雨の前後に増える中層は一様な高層雲として広げる (雨上がりの wetness が残る間に高積雲の粒のまま増やすと、
    // 低層の雲の周りに縁のくっきりした白い欠片が散らばって見えた)
    float stratus = max(smoothstep(0.6, 1.0, cover), linearStep(CLOUD_MID_RAIN_VEIL.x, CLOUD_MID_RAIN_VEIL.y, ctx.rainLight));
    vec4 n = texture(cloudNoiseTex, q / CLOUD_MID_PERIOD);
    float patches = linearStep(1.0 - cover, 1.0 - cover + CLOUD_MID_PATCH_SOFTNESS, n.g);
    // 高積雲: 細かいセルの一つ一つを、中心ほど背の高い小さなドームにする (うろこ状の小塊。壁のような縁を作らない)
    // 被覆が増えるほど粒どうしをつなげて、でこぼこした一枚の層にする (粒の隙間が穴の模様として透けないように)
    // 粒は風と直交する向きに伸ばして列 (さざ波) に並べ、なめらかな fbm を混ぜて Worley のセルの角張った輪郭を丸める
    // (セルのままだと角張った小片が散らばる点描に見えた)。倍率 0.5 は CLOUD_MID_TILE の畳みで継ぎ目が出ない値
    float cell = texture(cloudNoiseTex, q / CLOUD_MID_PERIOD * vec2(1.0, 0.5)).a;
    float grain = smoothstep(mix(0.25, -0.3, stratus), mix(0.85, 0.5, stratus), cell * 0.75 + n.g * 0.25) * patches;
    float x = (h - CLOUD_AC_BASE) / (0.6 * grain + 1e-3);
    float altocumulus = grain * linearStep(CLOUD_AC_BASE, CLOUD_AC_BASE + 0.05, h) * saturate(1.0 - x * x);
    // 高層雲の底と頂は位置ごとに上下させる (平らな面のままだと、浸食の穴の縁で直線の縁の平らな面が見えた)
    float hs = h + (n.r - 0.5) * 0.3;
    float altostratus = linearStep(0.3, 0.8, cover * (0.75 + 0.5 * n.g)) * linearStep(0.15, 0.35, hs) * (1.0 - linearStep(0.6, 0.85, hs + (cell - 0.5) * 0.2));
    float cloudiness = mix(altocumulus, altostratus, stratus);
    if (cloudiness <= 0.0) return 0.0;
    grainHeight = mix(saturate(x), h, stratus);

    vec3 p = vec3(q.x, altitude, q.y) + ctx.evolve * 0.5;
    float d = cloudiness - (1.0 - texture(cloudShapeTex, p / CLOUD_MID_SHAPE_PERIOD).g) * mix(CLOUD_MID_ERODE.x, 0.3, stratus) * CLOUD_MID_EROSION;
    if (d <= 0.0) return 0.0;
    if (detail) {
        float edge = 1.0 - smoothstep(0.0, CLOUD_DETAIL_REACH, d);
        d -= (1.0 - texture(cloudDetailTex, p / CLOUD_MID_DETAIL_PERIOD).r) * edge * (CLOUD_MID_ERODE.y * CLOUD_MID_EROSION);
        if (d <= 0.0) return 0.0;
    }
    // 低層 (縁で急に立ち上げる 3 乗) より柔らかく立ち上げる。遠い薄い小塊は輪郭がぼやけて見える
    d = smoothstep(0.0, CLOUD_MID_EDGE_WIDTH, d);
    // 小さな粒・群れの縁の粒ほど水量が少なく透ける (一様に濃いと、輪郭のはっきりした白い小片が貼り付いたように見えた)
    float thin = mix(CLOUD_MID_GRAIN_THIN, 1.0, smoothstep(0.1, 0.8, grain));
    // 雨天の濃さの倍率は高層雲と本降りの時だけ。雨上がりの wetness が残る間 (雨天度 0.1-0.4) に被覆が増えた高積雲の粒まで
    // 濃くすると、低層の雲の周りに縁のくっきりした白い欠片が散らばった
    float rainScale = mix(1.0, ctx.densityScale, max(stratus, smoothstep(CLOUD_HAZE_RAIN.x, CLOUD_HAZE_RAIN.y, ctx.rain)));
    return d * mix(thin, 0.45, stratus) * rainScale;
}

float cloudMidDensity(CloudContext ctx, float cover, vec2 rel, float altitude, bool detail) {
    float grainHeight;
    return cloudMidDensity(ctx, cover, rel, altitude, detail, grainHeight);
}

// 中層が空に占める割合 (粒を均した粗い被覆)。下の層に落とす影に使う
float cloudMidCoverage(CloudContext ctx, float cover, vec2 rel) {
    float g = texture(cloudNoiseTex, (rel + ctx.midOrigin) / CLOUD_MID_PERIOD).g;
    float stratus = max(smoothstep(0.6, 1.0, cover), linearStep(CLOUD_MID_RAIN_VEIL.x, CLOUD_MID_RAIN_VEIL.y, ctx.rainLight));
    float patches = linearStep(1.0 - cover, 1.0 - cover + CLOUD_MID_PATCH_SOFTNESS, g);
    float altostratus = linearStep(0.3, 0.8, cover * (0.75 + 0.5 * g));
    // 高積雲の粒は群れの中の半分ほど、高層雲は薄いので雲 1 つ分より光を通す
    return mix(patches * 0.5, altostratus * 0.7, stratus);
}

/*
 * 上層 (薄い体積) の消散係数 (1/m)。cover: 天気図の上層の被覆, dist: 距離 (繊維の LOD)
 * veil: 消散のうち巻層雲の割合 (ハロ用)
 * 巻雲は房 (層の上の方の発生源) から氷晶が落ちて筋になる。筋は下ほど風下に取り残されて傾き、
 * 斜めに層を抜ける視線がその傾いた筋を積むので、平面の筋ノイズを貼ったような刷毛目にならない (real-clouds.md 3.5)
 */
float cloudHighExtinction(CloudContext ctx, float cover, vec2 rel, float altitude, float dist, bool detail, out float veil) {
    veil = 0.0;
    float h = (altitude - CLOUD_R_HIGH_BASE) / CLOUD_R_HIGH_DEPTH;
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec2 q = rel + ctx.highOrigin;
    // 低い所ほど風下の房から落ちてきた氷晶を読む = 筋が房から風上側へ傾いて垂れる
    q += CLOUD_HIGH_WIND_DIR * ((1.0 - h) * CLOUD_CIRRUS_FALL_SHEAR);
    vec4 broad = texture(cloudNoiseTex, q / CLOUD_HIGH_PATCH_PERIOD);
    // 巻雲は空一面ではなく群れで現れる
    float patches = linearStep(0.45, 0.85, broad.g + 0.35 * (cover - 0.5));
    // 風向き (2, 1) に回した座標 (x 風下, y 横)。東西のままだと朝夕に筋が太陽へ放射状に集まって光線のように見える。
    // 整数の回転行列なので、原点を CLOUD_HIGH_TILE で畳んでも繰り返しの継ぎ目が出ない
    vec2 wq = vec2(CLOUD_HIGH_WIND_ROT.x * q.x + CLOUD_HIGH_WIND_ROT.y * q.y, CLOUD_HIGH_WIND_ROT.x * q.y - CLOUD_HIGH_WIND_ROT.y * q.x);
    float cirrus = 0.0;
    if (patches > 0.0) {
        // 房: 3D Perlin-Worley を風下に伸ばして読む。高さでも形が変わるので、層を抜ける視線ごとに違う断面が積まれる
        vec3 pc = vec3(wq.x / CLOUD_CIRRUS_ALONG, altitude / CLOUD_CIRRUS_VERTICAL, wq.y / CLOUD_CIRRUS_ACROSS);
        vec2 s = texture(cloudShapeTex, pc).rg;
        float threshold = 1.0 - 0.6 * cover;
        float tuft = s.r * 0.75 + broad.g * 0.25;
        float body = smoothstep(threshold, threshold + 0.22, tuft) * patches;
        // 鉛直の分布: 房 (上) が濃く、落下筋 (下) は薄れながら垂れる
        cirrus = body * smoothstep(0.0, 0.45, h) * (1.0 - smoothstep(0.85, 1.0, h)) * mix(0.4, 1.0, smoothstep(0.35, 0.85, h));
        if (detail && cirrus > 0.0 && dist < 50000.0) {
            // 繊維: 細かい Worley を風下に伸ばし、房の形状ノイズで曲げて密度に掛ける (輪郭は房の柔らかいまま、中に糸の濃淡)
            vec3 warp = vec3(s.g - 0.5, 0.0, s.r - 0.5) * 2.0;
            vec3 pf = vec3(wq.x / CLOUD_CIRRUS_FIBER_ALONG, altitude / CLOUD_CIRRUS_FIBER_VERTICAL, wq.y / CLOUD_CIRRUS_FIBER_ACROSS) + warp * CLOUD_CIRRUS_FIBER_CURL;
            float fiber = texture(cloudDetailTex, pf).r;
            // 遠くは繊維が画素より細かくちらつくので均す
            fiber = mix(fiber, 0.6, smoothstep(12000.0, 50000.0, dist));
            cirrus *= mix(CLOUD_CIRRUS_FIBER_MIN, 1.0, fiber);
            // 房の縁は繊維の谷から先に消える (ほつれた縁)
            cirrus = max(cirrus - (1.0 - fiber) * 0.25 * (1.0 - cirrus), 0.0);
        }
    }
    // 巻積雲: 層の上の方に細かい粒が所々に群れる。粒で穴を開けず、まだらな薄い膜にする (粒だけだと点描の網に見える)
    // 粒は風と直交する向きに少し並べる (さざ波状)。遠くは粒が画素より細かくちらつくので早めに均す
    float ccPatch = linearStep(0.9 - 0.1 * cover, 1.05 - 0.1 * cover, broad.r + 0.1 * (broad.g - 0.5));
    float cirrocumulus = 0.0;
    if (ccPatch > 0.0) {
        float grain = texture(cloudNoiseTex, q / CLOUD_CC_PERIOD * vec2(1.0, 2.0)).a;
        float grainFade = smoothstep(5000.0, 20000.0, dist);
        cirrocumulus = mix(mix(0.3, 1.0, smoothstep(0.15, 0.85, grain)), 0.6, grainFade) * sqr(ccPatch) * smoothstep(0.65, 0.8, h) * (1.0 - smoothstep(0.92, 1.0, h));
    }
    // 巻層雲: 広く覆う時の一様なベール
    float cs = linearStep(0.7, 1.2, cover) * (0.6 + 0.4 * broad.g) * smoothstep(0.1, 0.3, h) * (1.0 - smoothstep(0.75, 0.95, h));
    float extinction = cirrus * CLOUD_CIRRUS_SIGMA + cirrocumulus * CLOUD_CC_SIGMA + cs * CLOUD_CS_SIGMA;
    veil = extinction > 0.0 ? cs * CLOUD_CS_SIGMA / extinction : 0.0;
    return extinction;
}

/*------------------------------------------------------------------------------
  ライティング
------------------------------------------------------------------------------*/
// Draine の位相関数 (HG に (1 + alpha cos^2) を掛けて正規化したもの)
float cloudPhaseDraine(float cosTheta, float g, float alpha) {
    float g2 = g * g;
    float hg = (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1e-6), 1.5);
    return SKY_PHASE_ISOTROPIC * hg * (1.0 + alpha * cosTheta * cosTheta) / (1.0 + alpha * (1.0 + 2.0 * g2) / 3.0);
}

// 雲粒の位相 (HG + Draine の Mie 近似 + グローリー)。scale で非対称性を弱める (多重散乱のオクターブ・厚い所)
float cloudPhase(float cosTheta, float scale) {
    float forward = skyPhaseHG(cosTheta, CLOUD_MIE_G_HG * scale);
    float bulk = cloudPhaseDraine(cosTheta, CLOUD_MIE_G_D * scale, CLOUD_MIE_ALPHA * scale);
    float glory = skyPhaseHG(cosTheta, CLOUD_GLORY_G * scale) * CLOUD_GLORY_WEIGHT;
    return mix(forward, bulk, CLOUD_MIE_W_D) + glory;
}

// 光源方向の透過率 (べき乗則)。厚い所ほど指数より光が抜ける
float cloudLightTransmittance(float od) { return pow(1.0 + od * (1.0 / CLOUD_HETEROGENEITY), -CLOUD_HETEROGENEITY); }

struct CloudLighting {
    vec3 lightDir;         // ワールドの光源方向 (参照空間へはサンプルごとに cloudRefDir で写す)
    vec3 lightIrradiance;  // 雲の高度での光源照度
    vec3 skyRadiance;      // 上半球の空の平均放射 (= 上向き照度 / pi)
    vec3 groundRadiance;   // 下からの地面の照り返し
    float cosTheta;        // 視線と光源の角度
    float overcastDiffuse; // 雨雲の拡散透過の重み
};

// rain: 雲の中の光の雨天度 (CloudClimate.rainLight)。rainStrength (数秒で切り替わる) より少し遅く、被覆より早い
CloudLighting cloudLightingSetup(vec3 viewDir, float rain) {
    CloudLighting l;
    l.lightDir = frameData.skyParams[0].a > 0.0 ? getSunDir() : getMoonDir();
    l.lightIrradiance = frameData.skyParams[0].rgb;
    // 厚い雨雲の中の光は何度も散乱して太陽の色味が抜け、上から入る青空の光も混ざるのでわずかに寒色の灰になる
    // (太陽色のままだと雨雲が茶色く見える)
    l.lightIrradiance = mix(l.lightIrradiance, luminance(l.lightIrradiance) * CLOUD_OVERCAST_TINT, 0.7 * rain);
    vec3 skyUp = frameData.skyParams[2].rgb; // 彩度を落とす前の真上の空の照度 (prepare.csh)
    // 雷は雲の中を一瞬照らす。夜の露出のまま空一面が白飛びしないよう、月夜の地面の数倍の明るさに留める
    // (旧 4.0 は月光の数百倍で、雲の覆う空が真っ白になり降雪が黒い点に見えた)
    float lightning = lightningBoltPosition.w > 0.5 ? 1.0 : 0.0;
    skyUp += vec3(0.75, 0.8, 1.0) * lightning * CLOUD_LIGHTNING_FLASH;
    l.skyRadiance = skyUp * RCP_PI;
    vec3 groundIrradiance = frameData.sunIrradiance.rgb * max(getSunDir().y, 0.0) + frameData.moonIrradiance.rgb * max(getMoonDir().y, 0.0) + skyUp;
    l.groundRadiance = groundIrradiance * CLOUD_GROUND_ALBEDO * RCP_PI;
    l.cosTheta = dot(viewDir, l.lightDir);
    l.overcastDiffuse = CLOUD_OVERCAST_DIFFUSE * rain;
    return l;
}

/*
 * 1 サンプルの内散乱放射 (散乱係数 1 あたり)
 * extinction: その点の消散係数, odLight / odSky: 光源 / 真上への光学的深さ, groundVisibility: 地面の照り返しの届き具合
 * upperT: 上の層による光源の透過率, cloudHeight: その雲の中の高さ (底 0 / 頂 1)
 */
vec3 cloudInscatter(CloudLighting l, float extinction, float odLight, float odSky, float groundVisibility, float upperT, float cloudHeight) {
    // 周りに散乱体が少ない縁では多重散乱が育たない
    float growth = 1.0 - exp(-extinction * CLOUD_MS_LENGTH);
    float msGain = growth * CLOUD_MS_GAIN;
    float anisotropy = 1.0 / (1.0 + CLOUD_ANISO_DECAY * odLight);
    // 銀の縁: 前方の光を後段でもう一段持ち上げる (光学的に薄い逆光の縁ほど単散乱が残るので際立つ)
    float silver = CLOUD_SILVER_BOOST * skyPhaseHG(l.cosTheta, CLOUD_SILVER_G * anisotropy);
    float sun = cloudPhase(l.cosTheta, anisotropy) * cloudLightTransmittance(odLight) * (1.0 + silver);
    float ms = 0.0;
    float a = CLOUD_MS_ATTENUATION, b = CLOUD_MS_CONTRIBUTION, c = CLOUD_MS_ECCENTRICITY;
    for (int i = 1; i < CLOUD_MULTISCATTER; i++) {
        ms += b * cloudPhase(l.cosTheta, anisotropy * c) * cloudLightTransmittance(odLight * a);
        // 拡散光も吸収と横への漏れで減衰するので、高次のオクターブでも透過率の傾きを 0 にしない
        // (0 にすると厚い雲の底まで上面とほぼ同じ明るさになり、立体感が消える)
        a = max(a * CLOUD_MS_ATTENUATION, CLOUD_MS_DIFFUSION);
        b *= CLOUD_MS_CONTRIBUTION;
        c *= CLOUD_MS_ECCENTRICITY;
    }
    // 暗く重い底: 底の近くほど多重散乱と空の光が届かない
    float bottom = mix(CLOUD_BOTTOM_LIGHT, 1.0, smoothstep(0.0, CLOUD_BOTTOM_REACH, cloudHeight));
    sun += ms * msGain * bottom * (1.0 + silver * CLOUD_SILVER_MS);
    // 下部の側面は上の塊に空と太陽の一部を遮られ、上から下へ明るさが落ちる (順光で雲全体が一様に白く、立体感の無い綿玉に見えた)
    sun *= mix(CLOUD_BOTTOM_SUN, 1.0, smoothstep(0.0, CLOUD_BOTTOM_REACH, cloudHeight));
    // powder: 順光ほど、散乱体の少ない縁が暗い縁取りになる (逆光では縁が銀に光るので効かせない)
    float powder = 1.0 - CLOUD_POWDER_STRENGTH * saturate(0.5 - 0.5 * l.cosTheta) * exp(-extinction * CLOUD_POWDER_LENGTH);
    sun *= powder;
    sun += l.overcastDiffuse * SKY_PHASE_ISOTROPIC / (1.0 + CLOUD_AMBIENT_DIFFUSION * odLight);
    // 空の光は上半球からの等方入射 = E / 2pi。地面の照り返しは雲の底ほど届く
    float sky = (1.0 + CLOUD_AMBIENT_MS * growth) / (1.0 + CLOUD_AMBIENT_DIFFUSION * odSky) * mix(0.6, 1.0, bottom);
    vec3 ambient = (l.skyRadiance * 0.5 * sky + l.groundRadiance * 0.5 * groundVisibility) * CLOUD_AMBIENT;
    // 上の層の影は雲の表面だけにくっきり落ち、奥では光が拡散して均される (底に放射状の縞を作らない)
    float shadow = pow(upperT, exp(-0.2 * odLight));
    return l.lightIrradiance * (sun * shadow) + ambient;
}

// 低層の光源方向の光学的深さ。歩幅を毎回 2 倍に伸ばす (近くは細かく、遠くは粗く)。先頭 2 歩だけ侵食ノイズを使う
// lightDir: 参照空間の光源方向
float cloudLowLightOD(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, vec3 lightDir, float dither) {
    float stepLength = CLOUD_LIGHT_STEP0;
    float t = 0.0;
    float od = 0.0;
    for (int i = 0; i < CLOUD_LIGHT_STEPS; i++) {
        float sampleT = t + stepLength * dither;
        float a = altitude + lightDir.y * sampleT;
        if (a > ctx.lowTop || a < CLOUD_R_BASE) break;
        od += cloudLowDensity(ctx, col, rel + lightDir.xz * sampleT, a, i < 2, true) * stepLength;
        t += stepLength;
        stepLength *= 2.0;
    }
    return od * (CLOUD_LOW_SHADE_SIGMA * CLOUD_LIGHT_OD_SCALE);
}

// 低層の真上 (空の光) 方向の光学的深さ
float cloudLowSkyOD(CloudContext ctx, CloudColumn col, vec2 rel, float altitude) {
    float stepLength = CLOUD_R_DEPTH * 0.06;
    float t = 0.0;
    float od = 0.0;
    for (int i = 0; i < CLOUD_SKY_STEPS; i++) {
        float a = altitude + t + stepLength * 0.5;
        if (a > ctx.lowTop) break;
        od += cloudLowDensity(ctx, col, rel, a, false, false) * stepLength;
        t += stepLength;
        stepLength *= 3.0;
    }
    return od * (CLOUD_LOW_SHADE_SIGMA * CLOUD_SKY_OD_SCALE);
}

// 中層の光源方向の光学的深さ (薄い層なので短く)
float cloudMidLightOD(CloudContext ctx, float cover, vec2 rel, float altitude, vec3 lightDir, float dither) {
    float stepLength = CLOUD_LIGHT_STEP0 * 0.75;
    float t = 0.0;
    float od = 0.0;
    for (int i = 0; i < CLOUD_MID_LIGHT_STEPS; i++) {
        float sampleT = t + stepLength * dither;
        float a = altitude + lightDir.y * sampleT;
        if (a > CLOUD_R_MID_TOP || a < CLOUD_R_MID_BASE) break;
        od += cloudMidDensity(ctx, cover, rel + lightDir.xz * sampleT, a, i == 0) * stepLength;
        t += stepLength;
        stepLength *= 2.5;
    }
    return od * CLOUD_MID_SIGMA;
}

/*
 * 上の層 (中層・上層) が参照高度 altitude の点に落とす影 (光源の透過率)。lightDir: 参照空間の光源方向
 * 上の層の真ん中の高さで 1 点だけ密度を見る (層が薄いので十分)
 */
float cloudUpperTransmittance(CloudContext ctx, vec2 rel, float altitude, vec3 lightDir) {
    float ly = max(lightDir.y, 0.08);
    float transmittance = 1.0;
#ifdef CLOUD_MID_LAYER
    if (altitude < CLOUD_R_MID_BASE) {
        // 粒単位の影は下の雲に斑点を作るだけなので、群れの粗い被覆で柔らかく落とす。
        // 途切れた層の平均の透過率は「隙間の割合 + 雲の割合 x 雲 1 つの透過率」(密度を均してから Beer にすると暗くなりすぎる)
        vec2 p = rel + lightDir.xz * ((CLOUD_R_MID_BASE + 0.5 * CLOUD_R_MID_DEPTH - altitude) / ly);
        float fraction = cloudMidCoverage(ctx, cloudMapFetch(p).b * CLOUD_COVER_RANGE, p);
        float cloudT = cloudLightTransmittance(CLOUD_MID_SIGMA * CLOUD_R_MID_DEPTH * CLOUD_MID_SHADOW / ly);
        transmittance *= 1.0 - fraction * (1.0 - cloudT);
    }
#endif
#ifdef CLOUD_CIRRUS
    if (altitude < CLOUD_R_HIGH_BASE) {
        float a = CLOUD_R_HIGH_BASE + 0.7 * CLOUD_R_HIGH_DEPTH;
        vec2 ph = rel + lightDir.xz * ((a - altitude) / ly);
        float veil;
        float od = cloudHighExtinction(ctx, cloudMapFetch(ph).a * CLOUD_COVER_RANGE, ph * (CLOUD_KH_HIGH / CLOUD_KH), a, 0.0, false, veil) * (0.6 * CLOUD_R_HIGH_DEPTH);
        // 氷晶の散乱はほとんど前方なので、影としての減衰は光学的深さの一部だけ。
        // 夕方に細い筋の影が下の雲にくっきり縞を作らないよう、斜めの光路の伸びも抑える
        transmittance *= exp(-0.3 * od / max(ly, 0.3));
    }
#endif
    return transmittance;
}

/*------------------------------------------------------------------------------
  レイマーチ (ワールドの視線で歩き、サンプルを参照空間へ写す)
------------------------------------------------------------------------------*/
struct CloudAccum {
    vec3 scattering;
    float transmittance;
    float meanDistance; // 散乱の重み付き平均距離 (参照 m, 空中遠近用)
    float meanAltitude; // 同じく参照高度
};

// 視線 dir の距離 t (ワールド) の点 (参照高度 altitude) までの参照空間の距離。kh: その層の水平の縮尺
float cloudRefDistance(CloudContext ctx, vec3 dir, float t, float altitude, float kh) {
    return length(vec2(t * length(dir.xz) * kh, altitude - ctx.cameraAltitude));
}
float cloudRefDistance(CloudContext ctx, vec3 dir, float t, float altitude) { return cloudRefDistance(ctx, dir, t, altitude, CLOUD_KH); }

// 重み付き平均の距離・高度を書き込む
void cloudAccumFinish(inout CloudAccum acc, vec3 sums, CloudContext ctx, vec3 dir, float tStart) {
    if (sums.z > 1e-4) {
        acc.meanDistance = sums.x / sums.z;
        acc.meanAltitude = sums.y / sums.z;
    } else {
        float y = cloudAltitudeAt(cameraPosition.y, dir.y, tStart, cameraPosition.y);
        acc.meanAltitude = cloudRefAltitude(y);
        acc.meanDistance = cloudRefDistance(ctx, dir, tStart, acc.meanAltitude);
    }
}

// share: 区間を分けて呼ぶ時のこの区間の歩数の割合 (分けない時 1)
CloudAccum cloudMarchLow(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, vec2 dither, float share) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_BASE + ctx.lowTopWorld);
    // 水平に近い視線ほど層の中を長く通るので歩数を増やす (上限 3 倍)
    float stepScale = clamp(segLength / share / ((ctx.lowTopWorld - CLOUD_BASE) * 1.5), 1.0, 3.0);
    int steps = max(int(float(CLOUD_LOW_STEPS) * stepScale * share), 4);
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither.x;
    float y0 = cameraPosition.y;
    vec3 sums = vec3(0.0); // 距離 x 重み, 高度 x 重み, 重み
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        vec2 rel = dir.xz * (t * CLOUD_KH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        CloudColumn col = cloudLowColumn(cloudMapFetch(rel));
        float cloudHeight;
        float density = cloudLowDensity(ctx, col, rel, altitude, cloudDetailLod(tRef), false, cloudHeight);
        if (density <= 0.0) continue;

        float extinction = density * CLOUD_LOW_SIGMA;
        float h = saturate((altitude - CLOUD_R_BASE) / CLOUD_R_DEPTH);
        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH, slope);
        float odLight = cloudLowLightOD(ctx, col, rel, altitude, lightDir, dither.y);
        float odSky = cloudLowSkyOD(ctx, col, rel, altitude);
        float upperT = cloudUpperTransmittance(ctx, rel, altitude, lightDir);
        vec3 inscatter = cloudInscatter(l, extinction, odLight, odSky, sqr(1.0 - h), upperT, cloudHeight);

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
        if (acc.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            // 打ち切った残りを 0 にする (残りの数 % でも太陽円盤や星は雲より桁違いに明るく、厚い雲を透けて見えてしまう)
            acc.transmittance = 0.0;
            break;
        }
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}

#ifdef CLOUD_MID_LAYER
CloudAccum cloudMarchMid(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, vec2 dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_MID_BASE + CLOUD_MID_TOP);
    float stepScale = clamp(segLength / ((CLOUD_MID_TOP - CLOUD_MID_BASE) * 2.0), 1.0, 3.0);
    int steps = int(float(CLOUD_MID_STEPS) * stepScale);
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither.x;
    float y0 = cameraPosition.y;
    vec3 sums = vec3(0.0);
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        vec2 rel = dir.xz * (t * CLOUD_KH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        float cover = cloudMapFetch(rel).b * CLOUD_COVER_RANGE;
        float grainHeight;
        float density = cloudMidDensity(ctx, cover, rel, altitude, tRef < CLOUD_DETAIL_FADE.y, grainHeight);
        if (density <= 0.0) continue;

        float extinction = density * CLOUD_MID_SIGMA;
        float h = saturate((altitude - CLOUD_R_MID_BASE) / CLOUD_R_MID_DEPTH);
        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH, slope);
        float odLight = cloudMidLightOD(ctx, cover, rel, altitude, lightDir, dither.y);
        // 真上は層の上端までの 1 歩で足りる
        float above = CLOUD_R_MID_TOP - altitude;
        float odSky = cloudMidDensity(ctx, cover, rel, altitude + above * 0.5, false) * above * CLOUD_MID_SIGMA;
        float upperT = cloudUpperTransmittance(ctx, rel, altitude, lightDir);
        // 地面の照り返しは低層の雲にさえぎられるので弱める
        // 粒の下側を沈めて、粒ごとに陰影を付ける (層の中の高さだけで沈めていた時は、陰の無い白い粒が並んで見えた)
        vec3 inscatter = cloudInscatter(l, extinction, odLight, odSky, 0.3 * (1.0 - h), upperT, CLOUD_MID_GRAIN_SHADE + (1.0 - CLOUD_MID_GRAIN_SHADE) * grainHeight);

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
        if (acc.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            // 打ち切った残りを 0 にする (残りの数 % でも太陽円盤や星は雲より桁違いに明るく、厚い雲を透けて見えてしまう)
            acc.transmittance = 0.0;
            break;
        }
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}
#endif

#ifdef CLOUD_CIRRUS
// 上層 (薄い体積)。光学的に薄いので単散乱 + 等方な多重散乱の底上げ + 空の光。光源までは層の上端までの解析的な透過率
CloudAccum cloudMarchHigh(CloudContext ctx, CloudLighting l, vec3 dir, vec2 seg, float dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float segLength = seg.y - seg.x;
    float yMid = 0.5 * (CLOUD_HIGH_BASE + CLOUD_HIGH_TOP);
    float stepScale = clamp(segLength / ((CLOUD_HIGH_TOP - CLOUD_HIGH_BASE) * 2.0), 1.0, 1.5);
    int steps = int(float(CLOUD_HIGH_STEPS) * stepScale);
    // 上層の被覆は天気図の規模 (数十 km) でしか変わらないので、層の中ほどで 1 回だけ読む
    float cover = cloudMapFetch(dir.xz * ((seg.x + 0.5 * segLength) * CLOUD_KH)).a * CLOUD_COVER_RANGE;
    float dt = segLength / float(steps);
    float t = seg.x + dt * dither;
    float y0 = cameraPosition.y;
    // 氷晶は前方散乱が液滴より弱い。巻層雲は太陽の周り 22 度にハロを作る
    float angle = acos(clamp(l.cosTheta, -1.0, 1.0));
    float haloLobe = CLOUD_HALO_STRENGTH * exp(-sqr((angle - CLOUD_HALO_ANGLE) / CLOUD_HALO_WIDTH));
    float icePhase = (1.0 - CLOUD_ICE_BACK) * skyPhaseHG(l.cosTheta, CLOUD_ICE_G) + CLOUD_ICE_BACK * skyPhaseHG(l.cosTheta, -0.2);
    vec3 sums = vec3(0.0);
    for (int i = 0; i < steps; i++, t += dt) {
        float y = cloudAltitudeAt(y0, dir.y, t, yMid);
        float slope;
        float altitude = cloudRefAltitude(y, slope);
        // 天気図は低層と同じ縮尺の座標で引き、形は上層の縮尺で読む
        vec2 rel = dir.xz * (t * CLOUD_KH_HIGH);
        float tRef = cloudRefDistance(ctx, dir, t, altitude, CLOUD_KH_HIGH);
        float veil;
        float extinction = cloudHighExtinction(ctx, cover, rel, altitude, tRef, true, veil);
        if (extinction <= 0.0) continue;

        vec3 lightDir = cloudRefDir(l.lightDir, CLOUD_KH_HIGH, slope);
        // 光源までは層の上端まで、その点と同じ濃さで続くとみなす
        float odLight = extinction * (CLOUD_R_HIGH_TOP - altitude) / max(abs(lightDir.y), 0.05);
        float phase = icePhase + veil * haloLobe;
        float multiScatter = SKY_PHASE_ISOTROPIC * (1.0 - exp(-odLight - extinction * 600.0));
        vec3 inscatter = l.lightIrradiance * (phase * exp(-odLight) + multiScatter) + l.skyRadiance * 0.5 + l.groundRadiance * 0.25;

        float stepT = exp(-extinction * dt * cloudRefStretch(dir, CLOUD_KH_HIGH, slope));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += inscatter * CLOUD_ALBEDO * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
    }
    cloudAccumFinish(acc, sums, ctx, dir, seg.x);
    return acc;
}
#endif

#ifdef CLOUD_CB
/*
 * 降水の柱 (雨脚): カメラが雲底より下の時、雲底 (下向きは海面) までの区間で嵐の芯の下の雨を積む
 * 雨粒の幕は厚い雲の影の中なので、光源の光はわずかで、灰色の空の光が主
 */
CloudAccum cloudMarchShaft(CloudContext ctx, CloudLighting l, vec3 dir, float maxDist, float dither) {
    CloudAccum acc = CloudAccum(vec3(0.0), 1.0, 0.0, 0.0);
    float y0 = cameraPosition.y;
    float tStart = CLOUD_SHAFT_NEAR / CLOUD_KH;
    float tEnd = min(maxDist, CLOUD_SHAFT_FAR / CLOUD_KH);
    if (dir.y > 1e-4) tEnd = min(tEnd, (CLOUD_BASE - y0) / dir.y);
    else if (dir.y < -1e-4) tEnd = min(tEnd, (y0 - SKY_SEA_LEVEL) / -dir.y);
    if (ctx.storm <= 1e-3 || y0 >= CLOUD_BASE || tEnd <= tStart) return acc;
    // 近くを細かく: 区間を距離の平方根で分ける
    float a = sqrt(tStart), b = sqrt(tEnd);
    float ds = (b - a) / float(CLOUD_SHAFT_STEPS);
    vec3 radiance = l.skyRadiance * 0.18 + l.lightIrradiance * (SKY_PHASE_ISOTROPIC * 0.06) + l.groundRadiance * 0.3;
    vec3 sums = vec3(0.0);
    for (int i = 0; i < CLOUD_SHAFT_STEPS; i++) {
        float s0 = a + ds * float(i);
        float s = s0 + ds * dither;
        float t = s * s;
        float dt = (s0 + ds) * (s0 + ds) - s0 * s0;
        float y = y0 + dir.y * t;
        float altitude = cloudRefAltitude(y);
        float fall = CLOUD_R_BASE - altitude;
        // 雨は風下へ流されながら落ちる (柱が斜めに傾く)
        vec2 rel = dir.xz * (t * CLOUD_KH) - CLOUD_WIND_DIR * (fall * CLOUD_SHAFT_SLANT);
        float type = cloudMapFetch(rel).g;
        float core = cloudStormCore(type) * cloudCumulonimbusWeight(type);
        if (core <= 0.0) continue;
        // 雨の強弱の筋と、地面に近いほど少し蒸発して薄れる
        float streak = 0.5 + texture(cloudNoiseTex, (rel + ctx.lowOrigin) / (CLOUD_CELL_PERIOD * 0.5) * vec2(1.0, 3.0)).g;
        float tRef = cloudRefDistance(ctx, dir, t, altitude);
        // 手前の打ち切り (CLOUD_SHAFT_NEAR) から距離をかけて濃くする。急に始めると、雲底がその距離より近くなる仰角を境に
        // 雨の幕の有無が切り替わり、幕の向こうの積乱雲に直線の縁の明るい面が出た
        float nearFade = smoothstep(CLOUD_SHAFT_NEAR, CLOUD_SHAFT_NEAR * 4.0, tRef);
        float extinction = linearStep(0.15, 0.6, core) * streak * mix(0.6, 1.0, saturate(altitude / CLOUD_R_BASE)) * CLOUD_SHAFT_SIGMA * ctx.storm * nearFade;
        float stepT = exp(-extinction * dt * cloudRefStretch(dir, y));
        float weight = acc.transmittance * (1.0 - stepT);
        acc.scattering += radiance * weight;
        sums += vec3(tRef, altitude, 1.0) * weight;
        acc.transmittance *= stepT;
    }
    cloudAccumFinish(acc, sums, ctx, dir, tStart);
    return acc;
}
#endif

// 高さ a..b (km) の区間での指数分布 exp(-y/H) の平均
float cloudExpMean(float a, float b, float H) {
    float d = b - a;
    return abs(d) < 1e-3 ? exp(-0.5 * (a + b) / H) : H * (exp(-a / H) - exp(-b / H)) / d;
}

// 大気の消散係数 (1/km) の高さ a..b (km) の区間平均。Mie はもやの倍率込み
vec3 cloudAerialExtinction(float a, float b, float haze) {
    return ATMO_RAYLEIGH_SCATTER * (CLOUD_AERIAL_RAYLEIGH * cloudExpMean(a, b, ATMO_RAYLEIGH_HEIGHT))
         + ATMO_MIE_EXTINCT * (haze * cloudExpMean(a, b, ATMO_MIE_HEIGHT));
}

/*
 * 雲の空中遠近: 視線 dir で参照距離 dist、参照高度 altitude の雲までの大気の透過率 (戻り値) と、
 * その方向の空の放射 (= 大気の上端までの内散乱) のうち雲より手前の区間の取り分 share
 * 取り分は光学的深さの割合 (1 - T(dist)) / (1 - T(大気の上端)) で見積もる。空の色そのもの (SkyView LUT) を使うので、
 * 時刻・太陽高度・方位に応じた色へ溶ける (夕方は地平線の雲が橙の空に溶け、真上の雲には青みが少し乗る)
 * 参照空間の距離で測るので、縮めた高さテンプレートでも遠い雲の霞み方が現実比と同じ
 */
vec3 cloudAerialPerspective(CloudContext ctx, vec3 dir, float dist, float altitude, float rain, out vec3 share) {
    float haze = CLOUD_AERIAL_MIE * (1.0 + CLOUD_AERIAL_RAIN * rain);
    float y0 = max(ctx.cameraAltitude - ctx.seaAltitude, 0.0) * 1e-3;
    float y1 = max(altitude - ctx.seaAltitude, 0.0) * 1e-3;
    vec3 transmittance = exp(-cloudAerialExtinction(y0, y1, haze) * (dist * 1e-3));
    // 大気の上端までの光学的深さ: 指数大気の鉛直積分を見かけの傾きで割る (地平線付近は曲率で長さが頭打ちになる)
    float mu = max(dir.y, 0.03);
    vec3 odFull = (ATMO_RAYLEIGH_SCATTER * (CLOUD_AERIAL_RAYLEIGH * ATMO_RAYLEIGH_HEIGHT * exp(-y0 / ATMO_RAYLEIGH_HEIGHT))
                 + ATMO_MIE_EXTINCT * (haze * ATMO_MIE_HEIGHT * exp(-y0 / ATMO_MIE_HEIGHT))) / mu;
    share = saturate((1.0 - transmittance) / max(1.0 - exp(-odFull), 1e-3));
    return transmittance;
}

// 層の結果を手前から重ねる。遠い雲ほど空の色に溶かし、fadeEnd (参照 m) で完全に空へ戻す
void cloudComposite(CloudContext ctx, inout vec3 scattering, inout float transmittance, CloudAccum layer, vec3 dir, vec3 skyColor, float fadeEnd) {
    vec3 share;
    float farFade = 1.0 - smoothstep(fadeEnd * 0.6, fadeEnd, layer.meanDistance);
    vec3 fade = cloudAerialPerspective(ctx, dir, layer.meanDistance, layer.meanAltitude, ctx.rain * (1.0 - CLOUD_THUNDER_HAZE_CUT * thunderStrength), share) * farFade;
    share = mix(vec3(1.0), share, farFade);
    // 雲が隠した背景の空のうち、雲より手前の大気の内散乱のぶんは雲の上に戻す
    vec3 s = layer.scattering * fade + skyColor * share * (1.0 - layer.transmittance);
    scattering += transmittance * s;
    transmittance *= layer.transmittance;
}

/*
 * 視線 dir の雲 (降水の柱 + 低層 + 中層 + 上層を手前から順に)。maxDist: 地形までの距離 (ワールド, 空なら大きな値)
 * dither: x = 視線方向, y = 光方向のマーチの開始位置
 * 戻り値: rgb = 散乱光 (空中遠近込み), a = 透過率
 */
vec4 renderClouds(vec3 dir, float maxDist, vec2 dither) {
    CloudContext ctx = cloudContextSetup(cloudClimate());
    CloudLighting l = cloudLightingSetup(dir, ctx.rainLight);
    vec3 skyColor = getSkyRadiance(dir);
    float y0 = cameraPosition.y;
    float farLimit = min(maxDist, CLOUD_MAX_DISTANCE / CLOUD_KH);

    vec2 segLow = cloudLayerSegment(y0, dir.y, CLOUD_BASE, ctx.lowTopWorld);
    segLow.y = min(segLow.y, farLimit);
    vec2 segMid = vec2(1.0, 0.0);
#ifdef CLOUD_MID_LAYER
    segMid = cloudLayerSegment(y0, dir.y, CLOUD_MID_BASE, CLOUD_MID_TOP);
    segMid.y = min(segMid.y, farLimit);
#endif
    vec2 segHigh = vec2(1.0, 0.0);
#ifdef CLOUD_CIRRUS
    segHigh = cloudLayerSegment(y0, dir.y, CLOUD_HIGH_BASE, CLOUD_HIGH_TOP);
    segHigh.y = min(segHigh.y, min(maxDist, CLOUD_HIGH_MAX_DISTANCE / CLOUD_KH));
#endif

    vec3 scattering = vec3(0.0);
    float transmittance = 1.0;
#ifdef CLOUD_CB
    // 降水の柱は雲底より下だけなので、どの層よりも手前
    if (ctx.storm > 1e-3) cloudComposite(ctx, scattering, transmittance, cloudMarchShaft(ctx, l, dir, maxDist, dither.x), dir, skyColor, CLOUD_SHAFT_FAR);
#endif
    // 層を視線の入口が近い順に処理する (カメラが雲の上にいる時は順序が逆になる)
    // 積乱雲は中層の高さを突き抜けるので、低層の区間を視線が中層を抜ける所で 2 つに分け、その先 (中層より上の塔・かなとこ) は
    // 中層の後ろに重ねる (分けないと雨の日の中層の雲の上にある陽の当たる塔が手前に描かれ、灰色の空に直線の縁の白い面が出た)
    vec2 segLowFar = vec2(1.0, 0.0);
    float lowShare = 1.0;
    if (ctx.storm > 1e-3 && segMid.y > segMid.x && segMid.y > segLow.x && segMid.y < segLow.y) {
        lowShare = (segMid.y - segLow.x) / (segLow.y - segLow.x);
        segLowFar = vec2(segMid.y, segLow.y);
        segLow.y = segMid.y;
    }
    float starts[4] = float[4](segLow.y > segLow.x ? segLow.x : 1e30, segMid.y > segMid.x ? segMid.x : 1e30, segHigh.y > segHigh.x ? segHigh.x : 1e30, segLowFar.y > segLowFar.x ? segLowFar.x : 1e30);
    for (int k = 0; k < 4; k++) {
        int idx = 0;
        for (int m = 1; m < 4; m++) if (starts[m] < starts[idx]) idx = m;
        if (starts[idx] >= 1e29 || transmittance < CLOUD_MIN_TRANSMITTANCE) break;
        starts[idx] = 1e30;
        if (idx == 0) {
            cloudComposite(ctx, scattering, transmittance, cloudMarchLow(ctx, l, dir, segLow, dither, lowShare), dir, skyColor, CLOUD_MAX_DISTANCE);
        } else if (idx == 3) {
            cloudComposite(ctx, scattering, transmittance, cloudMarchLow(ctx, l, dir, segLowFar, dither, 1.0 - lowShare), dir, skyColor, CLOUD_MAX_DISTANCE);
        }
#ifdef CLOUD_MID_LAYER
        else if (idx == 1) {
            cloudComposite(ctx, scattering, transmittance, cloudMarchMid(ctx, l, dir, segMid, dither), dir, skyColor, CLOUD_MAX_DISTANCE);
        }
#endif
#ifdef CLOUD_CIRRUS
        else {
            cloudComposite(ctx, scattering, transmittance, cloudMarchHigh(ctx, l, dir, segHigh, dither.x), dir, skyColor, CLOUD_HIGH_MAX_DISTANCE);
        }
#endif
    }
    return vec4(scattering, transmittance);
}

/*
 * 雲影マップ用: 低層の下面の点 rel (ワールド, カメラ基準) から光源方向に層を抜けるまでの透過率 (上の層の影も含む)
 * lightDir: ワールドの光源方向
 */
float cloudShadowTransmittance(CloudContext ctx, vec2 relWorld, vec3 lightDirWorld, float dither) {
    const int SHADOW_STEPS = 10;
    vec2 rel = relWorld * CLOUD_KH;
    vec3 lightDir = cloudRefDir(lightDirWorld, CLOUD_BASE);
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    float depth = ctx.lowTop - CLOUD_R_BASE;
    float pathLength = min(depth / ly, depth * 4.0);
    float dt = pathLength / float(SHADOW_STEPS);
    // 天気図は粗いので、光の通り道の手前寄りの 1 点で代表させる
    CloudColumn col = cloudLowColumn(cloudMapFetch(rel + lightDir.xz * (0.3 * pathLength)));
    float od = 0.0;
    for (int i = 0; i < SHADOW_STEPS; i++) {
        float t = (float(i) + dither) * dt;
        od += cloudLowDensity(ctx, col, rel + lightDir.xz * t, CLOUD_R_BASE + ly * t, false, true) * dt;
    }
    od *= CLOUD_LOW_SIGMA;
    // 多重散乱で厚い雲の下にも光が少し抜ける (オクターブ和の 2 項目相当)
    float transmittance = max(exp(-od), 0.25 * exp(-od * 0.25));
    return transmittance * cloudUpperTransmittance(ctx, rel, CLOUD_R_BASE, lightDir);
}

#endif
