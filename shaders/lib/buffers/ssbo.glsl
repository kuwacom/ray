/*
 * SSBO のレイアウト (全シェーダーで同一でなければならない。Iris の仕様)
 * サイズは shaders.properties の bufferObject.N と一致させること
 * 書き込むモジュールをフィールドごとに明記。それ以外は読むだけ
 */
#ifndef BUFFERS_SSBO_GLSL
#define BUFFERS_SSBO_GLSL

const int LIGHT_TABLE_SIZE = 256;   // 光源定義の数 (光源インデックス 0-255, 0 は「光らない」)
const int SHAPE_TABLE_SIZE = 128;   // 遮蔽形状の数 (ブロック ID 300-399 -> 形状 0-99)
const int TINT_TABLE_SIZE = 128;    // 透過色の数 (ブロック ID 200-299 -> 色 0-99)
const int ALBEDO_TABLE_SIZE = 4096; // ブロックの平均の色の数 (ボクセルの 12bit ID をそのまま引く)
const int MAX_GLOBAL_LIGHTS = 4096; // 1 フレームに登録できる光源インスタンス数
const int MAX_GLOBAL_LIGHTS_ALLOC = MAX_GLOBAL_LIGHTS; // 確保数。ビンのキーの下位 13 bit に入る数

const int LIGHT_BIN_SIZE = 8;       // ライトビン 1 辺のブロック数
const int LIGHT_BIN_CAPACITY = 64;  // ビン 1 つに入る光源数
/*
 * ビン 1 つの枠の数。LIGHT_CULL_MODE 1/2 は重要度の降順に LIGHT_BIN_CAPACITY 個を持ち、
 * 最後の 1 枠に外れた光源のうち最も重要なもののキーを持つ (境界で弱めるため, lib/light/light_select.glsl)
 */
const int LIGHT_BIN_STRIDE = LIGHT_BIN_CAPACITY + 1;
const int LIGHT_BIN_STRIDE_ALLOC = LIGHT_BIN_STRIDE;
#if LIGHT_CULL_MODE == 0
    const ivec3 LIGHT_BIN_GRID = ivec3(VOXEL_SIZE_X, VOXEL_SIZE_Y, VOXEL_SIZE_Z) / LIGHT_BIN_SIZE;
#else
    // ビンをワールドの 8 ブロック格子にそろえる (カメラの 1 ブロックの移動でビンの境界が動かないように)。端の分 1 つ多い
    const ivec3 LIGHT_BIN_GRID = ivec3(VOXEL_SIZE_X, VOXEL_SIZE_Y, VOXEL_SIZE_Z) / LIGHT_BIN_SIZE + 1;
#endif
const int LIGHT_BIN_MAX = 40960;    // 最大体積 (384x128x384) のワールド格子のビン数 49x17x49 を 256 の倍数に。確保量はこれで固定

// 光源を間引く距離 (LIGHT_CULL_MODE 1/2) の分布の段数と 1 段の幅 (ブロック)
const int LIGHT_CULL_BUCKETS = 64;
const float LIGHT_CULL_BUCKET_WIDTH = 4.0;
const float LIGHT_CULL_NONE = 1e9;  // 間引かない時の cullDistance

// エンティティ光源の蓄積表 (lib/light/entity_light.glsl)
const int ENTITY_ACC_SIZE = 4096;      // エントリ数 (2 のべき乗)
const int ENTITY_ACC_STRIDE = 8;       // 1 エントリの uint 数: key, count, sumX, sumY, sumZ, 予備 x3
const int ENTITY_ACC_UINTS = ENTITY_ACC_SIZE * ENTITY_ACC_STRIDE;

/*
 * binding 0: フレーム共有データ (永続)
 * 確保: 4096 バイト
 */
