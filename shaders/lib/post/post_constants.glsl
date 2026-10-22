/*
 * post モジュールの内部定数 (ユーザー設定ではない調整値)
 * ユーザーに見せる設定は lib/settings.glsl にしかない。ここは「なぜその値か」を残すための置き場
 */
#ifndef POST_POST_CONSTANTS_GLSL
#define POST_POST_CONSTANTS_GLSL

// ---- 露出 ----
// 自動露出が平均輝度を写す先の中間グレー (AgX は 0.18 を表示値 0.5 付近に置く)
const float EXPOSURE_KEY = 0.18;
// 反射光式の較正定数 (EV100 = log2(L * 100 / K))。設定の EV はこの EV100 として扱う
const float EXPOSURE_CALIBRATION = 12.5;
/*
 * 露出の追従を完全補正にしない (iterationT の pow(L, -0.7) 相当の「カメラ感」)
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
 * 曲線 0.55 のままだと晴れの夜 (計測 -7) が -3.9 にしか補正されず、iterationT の半分以下の明るさで
 * 地形が読めなかった。雨の夜 (計測 -8.5) は下限 -4 で止まってほぼ真っ黒だった
 * 一律に持ち上げると雨の夜だけ暗いまま残るので、暗いほど補正を 0.55 -> 0.9 に近づける形にする
 * 洞窟は暗さを残したいので、目の位置のスカイライトが低いと効かせない
 * -4.8 / 0.35 では晴れの夜 (計測 -6.5) が iterationT の 7 割の明るさだったので -4.5 / 0.4 に (0.5 では iterationT より明るく灰色に浮いた)。雨の夜 (計測 -8.3) は iterationT と同程度なので上限を 1.3 にして据え置く
 */
const float EXPOSURE_NIGHT_EV_START = -4.5;
const float EXPOSURE_NIGHT_SLOPE = 0.4;
const float EXPOSURE_NIGHT_MAX_LIFT = 1.3;
/*
 * 灯りの点いた屋内・洞窟 (計測 EV -1.5 .. -3.5、目の位置のスカイライトが低い) を DIM EV 暗く写す
 * 光の届く範囲を広げた分だけ計測 EV が上がり、灯りを点けた部屋やたいまつの灯る洞窟が iterationT より 1 段明るく平板で、
 * AgX で明るい面の色が抜けて灯りが白っぽく見えた
 * EV の窓 (x..y で 0 -> 1, z..w で 1 -> 0)。両側とも 2 EV 前後かけて変え、計測 EV に対して表示の明るさが逆転しないようにする
 * 0.5 EV でも灯りを点けた部屋は iterationT の約 2 倍の明るさで平板だったので 0.8 に。
 * たいまつ 1 本の暗い洞窟 (計測 -4 前後) は逆に iterationT より暗いので、窓の暗い側を -5.5 .. -2.5 に寄せる (幅 3 EV で計測 EV に対する表示の明るさの逆転を防ぐ)
 */
const float EXPOSURE_INDOOR_DIM = 1.0;
const vec4 EXPOSURE_INDOOR_EV = vec4(-4.0, -1.5, -1.0, 0.5);
/*
 * 屋内の減光は目の位置のブロックライト (eyeBrightnessSmooth.x / 240) がこの範囲で 0 -> 1 で効かせる
 * 灯りの無い窓だけの部屋まで暗くすると、日だまりが暗い琥珀色に沈んだ (窓だけの部屋の床 p90 170 -> 69)
 * 灯りを点けた部屋・たいまつの灯る洞窟の目の位置は 0.6 / 0.8、窓だけの部屋は 0
 */
const vec2 EXPOSURE_INDOOR_BLOCKLIGHT = vec2(0.1, 0.4);
/*
 * 屋外の夜の最低限の持ち上げ (EV)。計測 EV による持ち上げは、たいまつの灯りが画面に入ると計測 EV が上がって消え、
 * 灯りの周りの夜景が真っ黒に沈んだ (たいまつを置いた夜の屋外 Y 41.7 vs iterationT 58.9)。太陽高度で夜を判定して下支えする
 */
const float EXPOSURE_NIGHT_MIN_LIFT = 0.4;
/*
 * 水中を暗く写す EV。水中は画面全体が内散乱のフォグになり、自動露出がそれを中間調まで持ち上げるので、
 * 吸収を強めても表示の明るさがほとんど変わらず、明るく白っぽい青になっていた (Y 116 vs iterationT 67)
 */
const float EXPOSURE_UNDERWATER_DIM = 0.9;
/*
 * 昼の雨・雷雨を暗く写す EV (屋外だけ)。曇天は計測 EV が下がった分を自動露出が半分以上戻すので、
 * 雷雨の空が晴れの日とほぼ同じ明るさの明るい灰色に持ち上がり、重い空にならなかった
 * 夜の雨は露出の持ち上げで iterationT と同程度に合わせてあるので、計測 EV が夜の側 (EXPOSURE_NIGHT_EV_START 付近) では効かせない
 */
