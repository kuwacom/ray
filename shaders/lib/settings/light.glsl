#ifndef SETTINGS_LIGHT_GLSL
#define SETTINGS_LIGHT_GLSL

// ブロックライト / ボクセル (light モジュール)
#define VOXEL_VOLUME 2 // [0 1 2 3] 0=128x64x128 1=192x96x192 2=256x128x256 3=384x128x384
#define FLOODFILL // 色付き floodfill (間接光のベース)
#define FLOODFILL_STRENGTH 0.35 // [0.0 0.1 0.2 0.25 0.3 0.35 0.4 0.5 0.6 0.8 1.0 1.25 1.5 2.0] 光源シャドウ ON 時の間接光の強さ
#define BLOCKLIGHT_BOUNCE 0.5 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 1.0 1.25 1.5 2.0 3.0 4.0] floodfill の壁の照り返しの濃さ (壁の色が光に混ざる) 0=なし
#define BLOCKLIGHT_BRIGHTNESS 1.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0 5.0 6.0 8.0]
#define BLOCKLIGHT_WARMTH 0.6 // [0.0 0.25 0.4 0.5 0.6 0.7 0.75 1.0] 0=中性 1=バニラ寄りの暖色
#define LIGHT_FLICKER // 炎系光源の揺らぎ
#define DECORATIVE_BLOCK_LIGHTS 0 // [0 1 2] 光らない鉱物ブロック (ラピス・エメラルド・ダイヤ・金・レッドストーン・アメジスト) 0=そのまま 1=発光のみ 2=光源
#define LIGHT_SHADOWS // 設置光源の光源シャドウ (直接光のレイトレース)
#define LIGHT_SHADOW_STRENGTH 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0] 設置光源 (ドロップ・燃焼・発光エンティティの光も) の影の濃さ 0=影なし 1=真っ暗な影
#define LIGHT_TRACE_COUNT 4 // [1 2 3 4 6 8 12 16] 1 ピクセルあたりトレースする光源数
#define LIGHT_TRACE_RES 2 // [1 2 4] トレース解像度の分母 (1=フル 2=半分 4=1/4)
#define LIGHT_SHAPE_TRACE // ハーフブロック等の形状で遮蔽判定
#define LIGHT_SOURCE_SIZE 0.5 // [0.0 0.25 0.5 0.75 1.0 1.5 2.0] 光源サイズ (半影の柔らかさ)
#define LIGHT_EMISSION_MASK_MODE 0 // [0 1 2] 光るブロックの照り返しの面の光り方 0=面全体 1=光る範囲の四角 2=テクスチャのマスク
#define LIGHT_TRANSLUCENT_TINT // 色ガラス越しの光の色付け
#define LIGHT_SPECULAR // ブロックライトの鏡面反射
#define LIGHT_DENOISE 2 // [0 1 2] 0=なし 1=時間 2=時間+空間
#define LIGHT_ENTITY_OCCLUSION // エンティティがブロックライトを遮る
#define LIGHT_PLAYER_OCCLUSION // プレイヤーがブロックライトを遮る
#define LIGHT_OCCLUSION_MODE 1 // [0 1] エンティティ遮蔽の方式 0=ボクセル (0.5 ブロックの箱) 1=三角形 (形状どおり)
#define LIGHT_ENTITY_TRIANGLES 4096 // [2048 4096 8192 16384] 三角形方式で保持する三角形の上限
#define LIGHT_CONTACT_SHADOWS // スクリーンスペース接触影でボクセル外の細部を補う
#define LIGHT_CULL_MODE 2 // [0 1 2] 光源が上限を超えた時に残す光源の選び方 0=到着順 (毎フレーム入れ替わる) 1=近い順 2=明るさ x 近さ
#define LIGHT_MAX_COUNT 4096 // [1024 2048 4096 8192] 1 フレームに登録する光源の総数の上限
#define LIGHT_BIN_LIGHTS 64 // [16 24 32 48 64 96 128] ライトビン (8x8x8 ブロック) 1 つに入る光源数の上限
#define LIGHT_TRACE_STEPS 96 // [48 64 96 128 192] 光源の影のレイが辿るセル数の上限
#define LIGHT_SPECULAR_COUNT 4 // [1 2 4 6 8] 鏡面反射を付ける光源数 (照度の大きい順)
#define LIGHT_CONTACT_SHADOW_COUNT 4 // [1 2 4 8 16] 接触影を付ける光源数 (寄与の大きい順)
#define HAND_LIGHT // 手持ち光源
#define HAND_LIGHT_RAYS // 手持ち光源のレイトレース影
#define HAND_LIGHT_SS_SHADOWS // 手持ち光源のスクリーンスペース影 (手・エンティティの遮蔽)
#define HAND_LIGHT_BRIGHTNESS 1.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define HAND_LIGHT_SHADOW_STRENGTH 0.6 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0] 手持ち光源の影の濃さ 0=影なし 0.6=直接光の影は真っ暗 (照り返しあり) 1=照り返しなし
#define ENTITY_LIGHTS // 動的エンティティ光源の総スイッチ
#define ITEM_LIGHTS // ドロップした光源アイテム
#define PROJECTILE_LIGHTS // 投擲物 (光る矢・火の玉等)
#define BURNING_ENTITY_LIGHTS // 燃えているエンティティ
#define GLOWING_ENTITY_LIGHTS // 発光エンティティ (ブレイズ・グロウイカ等)

#endif
