/*
 * Iris の能力の判定 (仮)。tools/capabilities.py から生成する lib/settings/capabilities.glsl ができたら、それに置き換えて消す
 * 未定義のマクロは #if で 0 になるので、IRIS_VERSION の無い旧い Iris は「能力なし」に倒れる
 */
#ifndef COMMON_CAPABILITIES_STUB_GLSL
#define COMMON_CAPABILITIES_STUB_GLSL

// shadow_entities / shadow_block が読まれる (Iris 1.8 以降)。無ければエンティティも shadow に来る
#if IRIS_VERSION >= 10800
    #define CAP_SHADOW_ENTITIES
#endif

#endif
