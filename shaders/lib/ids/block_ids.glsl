/*
 * ブロック ID (block.properties と同じ表から生成する)
 * tools/gen_block_properties.py が生成する (光源以外は同スクリプトの BLOCKS、光源は tools/id_tables.py)。手で編集しない
 *
 * 番号帯
 *   1        : 未登録の固体 (mc_Entity.x = -1 をボクセルではこれに置き換える)
 *   10-19    : マテリアルのヒント付き固体 (完全遮蔽)
 *   100-129  : 遮蔽しない植物・小物
 *   130-178  : 染めた小物 (カーペット・旗・火のないロウソク。扱いは BLOCK_NON_OCCLUDING と同じ)
 *   200-299  : 半透明 (透過色テーブル index = id - 200)
 *   300-399  : 部分形状 (形状テーブル index = id - 300)
 *   1001-1255: 光源 (光源インデックス = id - 1000, lib/ids/light_ids.glsl)
 *   1257-1895: 向きのある光源の東・南・西 (id - 1000 = 256 x 向き + 光源インデックス)
 *   2000-4095: 色の付いた固体 (完全遮蔽。上の帯に無いブロックを平均の色ごとにまとめたもの。色は lib/ids/block_albedo.glsl)
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
const int BLOCK_NON_OCCLUDING = 106;    // レール・ボタン等 (揺れない)
const int BLOCK_COBWEB = 107;
const int BLOCK_LILY_PAD = 108;
const int BLOCK_CANE = 109;             // サトウキビ・竹
const int BLOCK_UNDERWATER_PLANT = 110; // 海草・コンブ
// 130-178: 染めた小物。質感・遮蔽・揺れは BLOCK_NON_OCCLUDING と同じで、反射率の設定 (ALBEDO_*_STRENGTH) を掛けるために分ける
const int BLOCK_CARPET = 130;             // 130-145 カーペット (色の順は BLOCK_STAINED_GLASS と同じ)
const int BLOCK_BANNER = 146;             // 146-161 旗・壁の旗 (同順)
const int BLOCK_CANDLE = 162;             // 火の付いていないロウソク。163-178 は色付き (同順)
const int BLOCK_DYED_LAST = 178;

const int BLOCK_WATER = 200;
const int BLOCK_ICE = 201;
const int BLOCK_GLASS = 202;
const int BLOCK_GLASS_PANE = 203;
const int BLOCK_SLIME = 204;
const int BLOCK_HONEY = 205;
const int BLOCK_TINTED_GLASS = 206;
const int BLOCK_WATER_FLOWING = 207;      // 上面が水源より低い流れる水。頂点で BLOCK_WATER に戻し、ボクセルには印だけ残す
const int BLOCK_STAINED_GLASS = 210;      // 210-225 (white, orange, magenta, light_blue, yellow, lime, pink, gray, light_gray, cyan, purple, blue, brown, green, red, black)
const int BLOCK_STAINED_GLASS_PANE = 230; // 230-245 (同順)

const int BLOCK_SLAB_BOTTOM = 300;
const int BLOCK_SLAB_TOP = 301;
const int BLOCK_PANEL_OPEN_FIRST = 302; // 302-305 = 開いたドア・トラップドア (厚さ 3/16 の縦の板が北・東・南・西の側)
const int BLOCK_LOW = 307;              // ベッド・石切台等の背の低いブロック
const int BLOCK_SNOW_LAYER = 308;       // 積もった雪 1 層 (高さ 1/8)
const int BLOCK_SNOW_LAYER_2 = 310;     // 310-316 = 積もった雪 2-8 層 (層の数 = ID - 308)
const int BLOCK_SNOW_LAYER_8 = 316;
const int BLOCK_STAIRS_FIRST = 320;     // 320-335 = 階段 (向き x 上下 x 外角の 16 通り。形は lib/light/light_table.glsl)
const int BLOCK_STAIRS_LAST = 335;
const int BLOCK_FENCE_FIRST = 336;      // 336-351 = フェンス (接続の向き 16 通り: 北 1 東 2 南 4 西 8 の和。形は lib/light/light_table.glsl)
const int BLOCK_WALL_FIRST = 352;       // 352-367 = 塀 (同じ接続の 16 通り)
const int BLOCK_PANE_BARS_FIRST = 368;  // 368-383 = 鉄格子 (同じ接続の 16 通り)
const int BLOCK_STAIRS_INNER_FIRST = 384; // 384-391 = 階段の内角 (上下 x 欠けた 1/4 の象限 北西・北東・南東・南西)
const int BLOCK_STAIRS_INNER_LAST = 391;
const int BLOCK_PANEL_CLOSED_FIRST = 392; // 392-397 = 閉じたドア (板が北・東・南・西の側) と閉じたトラップドア (下・上)
const int BLOCK_PANEL_CLOSED_LAST = 397;

const int BLOCK_LIGHT_BASE = 1000;      // 1001-1255 が光源 (光源インデックス = id - 1000)
const int BLOCK_LIGHT_FACING_STRIDE = 256; // 向きのある光源は 1000 + 256 x 向き (1 東 2 南 3 西) + 光源インデックス
const int BLOCK_LIGHT_LAST = 1895;      // 光源の ID の上限 (向きのある光源の西)

const int BLOCK_COLOR_FIRST = 2000;     // 2000 以降は色の付いた固体 (マテリアル・遮蔽は BLOCK_SOLID と同じ)

const int METAL_GATE_STRIDE = 4096;     // 一部だけ金属の ID = 元の ID + 判定の番号 x この値 (ブロック・アイテム)
const int METAL_GATE_ALL = 1;
const int METAL_GATE_GRAY = 2;
const int METAL_GATE_COOL = 3;
const int METAL_GATE_RAIL = 4;
const int METAL_GATE_GOLD = 5;
const int METAL_GATE_COPPER = 6;
const int METAL_GATE_NETHERITE = 7;
const int METAL_GATE_GEM = 8;

// 色の付いた固体 (2000 番台) の種類。0 = その他 (種類の混ざった ID も 0)
const int COLOR_KIND_CONCRETE = 1; // コンクリート・コンクリートパウダー
const int COLOR_KIND_WOOL = 2; // 羊毛
const int COLOR_KIND_TERRACOTTA = 3; // テラコッタ (彩釉テラコッタは BLOCK_GLOSSY の行にある)
const uint BLOCK_COLOR_KINDS[23] = uint[23](
    0x00536181u, 0x0C024001u, 0x00820000u, 0x35003010u, 0x08C00070u, 0x00104000u, 0x00000014u, 0x20000003u,
    0x0030200Cu, 0x00008000u, 0x00040000u, 0x00004100u, 0x0000C010u, 0x00D00000u, 0xC0300020u, 0x0003E040u,
    0x00000140u, 0xC0000000u, 0x00000012u, 0x04C04000u, 0x11000000u, 0x6A041100u, 0x00000080u
);
int blockColorKind(int id) {
    uint i = uint(id - BLOCK_COLOR_FIRST);
    if (i >= 356u) return 0;
    return int((BLOCK_COLOR_KINDS[i / 16u] >> ((i % 16u) * 2u)) & 3u);
}

#endif
