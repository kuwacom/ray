/*
 * setup2 (起動時 1 回): 多重散乱 LUT (Hillaire 2020, 32x32) を skyMultiScatterImg に作る
 * 各テクセル = (高度, 太陽の天頂角余弦) で、全方位から届く 2 次散乱 L2 と等方散乱の伝達率 f_ms を求め
 * 無限次の等比級数 Psi_ms = L2 / (1 - f_ms) を格納する (論文 5.5 節)。照度 1 あたりの値
 * sky モジュール (lib/sky)
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_SKY_MULTISCATTER
#include "/lib/common/common.glsl"
#include "/lib/sky/sky.glsl"

layout(local_size_x = 8, local_size_y = 8) in;
const ivec3 workGroups = ivec3(4, 4, 1);

const int MS_DIRECTIONS_SQRT = 8; // 球面の方向数 = 8x8
const int MS_STEPS = 24;

void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(texel, MULTISCATTER_LUT_SIZE))) return;

    vec2 unit = atmoSubUvToUnit((vec2(texel) + 0.5) / vec2(MULTISCATTER_LUT_SIZE), vec2(MULTISCATTER_LUT_SIZE));
    float muSun = unit.x * 2.0 - 1.0;
    float r = ATMO_GROUND_RADIUS + saturate(unit.y) * (ATMO_TOP_RADIUS - ATMO_GROUND_RADIUS) + 0.001;
    r = min(r, ATMO_TOP_RADIUS - 0.001);
    vec3 origin = vec3(0.0, r, 0.0);
    vec3 sunDir = vec3(sqrt(max(1.0 - muSun * muSun, 0.0)), muSun, 0.0);

    vec3 secondOrder = vec3(0.0);
    vec3 transferAsOne = vec3(0.0);
    const int DIR_COUNT = MS_DIRECTIONS_SQRT * MS_DIRECTIONS_SQRT;
    for (int d = 0; d < DIR_COUNT; d++) {
        // 球面の一様な格子 (cos 天頂角 x 方位角)
        vec2 cell = (vec2(d % MS_DIRECTIONS_SQRT, d / MS_DIRECTIONS_SQRT) + 0.5) / float(MS_DIRECTIONS_SQRT);
        float cosTheta = 1.0 - 2.0 * cell.y;
        float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
        float phi = TAU * cell.x;
        vec3 dir = vec3(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi));

        float mu = dir.y;
        bool hitsGround = atmoRayHitsGround(r, mu);
        float tMax = hitsGround ? atmoDistanceToGround(r, mu) : atmoDistanceToTop(r, mu);
        float dt = tMax / float(MS_STEPS);

        vec3 throughput = vec3(1.0);
        vec3 luminance = vec3(0.0);
        vec3 transfer = vec3(0.0);
        for (int i = 0; i < MS_STEPS; i++) {
            float t = (float(i) + 0.5) * dt;
            vec3 p = origin + dir * t;
            float pr = length(p);
            vec3 rayleighScatter, extinction;
            float mieScatter;
            atmoMedium(pr - ATMO_GROUND_RADIUS, rayleighScatter, mieScatter, extinction);
            vec3 scatter = rayleighScatter + mieScatter;
            vec3 sunT = atmoTransmittanceToLight(pr, dot(p / pr, sunDir));

            vec3 stepT = exp(-extinction * dt);
            vec3 integral = (1.0 - stepT) / max(extinction, vec3(1e-9));
            // 2 次散乱は等方位相で近似 (論文と同じ)
            luminance += throughput * sunT * scatter * SKY_PHASE_ISOTROPIC * integral;
            transfer += throughput * scatter * integral;
            throughput *= stepT;
        }
        // 地面で反射した太陽光 (ランバート)
        if (hitsGround) {
            vec3 groundPos = origin + dir * tMax;
            vec3 groundUp = normalize(groundPos);
            float nDotL = max(dot(groundUp, sunDir), 0.0);
            luminance += throughput * atmoTransmittance(ATMO_GROUND_RADIUS, dot(groundUp, sunDir)) * nDotL * ATMO_GROUND_ALBEDO * RCP_PI;
        }
        secondOrder += luminance;
        transferAsOne += transfer;
    }
    // 球面積分 (立体角 4pi / 方向数) に等方位相 1/4pi を掛けると方向数の平均になる
    secondOrder /= float(DIR_COUNT);
    transferAsOne /= float(DIR_COUNT);
    vec3 psi = secondOrder / max(1.0 - transferAsOne, vec3(1e-4));
    imageStore(skyMultiScatterImg, texel, vec4(psi, 1.0));
}
