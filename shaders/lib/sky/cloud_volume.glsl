/*
 * 体積雲の形状・ライティング・レイマーチ (sky モジュール, prepare2 / deferred20 だけが include する)
 *
 * 層 (高さは clouds.glsl。形と光はすべて「参照空間」= 現実の雲の寸法 (m) で決め、高さテンプレートは写像だけを変える)
 *   低層: 積雲 (扁平雲 -> 並雲 -> 雄大雲。大中小のセルをべき乗則の割合で重ねる) / 層積雲 / 雨天の乱層雲
 *         / 積乱雲 (CLOUD_CUMULONIMBUS。雷雨と熱帯の午後。塔・かなとこ・オーバーシュート・乳房雲・降水の柱)
 *         / 断片雲 (CLOUD_FRACTUS。濃い雲の周りに群れで散らばる薄いちぎれ雲)
 *   層ごとの量・濃さ・大きさ・浸食・風は lib/settings/sky.glsl の CLOUD_LOW_* / CLOUD_MID_* / CLOUD_HIGH_* / CLOUD_CB_*
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

#include "/lib/sky/cloud_constants.glsl"
#include "/lib/sky/cloud_weather.glsl"
#include "/lib/sky/cloud_density.glsl"
#include "/lib/sky/cloud_lighting.glsl"
#include "/lib/sky/cloud_march.glsl"

#endif
