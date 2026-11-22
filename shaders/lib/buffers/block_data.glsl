/*
 * SSBO binding 1: ブロックデータ表 (setup.csh が起動時に 1 回だけ書く。以降は読み取り専用)
 * 確保: 65536 バイト (使用 63728、shaders.properties の bufferObject.1)
 * 既定は readonly。書くプログラム (setup) は include の前に SSBO_BLOCK_DATA_WRITE を定義する
 */
#ifndef BUFFERS_BLOCK_DATA_GLSL
#define BUFFERS_BLOCK_DATA_GLSL

#ifdef SSBO_BLOCK_DATA_WRITE
    #define SSBO_BLOCK_DATA_ACCESS
#else
    #define SSBO_BLOCK_DATA_ACCESS readonly
#endif

const int LIGHT_TABLE_SIZE = 256;   // 光源定義の数 (光源インデックス 0-255, 0 は「光らない」)
const int SHAPE_TABLE_SIZE = 128;   // 遮蔽形状の数 (ブロック ID 300-399 -> 形状 0-99)
const int TINT_TABLE_SIZE = 128;    // 透過色の数 (ブロック ID 200-299 -> 色 0-99)
const int ALBEDO_TABLE_SIZE = 4096; // ブロックの平均の色の数 (ボクセルの 12bit ID をそのまま引く)
const int LIGHT_MASK_LIGHTS = 128;  // 面の光り方を持てる光源の数 (ブロック光源の帯 0-127)
const int LIGHT_MASK_FACE_CLASSES = 4; // 面の種類: 0 = 上、1 = 下、2 = 側面 (4 面の平均)、3 = 前面 (向きのある光源だけ)
const int LIGHT_MASK_TABLE_SIZE = LIGHT_MASK_LIGHTS * LIGHT_MASK_FACE_CLASSES;
// 反射体の面の凹凸 (lightMasks の LIGHT_MASK_TABLE_SIZE の後ろ)。tools/gen_block_properties.py の REFLECTOR_MAP_BLOCKS / REFLECTOR_MAP_VEC4S と同じ値
const int REFLECTOR_MAP_BLOCKS = 5;     // 鉄・ラピスラズリ・エメラルド・ダイヤモンド・金
const int REFLECTOR_MAP_VEC4S = 22;     // 1 ブロックの uvec4 の数
const int REFLECTOR_MAP_BASE = LIGHT_MASK_TABLE_SIZE;

struct LightDef {
    vec4 color;   // rgb = 線形色 (最大成分 1), a = 明るさ倍率
    vec4 shape;   // xyz = ブロック内の発光中心 [0,1], w = 光源半径 (ブロック, 半影用)
    vec4 params;  // x = 光源レベル 15 時の到達半径 (ブロック), y = フリッカー量 [0,1], z = 既定の光源レベル (0-15), w = 到達半径の下限 (LIGHT_FALLOFF_MODE 1。0 では 0)
    uvec4 info;   // x = フラグ (LIGHT_FLAG_*), y = 遮蔽形状 ID (SHAPE_*), zw = 予備
};

/*
 * 遮蔽形状の箱の上位 2bit: 鉄格子の腕の印。箱の中央の面 (x = 0.5 か z = 0.5) を通る所でだけ、バニラのテクスチャの棒の並びで遮る
 * (lib/light/trace.glsl の barsPlaneBlocks)。バニラの鉄格子は厚みのない面に抜きのあるテクスチャを貼った形で、箱のままだと隙間の光まで止める
 */
const uint BOX_BARS_PLANE_X = 1u << 30u; // 面 x = 0.5 (南北の腕)
const uint BOX_BARS_PLANE_Z = 1u << 31u; // 面 z = 0.5 (東西の腕)

