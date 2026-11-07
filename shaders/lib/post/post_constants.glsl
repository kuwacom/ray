/*
 * post モジュールの内部定数 (ユーザー設定ではない調整値)
 * ユーザーに見せる設定は lib/settings/ にしかない。ここは「なぜその値か」を残すための置き場
 */
#ifndef POST_POST_CONSTANTS_GLSL
#define POST_POST_CONSTANTS_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/look_presets.glsl"

// 露出
// 自動露出が平均輝度を写す先の中間グレー (AgX は 0.18 を表示値 0.5 付近に置く)
const float EXPOSURE_KEY = 0.18;
// 反射光式の較正定数 (EV100 = log2(L * 100 / K))。設定の EV はこの EV100 として扱う
const float EXPOSURE_CALIBRATION = 12.5;
/*
 * 露出の追従を完全補正にしない (pow(L, -0.7) 相当の「カメラ感」。iterationT の考え方)
 * 暗い場面は少し暗いまま、明るい場面は少し明るいままにして明暗の印象を残す
 * 基準 EV で補正量 1、そこから離れるほど (1 - 曲線) の分だけ取り残す
 */
/*
 * 実測の計測 EV100: 晴れの昼 1.3-2.4、森の中 0、室内・洞窟のたいまつ -2.4..-2.8、夜 -7 (2026-10-19)
 * 基準を昼より上 (3.0) に置くと昼まで暗く写るので、夕方と洞窟の間 (-0.5) に置き、
 * 曲線 0.55 で昼を +0.8..+1.3 EV 明るく (雪が白く飛ぶ手前)、室内・洞窟を約 -0.9 EV 暗く残す
 */
const float EXPOSURE_CURVE = 0.55;
const float EXPOSURE_ANCHOR_EV = -0.5;
/*
 * 明るい場面ほど補正をさらに緩める (晴れの雪原・砂漠で白が白く写るように)
 * 計測 EV が LOW .. HIGH の間で、最大 BOOST EV だけ追加で明るく写す。夕方・室内・夜には効かない
 */
const float EXPOSURE_BRIGHT_BOOST = 0.4;
const float EXPOSURE_BRIGHT_EV_LOW = 0.0;
const float EXPOSURE_BRIGHT_EV_HIGH = 2.5;
/*
 * 屋外の夜だけ補正を強める (計測 EV が START より暗い分に SLOPE を掛けた EV だけ明るく写す。最大 MAX)
 * 曲線 0.55 のままだと晴れの夜 (計測 -7) が -3.9 にしか補正されず、地形が読めない。
 * 雨の夜 (計測 -8.5) は下限 -4 で止まってほぼ真っ黒になる
 * 一律に持ち上げると雨の夜だけ暗いまま残るので、暗いほど補正を 0.55 -> 0.9 に近づける形にする
 * 洞窟は暗さを残したいので、目の位置のスカイライトが低いと効かせない
 * -4.5 / 0.4 は、晴れの夜 (計測 -6.5) で地形が読め、灰色に浮かない明るさ (-4.8 / 0.35 では暗く、0.5 では明るく灰色に浮く)。上限 1.3 で雨の夜 (計測 -8.3) も同じくらいの明るさにする
 */
const float EXPOSURE_NIGHT_EV_START = -4.5;
const float EXPOSURE_NIGHT_SLOPE = 0.4;
const float EXPOSURE_NIGHT_MAX_LIFT = 1.3;
/*
 * 灯りの点いた屋内・洞窟 (計測 EV -1.5 .. -3.5、目の位置のスカイライトが低い) を DIM EV 暗く写す
 * ブロックライトの届く範囲が広いので計測 EV が上がり、そのままでは灯りを点けた部屋やたいまつの灯る洞窟が 1 段明るく平板で、
 * AgX で明るい面の色が抜けて灯りが白っぽく見える
 * EV の窓 (x..y で 0 -> 1, z..w で 1 -> 0)。両側とも 2 EV 前後かけて変え、計測 EV に対して表示の明るさが逆転しないようにする
 * 0.5 EV では灯りを点けた部屋がまだ明るく平板なので強めにする。
 * たいまつ 1 本の暗い洞窟 (計測 -4 前後) はそれ以上暗くしないよう、窓の暗い側を -5.5 .. -2.5 に寄せる (幅 3 EV で計測 EV に対する表示の明るさの逆転を防ぐ)
 */