layout(std430, binding = 0) buffer FrameDataBuffer {
    // post (composite25 で書く)
    float exposure;           // 線形の露出倍率。シーン色に掛けて使う
    float exposureTarget;     // 順応前の目標露出
    float averageLuminance;   // 計測した平均輝度 (露出前)
    float focusDistance;      // オートフォーカス距離 (ブロック, 平滑化済み)

    // sky (prepare で書く)
    vec4 sunIrradiance;          // rgb = 地表での太陽直達照度 (大気透過込み), a = 太陽高度の sin
    vec4 moonIrradiance;         // rgb = 地表での月直達照度, a = 月高度の sin
    vec4 shadowLightIrradiance;  // rgb = 影を落とす側 (昼は太陽 / 夜は月) の直達照度, a = 1 なら太陽
    vec4 skySH[9];               // rgb = 空の放射の SH L2 係数 (照度は shEvalIrradiance で)
    vec4 skyParams[4];           // sky の自由領域

    // light (deferred / deferred_a で書く)
    uvec4 lightStats;            // x = 前フレームの光源数, y = 溢れ数, z = エンティティ光源の登録締め切りフラグ (light), w = 前フレームに距離で間引いた数

    // surface の自由領域
    vec4 surfaceParams[4];

    // post
    uint histogram[256];         // 露出ヒストグラム (composite25 内で毎フレームクリア)
    vec4 postParams[4];          // post の自由領域
} frameData;

/*
 * binding 1: ブロックデータ表 (setup.csh が起動時に 1 回だけ書く。以降は読み取り専用)
 * 確保: 57344 バイト (使用 53252)
 */
struct LightDef {
    vec4 color;   // rgb = 線形色 (最大成分 1), a = 明るさ倍率
    vec4 shape;   // xyz = ブロック内の発光中心 [0,1], w = 光源半径 (ブロック, 半影用)
    vec4 params;  // x = 光源レベル 15 時の到達半径 (ブロック), y = フリッカー量 [0,1], z = 既定の光源レベル (0-15), w = 予備
    uvec4 info;   // x = フラグ (LIGHT_FLAG_*), y = 遮蔽形状 ID (SHAPE_*), zw = 予備
};

layout(std430, binding = 1) buffer BlockDataBuffer {
    LightDef lightDefs[LIGHT_TABLE_SIZE];
    uvec4 shapes[SHAPE_TABLE_SIZE]; // AABB 2 個: x/y = box0 min/max, z/w = box1 min/max (packUnorm4x8, min>max で無効)
    vec4 tints[TINT_TABLE_SIZE];    // rgb = 透過色 (線形), a = 不透明度
    uint initialized;
    /*
     * ボクセル ID ごとの平均の色 (sRGB 8bit を R | G << 8 | B << 16, lib/ids/block_albedo.glsl)
     * 生成した定数配列を floodfill の全セルから直接引くと EXTREME で 37 -> 22 FPS に落ちた (この SSBO に移して 41 FPS)。
     * 動的な添字の定数配列がスレッドごとのローカルメモリに展開されたとみられる
     */
    uint albedo[ALBEDO_TABLE_SIZE];
    // 上向きの面の色 (同じ詰め方)。上面の色が違うブロック (草ブロック・原木など) 以外は albedo と同じ
    uint albedoUp[ALBEDO_TABLE_SIZE];
} blockData;

/*
 * binding 2: 今フレームの光源インスタンス (light)
 * begin.csh で count 等を 0 に戻し、shadow / gbuffers_entities / deferred.csh が追加する
 * 確保: 147744 バイト
 */
struct LightInstance {
    vec4 posRadius;  // xyz = ボクセル空間の位置 (今フレーム), w = 到達半径 (ブロック)
    vec4 colorSize;  // rgb = 放射 (色 x 明るさ x レベル, BLOCKLIGHT_ILLUMINANCE 倍済み), a = 光源半径
};

