/*
 * ビーコンの光線 (EMISSION_BEACON_*)。光線は細い円柱の中を上へ進む光が大気に散乱して見えるものとして、視線ごとに解析的に積分する
 * 光線の柱・高さ・色は gbuffers_beaconbeam の頂点が FrameData に登録する (program/surface/beacon_beam.vsh)。ジオメトリは描かない
 * 深度を書かないので、光線までの距離は視線が光線の軸に最も近づく点で決め、そこまでの雲・フォグ・空中遠近・半透明で弱めて足す
 * 明るさ: 芯は (空気の散乱 + もや・霧・雨の散乱) x 位相関数。光線の向き (上) に沿って目へ来る前方散乱ほど明るく、
 * 視線が軸に沿うほど光線の中を通る長さが延びて明るい。もや・霧・雨の分は周りに広いにじみも作る
 */
#ifndef SKY_BEACON_BEAM_GLSL
#define SKY_BEACON_BEAM_GLSL

//@include "/lib/common/common.glsl"
//@include "/lib/common/exposure.glsl"
//@include "/lib/common/phase.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/celestial.glsl"
//@include "/lib/sky/clouds.glsl"
//@include "/lib/sky/fog.glsl"

const float BEACON_BEAM_FAR = 1e6;              // 奥に何も無い (空) 視線の距離
const float BEACON_BEAM_CORE_RADIUS = 0.12;     // 芯のガウスの半径 (ブロック)。バニラの内側の光線 (半径 0.2) と同じくらいの太さに見える
const float BEACON_BEAM_HALO_RADIUS = 1.5;      // にじみのガウスの半径 (ブロック)
const float BEACON_BEAM_REACH = 3.5;            // 半径のこの倍より軸から離れた視線は寄与なしとして飛ばす (exp(-12))
const float BEACON_BEAM_MIN_PIXELS = 0.75;      // 芯の半径の下限 (画素)。遠くの細い線が画素の間で途切れてちらつかないよう、光の量を保って太らせる
/*
 * 視線が軸に沿うほど通る長さ (1 / sin) と前方散乱の位相で明るくなるが、見下ろした光線の根元が白い大きな塊になったので、
 * 角の sin と位相の比 (横から見た値に対する) に下限・上限を置く
 */
const float BEACON_BEAM_MIN_SIN = 0.1;
const float BEACON_BEAM_PHASE_MAX = 4.0;
const float BEACON_BEAM_SQRT_PI = 1.7724539;
/*
 * 晴れた昼の地表のもやを 1 とした散乱の大きさ。空気そのもの (分子) の分は、もやの上端より上でも光線が消えないよう現実より多めに置く
 * 雨粒の消散係数 (1/ブロック) は雨の強さ 1 での値
 */
const float BEACON_BEAM_AIR_SCATTER = 0.3;
const float BEACON_BEAM_RAIN_SIGMA = 1.0e-3;
const float BEACON_BEAM_SCATTER_MAX = 4.0;      // 濃い霧の中で芯が白く飛び切らない上限
const float BEACON_BEAM_HALO_SHARE = 0.4;       // にじみの光の量 (芯に対する、もや 1 あたりの割合)
/*
 * 晴れた昼 (露出 1) に横から見た芯の放射輝度 = EMISSION_BEACON_BRIGHTNESS x GAIN。露出の -ADAPT 乗で暗い時ほど下げる
 * 光線の放射輝度は現実には昼夜で同じで、昼の明るい空に対しては淡く、夜は露出が上がってはっきり見える
 * そのままでは夜に白く飛ぶので、自動露出の分を一部だけ打ち消す (発光ブロックの getVisibleEmissionLuminance より強い)
 */
const float BEACON_BEAM_GAIN = 10.0;
const float BEACON_BEAM_EXPOSURE_ADAPT = 0.85;

bool hasBeaconBeams() { return frameData.beaconBeamKey[0] != 0u; }

// erf の近似 (Winitzki 2008。誤差 1e-3 程度)
float beaconBeamErf(float x) {
    const float A = 0.147;
    float x2 = x * x;
    float e = sqrt(1.0 - exp(-x2 * (4.0 / PI + A * x2) / (1.0 + A * x2)));
    return x < 0.0 ? -e : e;
}

/*
 * 半径 r のガウスの円柱 (縦の軸) を、視線の区間 [s1, s2] で積分した値
 * h2: 視線と軸の水平の最短距離の 2 乗, s0: 最も近づく点までの距離, sinA: 視線と軸の角の sin
 * 横から見た中心で 1。画素に合わせて r を radius より広げても、断面で積分した光の量は radius のときと同じ
 */
float beaconBeamProfile(float h2, float s0, float s1, float s2, float sinA, float radius, float r) {
    float k = sinA / r;
    float len = min(0.5 * BEACON_BEAM_SQRT_PI * (beaconBeamErf(k * (s2 - s0)) - beaconBeamErf(k * (s1 - s0))) / k, s2 - s1);
    return exp(-h2 / (r * r)) * len * radius / (BEACON_BEAM_SQRT_PI * r * r);
}