const float EXPOSURE_INDOOR_DIM = 1.0;
const vec4 EXPOSURE_INDOOR_EV = vec4(-4.0, -1.5, -1.0, 0.5);
/*
 * 屋内の減光は目の位置のブロックライト (eyeBrightnessSmooth.x / 240) がこの範囲で 0 -> 1 で効かせる
 * 灯りの無い窓だけの部屋まで暗くすると、日だまりが暗い琥珀色に沈む (窓だけの部屋の床 p90 が 170 から 69 に下がる)
 * 灯りを点けた部屋・たいまつの灯る洞窟の目の位置は 0.6 / 0.8、窓だけの部屋は 0
 */
const vec2 EXPOSURE_INDOOR_BLOCKLIGHT = vec2(0.1, 0.4);
/*
 * 屋外の夜の最低限の持ち上げ (EV)。計測 EV による持ち上げは、たいまつの灯りが画面に入ると計測 EV が上がって消え、
 * 灯りの周りの夜景が真っ黒に沈む。太陽高度で夜を判定して下支えする
 */
const float EXPOSURE_NIGHT_MIN_LIFT = 0.4;
/*
 * 水中を暗く写す EV。水中は画面全体が内散乱のフォグになり、自動露出がそれを中間調まで持ち上げるので、
 * 吸収を強めても表示の明るさがほとんど変わらず、明るく白っぽい青になる
 */
const float EXPOSURE_UNDERWATER_DIM = 0.9;
/*
 * 昼の雨・雷雨を暗く写す EV (屋外だけ)。曇天は計測 EV が下がった分を自動露出が半分以上戻すので、
 * 雷雨の空が晴れの日とほぼ同じ明るさの明るい灰色に持ち上がり、重い空にならない
 * 夜の雨は夜の露出の持ち上げ (EXPOSURE_NIGHT_*) で明るさを決めているので、計測 EV が夜の側 (EXPOSURE_NIGHT_EV_START 付近) では効かせない
 */
const float EXPOSURE_RAIN_DIM = 0.45;
const float EXPOSURE_THUNDER_DIM = 1.0;
// ヒストグラムの範囲 (log2 輝度)。MIN_AMBIENT 付近の暗所から太陽円盤の手前まで
const float HISTOGRAM_LOG_MIN = -16.0;
const float HISTOGRAM_LOG_MAX = 10.0;
const float HISTOGRAM_LAST_BIN = 255.0;   // ビンは 0 (黒) と 1-255 (log2 輝度の等間隔)
// パーセンタイル: 暗すぎる影と空・太陽の外れ値を平均から除く (UE 4.25 方式)
const float HISTOGRAM_LOW_PERCENT = 0.35;
const float HISTOGRAM_HIGH_PERCENT = 0.92;
// 中央重点測光: 画面端の重み
const float METERING_EDGE_WEIGHT = 0.35;

// Purkinje 効果 (薄暗視の青シフト)
// 強さは設定 PURKINJE_STRENGTH。青すぎると不評になりやすいので既定は控えめ
// 順応輝度 (露出前のシーン単位) がこの範囲で錐体 -> 桿体へ移る
// 室内・洞窟のたいまつ (順応輝度 0.015-0.025) で効くと木材や石が灰緑に濁るので、月明かりの水準 (0.002 前後) から下だけにする
const float PURKINJE_LUM_LOW = 0.0005;
const float PURKINJE_LUM_HIGH = 0.008;

