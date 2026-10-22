/*
 * gbuffers_lightning: 雷の稲妻 (と Iris が同じ枠で描くエンダードラゴンの死亡時の光線)
 * 頂点形式は POSITION_COLOR だけでテクスチャ・法線・ライトマップが無い。G バッファ経路 (gbuffers_entities への
 * フォールバック) だと発光しない不透明物として暗い柱になるので、半透明バッファへ発光だけを足す
 */
#include "/lib/common/common.glsl"

out vec4 glcolor;

void main() {
    glcolor = gl_Color;
    gl_Position = ftransform();
    applyTaaJitter(gl_Position);
}
