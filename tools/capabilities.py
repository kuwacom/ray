"""
ローダーの能力 (CAP_*) と、本体が見る機能 (FX_*) の表。1 つの zip で古い Iris / Oculus から最新の Iris まで動かすための判定の正本

- CAP_*: ローダーが持つ能力。検出はローダーが定義するマクロで書き、マクロが無い環境では「能力なし」に倒れる式だけを使う
  (未定義のマクロは #if で 0 になる。値を比べる前に `defined` で確かめる)
- FX_*: 本体が見る機能のスイッチ。設定と CAP_* (と先に書いた FX_*) から決まる
- 本体 (shaders/lib、shaders/program) は FX_* だけを見る。MC_VERSION / IRIS_VERSION / MAX_COLOR_BUFFERS を書いてよいのは
  生成物 (lib/settings/capabilities.glsl と shaders.properties の生成区間) だけ。validate_shaders.py が検査する
- 生成は tools/gen_capabilities.py。GLSL には `#define NAME 1` を条件の中で書く (値なしの define は Iris がブール設定と見なすため)
- ENVS は検証 (validate_shaders.py) で使うローダーの一覧。マクロの値と資源の上限を持つ
"""

from __future__ import annotations

from dataclasses import dataclass

# 検出の式で使ってよいローダーのマクロ (直接書き禁止の検査もこの名前を見る)
LOADER_MACROS = ("MC_VERSION", "IRIS_VERSION", "MAX_COLOR_BUFFERS")


@dataclass(frozen=True)
class Cap:
    """
    ### Cap
    ローダーの能力。detect は #if の式 (LOADER_MACROS だけを使う)。missing は能力が無い環境
    """

    name: str
    detect: str
    meaning: str
    missing: str


@dataclass(frozen=True)
class Fx:
    """
    ### Fx
    本体が見る機能。condition は #if の式で、設定と `defined CAP_*` / `defined FX_*` (表で先に書いたもの) で書く
    properties は条件で true / false を出し分ける shaders.properties の項目 (shaders.properties からは GLSL の FX_* が見えないので、式を展開して書く)
    """

    name: str
    condition: str
    meaning: str
    properties: tuple[str, ...] = ()


CAPS: list[Cap] = [
    Cap("CAP_SHADOW_ENTITIES", "defined IRIS_VERSION && IRIS_VERSION >= 10800",
        "shadow_entities / shadow_block のプログラムが読まれる",
        "Iris 1.8 未満と Oculus。エンティティとブロックエンティティも shadow に来る"),
    # Iris 1.7 系にも gbuffers_lightning はあるが、Oculus と区別できるマクロが無い。IRIS_VERSION の有無で分け、
    # 無い環境 (Oculus、IRIS_VERSION を持たない古い Iris) では雷を gbuffers_entities でも扱う
    Cap("CAP_LIGHTNING_PROGRAM", "defined IRIS_VERSION",
        "gbuffers_lightning のプログラムが読まれる",
        "Oculus (雷は gbuffers_entities で描かれる)"),
]

ENTITY_VOXEL_SETTINGS = "defined ENTITY_SHADOWS || defined LIGHT_ENTITY_OCCLUSION || defined LIGHT_PLAYER_OCCLUSION || defined ENTITY_LIGHTS"
BLOCK_ENTITY_VOXEL_SETTINGS = "defined BLOCK_ENTITY_SHADOWS || defined LIGHT_ENTITY_OCCLUSION || defined ENTITY_LIGHTS"

FXS: list[Fx] = [
    Fx("FX_ENTITY_VOXEL", ENTITY_VOXEL_SETTINGS,
       "エンティティを影とボクセルに描く (遮蔽とエンティティの光源)", ("shadowEntities",)),
    Fx("FX_BLOCK_ENTITY_VOXEL", BLOCK_ENTITY_VOXEL_SETTINGS,
       "ブロックエンティティを影とボクセルに描く", ("shadowBlockEntities",)),
    # shadowPlayer と shadowLightBlockEntities は設定に依らず有効なので、FX_ENTITY_VOXEL が無くても地形以外が来る
    # (shadow でエンティティを扱うかは、来たものを renderStage で分けるだけなので、FX_ENTITY_VOXEL との組の FX は要らない)
    Fx("FX_SHADOW_NON_TERRAIN", "!defined CAP_SHADOW_ENTITIES",
       "shadow のプログラムに地形以外 (プレイヤー・エンティティ・ブロックエンティティ) が来る。地形用の処理を地形だけに閉じる"),
    Fx("FX_LIGHTNING_IN_ENTITIES", "!defined CAP_LIGHTNING_PROGRAM",
       "雷を gbuffers_entities でも扱う (gbuffers_lightning が読まれない環境)"),
]


