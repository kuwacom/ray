/*
 * エンティティ ID (entity.properties と対応) とアイテム ID (item.properties と対応)
 * 未登録のエンティティは 65535、未登録 / 素手のアイテムは -1 (heldItemId) または 0
 */
#ifndef IDS_ENTITY_IDS_GLSL
#define IDS_ENTITY_IDS_GLSL

const int ENTITY_CURRENT_PLAYER = 5001; // Iris のハードコード ID minecraft:current_player
const int ENTITY_PLAYER = 5002;         // 他のプレイヤー
const int ENTITY_ITEM = 5003;           // ドロップアイテム (光るかは currentRenderedItemId で判定)
const int ENTITY_ITEM_FRAME = 5004;     // 額縁 (中のアイテムは光源化しない)
const int ENTITY_SHADOW = 5005;         // Iris の minecraft:entity_shadow (丸影, 描かない)
const int ENTITY_NAME_TAG = 5006;       // Iris の minecraft:name_tag (ボクセル化しない)
const int ENTITY_BEAM = 5007;           // Iris の minecraft:end_crystal_beam
const int ENTITY_LIGHT_BASE = 5100;     // 5100-5163 は光源エンティティ (光源インデックス 192 + (id - 5100))
const int ENTITY_LIGHT_LAST = 5163;

// アイテム: 光るアイテムは 1000 + 光源インデックス。それ以外の特別扱い
const int ITEM_LIGHT_BASE = 1000;
const int ITEM_LIGHT_LAST = 1255;

#endif