// TAA
// 静止時の今フレームの重み (= 履歴の実効長 1/α フレーム)
const float TAA_BLEND_STATIC = 0.07;
// 動いている時の重み (ゴーストを減らしつつ AA を残す)
const float TAA_BLEND_MOVING = 0.2;
// 手は画面に貼り付いて別の動きをするので履歴を短くする
const float TAA_BLEND_HAND = 0.35;
// variance clipping の幅 (σ の倍数)。静止時は緩く、動くと狭く
const float TAA_GAMMA_STATIC = 2.0;
const float TAA_GAMMA_MOVING = 0.85;
// ディスオクルージョン判定: 前フレームの距離との相対誤差
const float TAA_DEPTH_TOLERANCE = 0.04;
// 履歴の a に書く空の距離 (RGBA16F で表せる範囲)
const float TAA_SKY_DISTANCE = 60000.0;

// モーションブラー (McGuire 2012)
const int MOTION_BLUR_SAMPLES = 12;
// シャッター角 180 度 = 1 フレームの半分の移動量
const float MOTION_BLUR_SHUTTER = 0.5;
// ブラー長の上限 (画面高さ比)。タイルの近傍探索距離もこれで決まる
const float MOTION_BLUR_MAX_LENGTH = 0.04;
// 深度の前後判定の柔らかさ (ブロック)
const float MOTION_BLUR_DEPTH_SOFTNESS = 0.5;

// 被写界深度
/*
 * センサー高さ (mm)。FOV から焦点距離を出すのに使う (画面の縦 = センサーの縦)
 * 同じ画角・同じ F 値なら、センサーが大きいほど焦点距離が伸びてボケ (画面比) がセンサー高さに比例して増える
 * 大判は実フィルムの画面寸法 (4x5 = 約 96x120mm, 8x10 = 約 194x245mm)
 */
const float DOF_SENSOR_HEIGHT_FULL = 24.0;
#if DOF_SENSOR == 1
const float DOF_SENSOR_HEIGHT = 15.6;   // APS-C
#elif DOF_SENSOR == 2
const float DOF_SENSOR_HEIGHT = 33.0;   // 中判デジタル 44x33
#elif DOF_SENSOR == 3
const float DOF_SENSOR_HEIGHT = 56.0;   // 中判 6x7
#elif DOF_SENSOR == 4
const float DOF_SENSOR_HEIGHT = 96.0;   // 大判 4x5
#elif DOF_SENSOR == 5
const float DOF_SENSOR_HEIGHT = 194.0;  // 大判 8x10
#else
const float DOF_SENSOR_HEIGHT = DOF_SENSOR_HEIGHT_FULL;  // 35mm 判 36x24
#endif
/*
 * 絞りの直径 (mm, DOF_STRENGTH = 1 の時)
 * Minecraft の FOV (70 度前後) は 17mm 前後の広角なので、実在の F 値では殆どボケない
 * 薄レンズの式はそのまま使い、絞り径だけ誇張してボケを見える量にする
 * 80mm (DOF_STRENGTH 0.5 で 40mm = f/0.4 相当) では、近くの壁や床にピントが合った時に遠くのたいまつが
 * 10 px 以上の玉ボケになり「遠くの光が距離に比例して滲む」という報告があった
 * 16mm (既定 0.5 で 8mm = f/2 相当) にして、手前 2m に合焦した時の遠景のボケを約 2 px@752p (3 px@1080p) に抑える
 */
const float DOF_APERTURE_DIAMETER = 16.0;
// 既定 (DOF_STRENGTH 0.5, フルサイズ) の絞り径。ボケ半径の上限を広げる基準
const float DOF_APERTURE_REFERENCE = 8.0;
// ボケ半径の上限 (画面高さ比)。既定の絞りの時の値
const float DOF_MAX_RADIUS = 0.022;
/*
 * 絞り径 (遠景のボケの画面比はこれに比例) が既定の何倍かに合わせて上限を広げる、その倍率の上限
 * 0.022 x 7 = 画面高さの 15% (1080p で半径 166 px)。マクロ撮影の背景の大きなボケまで出し、
 * それ以上はサンプル数と前ボケの探索が追いつかないので打ち切る
 */