/*
 * 視線 dir (player 空間の単位ベクトル) に見えるビーコンの光線の放射輝度
 * opaqueDist: 奥の不透明面までの距離 (空は BEACON_BEAM_FAR), frontDist: 手前の半透明までの距離 (無ければ opaqueDist), frontAlpha: 半透明の不透明度
 * fogTransmittance: fogDist までの高さフォグ (VL) の透過率。光線の点までの分は距離の比の冪で近似する
 * texel: 雲 (getCloudLayer) を読む画素。雲は奥の不透明面 (空) まで積分してあるので、光線の点までの分に割り引く
 */
vec3 evalBeaconBeams(vec3 dir, float opaqueDist, float frontDist, float frontAlpha, float fogTransmittance, float fogDist, ivec2 texel) {
    vec3 sum = vec3(0.0);
    float sinA = max(length(dir.xz), BEACON_BEAM_MIN_SIN);
    float a = sinA * sinA;
    float pixel = skyPixelAngle() * BEACON_BEAM_MIN_PIXELS;
    float fogT = max(fogTransmittance, 1e-4);
#if defined HAS_SKY && defined EMISSION_BEACON_SCATTER
    // 光線は上へ進むので、目へ向かう散乱の角の cos は -dir.y (上から光線を見下ろすほど前方散乱で明るい)
    float cosTheta = -dir.y;
    FogMedium m = fogMedium();
    float phaseAir = phaseRayleigh(cosTheta) / phaseRayleigh(0.0);
    float phaseHaze = min(fogPhaseHaze(cosTheta) / fogPhaseHaze(0.0), BEACON_BEAM_PHASE_MAX) / FOG_HAZE_DENSITY;
    float phaseDroplet = min(fogPhaseDroplet(cosTheta) / fogPhaseDroplet(0.0), BEACON_BEAM_PHASE_MAX) / FOG_HAZE_DENSITY;
    float rainSigma = fogRainFactor() * BEACON_BEAM_RAIN_SIGMA;
    float invD = fogScenicInvD();
    float outdoor = mix(AERIAL_OUTDOOR_MIN, 1.0, 1.0 - getCaveFactor());
    #if CLOUDS >= 2
        vec4 clouds = getCloudLayer(texel);
        float cloudBack = opaqueDist >= BEACON_BEAM_FAR ? CLOUD_RAY_FAR : opaqueDist;
    #endif
#endif
    for (int i = 0; i < BEACON_BEAM_MAX; i++) {
        if (frameData.beaconBeamKey[i] == 0u) break;
        vec2 c = vec2(frameData.beaconBeamCell[i]) - cameraPosition.xz + 0.5;
        float s0 = dot(dir.xz, c) / a;
        float h2 = max(dot(c, c) - s0 * s0 * a, 0.0);
        float rCore = max(BEACON_BEAM_CORE_RADIUS, pixel * max(s0, 0.0));
#if defined HAS_SKY && defined EMISSION_BEACON_SCATTER
        float rHalo = max(BEACON_BEAM_HALO_RADIUS, rCore);
#else
        float rHalo = rCore;
#endif
        if (h2 > sqr(BEACON_BEAM_REACH * rHalo)) continue;

        // 光線の区間の高さと、奥の面までで視線を切る
        float yMin = float(frameData.beaconBeamYMin[i]) - cameraPosition.y;
        float yMax = float(frameData.beaconBeamYMax[i]) - cameraPosition.y;
        float s1 = 0.0;
        float s2 = opaqueDist;
        if (abs(dir.y) > 1e-5) {
            float ta = yMin / dir.y;
            float tb = yMax / dir.y;
            s1 = max(s1, min(ta, tb));
            s2 = min(s2, max(ta, tb));
        } else if (yMin > 0.0 || yMax < 0.0) {
            continue;
        }
        if (s2 <= s1) continue;

        // 光線の見える点 (視線が軸に最も近づく点)。そこまでの媒質で弱める
        float sp = clamp(s0, s1, s2);
        vec3 T = vec3(pow(fogT, sp / max(fogDist, 1.0)));
        if (sp > frontDist) T *= 1.0 - frontAlpha;
        float core = beaconBeamProfile(h2, s0, s1, s2, sinA, BEACON_BEAM_CORE_RADIUS, rCore);
#if defined HAS_SKY && defined EMISSION_BEACON_SCATTER
        vec3 p = dir * sp;
        vec2 dens = fogDensityAt(p, m);
        float medium = min((dens.x * phaseHaze + (dens.y + rainSigma) * phaseDroplet), BEACON_BEAM_SCATTER_MAX);
        // 光の量を芯と同じにそろえ、割合は HALO_SHARE で決める
        float halo = beaconBeamProfile(h2, s0, s1, s2, sinA, BEACON_BEAM_CORE_RADIUS, rHalo);
        float amount = core * (BEACON_BEAM_AIR_SCATTER * phaseAir + medium) + halo * medium * (BEACON_BEAM_HALO_SHARE * EMISSION_BEACON_SCATTER_STRENGTH);
        T *= exp(-fogAerialExtinction(cameraPosition.y, cameraPosition.y + p.y) * fogScenicDistance(sp, invD) * outdoor);
    #if CLOUDS >= 2
        T *= cloudFrontPart(clouds, dir, sp, cloudBack).a;
    #endif
#else
        float amount = core;
#endif
        sum += unpackUnorm4x8(frameData.beaconBeamColor[i]).rgb * T * amount;
    }
    return sum * (EMISSION_BEACON_BRIGHTNESS * BEACON_BEAM_GAIN * pow(getExposure(), -BEACON_BEAM_EXPOSURE_ADAPT));
}

#endif
