/*
  ローダーの能力 (CAP_*) と、本体が見る機能 (FX_*)。tools/gen_capabilities.py が tools/capabilities.py から生成する (手で編集しない)
  本体は FX_* だけを見る。MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS はこのファイルの外で使わない
  値なしの define は Iris がブール設定と見なすので、値 1 で定義する。無い環境では未定義のまま (能力なし) になる
*/
#ifndef SETTINGS_CAPABILITIES_GLSL
#define SETTINGS_CAPABILITIES_GLSL

//@include "/lib/settings/light.glsl"
//@include "/lib/settings/surface.glsl"

// shadow_entities / shadow_block のプログラムが読まれる。無い環境: Iris 1.8 未満と Oculus。エンティティとブロックエンティティも shadow に来る
#if defined IRIS_VERSION && IRIS_VERSION >= 10800
#define CAP_SHADOW_ENTITIES 1
#endif

// gbuffers_lightning のプログラムが読まれる。無い環境: Oculus (雷は gbuffers_entities で描かれる)
#if defined IRIS_VERSION
#define CAP_LIGHTNING_PROGRAM 1
#endif

// エンティティを影とボクセルに描く (遮蔽とエンティティの光源)
#if defined ENTITY_SHADOWS || defined LIGHT_ENTITY_OCCLUSION || defined LIGHT_PLAYER_OCCLUSION || defined ENTITY_LIGHTS
#define FX_ENTITY_VOXEL 1
#endif

// ブロックエンティティを影とボクセルに描く
#if defined BLOCK_ENTITY_SHADOWS || defined LIGHT_ENTITY_OCCLUSION || defined ENTITY_LIGHTS
#define FX_BLOCK_ENTITY_VOXEL 1
#endif

// shadow のプログラムに地形以外 (プレイヤー・エンティティ・ブロックエンティティ) が来る。地形用の処理を地形だけに閉じる
#if !defined CAP_SHADOW_ENTITIES
#define FX_SHADOW_NON_TERRAIN 1
#endif

// 雷を gbuffers_entities でも扱う (gbuffers_lightning が読まれない環境)
#if !defined CAP_LIGHTNING_PROGRAM
#define FX_LIGHTNING_IN_ENTITIES 1
#endif

#endif // SETTINGS_CAPABILITIES_GLSL
