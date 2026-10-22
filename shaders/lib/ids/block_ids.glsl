/*
 * ブロック ID (block.properties と 1 対 1 で対応。変更は両方を同時に)
 *
 * 番号帯
 *   1        : 未登録の固体 (mc_Entity.x = -1 をボクセルではこれに置き換える)
 *   10-19    : マテリアルのヒント付き固体 (完全遮蔽)
 *   100-129  : 遮蔽しない植物・小物
 *   200-299  : 半透明 (透過色テーブル index = id - 200)
 *   300-399  : 部分形状 (形状テーブル index = id - 300)
 *   1001-1255: 光源 (光源インデックス = id - 1000, lib/ids/light_ids.glsl)
 * ボクセルには下位 12bit しか入らないので 4095 を超える ID は作らない
 */
#ifndef IDS_BLOCK_IDS_GLSL
#define IDS_BLOCK_IDS_GLSL

const int BLOCK_AIR = 0;
const int BLOCK_SOLID = 1;

const int BLOCK_METAL = 10;
const int BLOCK_GLOSSY = 11;
const int BLOCK_SNOW = 12;
// 光らないが鮮やかな鉱物ブロック (DECORATIVE_BLOCK_LIGHTS で発光・光源にする。光源インデックスは LIGHT_DECOR_FIRST から同じ順)
const int BLOCK_DECOR_LAPIS = 13;
const int BLOCK_DECOR_EMERALD = 14;
const int BLOCK_DECOR_DIAMOND = 15;
const int BLOCK_DECOR_GOLD = 16;
const int BLOCK_DECOR_REDSTONE = 17;
const int BLOCK_DECOR_AMETHYST = 18; // アメジストブロック・芽生えたアメジスト

const int BLOCK_PLANT_SHORT = 100;      // 草・花・苗木 (根元固定で揺れる)
const int BLOCK_PLANT_TALL_LOWER = 101; // 2 ブロックの植物の下半分
const int BLOCK_PLANT_TALL_UPPER = 102; // 2 ブロックの植物の上半分
const int BLOCK_LEAVES = 103;
const int BLOCK_VINES = 104;
const int BLOCK_CROPS = 105;
const int BLOCK_NON_OCCLUDING = 106;    // レール・ボタン・カーペット等 (揺れない)
const int BLOCK_COBWEB = 107;
const int BLOCK_LILY_PAD = 108;
const int BLOCK_CANE = 109;             // サトウキビ・竹
const int BLOCK_UNDERWATER_PLANT = 110; // 海草・コンブ

const int BLOCK_WATER = 200;
const int BLOCK_ICE = 201;
const int BLOCK_GLASS = 202;
const int BLOCK_GLASS_PANE = 203;
const int BLOCK_SLIME = 204;
const int BLOCK_HONEY = 205;
const int BLOCK_TINTED_GLASS = 206;
const int BLOCK_STAINED_GLASS = 210;      // 210-225 (white, orange, magenta, light_blue, yellow, lime, pink, gray, light_gray, cyan, purple, blue, brown, green, red, black)
const int BLOCK_STAINED_GLASS_PANE = 230; // 230-245 (同順)

const int BLOCK_SLAB_BOTTOM = 300;
const int BLOCK_SLAB_TOP = 301;
const int BLOCK_STAIRS_BOTTOM = 302;
const int BLOCK_STAIRS_TOP = 303;
const int BLOCK_FENCE = 304;
const int BLOCK_WALL = 305;
const int BLOCK_PANE_BARS = 306;
const int BLOCK_LOW = 307;              // ベッド・石切台等の背の低いブロック
const int BLOCK_SNOW_LAYER = 308;       // 積もった雪 1 層 (高さ 1/8)
const int BLOCK_DOOR_CLOSED = 309;      // 閉じたドア・トラップドア (薄いが光は遮る)
const int BLOCK_SNOW_LAYER_2 = 310;     // 310-316 = 積もった雪 2-8 層 (層の数 = ID - 308)
const int BLOCK_SNOW_LAYER_8 = 316;

const int BLOCK_LIGHT_BASE = 1000;      // 1001-1255 が光源

#endif
