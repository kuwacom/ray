/*
 * バッファのフォーマットとクリア設定 (final.fsh から include される)
 * Iris はコメント内の const 宣言も読むので、このブロック全体がコメントで正しい
 * 割り当ての変更時は docs/architecture.md も更新すること

const int colortex0Format  = RGBA16F; // シーン HDR          | deferred30 -> composite* -> final
const int colortex1Format  = RGBA8;   // G: アルベド + ID    | gbuffers (不透明) -> deferred*
const int colortex2Format  = RGBA16;  // G: 法線 + ライトマップ | gbuffers (不透明) -> deferred* / composite*
const int colortex3Format  = RGBA16;  // G: PBR + AO          | gbuffers (不透明) -> deferred*
const int colortex4Format  = RGBA16F; // 半透明の色 (乗算済み) | gbuffers (半透明) -> composite1
const int colortex5Format  = RGBA16;  // 半透明のデータ       | gbuffers (半透明) -> composite*
const int colortex6Format  = RGBA16F; // A: ブロックライト    | deferred2 -> deferred30 / composite*
const int colortex7Format  = RGBA16F; // A: ブロックライト履歴 | deferred2 (永続)
const int colortex8Format  = RGBA16F; // C: GI / AO           | deferred11 -> deferred30
const int colortex9Format  = RGBA16F; // C: GI 履歴           | deferred11 (永続)
const int colortex10Format = RGBA16F; // B: 雲 (低解像度)     | deferred20 -> deferred21
const int colortex11Format = RGBA16F; // B: 雲履歴            | deferred21 (永続) -> deferred30 / composite*
const int colortex12Format = RGBA16F; // B: ボリューメトリック | composite10 -> composite11
const int colortex13Format = RGBA16F; // D: TAA 履歴          | composite20 (永続)
const int colortex14Format = RGBA16F; // D: ブルームタイル    | composite23 -> composite24 -> final
const int colortex15Format = RGBA16F; // 速度ベクトル         | gbuffers (エンティティ/手) -> composite20 / 21

const bool colortex0Clear  = true;
const bool colortex1Clear  = true;
const bool colortex2Clear  = true;
const bool colortex3Clear  = true;
const bool colortex4Clear  = true;
const bool colortex5Clear  = true;
const bool colortex6Clear  = true;
const bool colortex7Clear  = false;
const bool colortex8Clear  = true;
const bool colortex9Clear  = false;
const bool colortex10Clear = false;
const bool colortex11Clear = false;
const bool colortex12Clear = false;
const bool colortex13Clear = false;
const bool colortex14Clear = true;
const bool colortex15Clear = true;

const vec4 colortex0ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex1ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex2ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex3ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex4ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex5ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex6ClearColor  = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex8ClearColor  = vec4(0.0, 0.0, 0.0, 1.0);
const vec4 colortex14ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
const vec4 colortex15ClearColor = vec4(0.0, 0.0, 0.0, 0.0);

const int shadowcolor0Format = RGBA8;  // 最も太陽側の面の色 (半透明は透過色, a = 不透明度)
const int shadowcolor1Format = RGBA16; // rg = 法線 (oct), b = スカイライト, a = 種別 (0=不透明 0.5=半透明 1=水)
const bool shadowcolor0Clear = true;
const bool shadowcolor1Clear = true;
const vec4 shadowcolor0ClearColor = vec4(1.0, 1.0, 1.0, 0.0);
const vec4 shadowcolor1ClearColor = vec4(0.5, 0.5, 1.0, 0.0);
*/