const float EXPOSURE_RAIN_DIM = 0.45;
const float EXPOSURE_THUNDER_DIM = 1.0;
// ヒストグラムの範囲 (log2 輝度)。MIN_AMBIENT 付近の暗所から太陽円盤の手前まで
const float HISTOGRAM_LOG_MIN = -16.0;
const float HISTOGRAM_LOG_MAX = 10.0;
// パーセンタイル: 暗すぎる影と空・太陽の外れ値を平均から除く (UE 4.25 方式)
const float HISTOGRAM_LOW_PERCENT = 0.35;
const float HISTOGRAM_HIGH_PERCENT = 0.92;
// 中央重点測光: 画面端の重み
const float METERING_EDGE_WEIGHT = 0.35;

// ---- Purkinje 効果 (薄暗視の青シフト) ----
// 強さは設定 PURKINJE_STRENGTH。青すぎると不評になりやすいので既定は控えめ (camera-color.md 2.3)
// 順応輝度 (露出前のシーン単位) がこの範囲で錐体 -> 桿体へ移る
// 室内・洞窟のたいまつ (順応輝度 0.015-0.025) で効くと木材や石が灰緑に濁るので、月明かりの水準 (0.002 前後) から下だけにする
const float PURKINJE_LUM_LOW = 0.0005;
const float PURKINJE_LUM_HIGH = 0.008;

// ---- TAA ----
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

// ---- モーションブラー (McGuire 2012) ----
const int MOTION_BLUR_SAMPLES = 12;
// シャッター角 180 度 = 1 フレームの半分の移動量
const float MOTION_BLUR_SHUTTER = 0.5;
// ブラー長の上限 (画面高さ比)。タイルの近傍探索距離もこれで決まる
const float MOTION_BLUR_MAX_LENGTH = 0.04;
// 深度の前後判定の柔らかさ (ブロック)
const float MOTION_BLUR_DEPTH_SOFTNESS = 0.5;

// ---- 被写界深度 ----
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
// 絞り羽根の丸みはレンズプリセット (LP_BLADE_ROUNDNESS)

// ---- ブルーム ----
const int BLOOM_LEVELS = 7;          // 1/2 .. 1/128
const int BLOOM_PADDING = 4;         // タイル間の隙間 (ピクセル)。ぼかしの滲み込みを防ぐ
// 合成時のレベル間の減衰 (幾何級数)。小さいほど狭くタイトな光
const float BLOOM_LEVEL_DECAY = 0.82;
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
 * そのままではブルーム (混合率 BLOOM_AMOUNT) の滲みが周りの壁より暗く、光って見えなかった
 * シーンの HDR は変えず (露出・DoF・反射の色はそのまま)、ブルームの縮小 (composite23) でだけ溶岩の分を明るくする
 */
// -> 設定 LAVA_BLOOM。1.0 で以前の定数 10 倍、0 で他と同じ (倍率なし)
const float LAVA_BLOOM_GAIN = 1.0 + 9.0 * LAVA_BLOOM;
// 溶岩の画素で下げるブルームの混合率の割合 (final)
// -> 倍率を設定にしたので、溶岩の上に乗る自分のブルームが倍率 10 で 0.85 下げた時と同じ量 (元の 1.5 倍) になるよう倍率から決める
const float LAVA_SELF_BLOOM = 1.5;
const float LAVA_SELF_BLOOM_CUT = max(1.0 - LAVA_SELF_BLOOM / LAVA_BLOOM_GAIN, 0.0);

// ---- レンズ (強さの割合はプリセット lib/post/lens_presets.glsl) ----
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
 * 夜の月のフレアの倍率 (全体 / 光条だけ)。月の円盤は夜の露出で白飛びしないよう放射を大きく下げてある
 * (celestial.glsl の MOON_NIGHT_BRIGHTNESS) ので、照度どおりのフレアだと小さな円盤から昼の太陽並みの星形が伸びた
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
// ハレーション: 露出後の閾値と色 (フィルムベースで反射して赤い層だけが感光する)
const float LENS_HALATION_THRESHOLD = 0.8;
const vec3 LENS_HALATION_TINT = vec3(1.0, 0.28, 0.08);
const float LENS_HALATION_GAIN = 0.6;
// 非点収差 (ぐるぐるボケ): 画面の隅でのボケの接線方向の伸び (LP_SWIRL = 1 の時)
const float LENS_SWIRL_STRETCH = 0.6;
// 像面湾曲: 画面の隅でピント距離が縮む割合 (LP_FIELD_CURVATURE = 1 の時)
const float LENS_FIELD_CURVATURE_SCALE = 0.35;
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
// フィルムグレインの振幅 (sRGB) は設定 FILM_GRAIN。既定はデジカメのセンサーノイズ程度の微弱な値

#endif
