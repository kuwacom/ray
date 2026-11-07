/*
 * 水に入った自分 (三人称のプレイヤー) の水面より下の判定 (surface モジュール)
 * Iris 26.1 は自分のスキン・防具を半透明の前方シェーディング (gbuffers_entities_translucent) で水より先に描き、その色が
 * 半透明の層に残るので、水の合成が水の中の脚を屈折も吸収も無いまま水面の上に重ねていた
 */
#ifndef SURFACE_WATER_SELF_GLSL
#define SURFACE_WATER_SELF_GLSL

//@include "/lib/common/voxel_space.glsl"
//@include "/lib/ids/block_ids.glsl"
//@include "/lib/light/voxel_read.glsl"

// 上に水の無い水のブロックの水面の高さ (バニラの水源の上面。Ray の水面は形を動かさず法線だけで波を描くので、描く水面もこの高さ)
const float WATER_SELF_SURFACE = 8.0 / 9.0;
// 水面を探して上へ辿るセルの数。これより深い所は辿った分の深さとみなす (吸収はそこで飽和している)
// 自分の三角形を辿る長さ (WATER_SELF_TRACE_MAX) より深くまで水の中と判定できる数にする
const int WATER_SELF_SEARCH = 6;
// 水面を探して下へ辿るセルの数 (水面より上の体)。立った体の高さ (1.8) と跳んだ分が入る数
const int WATER_SELF_ABOVE_SEARCH = 3;
// 目からこれより下を足の側とみなす。足のあるセルだけは水でないブロック (水の入ったハーフブロック・階段) でも上の水を探す
const float WATER_SELF_FEET_BELOW_EYE = 1.0;
// 視線の上向きの cos の下限 (かすめ角で水の中の長さが無限にならない)
const float WATER_SELF_MIN_COS = 0.1;
// 水のセルの底からこの分だけ下も水の中とみなす (膨らませた防具のブーツの底は足場のブロックへ 1/16 はみ出す)
const float WATER_SELF_FLOOR_EPS = 0.125;
// 屈折した視線を自分の三角形に当てる最大の距離 (ブロック)。水面から自分の足までの距離より長ければよい
const float WATER_SELF_TRACE_MAX = 4.0;
/*
 * 自分の三角形を辿る前に視線を当てる箱 (目の位置からの player 空間)。泳ぐ姿勢・腕・防具まで入る大きさ
 * 水面のほとんどの画素はこの箱で外れ、三角形の箱 (SSBO) を読まずに済む
 */
const vec3 WATER_SELF_BOX_LO = vec3(-1.5, -2.0, -1.5);
const vec3 WATER_SELF_BOX_HI = vec3(1.5, 0.5, 1.5);

/*
 * 水面からの深さ (ブロック)。水の中でなければ負
 * 上に水のある水のセルは面がすべて隠れて描かれず、ボクセルには空気として残る。水の下に空気のセルは長く残らないので、
 * 空気は上に水がある限り水とみなして水面まで辿る
 * 一番上の水が流れる水なら水の中とみなさない (上面が水源より低く高さが分からない。捨てた体の水面より上の部分が欠ける)。
 * 乗り物の中も水の中とみなさない (ボートの中は水を描かないので、捨てた脚が消える)
 */
float waterSelfDepth(vec3 playerPos) {
    if (isRiding) return -1.0;
    vec3 v = playerToVoxel(playerPos);
    ivec3 cell = ivec3(floor(v + vec3(0.0, WATER_SELF_FLOOR_EPS, 0.0)));
    bool feet = playerPos.y < -relativeEyePosition.y - WATER_SELF_FEET_BELOW_EYE;
    int top = -1;
    bool flowing = false;
    for (int k = 0; k <= WATER_SELF_SEARCH; k++) {
        ivec3 c = cell + ivec3(0, k, 0);
        if (!isInVoxelVolume(c)) break;
        uint data = fetchVoxelBlockData(c);
        int id = unpackVoxelBlockId(data);
        if (id == BLOCK_WATER || id == BLOCK_UNDERWATER_PLANT) {
            top = k;
            flowing = (data >> 12u) == VOXEL_WATER_FLOWING;
        } else if (id != BLOCK_AIR && !(k == 0 && feet)) {
            break;
        }
    }
    if (top < 0 || flowing) return -1.0;
    return float(cell.y + top) + WATER_SELF_SURFACE - v.y;
}

/*
 * 水面からの高さ (ブロック)。真下に辿った空気の先が水源の水面でなければ負
 * カメラが水の中の時、水面より上の体は水面越し (スネルの窓の屈折) に見えるはずなので、半透明の層で捨てて composite1 が描く
 * 水の中のセルの上の端 (水面と上のセルの間) と、その上の空気のセルだけを対象にする。足場のブロック・流れる水の上は対象外
 */
float waterSelfHeight(vec3 playerPos) {
    if (isRiding) return -1.0;
    vec3 v = playerToVoxel(playerPos);
    ivec3 cell = ivec3(floor(v));
    for (int k = 0; k <= WATER_SELF_ABOVE_SEARCH; k++) {
        ivec3 c = cell - ivec3(0, k, 0);
        if (!isInVoxelVolume(c)) break;
        uint data = fetchVoxelBlockData(c);
        int id = unpackVoxelBlockId(data);
        if (id == BLOCK_WATER || id == BLOCK_UNDERWATER_PLANT) {
            // 上に水のある水のセルはボクセルで空気なので、水のセルが見つかればそれが一番上
            if ((data >> 12u) == VOXEL_WATER_FLOWING) return -1.0;
            return v.y - (float(c.y) + WATER_SELF_SURFACE);
        }
        if (id != BLOCK_AIR) break;
    }
    return -1.0;
}

#endif