const float DOF_MAX_RADIUS_SCALE = 7.0;
// ミップの上限 (これ以上は四角いブロックが見える)
const float DOF_MAX_LOD = 4.0;
/*
 * 大きなボケのサンプル数: 1 サンプルの受け持ち幅がこの値 (px, 1080p 換算) 以下になる数まで増やす
 * 幅が粗いと点光源の玉ボケがサンプル配置のまだら・花のように欠けた縁になる (16 はまだら、11 で滑らか)
 * 既定の上限半径 (画面高さの 2.2%) では基本数 (DOF_QUALITY) のままなので、既定の見た目と負荷は解像度に依らず変わらない
 */
const float DOF_SAMPLE_SPACING = 11.0;
const float REFERENCE_HEIGHT = 1080.0;  // px: 画素数で決めた値を画面の高さに合わせて拡縮する基準
#if DOF_QUALITY == 0
const int DOF_SAMPLE_LIMIT = 256;
#elif DOF_QUALITY == 1
const int DOF_SAMPLE_LIMIT = 384;
#else
const int DOF_SAMPLE_LIMIT = 512;
#endif
// 中心の前ボケ半径 (px) がこれを超えたら、中心も前景層として扱う (前ボケの輪郭の内側も半透明にする)
const float DOF_NEAR_CENTER_COC = 1.0;
/*
 * 上の扱いを既定の絞り (上限半径を広げない設定) でも使うか
 * 使うと既定の前ボケの縁も内側へ柔らかくなる (合成シーンで縁の数 px、最大 53/255 の差)。既定の見た目を変えないため false
 */
const bool DOF_NEAR_CENTER_AT_DEFAULT = false;
/*
 * 既定の上限半径を超えるボケのミップの上限と、サンプル間隔に対するミップの上乗せ (log2)
 * 上乗せ 0 はまだら、1 以上は玉ボケの縁がガウスのように柔らかくなりすぎる (プレビューで 0 / 0.5 / 0.75 / 1 / 1.5 を比較)
 */
const float DOF_MAX_LOD_LARGE = 6.0;
const float DOF_LARGE_LOD_BIAS = 0.75;
// 絞り羽根の回転 (rad)
const float DOF_BLADE_ROTATION = 0.2;
/*
 * 縁の明るいボケ (LP_BOKEH_RIM / LP_SA_RIM) を効かせるボケ半径 (px) の範囲。実際の縁は円板の数 % の細い輪で、数 px の小さなボケでは
 * 画素と回折でならされて見えない。小さなボケにもそのまま掛けると、白飛びの点が中心の暗い 2-4 px の輪になり、点の中心が黒く抜けて見えた
 */
const vec2 DOF_RIM_COC = vec2(1.5, 4.0);
// 絞り羽根の丸みはレンズプリセット (LP_BLADE_ROUNDNESS)

/*
 * にじみ全体の強さ (設定 LENS_GLOW_STRENGTH)。明るい物の周りに光が広がる効果の「広げる量」に掛ける
 * ブルームの混合率、点像の配る割合、フレア系 (ゴースト・光条・ハロー・グレア・汚れ・ストリーク)、球面収差の滲み、ハレーション、玉ボケの縁
 * 配り直す効果 (点像) は総量を変えず、配る割合にだけ掛ける
 */
const float GLOW_GAIN = LENS_GLOW_STRENGTH;
const float FLARE_GAIN = LENS_FLARE_STRENGTH * GLOW_GAIN;
const float POINT_SPREAD_GAIN = LENS_POINT_SPREAD_STRENGTH * GLOW_GAIN;

// ブルーム
const int BLOOM_LEVELS = 7;          // 1/2 .. 1/128
const int BLOOM_PADDING = 4;         // タイル間の隙間 (ピクセル)。ぼかしの滲み込みを防ぐ
// 合成時のレベル間の減衰 (幾何級数)。小さいほど狭くタイトな光
// ルックのプリセットの値 (ナチュラルは 0.82)
const float BLOOM_LEVEL_DECAY = LK_BLOOM_SPREAD;
/*
 * シーンとの混合率 (BLOOM_STRENGTH = 1 の時)
 * 加算ではなく mix なので総エネルギーは保存される (PSF の畳み込みとして扱う)
 */
