/*
 * G バッファに書くマテリアル ID (8bit, colortex1.a / colortex5.a)
 * ブロック ID・エンティティ ID から gbuffers で変換して書く。deferred 以降はこれだけを見る
 */
#ifndef IDS_MATERIAL_IDS_GLSL
#define IDS_MATERIAL_IDS_GLSL

const int MAT_NONE = 0;              // 空 (ジオメトリなし)
const int MAT_TERRAIN = 1;
const int MAT_PLANT = 2;
const int MAT_LEAVES = 3;
const int MAT_EMISSIVE_BLOCK = 4;
const int MAT_METAL = 5;
const int MAT_GLOSSY = 6;
const int MAT_SNOW = 7;
const int MAT_LAVA = 8;
const int MAT_UNDERWATER_PLANT = 9;

const int MAT_WATER = 10;
const int MAT_GLASS = 11;
const int MAT_STAINED_GLASS = 12;
const int MAT_ICE = 13;
const int MAT_SLIME_HONEY = 14;
const int MAT_NETHER_PORTAL = 15;
const int MAT_TRANSLUCENT = 16;      // その他の半透明

const int MAT_ENTITY = 20;
const int MAT_PLAYER = 21;
const int MAT_ITEM_ENTITY = 22;
const int MAT_EMISSIVE_ENTITY = 23;
const int MAT_BLOCK_ENTITY = 24;
const int MAT_BEACON_BEAM = 25;
const int MAT_LIGHTNING = 26;

const int MAT_HAND = 30;
const int MAT_HAND_EMISSIVE = 31;

const int MAT_PARTICLE = 40;
const int MAT_WEATHER = 41;
const int MAT_CLOUD_VANILLA = 42;
const int MAT_BASIC = 43;

bool isHandMaterial(int m) { return m >= MAT_HAND && m < MAT_HAND + 10; }
bool isEntityMaterial(int m) { return m >= MAT_ENTITY && m < MAT_ENTITY + 10; }
bool isPlantMaterial(int m) { return m == MAT_PLANT || m == MAT_LEAVES || m == MAT_UNDERWATER_PLANT; }
bool isTranslucentMaterial(int m) { return m >= MAT_WATER && m < MAT_WATER + 10; }

#endif
