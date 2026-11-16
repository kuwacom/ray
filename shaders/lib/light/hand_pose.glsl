/*
 * 手の位置 (体のモデル)。手持ち光源 (hand_light.glsl) から分けてある
 * shadow_entities.gsh が使うので、光源の SSBO の宣言を持つ light_select.glsl を読まないようにする
 */
#ifndef LIGHT_HAND_POSE_GLSL
#define LIGHT_HAND_POSE_GLSL

//@include "/lib/common/uniforms.glsl"
//@include "/lib/settings/capabilities.glsl"
//@include "/lib/ids/entity_ids.glsl"

// 三人称の手の位置: 目からの下がり幅, 体の中心からの横幅, 前へのずれ (ブロック)
const float HAND_THIRD_PERSON_DROP = 0.75;
const float HAND_THIRD_PERSON_SIDE = 0.38;
const float HAND_THIRD_PERSON_FORWARD = 0.15;

// プレイヤーの目の位置 (player 空間)。relativeEyePosition = cameraPosition - eyePosition
vec3 getEyePlayerPos() { return -relativeEyePosition; }

// 体のモデル (shadow パス・三人称) で光源を持つ手の位置 (player 空間)
vec3 getBodyHandPosition(bool mainHand) {
    float side = (mainHand == isRightHanded) ? 1.0 : -1.0;
    // 体の向き (水平) から右手方向を作る。MC の座標系 (x 東, z 南) で右 = (-f.z, 0, f.x)
    vec3 body = vec3(playerBodyVector.x, 0.0, playerBodyVector.z);
    if (dot(body, body) < 1e-4) body = vec3(playerLookVector.x, 0.0, playerLookVector.z);
    body = dot(body, body) > 1e-4 ? normalize(body) : vec3(0.0, 0.0, 1.0);
    vec3 right = vec3(-body.z, 0.0, body.x);
    return getEyePlayerPos() + vec3(0.0, -HAND_THIRD_PERSON_DROP, 0.0)
        + right * (side * HAND_THIRD_PERSON_SIDE) + body * HAND_THIRD_PERSON_FORWARD;
}

/*
 * 光る物を持つ手 (体のモデル) の近くか。p は player 空間
 * 手持ちのランタンは影パスでエンティティ ID (entityId <= 0) も光るアイテムの ID も付かずに描かれる (たいまつ・グロウストーンでは起きない)。
 * ほかのエンティティの三角形として手持ち光の遮蔽物になり、一人称でランタン自身の影が床や壁に出ていた。
 * shadow_entities.gsh がこの範囲の ID の無い三角形を外す。ランタンのモデルはこの手の位置から 0.6 より離れた所まであるので 1.2 (実機で確認)
 */
const float HAND_HELD_ITEM_RADIUS = 1.2;

bool isNearLitHand(vec3 p) {
    if (heldBlockLightValue > 0 && distance(p, getBodyHandPosition(true)) < HAND_HELD_ITEM_RADIUS) return true;
    return heldBlockLightValue2 > 0 && distance(p, getBodyHandPosition(false)) < HAND_HELD_ITEM_RADIUS;
}

#ifdef FX_SELF_BY_DISTANCE
/*
 * 自分の体の範囲: 目から下がった体の中心と、そこからの半径 (ブロック)。持った物の先と、泳ぐ・滑空する時の横になった体まで入る大きさ
 * この範囲にいる他のプレイヤーも自分として扱われる
 */
const float SELF_BODY_CENTER_DROP = 0.8;
const float SELF_BODY_RADIUS = 1.6;

/*
 * 描いているエンティティが自分か。p はそのエンティティ上の点 (player 空間)
 * current_player の ID が無い Iris では自分も minecraft:player で来るので、目の近くのプレイヤーを自分とする
 * (見分けないと、影のパスの自分の手のたいまつがエンティティの光源として手持ち光源に重なって明るくなり、自分の体も手持ち光源を遮る)
 */
bool isSelfEntity(int entId, vec3 p) {
    return entId == ENTITY_CURRENT_PLAYER
        || (entId == ENTITY_PLAYER && distance(p, getEyePlayerPos() - vec3(0.0, SELF_BODY_CENTER_DROP, 0.0)) < SELF_BODY_RADIUS);
}
#endif

#endif
