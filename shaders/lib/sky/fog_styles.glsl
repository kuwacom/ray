/*
 * フォグのスタイル (FOG_STYLE, sky モジュール。fog.glsl が読む)
 * スタイルは成分の形と比だけを決める。全体の濃さはルックのプリセット (LOOK_FOG_DENSITY) と FOG_DENSITY が持つ
 * どのスタイルでも、遠景の空気の色は同じ方位の地平線の空に収束し (灰色の霧・距離によらない青みを出さない)、
 * 太陽から離れた方位の虚空と霧の帯は地平線の空より明るくしない
 * 番号: 0 = Ray (物理)、1 = Bliss 風、2 = Nostalgia 風、3 = カスタム (FOG_C_*)
 *   FS_HAZE:        もやの濃さの倍率 (晴れた昼の海面 5e-4 /ブロックに掛ける)
 *   FS_EDGE:        描画距離の端の景色の成分の光学的深さ (大きいほど端が霞む)
 *   FS_HAZE_MORNING / EVENING / NIGHT / DAWN: 時間帯のもやの倍率 (昼 1)
 *   FS_HAZE_TOP / FS_HAZE_SOFT: もやの上端の高さと柔らかさの倍率 (大きいほど高く、上へなだらかに薄れる)
 *   FS_LAYER / FS_LAYER_COVER: 霧の層の濃さと雲量の倍率
 *   FS_GROUND / FS_GROUND_EVENING / FS_GROUND_NIGHT: 地表の霧の倍率 (全体 / 夕 / 夜に掛ける)
 *   FS_FORWARD:     日の当たるもやと霧の前方の輝き (光芒の強さに掛ける)
 *   FS_VL_FAR:      遠くの光芒の重み
 *   FS_PHASE_G1..G3 / FS_PHASE_W2, W3: もやの位相 (Cornette-Shanks の和)
 *   FS_MIST_G:      霧の位相の前方の g
 */
#ifndef SKY_FOG_STYLES_GLSL
#define SKY_FOG_STYLES_GLSL

#if FOG_STYLE == 0
// Ray (物理): 混合層のもや、朝に霧の層と谷霧、端は透過率 0.4
const float FS_HAZE = 1.0;
const float FS_EDGE = 0.9;
const float FS_HAZE_MORNING = 1.6;
const float FS_HAZE_EVENING = 1.3;
const float FS_HAZE_NIGHT = 1.2;
const float FS_HAZE_DAWN = 1.5;
const float FS_HAZE_TOP = 1.0;
const float FS_HAZE_SOFT = 1.0;
const float FS_LAYER = 1.0;
const float FS_LAYER_COVER = 1.0;
const float FS_GROUND = 1.0;
const float FS_GROUND_EVENING = 1.0;
const float FS_GROUND_NIGHT = 1.0;
const float FS_FORWARD = 1.0;
const float FS_VL_FAR = 1.0;
const float FS_PHASE_G1 = 0.72;
const float FS_PHASE_G2 = 0.36;
const float FS_PHASE_G3 = 0.18;
const float FS_PHASE_W2 = 0.5;
const float FS_PHASE_W3 = 0.25;
const float FS_MIST_G = 0.82;

#elif FOG_STYLE == 1
/*
 * Bliss 風: 濃いめのもやと端の霞み、夕方と夜にも地表の霧、霧の層が多い。前方に強い位相で太陽側の霧が光る
 * 夜の地表の霧は Bliss の既定の半分 (夜に何も見えなくならないように)
 */
const float FS_HAZE = 1.2;
const float FS_EDGE = 1.2;
const float FS_HAZE_MORNING = 1.4;
const float FS_HAZE_EVENING = 1.3;
const float FS_HAZE_NIGHT = 1.6;
const float FS_HAZE_DAWN = 1.6;
const float FS_HAZE_TOP = 1.0;
const float FS_HAZE_SOFT = 1.0;
const float FS_LAYER = 1.5;
const float FS_LAYER_COVER = 1.5;
const float FS_GROUND = 1.0;
const float FS_GROUND_EVENING = 3.0;
const float FS_GROUND_NIGHT = 3.0;
const float FS_FORWARD = 1.3;
const float FS_VL_FAR = 1.0;
const float FS_PHASE_G1 = 0.85;
const float FS_PHASE_G2 = 0.35;
const float FS_PHASE_G3 = 0.0;
const float FS_PHASE_W2 = 0.5;
const float FS_PHASE_W3 = 0.0;
const float FS_MIST_G = 0.88;

#elif FOG_STYLE == 2
/*
 * Nostalgia 風: 霧の層なし。もやは上へなだらかに薄れ (指数に近い形)、端は透過率 0.5 の軽い霞み。
 * 朝が最も濃く、夕と夜は薄い。地表の霧は朝と雨だけ
 */
const float FS_HAZE = 1.4;
const float FS_EDGE = 0.7;
const float FS_HAZE_MORNING = 1.4;
const float FS_HAZE_EVENING = 0.85;
const float FS_HAZE_NIGHT = 0.65;
const float FS_HAZE_DAWN = 1.2;
const float FS_HAZE_TOP = 1.6;
const float FS_HAZE_SOFT = 3.0;
const float FS_LAYER = 0.0;
const float FS_LAYER_COVER = 0.0;
const float FS_GROUND = 0.67;
const float FS_GROUND_EVENING = 0.0;
const float FS_GROUND_NIGHT = 0.3;
const float FS_FORWARD = 1.0;
const float FS_VL_FAR = 0.6;
const float FS_PHASE_G1 = 0.7;
const float FS_PHASE_G2 = -0.3;
const float FS_PHASE_G3 = 0.0;
const float FS_PHASE_W2 = 0.15;
const float FS_PHASE_W3 = 0.0;
const float FS_MIST_G = 0.75;

#else
// カスタム: Ray (物理) の形に、スライダーの倍率を掛ける
const float FS_HAZE = FOG_C_HAZE;
const float FS_EDGE = FOG_C_EDGE;
const float FS_HAZE_MORNING = 1.6;
const float FS_HAZE_EVENING = 1.3;
const float FS_HAZE_NIGHT = 1.2;
const float FS_HAZE_DAWN = 1.5;
const float FS_HAZE_TOP = 1.0;
const float FS_HAZE_SOFT = 1.0;
const float FS_LAYER = FOG_C_LAYER;
const float FS_LAYER_COVER = 1.0;
const float FS_GROUND = FOG_C_GROUND;
const float FS_GROUND_EVENING = 1.0;
const float FS_GROUND_NIGHT = 1.0;
const float FS_FORWARD = FOG_C_FORWARD;
const float FS_VL_FAR = 1.0;
const float FS_PHASE_G1 = 0.72;
const float FS_PHASE_G2 = 0.36;
const float FS_PHASE_G3 = 0.18;
const float FS_PHASE_W2 = 0.5;
const float FS_PHASE_W3 = 0.25;
const float FS_MIST_G = 0.82;
#endif

#endif
