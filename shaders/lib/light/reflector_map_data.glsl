/*
 * 反射体の面の凹凸 (テクスチャの明るさのラプラシアンの 4 段のミップ)。ブロック x 22 uvec4。添字 j は SSBO の lightMasks の REFLECTOR_MAP_BASE からの位置
 * tools/gen_block_properties.py が tools/reflector_maps.json から生成する。手で編集しない
 * 中身の意味は lib/buffers/block_data.glsl の lightMasks。ブロックの順は lib/surface/reflector_light.glsl の reflectorMapIndex
 */
#ifndef LIGHT_REFLECTOR_MAP_DATA_GLSL
#define LIGHT_REFLECTOR_MAP_DATA_GLSL

uvec4 reflectorMapStatic(int j) {
    switch (j) {
        case 0: return uvec4(0x074949CEu, 0x07101717u, 0x32F00E07u, 0xC5322121u);
        case 1: return uvec4(0xCABA8149u, 0xD8DFC3CAu, 0xD5EBDAD6u, 0x32ABD5D5u);
        case 2: return uvec4(0x0202D80Eu, 0xFBFB0202u, 0xEEF9FE00u, 0x3CBAEEEEu);
        case 3: return uvec4(0x2525F259u, 0x23252525u, 0x30021510u, 0x40F92525u);
        case 4: return uvec4(0xD9D9A01Cu, 0xEED2D9D9u, 0xEE00E4EBu, 0x33BAEEEEu);
        case 5: return uvec4(0x0202D80Eu, 0x00070202u, 0xEEEE0000u, 0x33BAEEEEu);
        case 6: return uvec4(0x1E25F259u, 0x1510231Eu, 0x2530020Eu, 0x40F92525u);
        case 7: return uvec4(0xEED2A01Cu, 0xE4EBE7E7u, 0xEEEEF900u, 0x33BAEEEEu);
        case 8: return uvec4(0xFB02D80Eu, 0xFBFBFBFBu, 0xF9F9F9F4u, 0x33BAEEEEu);
        case 9: return uvec4(0x2525F259u, 0x1E252525u, 0x02151023u, 0x40F92530u);
        case 10: return uvec4(0xD9D9A01Cu, 0xEED2D9D9u, 0x00E4EBE7u, 0x33BAEEEEu);
        case 11: return uvec4(0x0202D80Eu, 0x00020202u, 0xEE000000u, 0x33BAEEEEu);
        case 12: return uvec4(0x2525F259u, 0x10231E25u, 0x30020E15u, 0x40F92525u);
        case 13: return uvec4(0xD9D9A01Cu, 0xEBE7EED2u, 0xEEF900E4u, 0x33BAEEEEu);
        case 14: return uvec4(0xE3E3B821u, 0xD3DCDCE3u, 0xCCCCD5D3u, 0x3D98CCCCu);
        case 15: return uvec4(0x3B2B2B07u, 0x57323B3Bu, 0x3D572957u, 0x233D3D3Du);
        case 16: return uvec4(0xEBC1D1FBu, 0xEE0E0EDBu, 0x1B23D663u, 0x71BDF3F2u);
        case 17: return uvec4(0xD3BE82FAu, 0x3783DED4u, 0xEE1CBB3Du, 0x6CD73A0Au);
        case 18: return uvec4(0x322DF15Fu, 0x62E7EB1Au, 0xCFC286FAu, 0x3788DBDBu);
        case 19: return uvec4(0xD3DE813Au, 0x5CB0E4C6u, 0x6D5F4032u, 0x6717565Du);
        case 20: return uvec4(0x50DDDF2Au, 0x40C595E8u, 0x2F8BAC00u, 0x7F231828u);
        case 21: return uvec4(0x60EC3481u, 0x324C406Bu, 0x1C6728A5u, 0x00000000u);
        case 22: return uvec4(0xDDBEF2C9u, 0xC2F2BEC2u, 0xE6D5A181u, 0xE6C5F1BCu);
        case 23: return uvec4(0xB62C17F2u, 0x53FDEC3Eu, 0x1735002Cu, 0x58E8F707u);
        case 24: return uvec4(0x27A226C1u, 0xE5E532E0u, 0x19F2F61Au, 0x170FDC17u);
        case 25: return uvec4(0xF11137C5u, 0xE53FDC0Fu, 0x2618D9EDu, 0x2206F612u);
        case 26: return uvec4(0xE02B11CDu, 0x00F71AFFu, 0xB0F7F42Du, 0x1FD1240Eu);
        case 27: return uvec4(0x0815D7D1u, 0x0009EEF7u, 0x15B00A1Cu, 0x4FE824E5u);
        case 28: return uvec4(0xFDC429CDu, 0xDD12E611u, 0xFF222B0Au, 0x0D15F6DCu);
        case 29: return uvec4(0x08EB2ED5u, 0x1800F625u, 0x0522FEA9u, 0x1531F217u);
        case 30: return uvec4(0xEE242395u, 0x24F635EEu, 0x05E000EBu, 0x2FDECF1Eu);
        case 31: return uvec4(0x0E092389u, 0x2DF4C7FEu, 0x051B1CEDu, 0x5DD71C0Cu);
        case 32: return uvec4(0x220E13BDu, 0xDBD0E713u, 0xFFE4ED24u, 0x41CA220Au);
        case 33: return uvec4(0xB90019E9u, 0xED1B1A30u, 0xF6C71F09u, 0x26E818FFu);
        case 34: return uvec4(0x360802A4u, 0x050C1AB0u, 0xEE0319F8u, 0x4819F6E6u);
        case 35: return uvec4(0xF6EEF6DEu, 0xFCFC0524u, 0xF612F819u, 0x29CE1209u);
        case 36: return uvec4(0xFBCE31DFu, 0x1204DFE9u, 0x0EFCFED2u, 0x41C6D1EBu);
        case 37: return uvec4(0x394142C1u, 0xF7323939u, 0x131A5151u, 0x42423B40u);
        case 38: return uvec4(0xF9C6B1E3u, 0xF4CB0A92u, 0x0F17E8F5u, 0x1F0C43EBu);
        case 39: return uvec4(0x0FF322BAu, 0x1B208136u, 0xF41EDFE8u, 0x3BDF3FE6u);
        case 40: return uvec4(0x18E051A2u, 0x04111EEEu, 0xC5210FEBu, 0x142BB228u);
        case 41: return uvec4(0x1BFE03ADu, 0x30D1F017u, 0x152A3812u, 0x391A2631u);
        case 42: return uvec4(0x13CFC581u, 0x43F12FADu, 0x23F105E3u, 0x323E5B00u);
        case 43: return uvec4(0x4C270C81u, 0x35693F88u, 0x211F29E7u, 0x00000000u);
        case 44: return uvec4(0x111111EFu, 0x11071111u, 0xF9111107u, 0x09FE07F9u);
        case 45: return uvec4(0xBCBCBC11u, 0xA9E4B3BCu, 0x04A5B3DBu, 0x43BFB9FAu);
        case 46: return uvec4(0x3A44B311u, 0x313A4444u, 0x142C2345u, 0x3AB64A19u);
        case 47: return uvec4(0xE430E407u, 0xCCB3BCB3u, 0xF1ECECF1u, 0x3AC041B9u);
        case 48: return uvec4(0xB344B311u, 0x3A444444u, 0x3C232222u, 0x44814BB0u);
        case 49: return uvec4(0xBC44B311u, 0xCBD4BC44u, 0x3DA0E4E4u, 0x2CE025E9u);
        case 50: return uvec4(0xB33ADA07u, 0x0614D444u, 0x33DB1C1Cu, 0x22F01BDBu);
        case 51: return uvec4(0xDA30DA07u, 0xBD06CB3Au, 0x33B9FB0Eu, 0x22F01BD1u);
        case 52: return uvec4(0xD03AA911u, 0x0E1CE430u, 0x11112403u, 0x2CC81BF9u);
        case 53: return uvec4(0xC227DA07u, 0xED1CE430u, 0x1BD12524u, 0x2CC81B07u);
        case 54: return uvec4(0xF13CB907u, 0xF1CDA023u, 0x33DBD103u, 0x22F029A7u);
        case 55: return uvec4(0xF22EFFF9u, 0x1B293D46u, 0x41331B11u, 0x22F029B0u);
        case 56: return uvec4(0x9C28B407u, 0xEFF9E893u, 0xB0A707EFu, 0x2CD625F7u);
        case 57: return uvec4(0x3D24F1F9u, 0x1B111B3Du, 0x29291B1Bu, 0x3AB24125u);
        case 58: return uvec4(0xC8FAD1F0u, 0xC8F0F0C8u, 0xF0F0C8D2u, 0x4C87B2D6u);
        case 59: return uvec4(0x2C223509u, 0x2C22222Cu, 0x22222C2Cu, 0xEF4C3A2Cu);
        case 60: return uvec4(0xD4C299EFu, 0x31CBC4AFu, 0xF0CB64C8u, 0x0A23FF55u);
        case 61: return uvec4(0xF152CBCBu, 0x0FED1EDDu, 0x81F100E6u, 0x6FF7D5FFu);
        case 62: return uvec4(0xF6F4F0BAu, 0x12320068u, 0xEB1140D2u, 0x728244F8u);
        case 63: return uvec4(0x2BBAF0C2u, 0xF14D8225u, 0x3C57563Cu, 0x0BF17818u);
        case 64: return uvec4(0x13E08ED3u, 0x68CFA8A3u, 0x3168D7C5u, 0x18267F37u);
        case 65: return uvec4(0x501F1081u, 0x380B44EFu, 0x268E2CE7u, 0x00000000u);
        case 66: return uvec4(0xFD00FFC4u, 0xFAF20A0Fu, 0xF5020FF7u, 0x37DCF702u);
        case 67: return uvec4(0xB1BAD2FFu, 0xDAD1F5EBu, 0xEDBAD8C4u, 0x59A7BCFFu);
        case 68: return uvec4(0x2639BA06u, 0xF412D524u, 0x202D131Bu, 0x59AB1518u);
        case 69: return uvec4(0x0E26B1FDu, 0x05F012CDu, 0x11FF07F6u, 0x50CF03E7u);
        case 70: return uvec4(0xF012EB0Fu, 0xFB05F009u, 0xF6030F0Fu, 0x43A410F6u);
        case 71: return uvec4(0x00F8EC0Au, 0x16080AF0u, 0xDEE60B0Fu, 0x3B0AFE03u);
        case 72: return uvec4(0xF009D1F2u, 0xFEF10010u, 0x0BE6DE0Bu, 0x3EED1107u);
        case 73: return uvec4(0x10F9D1F2u, 0x0A0AF600u, 0x0F0BFEF6u, 0x4CD319F8u);
        case 74: return uvec4(0x0010E40Fu, 0xF60A0AF6u, 0x0FF90AF6u, 0x36CC0C00u);
        case 75: return uvec4(0xF608CF07u, 0xF6FE120Au, 0xF100000Au, 0x36D8E228u);
        case 76: return uvec4(0x0AF1FBF5u, 0x0BDEE61Au, 0x1AF900F9u, 0x44F1F6D7u);
        case 77: return uvec4(0x1AFE07EDu, 0x070BE6E6u, 0xD730EA07u, 0x44EC03E6u);
        case 78: return uvec4(0xDE0BF7F3u, 0x11FE0BE6u, 0xFEE21319u, 0x36D11603u);
        case 79: return uvec4(0xF6D126EAu, 0x1111FE03u, 0xF6FEF1FEu, 0x3BCC1916u);
        case 80: return uvec4(0xE60BC9D8u, 0xD3EDF6E1u, 0xECECD3CCu, 0x5881CCD1u);
        case 81: return uvec4(0x3749372Eu, 0x4C3E3B2Eu, 0x4444363Eu, 0x0B604336u);
        case 82: return uvec4(0xB01884DEu, 0x27C2E3C6u, 0xD1B74DA1u, 0x1FC85815u);
        case 83: return uvec4(0x25E8D819u, 0x50DBA93Au, 0x1107E4A8u, 0x771DF6D3u);
        case 84: return uvec4(0xED22F1EDu, 0x1FF30D01u, 0xF2C30A00u, 0x728A0207u);
        case 85: return uvec4(0x29CA9210u, 0xFAFCA9FEu, 0x6A5C7F36u, 0x4B127221u);
        case 86: return uvec4(0xEE169ABFu, 0x7FC50BAFu, 0x10DDB9EBu, 0x3F1A7845u);
        case 87: return uvec4(0x25342781u, 0x3820438Fu, 0x25F72E5Du, 0x00000000u);
        case 88: return uvec4(0xFCFD00C1u, 0xFAF30409u, 0xF2FD09F9u, 0x3ADAF9FEu);
        case 89: return uvec4(0xB4C0C700u, 0xD5C9FDEEu, 0xEBC0DDBEu, 0x5FA1B7FEu);
        case 90: return uvec4(0x2334C003u, 0xFA18CA27u, 0x1E291519u, 0x5FA3181Cu);
        case 91: return uvec4(0x1023B4FCu, 0x04F318C3u, 0x130209F3u, 0x53D202E6u);
        case 92: return uvec4(0xF30FEE09u, 0xF704F30Cu, 0xF5FE1111u, 0x46A70BF7u);
        case 93: return uvec4(0x00F9F104u, 0x1A0409F3u, 0xE4EA0411u, 0x420403FEu);
        case 94: return uvec4(0xF30CC9F3u, 0xFCF3000Du, 0x04EAE407u, 0x44E90E0Au);
        case 95: return uvec4(0x0DFFC9F3u, 0x0909F700u, 0x1107FEF7u, 0x50D515F9u);
        case 96: return uvec4(0x000DEB09u, 0xF70909F7u, 0x11F709F7u, 0x3BC60F00u);
        case 97: return uvec4(0xF707D402u, 0xF7FE0F09u, 0xEF000009u, 0x3BD3E129u);
        case 98: return uvec4(0x09F3F7F2u, 0x07E4EA16u, 0x16F700F7u, 0x49F0F5DBu);
        case 99: return uvec4(0x16FC0AE9u, 0x0A04EAEAu, 0xDB32E60Au, 0x49ECFEEAu);
        case 100: return uvec4(0xE407FAEFu, 0x0E0304EAu, 0xFEE11715u, 0x3BCB1AFEu);
        case 101: return uvec4(0xF5D323E7u, 0x0E0E03FEu, 0xF3FCEF03u, 0x40C81A1Au);
        case 102: return uvec4(0xE604CBD0u, 0xD5E9F0E2u, 0xECECCFC6u, 0x5D81C8CBu);
        case 103: return uvec4(0x3A4F3A33u, 0x50444233u, 0x49493B42u, 0x0B64473Bu);
        case 104: return uvec4(0xA9178CD7u, 0x27BBE1C7u, 0xDBB143A9u, 0x1FCA5512u);
        case 105: return uvec4(0x1FEFDC16u, 0x55D6AE3Au, 0x0D06EAA1u, 0x7B19F7D6u);
        case 106: return uvec4(0xEF1DF1F0u, 0x1EF50AFFu, 0xF3CB05FCu, 0x788B0405u);
        case 107: return uvec4(0x24C8940Au, 0xFAFAA5FEu, 0x6F5E7F38u, 0x53137921u);
        case 108: return uvec4(0xED1299C0u, 0x7FC809B1u, 0x14D6BAE6u, 0x441B7A44u);
        case 109: return uvec4(0x27322581u, 0x38054340u, 0x25BC2E2Au, 0x00000000u);
    }
    return uvec4(0u);
}

#endif