// 遮蔽形状の箱 1 個 (lib/light/light_table.glsl の packBox) を 1/16 刻みの min, max に戻す。min > max は無効な箱
void unpackShapeBox(uint p, out vec3 bmin, out vec3 bmax) {
    bmin = vec3(uvec3(p & 31u, (p >> 5) & 31u, (p >> 10) & 31u)) * (1.0 / 16.0);
    bmax = vec3(uvec3((p >> 15) & 31u, (p >> 20) & 31u, (p >> 25) & 31u)) * (1.0 / 16.0);
}

layout(std430, binding = 1) SSBO_BLOCK_DATA_ACCESS buffer BlockDataBuffer {
    LightDef lightDefs[LIGHT_TABLE_SIZE];
    uvec4 shapes[SHAPE_TABLE_SIZE]; // AABB 4 個: x/y/z/w = box0-3 (1/16 刻みの min xyz, max xyz を 5bit ずつ。min>max で無効)
    vec4 tints[TINT_TABLE_SIZE];    // rgb = 透過色 (線形), a = 不透明度
    /*
     * 遮蔽形状が面全体をふさぐ向き (bit i: 軸 i >> 1、i が偶数で +、奇数で -。floodfill の 6 近傍の順)
     * floodfill はセル単位で伝わるので、ハーフブロックの床や閉じたドアの板の面ではここを見て光を渡さない
     */
    uint shapeFaces[SHAPE_TABLE_SIZE];
    uint initialized;
    /*
     * ボクセル ID ごとの平均の色 (sRGB 8bit を R | G << 8 | B << 16, lib/ids/block_albedo.glsl)
     * 反射率の強さが 1 でない時だけ、色付きの固体の << 24 に平均の最大成分を入れる (colorBlockMeanMax。テラコッタの倍率に使う)
     * 生成した定数配列を floodfill の全セルから直接引くと EXTREME で 37 -> 22 FPS に落ちた (この SSBO に移して 41 FPS)。
     * 動的な添字の定数配列がスレッドごとのローカルメモリに展開されたとみられる
     */
    uint albedo[ALBEDO_TABLE_SIZE];
    // 上向きの面の色 (同じ詰め方)。上面の色が違うブロック (草ブロック・原木など) 以外は albedo と同じ
    uint albedoUp[ALBEDO_TABLE_SIZE];
    /*
     * 光るブロックの面の光り方 (添字 = 光源インデックス x 4 + 面の種類。lib/light/light_mask_data.glsl)
     * x = 光る範囲の四角 packUnorm4x8(vec4(u0, v0, u1, v1)) (テクスチャの座標、v は上が 0)
     * y = packHalf2x16(vec2(割合, マスの最大の重み))。割合 = 面の光の量 / (四角の面積 x 光源の最も明るい面の中の平均)
     * z, w = 光る範囲の四角を 4x4 に分けたマス (4 bit ずつ、重み = 値 / 15 x マスの最大の重み)。z が行 0-1、w が行 2-3 で、
     *   行 r 列 c は bit 4 x (c + 4 x (r & 1))。r は v の向き、c は u の向き
     * 光らない面は全部 0。データの無い光源は LIGHT_FLAG_EMISSION_MASK が立たない
     * albedoUp の後ろに置くのは、手前のメンバーのオフセットを変えないため
     *
     * 後ろに反射体の面の凹凸が続く (REFLECTOR_MAP_BASE から ブロック x REFLECTOR_MAP_VEC4S 個。lib/light/reflector_map_data.glsl)。
     * 1 ブロックは 88 語 (4 語 = 1 uvec4): 語 0-63 = 16x16、64-79 = 8x8、80-83 = 4x4、84 = 2x2 (8bit の符号付きを 4 つずつ。値 / 127 x 段の倍率が
     * テクスチャの明るさのラプラシアン。段ごとに二乗平均平方根をそろえ、ブロックの凹凸の相対の強さを掛けてある)、85 = half 2 つ (段 0 と 1 の倍率)、86 = 同 (段 2 と 3)
     */
    uvec4 lightMasks[]; // 要素数: LIGHT_MASK_TABLE_SIZE + REFLECTOR_MAP_BLOCKS * REFLECTOR_MAP_VEC4S
} blockData;

#endif
