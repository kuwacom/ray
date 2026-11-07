/*
 * SSBO binding 4: エンティティの三角形 (light, lib/light/entity_tri.glsl)
 * begin.csh で counts と AABB を戻し、shadow_entities.gsh が三角形と AABB (atomicMin/Max) を書く。deferred 以降は読むだけ
 * 座標はボクセル空間 (今フレーム)。三角形は v0 と 2 辺 e1, e2 で持つ (Möller-Trumbore でそのまま使う)
 * クラスタ = ENTITY_TRI_CLUSTER 個の連続スロット, グループ = ENTITY_TRI_GROUP 個の連続スロット
 * AABB は 6 uint (min xyz, max xyz) の順序付き uint (entityTriOrderedFromFloat)。空は min = 0xFFFFFFFF, max = 0
 * atomicMin/Max を確実に通すため、ベクトルの成分ではなく uint の配列で持つ
 * 確保: 838672 バイト (shaders.properties の bufferObject.4)
 * 既定は readonly。書くプログラム (begin・shadow_entities・shadow_block) は include の前に SSBO_ENTITY_TRIS_WRITE を定義する
 */
#ifndef BUFFERS_ENTITY_TRIS_GLSL
#define BUFFERS_ENTITY_TRIS_GLSL

#ifdef SSBO_ENTITY_TRIS_WRITE
    #define SSBO_ENTITY_TRIS_ACCESS
#else
    #define SSBO_ENTITY_TRIS_ACCESS readonly
#endif

const int ENTITY_TRI_MAX = 16384;      // 三角形の確保数 (LIGHT_ENTITY_TRIANGLES の最大)
const int ENTITY_TRI_CLUSTER = 8;
const int ENTITY_TRI_GROUP = 128;
const int ENTITY_TRI_MAX_CLUSTERS = ENTITY_TRI_MAX / ENTITY_TRI_CLUSTER;
const int ENTITY_TRI_MAX_GROUPS = ENTITY_TRI_MAX / ENTITY_TRI_GROUP;

struct EntityTriangle {
    vec3 v0; uint maskLo; // maskLo/Hi = 重心座標 8x8 格子のアルファ (bit = i + j*8, i は e1 方向)
    vec3 e1; uint maskHi;
    vec3 e2; uint color;  // 不透明なセルのテクスチャ x 頂点色の平均 (sRGB の RGBA8、packUnorm4x8)。水の中の自分を屈折で描く色
};

layout(std430, binding = 4) SSBO_ENTITY_TRIS_ACCESS buffer EntityTriangleBuffer {
    uint counts[4]; // 0 = プレイヤー, 1 = カメラ近傍, 2 = 遠方 の確保要求数 (容量超過を含む), 3 = 溢れ数
    uint groupBounds[ENTITY_TRI_MAX_GROUPS * 6];
    uint clusterBounds[ENTITY_TRI_MAX_CLUSTERS * 6];
    EntityTriangle tris[]; // 要素数: ENTITY_TRI_MAX
} entityTris;

#endif