layout(std430, binding = 2) buffer GlobalLightsBuffer {
    uint count;       // 登録数 (atomicAdd で確保。MAX_GLOBAL_LIGHTS を超えた分は捨てる)
    uint blockCount;  // うちブロック光源
    uint entityCount; // うちエンティティ光源 (ドロップ・投擲・燃焼・発光)
    uint overflow;    // 容量超過で捨てた数
    float cullDistance; // これより遠い光源は登録しない (LIGHT_CULL_MODE 1/2, 永続。deferred_a が前フレームの分布から更新)
    uint culled;        // cullDistance で間引いた数
    uint cullPad0;
    uint cullPad1;
    uint cullHist[LIGHT_CULL_BUCKETS]; // 登録しようとした光源の距離の分布 (deferred が足し、deferred_a が読んで 0 に戻す)
    LightInstance lights[MAX_GLOBAL_LIGHTS_ALLOC];
    float lightPower[MAX_GLOBAL_LIGHTS_ALLOC]; // 揺らぎを掛ける前の放射の輝度 (ビンの重要度用。揺らぎで順位が入れ替わらないように)
} globalLights;

/*
 * binding 3: ワールド空間のライトビン (light, deferred_a.csh が書く)
 * ビン = LIGHT_BIN_SIZE^3 ブロック。index = x + y*GRID.x + z*GRID.x*GRID.y
 * 確保: 10944512 バイト
 */
layout(std430, binding = 3) buffer LightBinsBuffer {
    uint binCount[LIGHT_BIN_MAX]; // 登録しようとした数 (容量超過を含む)
    // エンティティ光源の蓄積表。begin でクリア -> shadow / gbuffers で蓄積 -> deferred で読む
    uint entityAcc[ENTITY_ACC_UINTS];
    // ビンの中身 (キー, lib/light/light_select.glsl)。下位 13 bit が globalLights.lights のインデックス
    uint binLights[LIGHT_BIN_MAX * LIGHT_BIN_STRIDE_ALLOC];
} lightBins;

/*
 * binding 4: エンティティの三角形 (light, lib/light/entity_tri.glsl)
 * begin.csh で counts と AABB を戻し、shadow_entities.gsh が三角形と AABB (atomicMin/Max) を書く。deferred 以降は読むだけ
 * 座標はボクセル空間 (今フレーム)。三角形は v0 と 2 辺 e1, e2 で持つ (Möller-Trumbore でそのまま使う)
 * クラスタ = ENT_TRI_CLUSTER 個の連続スロット, グループ = ENT_TRI_GROUP 個の連続スロット
 * AABB は 6 uint (min xyz, max xyz) の順序付き uint (entityTriOrderedFromFloat)。空は min = 0xFFFFFFFF, max = 0
 * atomicMin/Max を確実に通すため、ベクトルの成分ではなく uint の配列で持つ
 * 確保: 838672 バイト
 */
const int ENT_TRI_MAX = 16384;      // 三角形の確保数 (LIGHT_ENTITY_TRIANGLES の最大)
const int ENT_TRI_CLUSTER = 8;
const int ENT_TRI_GROUP = 128;
const int ENT_TRI_MAX_CLUSTERS = ENT_TRI_MAX / ENT_TRI_CLUSTER;
const int ENT_TRI_MAX_GROUPS = ENT_TRI_MAX / ENT_TRI_GROUP;

struct EntityTriangle {
    vec3 v0; uint maskLo; // maskLo/Hi = 重心座標 8x8 格子のアルファ (bit = i + j*8, i は e1 方向)
    vec3 e1; uint maskHi;
    vec3 e2; uint flags;  // 予備
};

layout(std430, binding = 4) buffer EntityTriangleBuffer {
    uint counts[4]; // 0 = プレイヤー, 1 = カメラ近傍, 2 = 遠方 の確保要求数 (容量超過を含む), 3 = 溢れ数
    uint groupBounds[ENT_TRI_MAX_GROUPS * 6];
    uint clusterBounds[ENT_TRI_MAX_CLUSTERS * 6];
    EntityTriangle tris[ENT_TRI_MAX];
} entityTris;

// binding 5-8 は予備

#endif