const float BLOOM_AMOUNT = 0.16;
// 雨・水中で広いブルームを足す量
const float BLOOM_RAIN_BOOST = 0.6;
const float BLOOM_WATER_BOOST = 1.0;
// ブルーミーフォグ: この距離 (ブロック) で約 63% 効く
const float BLOOM_FOG_DISTANCE = 160.0;
/*
 * 溶岩のブルームの元の明るさの倍率。溶岩の見た目は露出後 LAVA_EXPOSED_MAX (deferred30) で頭打ちにしてあり、
 * そのままではブルーム (混合率 BLOOM_AMOUNT) の滲みが周りの壁より暗く、光って見えない
 * シーンの HDR は変えず (露出・DoF・反射の色はそのまま)、ブルームの縮小 (composite23) でだけ溶岩の分を明るくする
 */
// 設定 LAVA_BLOOM。1.0 で 10 倍、0 で他と同じ (倍率なし)
const float LAVA_BLOOM_GAIN = 1.0 + 9.0 * LAVA_BLOOM;
// 溶岩の画素で下げるブルームの混合率の割合 (final)
// 倍率によらず、溶岩の上に乗る自分のブルームが元の 1.5 倍 (倍率 10 で 0.85 下げた量) になるよう倍率から決める
const float LAVA_SELF_BLOOM = 1.5;
const float LAVA_SELF_BLOOM_CUT = max(1.0 - LAVA_SELF_BLOOM / LAVA_BLOOM_GAIN, 0.0);

// レンズ (強さの割合はプリセット lib/post/lens_presets.glsl)
const float VIGNETTE_SCALE = 0.8;
// F 値の上限と、DOF_STRENGTH 既定 (0.5) での F 値 (焦点距離 17mm / 絞り径 8mm)。収差の開放連動の基準
const float LENS_F_MAX = 22.0;
const float LENS_F_REFERENCE = 2.14;
/*
 * ゴースト: 物理量 (2 面の反射率の積と広がり) に掛ける倍率
 * Minecraft の太陽は照度と円盤の輝度が控えめで、現実の写真ほど眩しくないので少し盛る
 */
const float LENS_GHOST_GAIN = 10.0;
// 前玉の像が点に収束するゴーストの倍率の下限 (tools/gen_lens_ghosts.py の MIN_SCALE と揃える)
const float LENS_GHOST_MIN_SCALE = 0.03;
/*
 * 画面の明るい画素のゴーストの倍率 (反射率に掛ける。composite24 参照)、コートの反射色を残す割合、縮んだゴーストの集光の上限
 * 単層コートで手持ちのたいまつ・近くのランタンのゴーストが淡く見える程度 (400 / 集光 4 倍では橙の塊が浮いた)
 */
const float LENS_SCREEN_GHOST_GAIN = 150.0;
const float LENS_SCREEN_GHOST_SATURATION = 0.5;
const float LENS_SCREEN_GHOST_MAX_GATHER = 2.0;
// 画面ゴースト・ストリークの元にする明るさの閾値 (露出後, ぼかしたタイルの値)。これ以下 (空など) からは出さない
const float LENS_SCREEN_THRESHOLD = 0.3;
const float LENS_STREAK_THRESHOLD = 0.5;
// 画面ストリークの長さ (画面幅比) と強さ
const float LENS_STREAK_LENGTH = 0.35;
const float LENS_STREAK_GAIN = 0.08;
/*
 * スターバースト: テクスチャの 1 単位 (Airy 半径) の表示の大きさ (tan, F2.14 の時)
 * テクスチャは Airy 半径の 50 倍まで焼いてあるので、光条は約 0.3 (画面高さの 4 割) まで伸びる
 */
const float LENS_STAR_AIRY = 0.006;
const float LENS_STAR_GAIN = 1.0;
// 開放での光条の残り (割合) と、開放 F 値の何倍 + 1 まで絞ると羽根の形が出きるか
const float LENS_STAR_OPEN = 0.35;
const float LENS_STAR_STOPDOWN_RANGE = 1.5;
const float LENS_STAR_R_MIN = 0.25;
const float LENS_STAR_R_MAX = 50.0;
/*
 * 夜の月のフレアの倍率 (全体 / 光条だけ)。月の円盤は放射を物理より大きく下げてある
 * (constants.glsl の MOON_NIGHT_BRIGHTNESS) ので、照度どおりのフレアだと小さな円盤から昼の太陽並みの星形が伸びた
 */
