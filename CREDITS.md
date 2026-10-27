# Credits

## 流用コード

なし

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
| 薄明の空 (オゾンの Chappuis 吸収による天頂の青、成層圏のエアロゾルによる紫の光) | Hulburt, "Explanation of the Brightness and Color of the Sky, Particularly the Twilight Sky", JOSA 1953 / Lange, Rozanov, von Savigny, "Revisiting the question 'Why is the sky blue?'", ACP 2023 / Lee & Hernández-Andrés, "Measuring and modeling twilight's purple light", Applied Optics 2003 | lib/sky/atmosphere.glsl, program/prepare1.csh |
| 大気の物理モデル | Bruneton, "A Qualitative and Quantitative Evaluation of 8 Clear Sky Models", TVCG 2017 | lib/sky/atmosphere.glsl |
| 体積雲の散乱 (多重散乱近似) | Wrenninge et al., "Oz: The Great and Volumetric", SIGGRAPH 2013 Talks | lib/sky/cloud_volume.glsl |
| 積雲のこぶの陰影 (不透明な芯・光源方向の近くの光学的深さで多重散乱も落とす・塊の中は削らず境目だけ深く削る浸食) | Bliss Shaders (X0nk) の雲の見え方と考え方を参考に独自実装 (コードは不使用) | lib/sky/cloud_volume.glsl |
| 角の丸い平らな板の雲 (雲の形 Nostalgia 風) | Nostalgia (RRe36) のバニラの雲を押し出した見え方を参考に独自実装 (コードは不使用) | lib/sky/cloud_volume.glsl |
| 空中遠近 (消散と内散乱を組にし、遠景を地平線の空へ収束させる) | Koschmieder, "Theorie der horizontalen Sichtweite", Beiträge zur Physik der freien Atmosphäre, 1924 | lib/sky/fog.glsl |
| 高さフォグの閉形式の光学的深さ | Quilez, "fog" (iquilezles.org) の指数の積分の考え方。上端のロジスティックの積分は独自に導出 | lib/sky/fog.glsl |
| 遠方区間の画面空間の光芒 | Mitchell, "Volumetric Light Scattering as a Post-Process", GPU Gems 3, 2007 | lib/sky/volumetrics.glsl |
| 時間帯・天気・バイオームで切り替えるフォグの構成と、太陽側で強く光る霧 (Bliss 風のスタイル) | Bliss Shaders (X0nk) の見え方と考え方を参考に独自実装 (コードは不使用) | lib/sky/fog.glsl, fog_styles.glsl |
| 2 成分のもやと朝の霧の構成 (Nostalgia 風のスタイル) | Nostalgia Shader (RRe36) の見え方と考え方を参考に独自実装 (コードは不使用) | lib/sky/fog_styles.glsl |
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
| 純水の吸収係数 | Pope & Fry, "Absorption spectrum (380-700 nm) of pure water", Applied Optics 1997 | lib/common/water.glsl |
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
| Oklab | Björn Ottosson, "A perceptual color space for image processing" (2020) | lib/post/color_grade.glsl |
| カラーグレーディングの段の分け方と順番 (オフセット・コントラストとピボット・HDR のゾーン・リフト / ガンマ / ゲイン) | Blackmagic Design, DaVinci Resolve Reference Manual の Color ページの説明 | lib/post/color_grade.glsl |
| フィルム風の LUT の特性 (コントラスト・彩度・色の傾向・色温度) | Kodak の技術資料 E-4050 (Portra 400)・Ektar 100 の製品説明・VISION3 500T 5219/7219 の技術資料、富士フイルムの Fujichrome Velvia 50 / Provia 100F のデータシート・Motion Picture Film Manual (Eterna) の文章の説明から値を決めた近似。メーカーの LUT や測定データは使っていない | tools/look_luts/*.json |
| ブリーチバイパス・クロスプロセスの見た目 | 現像の手法の一般的な説明 (Wikipedia の Bleach bypass / Cross processing の項) | lib/common/look_presets.glsl |
| 単調な 3 次補間 (トーンカーブ) | Fritsch & Carlson, "Monotone Piecewise Cubic Interpolation", SIAM J. Numer. Anal. 1980 / Fritsch & Butland 1984 | lib/post/color_grade.glsl |

## レンズの処方の出典

レンズプリセット 7-18 (lib/post/lens_presets.glsl, tools/gen_lens_ghosts.py) の処方は、次の特許の実施例の数値 (曲率半径・面間隔・屈折率・アッベ数) を公称焦点距離に拡大して使っています。有効半径は特許に無いため、surfaceandstop.com (https://surfaceandstop.com/lenses/) の推定値を使っています。13-18 は Bill Claff の PhotonsToPhotos Optical Bench (https://www.photonstophotos.net/GeneralTopics/Lenses/OpticalBench/OpticalBench.htm) の転記とも照合しています (Canon 50mm f/0.95 はこの転記だけです)。ゴーストの光路は Lee & Eisemann, "Practical Real-Time Lens-Flare Rendering", EGSR 2013 の近軸行列近似で解いています

| プリセット | 特許 |
|---|---|
| Zeiss Sonnar 50mm f/1.5 | US 2,186,621 (L. Bertele, 1940) Fig. 1 |
| Leica Summilux 35mm f/1.4 | US 2,975,673 (W. Mandler, E. Wagner, 1961) Table 1 |
| Canon 50mm f/1.2 | US 2,836,102 (H. Ito, 1958) Example 2 |
| Zeiss Hologon 15mm f/8 | US 3,661,447 (E. Glatzel, H. Schulz, 1972) Table I |
| Carl Zeiss Jena Flektogon 20mm f/4 | DE 1,192,845 B (VEB Carl Zeiss Jena, 1965) 実施例 1 |
| Minolta Fish-eye Rokkor 16mm f/2.8 | US 3,589,798 (T. Ogura, 1971) Embodiment II |
| Nikon Gyogyotto 20mm f/8 | US 5,949,588 (K. Ohshita, A. Shibayama, 1999) Table 8 |
| Voigtländer Ultra Wide-Heliar 12mm f/5.6 | JP 2001-124985 A (コシナ, 2001) 実施例 1 |
| Canon New FD 14mm f/2.8L | JP S57-64716 A (池森敬二, 1982) 実施例 1 |
| Minolta STF 135mm f/2.8 [T4.5] | JP H11-231209 A (工藤吉信, 1999) 実施例 1 |
| Pentax SMC FA 28mm f/2.8 Soft | US 5,822,132 (J. Hirakawa, 1998) Example 1 |
| Canon 50mm f/0.95 | JP S39-10178 (キヤノン, 1964) 実施例 1 (原本は未確認) |

## 参考にしたシェーダー (コード不使用)
すべて大変大好きなシェーダーです！  
尊敬しています

Rethinking Voxels (gri573), Shrimple (Null-MC), Photon (sixthsurge), iterationT (Tahnass), Nostalgia / Kappa (RRe36), Chocapic13, Bliss (X0nk), BSL (capt tatsu), Complementary (EminGT), Solas / Revelation (HaringPro) 等

## ツール

- glslang (Khronos Group) - 検証に使用 (同梱しない)
