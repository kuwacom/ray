/*
 * light モジュール (ボクセル / ブロックライト / 手持ち・エンティティ光源) の公開ヘッダ
 * 他モジュールはこのファイルだけを include する
 */
#ifndef LIGHT_LIGHT_GLSL
#define LIGHT_LIGHT_GLSL

#include "/lib/light/light_table.glsl"
#include "/lib/light/block_data.glsl"
#include "/lib/light/voxel.glsl"
#include "/lib/light/floodfill.glsl"
#include "/lib/light/entity_tri.glsl"
#include "/lib/light/trace.glsl"
#include "/lib/light/light_select.glsl"
#include "/lib/light/entity_light.glsl"
#include "/lib/light/hand_light.glsl"
#include "/lib/light/blocklight.glsl"

#endif