const float LENS_MOON_FLARE = 0.35;
const float LENS_MOON_STARBURST = 0.12;
// ハロー: 画面中心からの半径 (tan, 縦) と幅
const float LENS_HALO_RADIUS = 0.42;
const float LENS_HALO_WIDTH = 0.025;
const float LENS_HALO_GAIN = 0.004;
// ベーリンググレア: 光源の周りの広い滲み (照度に対する割合, 広がり tan) と、画面全体のヘイズ (ブルーム最粗の混合率)
const float LENS_VEIL_SUN_GAIN = 0.004;
const float LENS_VEIL_SUN_SIGMA = 0.35;
const float LENS_VEIL_HAZE = 0.03;
/*
 * 点像の裾: 白飛び分 (colortex17) から周りへ配る割合 = 下限 + ベーリンググレアの強さ x 傾き (散乱の強いレンズほど大きい)
 * 4 段 (半径 約 2, 4, 8, 16 px) へ同じエネルギーずつ配るので裾は r^-2 になる。現代の単焦点で約 0.41
 * 白く飛ぶ大きさは配る割合の平方根で増えるので、明るい点やつながった塊ほど大きくにじむ (0.06 ではどの点も同じ大きさに見えた)
 * 水面のきらめきは数を絞って 1 つずつを明るくしているので、0.10 では 1-2 画素の小さな点に留まり、隣のきらめきや波の面と
 * にじみがつながらなかった
 */
// 設定 LENS_POINT_SPREAD_SIZE の段 (裾の割合, 芯の割合, 芯の sigma px)。段の大きさ: 小 1-2 px, 中 3-5 px, 大 4-8 px, 特大 7-10 px
#if LENS_POINT_SPREAD_SIZE == 0
const vec3 POINT_SPREAD_SHAPE = vec3(0.10, 0.22, 0.7);
#elif LENS_POINT_SPREAD_SIZE == 1
const vec3 POINT_SPREAD_SHAPE = vec3(0.22, 0.32, 0.9);
#elif LENS_POINT_SPREAD_SIZE == 2
const vec3 POINT_SPREAD_SHAPE = vec3(0.40, 0.40, 1.1);
#else
const vec3 POINT_SPREAD_SHAPE = vec3(0.60, 0.35, 1.3);
#endif
const float POINT_SPREAD_BASE = POINT_SPREAD_SHAPE.x;
const float POINT_SPREAD_PER_GLARE = 0.035;
const int POINT_SPREAD_LEVELS = 4;
// 最も粗い段の手前の段で近くに白飛び分が無い画素は 4 段の読みを省く
const int POINT_SPREAD_GATE_LEVEL = 5;
/*
 * DoF のボケ半径 (px) がこの値に達すると芯と裾を重ねない (ボケた点は玉ボケに任せる)。芯と裾は DoF の前の白飛び分を点の中心から引くので、
 * ボケて広がった点に掛けると中心が引かれて黒く抜け、鋭い芯が重なった輪の玉ボケになった
 */
const float POINT_SPREAD_COC_FADE = 2.0;
/*
 * 点像の芯: 回折・センサー・現像の滲みで、点のエネルギーの一部が半径 1-2 px に広がる。白を大きく超えた点ほど芯の周りまで
 * 白く飛び、明るい点ほど大きな光の塊に見える (裾の r^-2 だけでは隣の画素へ行く分が 1% 未満で、点が 1 画素の白い四角に見えた)
 * 白飛び分のうち POINT_CORE_SHARE をガウス (sigma POINT_CORE_SIGMA px) で配る。1 軸 5 回 (中心、1-2 px と 3-4 px をそれぞれ双線形で
 * 1 回) の読みを掛け合わせた 9 x 9 の重みにする。2 px で切ると (3 x 3 の読み)、白を大きく超えた点では 2 px の重み (中心の 2 割) でも
 * 白く飛び、3 px で 0 になるので、点や鎖の周りに縁の立った四角い光が出て、その外が黒い枠に見えた
 * 芯が大きいと、白をわずかに超えた暗い点まで 3-5 px の丸になり、明るさによらず同じ大きさの丸い粒が並んだ (水面のきらめきが
 * 多く暗かった時)。きらめきを少数の明るい点にした後は、芯も大きくして 1 つのきらめきを大きく光らせる
 */
