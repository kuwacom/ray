/*
 * shadow (地形: solid / cutout / 半透明): 太陽影マップ + 地形のボクセル化
 * light モジュール (影マップの出力内容は surface モジュールと調整)
 * shadow_entities / shadow_block が無いジオメトリもここに来るが、Iris 1.8+ ではエンティティは来ない
 */
// このプログラムで書く image (lib/buffers/images.glsl。宣言は 8 個まで)
#define IMG_VOXEL_BLOCK
#include "/lib/common/common.glsl"
#include "/lib/light/light.glsl"
#include "/lib/surface/surface.glsl"

in vec2 mc_Entity;
in vec4 at_midBlock;

out vec2 texcoord;
out vec4 glcolor;
out vec3 normalPlayer;
out float skyLight;
flat out int blockId;
flat out vec3 tintTransmittance;

void main() {
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor = gl_Color;
    vec2 lm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    skyLight = saturate((lm.y - 1.0 / 32.0) * 32.0 / 30.0);
    normalPlayer = mat3(shadowModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
    blockId = int(round(mc_Entity.x));
    // 色付き影はブロックライト (floodfill / 光源シャドウ) と同じ透過色の表を使う
    tintTransmittance = isTintBlock(blockId) ? floodCellTransmittance(blockId) : vec3(1.0);

    vec3 playerPos = (shadowModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;

    bool isTerrain = renderStage == MC_RENDER_STAGE_TERRAIN_SOLID
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT
        || renderStage == MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
        || renderStage == MC_RENDER_STAGE_TERRAIN_TRANSLUCENT;
    if (isTerrain) {
        // ボクセルは揺れ適用前のブロック中心で書く
        voxelizeTerrainVertex(playerPos, at_midBlock.xyz / 64.0, blockId, at_midBlock.w);
    }

    playerPos = applyWaving(playerPos, blockId, at_midBlock.y < 0.0, skyLight);
    vec3 clip = (shadowProjection * vec4(playerToShadowView(playerPos), 1.0)).xyz;
    gl_Position = vec4(distortShadowClip(clip), 1.0);
}
