/*
 * composite2_a (compute): 何もしない。Iris は compute を走らせたパスの後に glMemoryBarrier (image・テクスチャの読み・SSBO) を出すので、
 * composite1 の fragment が imageStore で書いた水の値 (STORE_WATER_MIRROR / STORE_WATER_SUNVIS、lib/buffers/slots.glsl) を
 * composite2 が sampler で読む前の同期に使う。バリアはそれより前の全ての書きに効く
 * surface モジュール (lib/surface)
 */
layout(local_size_x = 1, local_size_y = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
}