const float POINT_CORE_SHARE = POINT_SPREAD_SHAPE.y;
const float POINT_CORE_SIGMA = POINT_SPREAD_SHAPE.z;
// x px 離れた重み (中心で 1)
#define POINT_CORE_G(x) exp(-0.5 * (x) * (x) / (POINT_CORE_SIGMA * POINT_CORE_SIGMA))
const float POINT_CORE_NORM = 1.0 / (1.0 + 2.0 * (POINT_CORE_G(1.0) + POINT_CORE_G(2.0) + POINT_CORE_G(3.0) + POINT_CORE_G(4.0)));
// 1 軸の読みの重み (中心、1-2 px、3-4 px) と位置 (px)。片側の 2 画素を、重みの比の位置の双線形の 1 回で読む
const vec3 POINT_CORE_TAP_W = vec3(1.0, POINT_CORE_G(1.0) + POINT_CORE_G(2.0), POINT_CORE_G(3.0) + POINT_CORE_G(4.0)) * POINT_CORE_NORM;
const vec3 POINT_CORE_TAP_X = vec3(0.0, (POINT_CORE_G(1.0) + 2.0 * POINT_CORE_G(2.0)) / (POINT_CORE_G(1.0) + POINT_CORE_G(2.0)),
    (3.0 * POINT_CORE_G(3.0) + 4.0 * POINT_CORE_G(4.0)) / (POINT_CORE_G(3.0) + POINT_CORE_G(4.0)));
// 汚れ: 光源の周りの散乱光 (照度に対する割合, 広がり tan) と、明るい画素の周りの散乱 (広いブルームに対する割合)
const float LENS_DIRT_SUN_GAIN = 0.006;
const float LENS_DIRT_SUN_SIGMA = 0.45;
const float LENS_DIRT_BLOOM_GAIN = 0.25;
// アナモルフィックの横ストリーク (太陽): 長さと太さ (tan), 照度に対する割合
const float LENS_STREAK_SUN_LENGTH = 0.5;
const float LENS_STREAK_SUN_WIDTH = 0.004;
const float LENS_STREAK_SUN_GAIN = 0.004;
// 倍率色収差: 画面の隅で波長 410 / 690nm がずれる量 (UV の倍率, LP_CA = 1 の時)
const float LENS_CA_SCALE = 0.004;
// 軸上色収差: ピント面での R/B のボケ半径 (ピクセル @1080p, LP_AXIAL_CA = 1, 既定の F 値の時)
const float LENS_AXIAL_CA_PX = 1.5;
// 球面収差: 狭いブルームへの混合率 (LP_SOFT_FOCUS = 1 の時)
const float LENS_SOFT_FOCUS_AMOUNT = 0.35;
// 処方の球面収差のハロー (LENS_SOFT_HALO_TABLE) の割合に掛ける倍率 (1 = 処方の点像のエネルギーどおり)
const float LENS_SOFT_HALO_GAIN = 1.0;
// ハレーション: 露出後の閾値と色 (フィルムベースで反射して赤い層だけが感光する)
const float LENS_HALATION_THRESHOLD = 0.8;
const vec3 LENS_HALATION_TINT = vec3(1.0, 0.28, 0.08);
const float LENS_HALATION_GAIN = 0.6;
// 非点収差 (ぐるぐるボケ): 画面の隅でのボケの接線方向の伸び (LP_SWIRL = 1 の時)
const float LENS_SWIRL_STRETCH = 0.6;
// 像面湾曲: 画面の隅でピント距離が縮む割合 (LP_FIELD_CURVATURE = 1 の時)
const float LENS_FIELD_CURVATURE_SCALE = 0.35;
// 負の像面湾曲 (周辺ほどピントが奥) で、ピント距離の割り算が 0 や負にならないための下限 (隅でピント距離 5 倍まで)
const float LENS_FIELD_CURVATURE_MIN = 0.2;
/*
 * 処方の像面の焦点ずれ (LP_FIELD_ZT / ZS, mm) をボケに足す時の基準: 135 判の対角の半分 (mm)。画面の隅をこれに合わせる
 * 1 軸あたりの上限 (画面の高さ比)。処方の設計画角の外 (Flektogon の隅) で像面が崩れた分を伸ばしすぎない
 * (0.025 では Flektogon の画面の外側 1/3 が流れて見えた。開放の Canon 50/1.2 の隅の非点収差もこの上限で止まる)
 */
