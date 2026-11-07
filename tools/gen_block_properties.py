"""
ID と光源の表から、シェーダー側の ID の定数・properties・光源のデータを生成する

    shaders/block.properties, item.properties, entity.properties
    shaders/lib/ids/block_ids.glsl, light_ids.glsl, entity_ids.glsl, block_albedo.glsl
    shaders/lib/light/light_table_data.glsl, light_mask_data.glsl

正本は、光源・エンティティ・ID の定数が tools/id_tables.py、光源でないブロックの表 (BLOCKS) がこのスクリプト、
ブロックの色と光源の面の光り方が tools/block_colors.json と tools/light_masks.json (tools/gen_block_colors.py が作る)
未登録のブロックはボクセルで「完全な固体」として扱われるので、光を通す形のブロックは必ずどこかに載せる。
下の表に載っていないブロックのうち tools/block_colors.json に色のあるものは、色ごとに 2000 番台の ID (色の付いた固体) を振る

使い方
    uv run tools/gen_block_properties.py            # 生成物を書く
    uv run tools/gen_block_properties.py --check    # 生成物が最新か確認する (ずれていれば終了コード 1)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from id_tables import (  # noqa: E402
    BLOCK_CONSTS, COLOR_BAND_FIRST, COLOR_BAND_LAST, COLORS, COPPER_PREFIX, ENTITIES, ENTITY_LIGHT_ID_BASE, LIGHT_BLOCK_LAST,
    FACINGS, LIGHT_ENTITY_FIRST, LIGHT_ENTITY_LAST, LIGHT_FACING_LAST, LIGHT_FACING_STRIDE, LIGHT_ID_BASE, LIGHT_ITEM_FIRST,
    LIGHT_ITEM_LAST, LIGHTS, Light, STAIRS_FIRST, with_state,
)
from lib.color import linear_to_srgb, srgb_to_linear  # noqa: E402
from lib.generated import check as generated_check  # noqa: E402
from lib.generated import cli  # noqa: E402
from lib.paths import ROOT, SHADERS  # noqa: E402

BLOCK_COLORS = ROOT / "tools" / "block_colors.json"
LIGHT_MASKS = ROOT / "tools" / "light_masks.json"

# この刻み (sRGB 8bit) で同じになる色は 1 つの ID にまとめる。照り返しの色にはこれで十分
COLOR_QUANT = 4
# 色の分からない ID (未登録の固体・MOD のブロック) の色。線形 0.3 の灰色
DEFAULT_ALBEDO_SRGB = (149, 149, 149)
# 番号帯ごとに表を分ける (ID がまばらなので 1 本の表にすると無駄が多い)。光源帯は 1000 + 光源インデックス
ALBEDO_BANDS = [(0, 100), (100, 200), (200, 300), (300, 400), (1000, 1256)]

WOODS = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "pale_oak", "bamboo", "crimson", "warped"]
# 酸化していない銅ブロックの ID は copper_block (ワックス付きは waxed_copper_block)。"copper" というブロックは無い
COPPER = ["copper_block", "exposed_copper", "weathered_copper", "oxidized_copper"]

SLAB_STAIR_BASES = [
    *WOODS, "bamboo_mosaic", "stone", "cobblestone", "mossy_cobblestone", "stone_brick", "mossy_stone_brick",
    "sandstone", "smooth_sandstone", "red_sandstone", "smooth_red_sandstone", "brick", "mud_brick",
    "nether_brick", "red_nether_brick", "quartz", "smooth_quartz", "purpur", "prismarine", "prismarine_brick",
    "dark_prismarine", "granite", "polished_granite", "diorite", "polished_diorite", "andesite", "polished_andesite",
    "end_stone_brick", "blackstone", "polished_blackstone", "polished_blackstone_brick", "cobbled_deepslate",
    "polished_deepslate", "deepslate_brick", "deepslate_tile", "tuff", "polished_tuff", "tuff_brick", "resin_brick",
    *[f"{p}cut_copper" for p in COPPER_PREFIX], *[f"waxed_{p}cut_copper" for p in COPPER_PREFIX],
]
SLAB_ONLY = ["smooth_stone", "cut_sandstone", "cut_red_sandstone", "petrified_oak"]
WALL_BASES = ["cobblestone", "mossy_cobblestone", "stone_brick", "mossy_stone_brick", "granite", "diorite", "andesite",
              "sandstone", "red_sandstone", "brick", "mud_brick", "prismarine", "nether_brick", "red_nether_brick",
              "end_stone_brick", "blackstone", "polished_blackstone", "polished_blackstone_brick", "cobbled_deepslate",
              "polished_deepslate", "deepslate_brick", "deepslate_tile", "tuff", "polished_tuff", "tuff_brick", "resin_brick"]
DOOR_TRAPDOOR = [*WOODS, "iron", *[f"{p}copper" for p in COPPER_PREFIX], *[f"waxed_{p}copper" for p in COPPER_PREFIX]]


def wood_prefixed(suffix: str, woods=WOODS) -> list[str]:
    return [f"{w}_{suffix}" for w in woods]


def colored(suffix: str) -> list[str]:
    return [f"{c}_{suffix}" for c in COLORS]


STAIR_FACINGS = ["north", "east", "south", "west"]  # 時計回り (上から見て)
STAIR_SHAPES = ["straight", "inner_left", "inner_right", "outer_left", "outer_right"]


def stair_slot(facing: str, shape: str) -> int:
    """0-3 = 直線 (段のある側 N/E/S/W)、4-7 = 外角 (段のある 1/4 が NW/NE/SE/SW)"""
    f = STAIR_FACINGS.index(facing)
    # 内角は段が 3/4 で、遮蔽の箱 2 個 (lib/light/light_table.glsl) に収まらないので同じ向きの直線で近似する (遮りすぎない側)
    if shape in ("straight", "inner_left", "inner_right"):
        return f
    # facing=north の外角は left = 北西、right = 北東。向きを時計回りに 1 つ回すと象限も 1 つ回る
    return 4 + (f + (0 if shape == "outer_left" else 1)) % 4


def stair_entries() -> list[tuple[int, str, list[str]]]:
    out = []
    for h, half in enumerate(["bottom", "top"]):
        for slot in range(8):
            names = [f"{b}_stairs:half={half}:facing={f}:shape={s}"
                     for b in SLAB_STAIR_BASES for f in STAIR_FACINGS for s in STAIR_SHAPES if stair_slot(f, s) == slot]
            out.append((STAIRS_FIRST + h * 8 + slot, f"stairs ({half}, shape {slot})", names))
    return out


# 光源でないブロックの表。光源 (ID 1001-1255) は id_tables.py の LIGHTS
# (ID, コメント, ブロック一覧) の順に並べる
# コメントは .properties にそのまま出るので ASCII で書く (Iris は ISO-8859-1 で読み、UTF-8 の日本語は前処理を壊す)
BLOCKS: list[tuple[int, str, list[str]]] = [
    # 暗い金属 (ネザライト・金床) はアルベドを F0 にすると黒い鏡になるので 11 (光沢のある誘電体) に入れる
    (10, "metal (material hint)", ["iron_block", *COPPER, *[f"waxed_{c}" for c in COPPER], *[f"{p}cut_copper" for p in COPPER_PREFIX],
                                     *[f"waxed_{p}cut_copper" for p in COPPER_PREFIX], *[f"{p}chiseled_copper" for p in COPPER_PREFIX],
                                     *[f"waxed_{p}chiseled_copper" for p in COPPER_PREFIX],
                                     *[f"{p}copper_grate" for p in COPPER_PREFIX], *[f"waxed_{p}copper_grate" for p in COPPER_PREFIX]]),
    (11, "polished stone / minerals / dark metals", ["netherite_block", "anvil", "chipped_anvil", "damaged_anvil", "heavy_core",
                            "quartz_block", "smooth_quartz", "quartz_bricks",
                            "polished_granite", "polished_diorite", "polished_andesite", "polished_deepslate", "polished_blackstone",
                            "polished_tuff", "polished_basalt", "packed_ice", "blue_ice", "obsidian", *colored("glazed_terracotta")]),
    (12, "snow", ["snow_block", "powder_snow"]),
    # 光らないが鮮やかな鉱物ブロック。DECORATIVE_BLOCK_LIGHTS で発光・光源にできる (OFF では元のマテリアル, lib/ids/id_decode.glsl)
    (13, "decorative: lapis (glossy)", ["lapis_block"]),
    (14, "decorative: emerald (glossy)", ["emerald_block"]),
    (15, "decorative: diamond (glossy)", ["diamond_block"]),
    (16, "decorative: gold (metal)", ["gold_block"]),
    (17, "decorative: redstone", ["redstone_block"]),
    (18, "decorative: amethyst", ["amethyst_block", "budding_amethyst"]),

    (100, "short plants (wave with fixed root)", ["short_grass", "fern", "dead_bush", "dandelion", "poppy", "blue_orchid", "allium",
                                         "azure_bluet", "red_tulip", "orange_tulip", "white_tulip", "pink_tulip", "oxeye_daisy",
                                         "cornflower", "lily_of_the_valley", "wither_rose", "torchflower", "closed_eyeblossom",
                                         "open_eyeblossom", "pink_petals", "wildflowers", "short_dry_grass", "tall_dry_grass", "bush",
                                         "cactus_flower", "oak_sapling", "spruce_sapling", "birch_sapling", "jungle_sapling",
                                         "acacia_sapling", "dark_oak_sapling", "cherry_sapling", "pale_oak_sapling", "mangrove_propagule",
                                         "brown_mushroom", "red_mushroom", "crimson_fungus", "warped_fungus", "crimson_roots",
                                         "warped_roots", "nether_sprouts", "sweet_berry_bush", "small_dripleaf", "leaf_litter"]),
    (101, "lower half of two-block plants", with_state(["tall_grass", "large_fern", "sunflower", "lilac", "rose_bush", "peony", "pitcher_plant"], "half=lower")),
    (102, "upper half of two-block plants", with_state(["tall_grass", "large_fern", "sunflower", "lilac", "rose_bush", "peony", "pitcher_plant"], "half=upper")),
    (103, "leaves", wood_prefixed("leaves", ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "pale_oak", "azalea"]) + ["flowering_azalea_leaves"]),
    (104, "vines / hanging plants", ["vine", "weeping_vines", "weeping_vines_plant", "twisting_vines", "twisting_vines_plant",
                              "cave_vines:berries=false", "cave_vines_plant:berries=false", "hanging_roots", "pale_hanging_moss",
                              "spore_blossom", "sculk_vein"]),
    (105, "crops", ["wheat", "carrots", "potatoes", "beetroots", "melon_stem", "pumpkin_stem", "attached_melon_stem",
                 "attached_pumpkin_stem", "torchflower_crop", "pitcher_crop", "nether_wart"]),
    (106, "small props that do not block light", ["rail", "powered_rail", "detector_rail", "activator_rail", "lever", "redstone_wire", "repeater",
                         "comparator", "tripwire", "tripwire_hook", "ladder", "scaffolding", "chain", "iron_chain",
                         *[f"{p}copper_chain" for p in COPPER_PREFIX], *[f"waxed_{p}copper_chain" for p in COPPER_PREFIX],
                         *[f"{p}lightning_rod" for p in COPPER_PREFIX], *[f"waxed_{p}lightning_rod" for p in COPPER_PREFIX],
                         "pointed_dripstone", "turtle_egg", "frogspawn", "sea_pickle:waterlogged=false", "moss_carpet",
                         "pale_moss_carpet", "flower_pot", "bell", "redstone_torch:lit=false", "redstone_wall_torch:lit=false",
                         "candle:lit=false", *with_state(colored("candle"), "lit=false"),
                         "stone_button", "polished_blackstone_button", *wood_prefixed("button"),
                         "stone_pressure_plate", "polished_blackstone_pressure_plate", "light_weighted_pressure_plate",
                         "heavy_weighted_pressure_plate", *wood_prefixed("pressure_plate"),
                         *colored("carpet"), *wood_prefixed("sign"), *wood_prefixed("wall_sign"), *wood_prefixed("hanging_sign"),
                         *wood_prefixed("wall_hanging_sign"), *colored("banner"), *colored("wall_banner"),
                         *wood_prefixed("fence_gate"),
                         *with_state([f"{w}_door" for w in DOOR_TRAPDOOR], "open=true"),
                         *with_state([f"{w}_trapdoor" for w in DOOR_TRAPDOOR], "open=true"),
                         "end_portal_frame:eye=false", "big_dripleaf", "big_dripleaf_stem",
                         "campfire:lit=false", "soul_campfire:lit=false"]),
    (107, "cobweb", ["cobweb"]),
    (108, "lily pad", ["lily_pad"]),
    (109, "sugar cane / bamboo", ["sugar_cane", "bamboo", "bamboo_sapling"]),
    (110, "underwater plants", ["seagrass", "tall_seagrass", "kelp", "kelp_plant"]),

    # 水の level は 0 が水源、1-7 が流れる水 (上面が低い)、8 以上が落ちる水 (上面は水源と同じ)
    (200, "water", ["water:level=0", *[f"water:level={k}" for k in range(8, 16)], "bubble_column"]),
    (207, "flowing water", [f"water:level={k}" for k in range(1, 8)]),
    (201, "ice", ["ice", "frosted_ice"]),
    (202, "glass", ["glass"]),
    (203, "glass pane", ["glass_pane"]),
    (204, "slime block", ["slime_block"]),
    (205, "honey block", ["honey_block"]),
    (206, "tinted glass", ["tinted_glass"]),
    *[(210 + i, f"{c} stained glass", [f"{c}_stained_glass"]) for i, c in enumerate(COLORS)],
    *[(230 + i, f"{c} stained glass pane", [f"{c}_stained_glass_pane"]) for i, c in enumerate(COLORS)],

    (300, "bottom slabs", with_state([f"{b}_slab" for b in SLAB_STAIR_BASES + SLAB_ONLY], "type=bottom")),
    (301, "top slabs", with_state([f"{b}_slab" for b in SLAB_STAIR_BASES + SLAB_ONLY], "type=top")),
    (304, "fences", [*wood_prefixed("fence", [w for w in WOODS]), "nether_brick_fence"]),
    (305, "walls", [f"{b}_wall" for b in WALL_BASES]),
    (306, "bars (panes other than glass)", ["iron_bars", *[f"{p}copper_bars" for p in COPPER_PREFIX], *[f"waxed_{p}copper_bars" for p in COPPER_PREFIX]]),
    (307, "low blocks", ["stonecutter", "daylight_detector", "lectern", "composter", "farmland", "dirt_path", "sculk_shrieker"]),
    # 積もった雪は層の数で高さが違う (1 層 = 1/8)。遮蔽の形を高さに合わせるため層ごとに分ける (308 = 1 層, 310-316 = 2-8 層)
    (308, "snow layers (1)", ["snow:layers=1"]),
    (309, "closed doors / trapdoors", [*with_state([f"{w}_door" for w in DOOR_TRAPDOOR], "open=false"),
                                 *with_state([f"{w}_trapdoor" for w in DOOR_TRAPDOOR], "open=false")]),
    *[(308 + k, f"snow layers ({k})", [f"snow:layers={k}"]) for k in range(2, 9)],
    *stair_entries(),
]


HEADER = """#
# Ray {kind}.properties
# Generated by tools/gen_block_properties.py. Do not edit by hand (ID ranges: shaders/lib/ids/*.glsl)
# Keep this file ASCII only: Iris reads .properties as ISO-8859-1 and non-ASCII bytes break its preprocessor
#
"""


def render(kind: str, entries: list[tuple[int, str, list[str]]]) -> str:
    lines = [HEADER.format(kind=kind)]
    seen: dict[str, int] = {}
    for bid, comment, names in entries:
        for n in names:
            if n in seen:
                raise SystemExit(f"{kind}: {n} が ID {seen[n]} と {bid} に重複")
            seen[n] = bid
        lines.append(f"# {comment}")
        lines.append(f"{kind}.{bid} = " + " ".join(names))
        lines.append("")
    text = "\n".join(lines)
    if not text.isascii():
        raise SystemExit(f"{kind}.properties に ASCII 以外の文字がある (コメントは ASCII で書く)")
    return text


def mean_srgb(colors: list[list[int]]) -> tuple[int, int, int]:
    """線形で平均してから sRGB 8bit へ (反射率の平均なので線形で取る)"""
    lin = [sum(srgb_to_linear(c[i] / 255.0) for c in colors) / len(colors) for i in range(3)]
    return tuple(int(round(linear_to_srgb(x, 1.0) * 255.0)) for x in lin)


Rgb = tuple[int, int, int]


def color_blocks(colors: dict[str, list[int]], tops: dict[str, list[int]]) -> tuple[list[tuple[int, str, list[str]]], list[Rgb], list[Rgb]]:
    """表に無いブロックを色 (全体と上面) でまとめて 2000 番台の ID を振る。戻り値は (BLOCKS と同じ形の項目, ID 順の色, ID 順の上面の色)"""
    # 状態付きで一部だけ載っているブロック (点灯したかまど等) は名前ごと外す。
    # 名前だけの項目を足すと Iris の状態の対応がどちらになるか定まらないため (残りの状態は今どおり未登録の固体)
    registered = {n.split(":")[0] for _, _, names in all_blocks() for n in names}
    groups: dict[tuple[int, ...], list[str]] = {}
    for name, c in colors.items():
        if name in registered:
            continue
        top = tops.get(name, c)
        groups.setdefault(tuple(v // COLOR_QUANT for v in c) + tuple(v // COLOR_QUANT for v in top), []).append(name)
    entries: list[tuple[int, str, list[str]]] = []
    palette: list[Rgb] = []
    palette_top: list[Rgb] = []
    for i, key in enumerate(sorted(groups)):
        bid = COLOR_BAND_FIRST + i
        if bid > COLOR_BAND_LAST:
            raise SystemExit("色の付いた固体の ID が 4095 を超えた (COLOR_QUANT を大きくする)")
        names = sorted(groups[key])
        rgb = mean_srgb([colors[n] for n in names])
        palette.append(rgb)
        palette_top.append(mean_srgb([tops.get(n, colors[n]) for n in names]))
        entries.append((bid, "colored solid #%02x%02x%02x" % rgb, names))
    return entries, palette, palette_top


def pack_srgb(rgb: tuple[int, int, int]) -> str:
    # unpackUnorm4x8 の x が最下位バイト
    return "0x%06Xu" % (rgb[0] | (rgb[1] << 8) | (rgb[2] << 16))


def render_albedo_glsl(colors: dict[str, list[int]], tops: dict[str, list[int]], palette: list[Rgb], palette_top: list[Rgb]) -> str:
    by_id: dict[int, Rgb] = {1: DEFAULT_ALBEDO_SRGB}
    top_by_id: dict[int, Rgb] = {}
    for bid, _, names in all_blocks():
        # 向きのある光源の東・南・西は向きなしと同じ色 (blockAlbedoBaseId で引く)
        if LIGHT_ID_BASE + 255 < bid <= LIGHT_FACING_LAST:
            continue
        known = [n.split(":")[0] for n in names if n.split(":")[0] in colors]
        if known:
            by_id[bid] = mean_srgb([colors[n] for n in known])
            top = mean_srgb([tops.get(n, colors[n]) for n in known])
            if top != by_id[bid]:
                top_by_id[bid] = top
    for i, (c, top) in enumerate(zip(palette, palette_top)):
        if top != c:
            top_by_id[COLOR_BAND_FIRST + i] = top
    default = pack_srgb(DEFAULT_ALBEDO_SRGB)

    def table(name: str, values: list[str], kind: str = "uint") -> list[str]:
        out = [f"const {kind} {name}[{len(values)}] = {kind}[{len(values)}]("]
        for k in range(0, len(values), 8):
            out.append("    " + ", ".join(values[k:k + 8]) + ("," if k + 8 < len(values) else ""))
        out.append(");")
        return out

    lines = [
        "/*",
        " * ブロックの平均の色 (sRGB 8bit を R | G << 8 | B << 16 に詰めたもの)",
        " * tools/gen_block_properties.py が tools/block_colors.json (バニラのテクスチャの平均) から生成する。手で編集しない",
        " * 2000 番台 (色の付いた固体) は ID ごとの色、それ以外の番号帯は帯の ID に載せたブロックの平均",
        " * バイオームで色が変わる草・葉・水は平原の色で代表させている",
        " * setup.csh が SSBO (blockData.albedo) へ展開し、実行時は lib/light/block_data.glsl の getBlockAlbedo で引く",
        " * 上面の色が違うブロック (草ブロック・原木など) は BLOCK_ALBEDO_TOP に上面だけの色を持つ (blockData.albedoUp)",
        " */",
        "#ifndef IDS_BLOCK_ALBEDO_GLSL",
        "#define IDS_BLOCK_ALBEDO_GLSL",
        "",
        '//@include "/lib/ids/block_ids.glsl"',
        "",
        f"const uint BLOCK_ALBEDO_DEFAULT = {default};",
        "",
    ]
    body = []
    for lo, hi in ALBEDO_BANDS:
        ids = [i for i in by_id if lo <= i < hi]
        if not ids:
            continue
        last = max(ids)
        name = f"BLOCK_ALBEDO_{lo}"
        lines += table(name, [pack_srgb(by_id[i]) if i in by_id else default for i in range(lo, last + 1)])
        body.append(f"    if (id >= {lo} && id <= {last}) return {name}[id - {lo}];")
    lines += table("BLOCK_ALBEDO_COLORED", [pack_srgb(c) for c in palette])
    lines += [
        "",
        "// 向きのある光源の ID (東・南・西) は向きなしの ID の色を使う",
        "int blockAlbedoBaseId(int id) {",
        "    return (id > BLOCK_LIGHT_BASE + 255 && id <= BLOCK_LIGHT_LAST) ? BLOCK_LIGHT_BASE + ((id - BLOCK_LIGHT_BASE) & 255) : id;",
        "}",
        "",
        "uint blockAlbedoPacked(int id) {",
        "    id = blockAlbedoBaseId(id);",
        f"    if (id >= BLOCK_COLOR_FIRST) return id - BLOCK_COLOR_FIRST < {len(palette)} ? BLOCK_ALBEDO_COLORED[id - BLOCK_COLOR_FIRST] : BLOCK_ALBEDO_DEFAULT;",
        *body,
        "    return BLOCK_ALBEDO_DEFAULT;",
        "}",
        "",
    ]
    top_ids = sorted(top_by_id)
    lines += table("BLOCK_ALBEDO_TOP_ID", [str(i) for i in top_ids], "int")
    lines += table("BLOCK_ALBEDO_TOP", [pack_srgb(top_by_id[i]) for i in top_ids])
    lines += [
        "",
        "// 上面の色 (setup で 1 回だけ引くので線形探索)",
        "uint blockAlbedoTopPacked(int id) {",
        f"    id = blockAlbedoBaseId(id);",
        f"    for (int k = 0; k < {len(top_ids)}; k++) if (BLOCK_ALBEDO_TOP_ID[k] == id) return BLOCK_ALBEDO_TOP[k];",
        "    return blockAlbedoPacked(id);",
        "}",
        "",
        "#endif",
        "",
    ]
    return "\n".join(lines)


Entry = tuple[int, str, list[str]]


def light_block_entries() -> list[Entry]:
    out: list[Entry] = []
    for light in LIGHTS:
        if light.blocks and light.facing:
            # 北は向きなしと同じ ID、東・南・西は 256 ずつ上の帯 (向きは Iris の状態 facing で分ける)
            for f, facing in enumerate(FACINGS):
                out.append((LIGHT_ID_BASE + LIGHT_FACING_STRIDE * f + light.index, f"{light.title} (facing {facing})",
                            [f"{b}:facing={facing}" for b in light.blocks]))
        elif light.blocks:
            out.append((LIGHT_ID_BASE + light.index, light.title, list(light.blocks)))
        for k, (title, names) in enumerate(light.variants):
            out.append((LIGHT_ID_BASE + light.index + k, title, list(names)))
    return out


def light_item_entries() -> list[Entry]:
    return [(LIGHT_ID_BASE + light.index, light.title, list(light.items)) for light in LIGHTS if light.items]


def all_blocks() -> list[Entry]:
    return BLOCKS + light_block_entries()


def check_tables() -> None:
    """光源の番号帯・ID の重複・定数と properties の対応を確かめる。ずれていれば生成を止める"""
    names: set[str] = set()
    prev_end = 0
    for light in LIGHTS:
        span = max(light.count, len(light.variants), 1)
        if light.index < prev_end or light.index + span - 1 > LIGHT_ENTITY_LAST:
            raise SystemExit(f"光源 {light.index} ({light.title}) の index が昇順でないか範囲外")
        prev_end = light.index + span
        if light.name:
            if light.name in names:
                raise SystemExit(f"光源の定数名 {light.name} が重複")
            names.add(light.name)
        in_block = light.index + span - 1 <= LIGHT_BLOCK_LAST
        if (light.blocks or light.variants) and not in_block:
            raise SystemExit(f"光源 {light.index} ({light.title}): ブロック光源の帯 (1-{LIGHT_BLOCK_LAST}) の外にブロックがある")
        if light.facing and (not in_block or span != 1 or not light.mask):
            raise SystemExit(f"光源 {light.index} ({light.title}): 向きのある光源はブロック光源の帯の 1 つで、前面を測る mask が要る")
        if light.items and light.index > LIGHT_ITEM_LAST:
            raise SystemExit(f"光源 {light.index} ({light.title}): アイテムはエンティティ光源の帯に置けない")
        if LIGHT_ITEM_FIRST <= light.index <= LIGHT_ITEM_LAST and not light.items:
            raise SystemExit(f"光源 {light.index} ({light.title}): アイテム専用光源の帯なのにアイテムが無い")
        if light.entities and light.index < LIGHT_ENTITY_FIRST:
            raise SystemExit(f"光源 {light.index} ({light.title}): エンティティはエンティティ光源の帯 ({LIGHT_ENTITY_FIRST}-) に置く")
        if light.index >= LIGHT_ENTITY_FIRST and not light.entities:
            raise SystemExit(f"光源 {light.index} ({light.title}): エンティティ光源の帯なのにエンティティが無い")
    ids: dict[int, str] = {}
    for bid, comment, _ in all_blocks():
        if bid in ids:
            raise SystemExit(f"ブロック ID {bid} が重複: {ids[bid]} / {comment}")
        ids[bid] = comment
    for _kind, _width, name, value, _c, in_table in (r for r in BLOCK_CONSTS if r[0] == "const"):
        if in_table and value not in ids:
            raise SystemExit(f"{name} = {value} に対応する block.properties の行が無い")
    entity_ids = [e[0] for e in ENTITIES]
    if len(set(entity_ids)) != len(entity_ids) or max(entity_ids) >= ENTITY_LIGHT_ID_BASE:
        raise SystemExit("エンティティ ID が重複しているか、光源の帯 (5100-) に入っている")


def trailing(line: str, width: int, comment: str) -> str:
    if not comment:
        return line
    return line + " " * max(width - len(line), 1) + "// " + comment


GENERATED_NOTE = "tools/gen_block_properties.py が tools/id_tables.py から生成する。手で編集しない"


def render_light_ids() -> str:
    def consts(lo: int, hi: int) -> list[str]:
        return [trailing(f"const int {l.name} = {l.index};", 0, l.comment) for l in LIGHTS if l.name and lo <= l.index <= hi]

    lines = [
        "/*",
        " * 光源インデックス (0-255)。光源テーブル (lib/light/light_table.glsl) の添字",
        f" * {GENERATED_NOTE}",
        f" *   1-{LIGHT_BLOCK_LAST}  : ブロック光源 (block.properties / item.properties の {LIGHT_ID_BASE} + index)",
        f" *   {LIGHT_ITEM_FIRST}-{LIGHT_ITEM_LAST}: アイテム専用光源 (item.properties の {LIGHT_ID_BASE} + index)",
        f" *   {LIGHT_ENTITY_FIRST}-{LIGHT_ENTITY_LAST}: エンティティ光源 (entity.properties の {ENTITY_LIGHT_ID_BASE} + (index - {LIGHT_ENTITY_FIRST}))",
        " */",
        "#ifndef IDS_LIGHT_IDS_GLSL",
        "#define IDS_LIGHT_IDS_GLSL",
        "",
        "const int LIGHT_NONE = 0;",
        "",
        "// ブロック光源",
        *consts(1, LIGHT_BLOCK_LAST),
        f"const int LIGHT_BLOCK_LAST = {LIGHT_BLOCK_LAST};",
        "",
        "// アイテム専用光源 (ドロップ・手持ち)",
        *consts(LIGHT_ITEM_FIRST, LIGHT_ITEM_LAST),
        f"const int LIGHT_ITEM_LAST = {LIGHT_ITEM_LAST};",
        "",
        "// エンティティ光源",
        *consts(LIGHT_ENTITY_FIRST, LIGHT_ENTITY_LAST),
        "",
        "// 光源フラグ (LightDef.info.x)",
        "const uint LIGHT_FLAG_OCCLUDES = 1u;        // 光源ブロック自体が完全遮蔽物 (グロウストーン等)",
        "const uint LIGHT_FLAG_FLUID = 2u;           // 液体 (溶岩)",
        "const uint LIGHT_FLAG_CAT_ITEM = 4u;        // ITEM_LIGHTS の対象",
        "const uint LIGHT_FLAG_CAT_PROJECTILE = 8u;  // PROJECTILE_LIGHTS の対象",
        "const uint LIGHT_FLAG_CAT_BURNING = 16u;    // BURNING_ENTITY_LIGHTS の対象",
        "const uint LIGHT_FLAG_CAT_GLOWING = 32u;    // GLOWING_ENTITY_LIGHTS の対象",
        "const uint LIGHT_FLAG_ENTITY_FLASH = 64u;   // entityColor.a (点滅) が強い時だけ光る (TNT・クリーパー)",
        "const uint LIGHT_FLAG_EMISSION_MASK = 128u; // 面の光り方のデータがある (lightMasks。setup_tables.csh が立てる)",
        "const uint LIGHT_FLAG_FACING = 256u;        // 向きのある光源 (前面だけが光る。向きはブロック ID の向きの番号 lib/ids/id_decode.glsl blockLightFacing)",
        "",
        "// 向きのある光源か (LIGHT_FLAG_FACING の光源。光源の表を引かずに gbuffers で判定する)",
        "bool isFacingLight(int light) {",
        "    return " + " || ".join(f"light == {l.name}" for l in LIGHTS if l.facing) + ";",
        "}",
        "",
        "#endif",
        "",
    ]
    return "\n".join(lines)


def render_block_ids() -> str:
    lines = [
        "/*",
        " * ブロック ID (block.properties と同じ表から生成する)",
        " * tools/gen_block_properties.py が生成する (光源以外は同スクリプトの BLOCKS、光源は tools/id_tables.py)。手で編集しない",
        " *",
        " * 番号帯",
        " *   1        : 未登録の固体 (mc_Entity.x = -1 をボクセルではこれに置き換える)",
        " *   10-19    : マテリアルのヒント付き固体 (完全遮蔽)",
        " *   100-129  : 遮蔽しない植物・小物",
        " *   200-299  : 半透明 (透過色テーブル index = id - 200)",
        " *   300-399  : 部分形状 (形状テーブル index = id - 300)",
        f" *   {LIGHT_ID_BASE + 1}-{LIGHT_ID_BASE + LIGHT_ENTITY_LAST}: 光源 (光源インデックス = id - {LIGHT_ID_BASE}, lib/ids/light_ids.glsl)",
        f" *   {LIGHT_ID_BASE + LIGHT_FACING_STRIDE + 1}-{LIGHT_FACING_LAST}: 向きのある光源の東・南・西 (id - {LIGHT_ID_BASE} = 256 x 向き + 光源インデックス)",
        f" *   {COLOR_BAND_FIRST}-{COLOR_BAND_LAST}: 色の付いた固体 (完全遮蔽。上の帯に無いブロックを平均の色ごとにまとめたもの。色は lib/ids/block_albedo.glsl)",
        f" * ボクセルには下位 12bit しか入らないので {COLOR_BAND_LAST} を超える ID は作らない",
        " */",
        "#ifndef IDS_BLOCK_IDS_GLSL",
        "#define IDS_BLOCK_IDS_GLSL",
        "",
    ]
    for row in BLOCK_CONSTS:
        if row[0] == "raw":
            lines.append(row[1])
        else:
            _, width, name, value, comment, _in_table = row
            lines.append(trailing(f"const int {name} = {value};", width, comment))
    lines += ["", "#endif", ""]
    return "\n".join(lines)


def render_entity_ids() -> str:
    last = ENTITY_LIGHT_ID_BASE + LIGHT_ENTITY_LAST - LIGHT_ENTITY_FIRST
    rows = [(f"const int {name} = {eid};", comment) for eid, name, comment, _n, _c in ENTITIES]
    rows.append((f"const int ENTITY_LIGHT_BASE = {ENTITY_LIGHT_ID_BASE};",
                 f"{ENTITY_LIGHT_ID_BASE}-{last} は光源エンティティ (光源インデックス {LIGHT_ENTITY_FIRST} + (id - {ENTITY_LIGHT_ID_BASE}))"))
    rows.append((f"const int ENTITY_LIGHT_LAST = {last};", ""))
    lines = [
        "/*",
        " * エンティティ ID (entity.properties と対応) とアイテム ID (item.properties と対応)",
        f" * {GENERATED_NOTE}",
        " * 未登録のエンティティは 65535、未登録 / 素手のアイテムは -1 (heldItemId) または 0",
        " */",
        "#ifndef IDS_ENTITY_IDS_GLSL",
        "#define IDS_ENTITY_IDS_GLSL",
        "",
        *[trailing(line, 40, comment) for line, comment in rows],
        "",
        f"// アイテム: 光るアイテムは {LIGHT_ID_BASE} + 光源インデックス。それ以外の特別扱い",
        f"const int ITEM_LIGHT_BASE = {LIGHT_ID_BASE};",
        f"const int ITEM_LIGHT_LAST = {LIGHT_ID_BASE + LIGHT_ENTITY_LAST};",
        "",
        "#endif",
        "",
    ]
    return "\n".join(lines)


def render_entity_properties() -> str:
    lines = [
        "#",
        "# Ray entity.properties",
        "# Generated by tools/gen_block_properties.py. Do not edit by hand (ID ranges: shaders/lib/ids/entity_ids.glsl)",
        f"# {ENTITY_LIGHT_ID_BASE}-{ENTITY_LIGHT_ID_BASE + LIGHT_ENTITY_LAST - LIGHT_ENTITY_FIRST} are light-emitting entities "
        f"(light index = {LIGHT_ENTITY_FIRST} + (ID - {ENTITY_LIGHT_ID_BASE}))",
        "# Keep this file ASCII only: Iris reads .properties as ISO-8859-1 and non-ASCII bytes break its preprocessor",
        "#",
        "",
    ]
    seen: dict[str, int] = {}

    def row(eid: int, names: tuple[str, ...], note: str) -> None:
        for n in names:
            if n in seen:
                raise SystemExit(f"entity: {n} が ID {seen[n]} と {eid} に重複")
            seen[n] = eid
        if note:
            lines.append(f"# {note}")
        lines.append(f"entity.{eid} = " + " ".join(names))

    for eid, _name, _c, names, note in ENTITIES:
        row(eid, names, note)
    lines += ["", "# Light-emitting entities"]
    for light in LIGHTS:
        if light.entities:
            row(ENTITY_LIGHT_ID_BASE + light.index - LIGHT_ENTITY_FIRST, light.entities, light.entity_note)
    lines.append("")
    text = "\n".join(lines)
    if not text.isascii():
        raise SystemExit("entity.properties に ASCII 以外の文字がある (コメントは ASCII で書く)")
    return text


def render_light_table_data() -> str:
    headers = {
        1: (False, "// ブロック光源: (sRGB 色, 明るさ, 既定レベル, 光源半径, 発光中心, フリッカー, フラグ)"),
        63: (False, "// 鉱物ブロック (DECORATIVE_BLOCK_LIGHTS 2 の時だけ光源)。本物の光源より暗く狭い、鉱物の色のほのかな灯り"),
        LIGHT_ITEM_FIRST: (True, "// アイテム専用光源 (ドロップ / 手持ち)"),
        LIGHT_ENTITY_FIRST: (True, "// エンティティ光源"),
    }
    lines = [
        "/*",
        " * 光源のデータ表。makeLight の式は lib/light/light_def.glsl",
        f" * {GENERATED_NOTE}",
        " */",
        "#ifndef LIGHT_LIGHT_TABLE_DATA_GLSL",
        "#define LIGHT_LIGHT_TABLE_DATA_GLSL",
        "",
        '//@include "/lib/light/light_def.glsl"',
        '//@include "/lib/ids/light_ids.glsl"',
        "",
        "LightDef lightDefStatic(int i) {",
        "    vec3 fire = fireSrgb();",
    ]
    for light in LIGHTS:
        if light.count > 1:
            lines += [f"    {n}" for n in light.note]
            lines += [f"    if (i >= {light.name} && i < {light.name} + {light.count}) {{",
                      f"        return makeLight({light.make});", "    }"]
    lines.append("    switch (i) {")
    for light in LIGHTS:
        if light.index in headers:
            blank, text = headers[light.index]
            if blank:
                lines.append("")
            lines.append(f"        {text}")
        if light.count > 1:
            continue
        lines += [f"        {n}" for n in light.note]
        label = f"case {light.label or light.name}:"
        width = 29 if light.index <= LIGHT_BLOCK_LAST else 34
        label = label.ljust(width) if len(label) <= width else label + " "
        make = light.make + " | LIGHT_FLAG_FACING" if light.facing else light.make
        lines.append(f"        {label}return makeLight({make});")
    lines += [
        "    }",
        "    LightDef none;",
        "    none.color = vec4(0.0);",
        "    none.shape = vec4(LT_CENTER, 0.0);",
        "    none.params = vec4(0.0);",
        "    none.info = uvec4(0u);",
        "    return none;",
        "}",
        "",
        "#endif",
        "",
    ]
    return "\n".join(lines)


def glsl_float(v: float) -> str:
    s = f"{v:.4f}".rstrip("0")
    return s + "0" if s.endswith(".") else s


def mask_face_value(m: dict | None) -> str:
    """面の種類 1 つのデータ (uvec4): x = 光る範囲の四角、y = (割合, マスの最大の重み)、zw = 4x4 のマス (4 bit ずつ、1 行 = 4 マス)"""
    if m is None:
        return "uvec4(0u)"
    rows = m["grid"].split()
    # 行 0-1 が z、行 2-3 が w。マス (行 r、列 c) は bit 4 x (c + 4 x (r & 1))
    zw = [sum(int(rows[r][c], 16) << (4 * (c + 4 * (r & 1))) for r in (lo, lo + 1) for c in range(4)) for lo in (0, 2)]
    rect = ", ".join(glsl_float(v) for v in m["rect"])
    return (f"uvec4(packUnorm4x8(vec4({rect})), packHalf2x16(vec2({glsl_float(m['ratio'])}, {glsl_float(m['scale'])})), "
            f"0x{zw[0]:08X}u, 0x{zw[1]:08X}u)")


def render_light_mask_data(masks: dict[str, dict]) -> str:
    wanted = {str(l.index) for l in LIGHTS if l.mask_block()}
    if wanted != set(masks):
        raise SystemExit("tools/light_masks.json が光源の表とずれている (uv run tools/gen_block_colors.py <client.jar> で作り直す): "
                         + ", ".join(sorted(wanted ^ set(masks), key=int)))
    lines = [
        "/*",
        " * 光るブロックの面の光り方 (光る範囲の四角と 4x4 のマス)。面の種類は 0 = 上、1 = 下、2 = 側面 (4 面の平均)、3 = 前面 (向きのある光源だけ)",
        f" * {GENERATED_NOTE.replace('tools/id_tables.py', 'tools/light_masks.json')}",
        " * 中身の意味は lib/buffers/block_data.glsl の lightMasks",
        " */",
        "#ifndef LIGHT_LIGHT_MASK_DATA_GLSL",
        "#define LIGHT_LIGHT_MASK_DATA_GLSL",
        "",
        '//@include "/lib/ids/light_ids.glsl"',
        "",
        "uvec4 lightMaskStatic(int i, int faceClass) {",
        "    switch (i) {",
    ]
    for light in LIGHTS:
        m = masks.get(str(light.index))
        if m is None:
            continue
        lines += [f"        case {light.label or light.name}:",
                  f"            if (faceClass == 0) return {mask_face_value(m['up'])};",
                  f"            if (faceClass == 1) return {mask_face_value(m['down'])};"]
        # 前面は向きのある光源だけが持つ
        lines.append(f"            if (faceClass == 3) return {mask_face_value(m['front']) if 'front' in m else 'uvec4(0u)'};")
        lines.append(f"            return {mask_face_value(m['side'])};")
    lines += ["    }", "    return uvec4(0u);", "}", "", "#endif", ""]
    return "\n".join(lines)


def generated(shaders: Path = SHADERS) -> dict[Path, str]:
    check_tables()
    data = json.loads(BLOCK_COLORS.read_text(encoding="utf-8"))
    colors: dict[str, list[int]] = data["colors"]
    tops: dict[str, list[int]] = data.get("top", {})
    colored, palette, palette_top = color_blocks(colors, tops)
    ids = shaders / "lib" / "ids"
    return {
        shaders / "block.properties": render("block", all_blocks() + colored),
        shaders / "item.properties": render("item", light_item_entries()),
        shaders / "entity.properties": render_entity_properties(),
        ids / "block_albedo.glsl": render_albedo_glsl(colors, tops, palette, palette_top),
        ids / "block_ids.glsl": render_block_ids(),
        ids / "light_ids.glsl": render_light_ids(),
        ids / "entity_ids.glsl": render_entity_ids(),
        shaders / "lib" / "light" / "light_table_data.glsl": render_light_table_data(),
        shaders / "lib" / "light" / "light_mask_data.glsl": render_light_mask_data(
            json.loads(LIGHT_MASKS.read_text(encoding="utf-8"))["lights"]),
    }


def check(shaders: Path = SHADERS) -> list[str]:
    return generated_check(generated, shaders, "gen_block_properties.py")


def main() -> int:
    return cli(generated, "gen_block_properties.py")


if __name__ == "__main__":
    sys.exit(main())
