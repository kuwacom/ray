/*
 * gbuffers_beaconbeam: 頂点シェーダーがクリップ空間の外へ置くので画素は来ない (beacon_beam.vsh)
 * surface モジュール (lib/surface)
 */

/* RENDERTARGETS: 1 */
layout(location = 0) out vec4 outAlbedo;

void main() {
    discard;
}
