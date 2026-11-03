/*
 * 光るブロックの面の光り方 (光る範囲の四角と 4x4 のマス)。面の種類は 0 = 上、1 = 下、2 = 側面 (4 面の平均)、3 = 前面 (向きのある光源だけ)
 * tools/gen_block_properties.py が tools/light_masks.json から生成する。手で編集しない
 * 中身の意味は lib/buffers/block_data.glsl の lightMasks
 */
#ifndef LIGHT_LIGHT_MASK_DATA_GLSL
#define LIGHT_LIGHT_MASK_DATA_GLSL

//@include "/lib/ids/light_ids.glsl"

uvec4 lightMaskStatic(int i, int faceClass) {
    switch (i) {
        case LIGHT_LANTERN:
            if (faceClass == 0) return uvec4(0u);
            if (faceClass == 1) return uvec4(0u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.1667, 0.1429, 0.8333, 0.8571)), packHalf2x16(vec2(1.0, 1.0433)), 0xFFFFAFFAu, 0xFFFFFFFFu);
        case LIGHT_SOUL_LANTERN:
            if (faceClass == 0) return uvec4(0u);
            if (faceClass == 1) return uvec4(0u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.1667, 0.1429, 0.8333, 0.8571)), packHalf2x16(vec2(1.0, 1.176)), 0xDFFD3DD3u, 0xDFFDFFFFu);
        case LIGHT_COPPER_LANTERN:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.1667, 0.1667, 0.8333, 0.8333)), packHalf2x16(vec2(1.2577, 1.5103)), 0xFFFF5FF5u, 0x5FF5FFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.1667, 0.1667, 0.8333, 0.8333)), packHalf2x16(vec2(1.2577, 1.5103)), 0xFFFF5FF5u, 0x5FF5FFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(0.908, 1.7633)), 0x6CC61661u, 0x2AA2BFFBu);
        case LIGHT_GLOWSTONE:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.4487)), 0xCCF9A98Au, 0x96BF5FBAu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.4487)), 0xCCF9A98Au, 0x96BF5FBAu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.4487)), 0xCCF9A98Au, 0x96BF5FBAu);
        case LIGHT_SEA_LANTERN:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.1133)), 0xFFFEAEEAu, 0xAFEAEFFEu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.1133)), 0xFFFEAEEAu, 0xAFEAEFFEu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.1133)), 0xFFFEAEEAu, 0xAFEAEFFEu);
        case LIGHT_SHROOMLIGHT:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0304)), 0xFFFFFEFEu, 0xDEFFFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0304)), 0xFFFFFEFEu, 0xDEFFFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0304)), 0xFFFFFEFEu, 0xDEFFFFFFu);
        case LIGHT_JACK_O_LANTERN:
            if (faceClass == 0) return uvec4(0u);
            if (faceClass == 1) return uvec4(0u);
            if (faceClass == 3) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.3155)), 0xEDEC9CCBu, 0x68A6FEECu);
            return uvec4(0u);
        case LIGHT_MAGMA_BLOCK:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.35)), 0xF4F7D9DCu, 0xDADF8F3Fu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.35)), 0xF4F7D9DCu, 0xDADF8F3Fu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.35)), 0xF4F7D9DCu, 0xDADF8F3Fu);
        case LIGHT_CRYING_OBSIDIAN:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0625, 0.125, 0.75, 0.6875)), packHalf2x16(vec2(1.2891, 3.8102)), 0x581AD310u, 0x21F33583u);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0625, 0.125, 0.75, 0.6875)), packHalf2x16(vec2(1.2891, 3.8102)), 0x581AD310u, 0x21F33583u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0625, 0.125, 0.75, 0.6875)), packHalf2x16(vec2(1.2891, 3.8102)), 0x581AD310u, 0x21F33583u);
        case LIGHT_RESPAWN_ANCHOR:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.125, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0061, 1.2518)), 0xCFFFAAABu, 0x8AADAFFEu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0625, 0.125, 0.75, 0.6875)), packHalf2x16(vec2(0.35, 1.0345)), 0x581AD310u, 0x21F33583u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.25, 0.1875, 0.8125, 0.875)), packHalf2x16(vec2(0.3791, 1.9386)), 0x025008F1u, 0x73160000u);
        case LIGHT_REDSTONE_LAMP:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.4304)), 0x9FD99A99u, 0x9999AFBAu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.4304)), 0x9FD99A99u, 0x9999AFBAu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0625, 0.0625, 0.9375, 0.9375)), packHalf2x16(vec2(1.0, 1.4304)), 0x9FD99A99u, 0x9999AFBAu);
        case LIGHT_OCHRE_FROGLIGHT:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0008)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0008)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(0.9912, 1.0008)), 0xFFFFFFFFu, 0xEFFEFFFFu);
        case LIGHT_VERDANT_FROGLIGHT:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0116)), 0xFFFFEFFEu, 0xEFFEFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0116)), 0xFFFFEFFEu, 0xEFFEFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(0.9487, 1.0116)), 0xFFFFCFFDu, 0xCEECEFFFu);
        case LIGHT_PEARLESCENT_FROGLIGHT:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0112)), 0xFFFFEFFEu, 0xEFFEFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0112)), 0xFFFFEFFEu, 0xEFFEFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(0.9564, 1.0112)), 0xFFFFDFEDu, 0xCEECEFFFu);
        case LIGHT_COPPER_BULB:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 0.9375, 1.0)), packHalf2x16(vec2(1.0037, 1.2089)), 0xFCDFAFFCu, 0x8BB8ECDFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 0.9375, 1.0)), packHalf2x16(vec2(1.0037, 1.2089)), 0xFCDFAFFCu, 0x8BB8ECDFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 0.9375, 1.0)), packHalf2x16(vec2(1.0037, 1.2089)), 0xFCDFAFFCu, 0x8BB8ECDFu);
        case LIGHT_REDSTONE_ORE:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0625, 0.25, 0.9375, 0.9375)), packHalf2x16(vec2(1.0084, 3.6547)), 0x931543F2u, 0x21927211u);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0625, 0.25, 0.9375, 0.9375)), packHalf2x16(vec2(1.0084, 3.6547)), 0x931543F2u, 0x21927211u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0625, 0.25, 0.9375, 0.9375)), packHalf2x16(vec2(1.0084, 3.6547)), 0x931543F2u, 0x21927211u);
        case LIGHT_FURNACE:
            if (faceClass == 0) return uvec4(0u);
            if (faceClass == 1) return uvec4(0u);
            if (faceClass == 3) return uvec4(packUnorm4x8(vec4(0.1875, 0.6875, 0.8125, 1.0)), packHalf2x16(vec2(1.0, 1.4422)), 0x9EC77321u, 0xFFFFBFFBu);
            return uvec4(0u);
        case LIGHT_SCULK_CATALYST:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.125, 0.125, 0.625, 1.0)), packHalf2x16(vec2(0.1738, 0.6951)), 0xF00F000Fu, 0xF0000000u);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(0.1023, 0.249)), 0x5006F779u, 0xA66F6007u);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.125, 1.0, 0.75)), packHalf2x16(vec2(1.0883, 2.5565)), 0x33051003u, 0x8FE8F66Fu);
        case LIGHT_DECOR_FIRST + 0:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.1751)), 0xCDCEDDEFu, 0xBCCDCDDDu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.1751)), 0xCDCEDDEFu, 0xBCCDCDDDu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.1751)), 0xCDCEDDEFu, 0xBCCDCDDDu);
        case LIGHT_DECOR_FIRST + 1:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0589)), 0xDFFFEFFFu, 0xDDDEDEFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0589)), 0xDFFFEFFFu, 0xDDDEDEFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0589)), 0xDFFFEFFFu, 0xDDDEDEFFu);
        case LIGHT_DECOR_FIRST + 2:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0056)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0056)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0056)), 0xFFFFFFFFu, 0xFFFFFFFFu);
        case LIGHT_DECOR_FIRST + 3:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.001)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.001)), 0xFFFFFFFFu, 0xFFFFFFFFu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.001)), 0xFFFFFFFFu, 0xFFFFFFFFu);
        case LIGHT_DECOR_FIRST + 4:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.2309)), 0xE77DEDDFu, 0xEDEFD98Eu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.2309)), 0xE77DEDDFu, 0xEDEFD98Eu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.2309)), 0xE77DEDDFu, 0xEDEFD98Eu);
        case LIGHT_DECOR_FIRST + 5:
            if (faceClass == 0) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0805)), 0xDEDFEEDEu, 0xEEEEEEFEu);
            if (faceClass == 1) return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0805)), 0xDEDFEEDEu, 0xEEEEEEFEu);
            if (faceClass == 3) return uvec4(0u);
            return uvec4(packUnorm4x8(vec4(0.0, 0.0, 1.0, 1.0)), packHalf2x16(vec2(1.0, 1.0805)), 0xDEDFEEDEu, 0xEEEEEEFEu);
    }
    return uvec4(0u);
}

#endif