const float LENS_FRAME_HALF_DIAGONAL_MM = 21.63;
const float LENS_FIELD_DEFOCUS_MAX = 0.01;
// 陣笠型の歪曲で、枠の外を読まない拡大率を決めるために端に沿って調べる点の数 (片側の端あたり)
const int LENS_DISTORTION_EDGE_STEPS = 8;
const float LENS_DISTORTION_NORM_MARGIN = 1e-4;
/*
 * 歪曲・魚眼を TAA の中で組み立てる (LENS_WARP_IN_TAA)
 * AUTO_AMOUNT: 自動で有効にする歪曲の大きさ (画面の倍率の変化の最大)。アナモルフィック (0.05) と処方どおりの
 *   Flektogon (0.023) は final のまま、Flektogon の強さ 3 (0.07) から TAA で組み立てる
 * SR_RAMP: 拡大率 1 から何倍分で超解像を効かせきるか (1 / RAMP 倍の拡大で全開)
 * KERNEL: 一番近い元の画素の中心が出力の画素の中心から d 画素 (出力) 離れた時の重み exp(-KERNEL d^2) (0.5 画素で 0.5)
 * SR_MOTION: 超解像を止める動きの速さ (出力の画素 / フレーム)。速い時は 1 フレームの補間に寄せて残像を出さない
 * MIN_BLEND: 今フレームの混合率の下限 (遠い元の画素しか来ないフレームが続いても履歴が固まらない)
 */
const float LENS_WARP_AUTO_AMOUNT = 0.06;
const float LENS_WARP_TAA_SR_RAMP = 2.0;
const float LENS_WARP_TAA_KERNEL = 2.77;
const float LENS_WARP_TAA_SR_MOTION = 2.0;
const float LENS_WARP_TAA_MIN_BLEND = 0.015;
// 魚眼の周辺光量・像面の表の rho = 1 に当たる半画角 (処方を解析した最大の画角)
const float LENS_FISHEYE_TABLE_ANGLE = 1.562070; // 89.5 度
// 口径食: 画面の隅での前玉の縁と絞りのずれ (開口半径比, LP_CATS_EYE = 1 の時)
const float LENS_CATS_EYE_SCALE = 1.0;
// トリウムガラスの黄変 (LP_YELLOWING = 1 の時の透過色)
const vec3 LENS_YELLOWING_TINT = vec3(1.0, 0.9, 0.68);
// 太陽・月の視半径 (rad, lib/sky/atmosphere.glsl と同じ値)。ゴーストの縁のぼけと可視判定の範囲に使う
const float LENS_LIGHT_ANGULAR_RADIUS = 0.0093;
// 光源の可視判定 (composite25): 太陽円盤の何倍の範囲を見るか、平滑化の速さ (1/秒)、画面外の許容幅 (UV)
const float LENS_VIS_DISC_SCALE = 1.3;
const float LENS_VIS_SPEED = 12.0;
const float LENS_VIS_OFFSCREEN = 0.25;
// 画面の外の光源に目の位置の影マップの判定を掛け始める幅 (UV)。端をまたぐ時にフレアが跳ばないよう、この幅で混ぜる
const float LENS_VIS_EYE_FADE = 0.05;
// フィルムグレインの振幅 (sRGB) は設定 FILM_GRAIN。既定はデジカメのセンサーノイズ程度の微弱な値

#endif
