/*
 * サンプラーの宣言 (全プログラム共通)
 * colortex の割り当ては docs/architecture.md の「バッファ設計」を正とする
 * 注意: gbuffers では colortex0-3 はアトラスに化けるので読まないこと (Iris の仕様)
 */
#ifndef COMMON_SAMPLERS_GLSL
#define COMMON_SAMPLERS_GLSL

// gbuffers 用アトラス
uniform sampler2D gtexture;
uniform sampler2D lightmap;
uniform sampler2D normals;
uniform sampler2D specular;

// colortex (用途は lib/buffers/formats.glsl のコメント参照)
uniform sampler2D colortex0;  // シーン HDR
uniform sampler2D colortex1;  // G: アルベド + マテリアル ID
uniform sampler2D colortex2;  // G: 法線 + ライトマップ
uniform sampler2D colortex3;  // G: PBR マテリアル + AO
uniform sampler2D colortex4;  // 半透明の色 (乗算済みアルファ)
uniform sampler2D colortex5;  // 半透明のデータ
uniform sampler2D colortex6;  // A: ブロックライト (デノイズ済み)
uniform sampler2D colortex7;  // A: ブロックライト履歴
uniform sampler2D colortex8;  // C: GI / AO
uniform sampler2D colortex9;  // C: GI 履歴
uniform sampler2D colortex10; // B: 雲 (低解像度)
uniform sampler2D colortex11; // B: 雲履歴 (フル解像度)
uniform sampler2D colortex12; // B: ボリューメトリック (低解像度)
uniform sampler2D colortex13; // D: TAA 履歴
uniform sampler2D colortex14; // D: ブルームタイル
uniform sampler2D colortex15; // 速度ベクトル

uniform sampler2D depthtex0; // 半透明・手を含む深度
uniform sampler2D depthtex1; // 半透明を含まない深度
uniform sampler2D depthtex2; // 手を含まない深度

uniform sampler2D shadowtex0;   // 半透明を含む影深度
uniform sampler2D shadowtex1;   // 不透明のみの影深度
uniform sampler2D shadowcolor0; // 最も太陽側の面の色 (半透明なら色付き透過色、a=不透明度)
uniform sampler2D shadowcolor1; // 最も太陽側の面の法線 (rg=oct) と種別 (a)

uniform sampler2D noisetex;
uniform sampler2D blueNoiseTex; // shaders/textures/blue_noise.png (128x128, R/G/B/A 独立)

#endif
