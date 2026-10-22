# Credits

## 流用したコード

なし  
他のシェーダーパックのコードは含まない

## 手法の出典 (独自実装したもの)

| 手法 | 出典 | 使用箇所 |
|---|---|---|
| 3D DDA (ボクセル走査) | Amanatides & Woo, "A Fast Voxel Traversal Algorithm for Ray Tracing", Eurographics 1987 | lib/light/trace.glsl |
| void-and-cluster ブルーノイズ | Ulichney, "The void-and-cluster method for dither array generation", SPIE 1993 | tools/gen_blue_noise.py |
| PCG ハッシュ | Jarzynski & Olano, "Hash Functions for GPU Rendering", JCGT 2020 | lib/common/noise.glsl |
| Interleaved Gradient Noise | Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014 | lib/common/noise.glsl |
| R2 低食い違い列 | Roberts, "The Unreasonable Effectiveness of Quasirandom Sequences", 2018 | lib/common/noise.glsl |
| 八面体法線エンコード | Cigolle et al., "A Survey of Efficient Representations for Independent Unit Vectors", JCGT 2014 | lib/common/encoding.glsl |
| 正規直交基底 | Duff et al., "Building an Orthonormal Basis, Revisited", JCGT 2017 | lib/common/math.glsl |
| 球面調和の放射照度 | Ramamoorthi & Hanrahan, "An Efficient Representation for Irradiance Environment Maps", SIGGRAPH 2001 | lib/sky/sh.glsl |
| 窓付き逆二乗減衰 | Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013 | lib/light/block_data.glsl |
| 黒体放射の近似色 | Tanner Helland の近似式 | lib/common/color.glsl |
| Light Propagation Volumes | Kaplanyan & Dachsbacher, I3D 2010 | lib/light/floodfill.glsl, program/deferred.csh |
| 大気散乱 LUT (透過率・多重散乱・SkyView) | Hillaire, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique", EGSR 2020 | lib/sky/atmosphere.glsl, program/setup1-2, prepare1 |
| 大気の物理モデル | Bruneton, "A Qualitative and Quantitative Evaluation of 8 Clear Sky Models", TVCG 2017 | lib/sky/atmosphere.glsl |
| 体積雲の散乱 (多重散乱近似) | Wrenninge et al., "Oz: The Great and Volumetric", SIGGRAPH 2013 Talks | lib/sky/cloud_volume.glsl |
| 体積雲のレイマーチと天気マップ | Schneider, "The Real-time Volumetric Cloudscapes of Horizon Zero Dawn", SIGGRAPH 2015 | lib/sky/cloud_volume.glsl, program/prepare2, deferred20-21 |
| 大気の高さ分布 | Kasten & Young, "Revised optical air mass tables and approximation formula", Applied Optics 1989 | lib/sky/atmosphere.glsl |
| 月面の反射 | Lommel-Seeliger の法則 | lib/sky/celestial.glsl |
| GGX / 可視法線サンプリング | Heitz, "Understanding the Masking-Shadowing Function", JCGT 2014 / "Sampling the GGX Distribution of Visible Normals", JCGT 2018 | lib/surface/brdf.glsl, reflection.glsl |
| 球冠 VNDF サンプリング | Dupuy & Benyoub, "Sampling Visible GGX Normals with Spherical Caps", HPG 2023 | lib/surface/reflection.glsl |
| マルチスキャッタ GGX | Kulla & Conty, "Revisiting Physically Based Shading at Imageworks", SIGGRAPH 2017 / Fdez-Agüera, "A Multiple-Scattering Microfacet Model for Real-Time Image-based Lighting", JCGT 2019 | lib/surface/brdf.glsl |
| 拡散モデル (EON) | Portsmouth et al., "EON: A practical energy-preserving rough diffuse BRDF", JCGT 2025 | lib/surface/brdf.glsl |
| GTAO | Jimenez et al., "Practical Real-Time Strategies for Accurate Indirect Occlusion", SIGGRAPH 2016 | program/deferred10.csh |
| 反射率の測定値・濡れた面 | Lagarde, "Water drop 2b - Dynamic rain and its effects", 2013 | program/gbuffers/solid.fsh |
| RSM | Dachsbacher & Stamminger, "Reflective Shadow Maps", I3D 2005 | program/deferred10.csh |
| 粗い誘電体の透過 | Walter et al., "Microfacet Models for Refraction through Rough Surfaces", EGSR 2007 | program/composite1.fsh |
| 純水の吸収係数 | Pope & Fry, "Absorption spectrum (380-700 nm) of pure water", Applied Optics 1997 | lib/surface/water.glsl |
| POM | Tatarchuk, "Dynamic Parallax Occlusion Mapping with Approximate Soft Shadows", I3D 2006 | program/gbuffers/solid.fsh |
| AgX トーンマップ | Troy Sobotka の AgX (Blender 4.0 の実装と公開されている多項式近似) | lib/post/tonemap.glsl |
| ACES fit | Stephen Hill, "ACES Filmic Tone Mapping Curve" (BakingLab, MIT) の近似式 | lib/post/tonemap.glsl |
| PBR Neutral トーンマップ | Khronos Group, "Khronos PBR Neutral Tone Mapper" 仕様 | lib/post/tonemap.glsl |
| ブルームの縮小フィルタ | Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH 2014 | program/composite23.fsh |
| Karis average / TAA | Karis, "High Quality Temporal Supersampling", SIGGRAPH 2014 | program/composite20.fsh, composite23.fsh |
| TAA の variance clipping | Salvi, "An Excursion in Temporal Supersampling", GDC 2016 / Pedersen, "Temporal Reprojection Anti-Aliasing in INSIDE", GDC 2016 | program/composite20.fsh |
| モーションブラー | McGuire et al., "A Reconstruction Filter for Plausible Motion Blur", I3D 2012 | program/composite21.fsh |
| CAS | AMD FidelityFX Contrast Adaptive Sharpening (アルゴリズムを参照して自前実装) | program/final.fsh |
| Purkinje 効果の桿体輝度 | Larson et al., "A Visibility Matching Tone Reproduction Operator for High Dynamic Range Scenes", TVCG 1997 | lib/post/grading.glsl |
| ASC CDL | American Society of Cinematographers, ASC Color Decision List | lib/post/tonemap.glsl, program/final.fsh |

## 参考にしたシェーダー (コードは不使用)

Rethinking Voxels (gri573), Shrimple (Null-MC), Photon (sixthsurge), iterationT (Tahnass), Nostalgia / Kappa (RRe36), Chocapic13, Bliss (X0nk), BSL (capt tatsu), Complementary (EminGT), Solas / Revelation (HaringPro) ほか。調査内容は `docs/` を参照。

## ツール

- glslang (Khronos Group) - 検証に使用 (同梱しない)
