/*
 * ビーコンの光線の形 (縦の円柱) と視線の位置関係 (sky モジュール)
 * 光線を描く composite19 (lib/sky/beacon_beam.glsl) と、光線の画素を光線の点で再投影する TAA (composite20) が使う
 * 光線は深度を書かないので、TAA が奥の地形・空の動きで履歴を読むと、高い所から動きながら見た時に
 * 光線と奥の視差の分 (1 フレームに 1 画素ほど) 履歴がずれ、細い光線が速さに応じて半分ほどに暗くなってちらついた
 * 確かめ方: 高い所 (高さ 200 など) から光線を横切るように動きながら連写し、止まった時と光線の明るさが同じこと
 */
#ifndef SKY_BEACON_BEAM_SHAPE_GLSL
#define SKY_BEACON_BEAM_SHAPE_GLSL

//@include "/lib/common/common.glsl"
//@include "/lib/buffers/frame_data.glsl"

const float BEACON_BEAM_FAR = 1e6;              // 奥に何も無い (空) 視線の距離
const float BEACON_BEAM_CORE_RADIUS = 0.12;     // 芯のガウスの半径 (ブロック)。バニラの内側の光線 (半径 0.2) と同じくらいの太さに見える
const float BEACON_BEAM_MIN_PIXELS = 0.75;      // 芯の半径の下限 (画素)。遠くの細い線が画素の間で途切れてちらつかないよう、光の量を保って太らせる
const float BEACON_BEAM_MIN_SIN2 = 1e-12;       // 真上・真下の視線で 0 で割らないための水平成分の 2 乗の下限

bool hasBeaconBeams() { return frameData.beaconBeamKey[0] != 0u; }

/*
 * 視線と光線 i の位置関係
 * c: カメラから軸への水平のベクトル, s0: 視線が軸に最も近づく点までの距離, h2: その水平の距離の 2 乗,
 * [s1, s2]: 視線が光線の高さの区間にあり奥の面 (opaqueDist) より手前の範囲, sp: 光線の見える点 (s0 を区間に収めた距離)
 * yMin / yMax: カメラから見た光線の下端・上端の高さ
 */
struct BeaconBeamSpan {
    vec2 c;
    float s0;
    float h2;
    float s1;
    float s2;
    float sp;
    float yMin;
    float yMax;
};

// 視線が光線の高さの区間を通らない (s2 <= s1) 時は false
bool beaconBeamSpan(int i, vec3 dir, float opaqueDist, out BeaconBeamSpan b) {
    float a2 = dot(dir.xz, dir.xz);
    float a = max(a2, BEACON_BEAM_MIN_SIN2);
    b.c = vec2(frameData.beaconBeamCell[i]) - cameraPosition.xz + 0.5;
    b.s0 = dot(dir.xz, b.c) / a;
    // 最短距離は外積で求める (|c|^2 - s0^2 a の引き算は、視線が軸に沿う時に大きな数どうしの差になる)
    // 真上・真下ちょうどの視線は水平の向きが無く、軸までの距離はカメラの水平の距離そのもの
    // (分母だけ下限で押さえると h2 が縮み、軸から離れていても中心の 1 画素に光線が出る)
    b.h2 = a2 > BEACON_BEAM_MIN_SIN2 ? sqr(b.c.x * dir.z - b.c.y * dir.x) / a2 : dot(b.c, b.c);

    // 光線の区間の高さと、奥の面までで視線を切る
    b.yMin = float(frameData.beaconBeamYMin[i]) - cameraPosition.y;
    b.yMax = float(frameData.beaconBeamYMax[i]) - cameraPosition.y;
    b.s1 = 0.0;
    b.s2 = opaqueDist;
    if (abs(dir.y) > 1e-5) {
        float ta = b.yMin / dir.y;
        float tb = b.yMax / dir.y;
        b.s1 = max(b.s1, min(ta, tb));
        b.s2 = min(b.s2, max(ta, tb));
    } else if (b.yMin > 0.0 || b.yMax < 0.0) {
        return false;
    }
    b.sp = clamp(b.s0, b.s1, b.s2);
    return b.s2 > b.s1;
}

// 芯の半径 (画素に合わせて太らせた分を含む)。pixel: 1 画素の角度 x BEACON_BEAM_MIN_PIXELS
// 画素の幅は見える点の距離で決める (s0 は視線が軸に沿うほど区間の外の遠くへ行き、芯が太り過ぎる)
float beaconBeamCoreRadius(BeaconBeamSpan b, float pixel) { return max(BEACON_BEAM_CORE_RADIUS, pixel * b.sp); }

// 芯の半径のこの倍まで軸に近い視線を、光線の写る画素として TAA で光線の点から再投影する
const float BEACON_BEAM_TAA_REACH = 2.0;

/*
 * 視線 dir に光線の芯が写っていれば、その見える点 (player 空間) を point に返す。重なる時は芯の半径に対して軸に近い方
 * にじみは広く淡いので、奥の動きで読んでもずれが目立たない
 */
bool beaconBeamCorePoint(vec3 dir, float opaqueDist, float pixel, out vec3 point) {
    float best = sqr(BEACON_BEAM_TAA_REACH);
    bool found = false;
    point = vec3(0.0);
    for (int i = 0; i < BEACON_BEAM_MAX; i++) {
        if (frameData.beaconBeamKey[i] == 0u) break;
        BeaconBeamSpan b;
        if (!beaconBeamSpan(i, dir, opaqueDist, b)) continue;
        float q = b.h2 / sqr(beaconBeamCoreRadius(b, pixel));
        if (q < best) {
            best = q;
            point = dir * b.sp;
            found = true;
        }
    }
    return found;
}

#endif