# Iris 1.7.6 (1.20.1) の列挙。出典は Iris のソースの 1.20.1 ブランチ (FeatureFlags / PixelType / PixelFormat / InternalTextureFormat)
FEATURES_1_7 = frozenset({
    "SEPARATE_HARDWARE_SAMPLERS", "HIGHER_SHADOWCOLOR", "CUSTOM_IMAGES", "PER_BUFFER_BLENDING", "COMPUTE_SHADERS",
    "TESSELLATION_SHADERS", "ENTITY_TRANSLUCENT", "REVERSED_CULLING", "BLOCK_EMISSION_ATTRIBUTE", "SSBO",
})
PIXEL_TYPES_1_7 = frozenset({
    "BYTE", "SHORT", "INT", "HALF_FLOAT", "FLOAT", "UNSIGNED_BYTE", "UNSIGNED_BYTE_3_3_2", "UNSIGNED_BYTE_2_3_3_REV",
    "UNSIGNED_SHORT", "UNSIGNED_SHORT_5_6_5", "UNSIGNED_SHORT_5_6_5_REV", "UNSIGNED_SHORT_4_4_4_4",
    "UNSIGNED_SHORT_4_4_4_4_REV", "UNSIGNED_SHORT_5_5_5_1", "UNSIGNED_SHORT_1_5_5_5_REV", "UNSIGNED_INT",
    "UNSIGNED_INT_8_8_8_8", "UNSIGNED_INT_8_8_8_8_REV", "UNSIGNED_INT_10_10_10_2", "UNSIGNED_INT_2_10_10_10_REV",
})
PIXEL_FORMATS_1_7 = frozenset({
    "RED", "RG", "RGB", "BGR", "RGBA", "BGRA", "RED_INTEGER", "RG_INTEGER", "RGB_INTEGER", "BGR_INTEGER", "RGBA_INTEGER",
    "BGRA_INTEGER",
})
INTERNAL_FORMATS_1_7 = frozenset({
    "RGBA", "R8", "RG8", "RGB8", "RGBA8", "R8_SNORM", "RG8_SNORM", "RGB8_SNORM", "RGBA8_SNORM", "R16", "RG16", "RGB16",
    "RGBA16", "R16_SNORM", "RG16_SNORM", "RGB16_SNORM", "RGBA16_SNORM", "R16F", "RG16F", "RGB16F", "RGBA16F", "R32F",
    "RG32F", "RGB32F", "RGBA32F", "R8I", "RG8I", "RGB8I", "RGBA8I", "R8UI", "RG8UI", "RGB8UI", "RGBA8UI", "R16I", "RG16I",
    "RGB16I", "RGBA16I", "R16UI", "RG16UI", "RGB16UI", "RGBA16UI", "R32I", "RG32I", "RGB32I", "RGBA32I", "R32UI", "RG32UI",
    "RGB32UI", "RGBA32UI", "R3_G3_B2", "RGB5_A1", "RGB10_A2", "RGB10_A2UI", "R11F_G11F_B10F", "RGB9_E5",
})


@dataclass(frozen=True)
class Env:
    """
    ### Env
    検証で想定するローダー。macros は LOADER_MACROS のうち定義されるもの (無いものは未定義のまま検証する)
    上限は、このローダーで読み込みが失敗する・資源が捨てられる境界
    """

    name: str
    macros: dict[str, str]
    colortex_count: int
    buffer_object_max_index: int
    image_count: int = 16
    features: frozenset[str] = FEATURES_1_7
    pixel_types: frozenset[str] = PIXEL_TYPES_1_7
    pixel_formats: frozenset[str] = PIXEL_FORMATS_1_7
    internal_formats: frozenset[str] = INTERNAL_FORMATS_1_7
    note: str = ""


ENVS: list[Env] = [
    Env("latest", {"MC_VERSION": "12104", "IRIS_VERSION": "11100", "MAX_COLOR_BUFFERS": "32"}, 32, 12,
        features=FEATURES_1_7 | {"CAN_DISABLE_WEATHER", "FADE_VARIABLE", "TEXTURE_FILTERING"},
        pixel_types=PIXEL_TYPES_1_7 | {"UNSIGNED_INT_10F_11F_11F_REV"},
        note="Iris 1.10.5 以降 (colortex 32 枚、bufferObject 0-12 は 1.21.11 / 26.x)"),
    # Iris 1.8〜1.10.4 の flag と pixel type の列挙は確かめていないので、1.7 と同じものに絞る
    Env("mid", {"MC_VERSION": "12101", "IRIS_VERSION": "10800"}, 16, 8,
        note="Iris 1.8〜1.10.4 (shadow_entities はあり、colortex は 16 枚)"),
    # 実際の Iris 1.7.5+ は IRIS_VERSION を定義するが、定義しない Oculus と 1.7.2 以下に合わせて未定義で検証する
    Env("1.7.6", {"MC_VERSION": "12001"}, 16, 8,
        note="Iris 1.7.x / Oculus 1.20.1-1.8.0 (shadow_entities なし、IRIS_VERSION なし)"),
]
