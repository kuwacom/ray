/*
  Iris にブール設定として認識させるための参照
  (Iris は #ifdef / #ifndef で一度も参照されない define をブール設定として扱わないため)
*/
#ifndef SETTINGS_BOOL_REFS_GLSL
#define SETTINGS_BOOL_REFS_GLSL

//@include "/lib/settings/light.glsl"
//@include "/lib/settings/surface.glsl"
//@include "/lib/settings/sky.glsl"
//@include "/lib/settings/post.glsl"

#ifdef FLOODFILL
#endif
#ifdef LIGHT_FLICKER
#endif
#ifdef LIGHT_SHADOWS
#endif
#ifdef LIGHT_SHAPE_TRACE
#endif
#ifdef LIGHT_TRANSLUCENT_TINT
#endif
#ifdef LIGHT_SPECULAR
#endif
#ifdef LIGHT_ENTITY_OCCLUSION
#endif
#ifdef LIGHT_PLAYER_OCCLUSION
#endif
#ifdef LIGHT_CONTACT_SHADOWS
#endif
#ifdef HAND_LIGHT
#endif
#ifdef HAND_LIGHT_RAYS
#endif
#ifdef HAND_LIGHT_SS_SHADOWS
#endif
#ifdef ENTITY_LIGHTS
#endif
#ifdef ITEM_LIGHTS
#endif
#ifdef PROJECTILE_LIGHTS
#endif
#ifdef BURNING_ENTITY_LIGHTS
#endif
#ifdef GLOWING_ENTITY_LIGHTS
#endif
#ifdef SHADOW_COLORED
#endif
#ifdef SHADOW_LEAF_TINT
#endif
#ifdef ENTITY_SHADOWS
#endif
#ifdef BLOCK_ENTITY_SHADOWS
#endif
#ifdef SCREEN_SPACE_SHADOWS
#endif
#ifdef NORMAL_MAPPING
#endif
#ifdef GENERATED_NORMALS
#endif
#ifdef POM
#endif
#ifdef POM_SHADOW
#endif
#ifdef SSS
#endif
#ifdef WAVING_PLANTS
#endif
#ifdef WAVING_LEAVES
#endif
#ifdef RAIN_PUDDLES
#endif
#ifdef WATER_WAVES
#endif
#ifdef WATER_GLITTER
#endif
#ifdef WATER_PARALLAX
#endif
#ifdef WATER_CAUSTICS
#endif
#ifdef WATER_TEXTURE
#endif
#ifdef SPECULAR_SPARKLE
#endif
#ifdef STARS
#endif
#ifdef CLOUD_TEMPORAL
#endif
#ifdef CLOUD_CIRRUS
#endif
#ifdef CLOUD_CUMULONIMBUS
#endif
#ifdef CLOUD_SHADOWS
#endif
#ifdef FOG_BIOME
#endif
#ifdef FOG_LAYER
#endif
#ifdef FOG_MIST
#endif
#ifdef VL
#endif
#ifdef VL_COLORED_SHADOWS
#endif
#ifdef FOG_BLOCKLIGHT
#endif
#ifdef FOG_CLOUD_SHADOWS
#endif
#ifdef VL_FAR
#endif
#ifdef CAVE_LEAK_PREVENTION
#endif
#ifdef GODRAYS
#endif
#ifdef BORDER_FOG
#endif
#ifdef TAA
#endif
#ifdef DOF
#endif
#ifdef DOF_FOCUS_GLASS
#endif
#ifdef DOF_FOCUS_WATER
#endif
#ifdef MOTION_BLUR
#endif
#ifdef LENS_FLARE
#endif
#ifdef LENS_GHOSTS
#endif
#ifdef LENS_SCREEN_FLARE
#endif
#ifdef LENS_STARBURST
#endif
#ifdef LENS_HALO
#endif
#ifdef LENS_DIRT
#endif
#ifdef LENS_VEILING_GLARE
#endif
#ifdef LENS_DISTORTION
#endif
#ifdef LENS_CHROMATIC
#endif
#ifdef LENS_AXIAL_CA
#endif
#ifdef LENS_SOFT_FOCUS
#endif
#ifdef LENS_SWIRL
#endif
#ifdef LENS_OPTICAL_VIGNETTING
#endif
#ifdef LENS_HALATION
#endif
#ifdef BLOOM
#endif
#ifdef GRADING
#endif
#ifdef SELECTION_OUTLINE
#endif

#endif // SETTINGS_BOOL_REFS_GLSL
