/*
 * ディメンション別の機能フラグ
 * world0 / world-1 / world1 のラッパーが WORLD_OVERWORLD / WORLD_NETHER / WORLD_END を定義する
 * (dimension.properties で未知のディメンションは world0 に割り当てる)
 */
#ifndef COMMON_DIMENSION_GLSL
#define COMMON_DIMENSION_GLSL

#if !defined WORLD_OVERWORLD && !defined WORLD_NETHER && !defined WORLD_END
    #define WORLD_OVERWORLD
#endif

#ifdef WORLD_OVERWORLD
    #define HAS_SKY          // 大気・雲・天候
    #define HAS_SUN_SHADOWS  // 太陽/月の影マップ
    #define HAS_SKYLIGHT     // スカイライトのライトマップが意味を持つ
#endif

#ifdef WORLD_END
    #define HAS_SUN_SHADOWS  // End フラッシュ (1.21.9+) / 固定方向の影
#endif

#endif
