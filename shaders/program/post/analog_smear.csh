/*
 * composite26 (compute): CCD の縦スミアの列の平均 (SSBO 6)
 * colortex0 (線形 HDR、露出前、DoF・MB の後) の列ごとの平均を求め、final が露出の前に列の筋として足す (lib/post/analog.glsl)
 * - 1 列を 1 グループの中で閉じて求めるので、atomic もクリアも要らない。読みは画面を 1 回
 * - 縦を 1 グループにするので、倍率の丸めを確かめていない workGroupsRender でなく絶対の workGroups を使う
 * - ANALOG と ANALOG_SMEAR の時だけ走る (それ以外は program.*.enabled で止まる)
 * post モジュール (lib/post)
 */
// このプログラムで書く SSBO (lib/buffers。ほかのプログラムでは readonly)
#define SSBO_ANALOG_SMEAR_USE
#define SSBO_ANALOG_SMEAR_WRITE
//@include "/lib/common/common.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/buffers/analog_smear.glsl"
//@include "/lib/post/sampling.glsl"
// BEGIN GENERATED includes (tools/gen_includes.py)
#include "/lib/settings/look.glsl"
#include "/lib/settings/light.glsl"
#include "/lib/settings/surface.glsl"
#include "/lib/settings/sky.glsl"
#include "/lib/settings/post.glsl"
#include "/lib/settings/internal.glsl"
#include "/lib/settings/bool_refs.glsl"
#include "/lib/settings.glsl"
#include "/lib/common/dimension.glsl"
#include "/lib/common/constants.glsl"
#include "/lib/common/uniforms.glsl"
#include "/lib/common/samplers.glsl"
#include "/lib/common/math.glsl"
#include "/lib/common/shading_types.glsl"
#include "/lib/common/common.glsl"
#include "/lib/common/transforms.glsl"
#include "/lib/buffers/analog_smear.glsl"
#include "/lib/post/sampling.glsl"
// END GENERATED includes

// グループは 8 列 x 32 行のスレッド。1024 グループで 8192 列 (ANALOG_SMEAR_COLUMNS_ALLOC) を覆う
const int SMEAR_GROUP_COLUMNS = 8;
const int SMEAR_GROUP_ROWS = 32;
layout(local_size_x = 8, local_size_y = 32) in;
const ivec3 workGroups = ivec3(1024, 1, 1);

shared vec3 sharedColumnSum[SMEAR_GROUP_ROWS][SMEAR_GROUP_COLUMNS];

void main() {
#if defined ANALOG && defined ANALOG_SMEAR
    ivec2 size = ivec2(viewSize());
    int lx = int(gl_LocalInvocationID.x);
    int ly = int(gl_LocalInvocationID.y);
    int x = int(gl_GlobalInvocationID.x);
    // 画面の幅を超えた列も barrier まで残す (幅が 8 の倍数でない時に、グループの一部のスレッドだけが抜けないように)
    bool inside = x < size.x;

    vec3 sum = vec3(0.0);
    if (inside) {
        for (int y = ly; y < size.y; y += SMEAR_GROUP_ROWS) {
            // NaN / Inf の 1 画素が列の平均を汚さないように入口で止める
            sum += sanitizeColor(texelFetch(colortex0, ivec2(x, y), 0).rgb);
        }
    }
    sharedColumnSum[ly][lx] = sum;
    barrier();
    for (int s = SMEAR_GROUP_ROWS / 2; s > 0; s /= 2) {
        if (ly < s) sharedColumnSum[ly][lx] += sharedColumnSum[ly + s][lx];
        barrier();
    }
    if (ly == 0 && inside) analogSmear.columns[x] = vec4(sharedColumnSum[0][lx] / float(size.y), 0.0);
#endif
}
