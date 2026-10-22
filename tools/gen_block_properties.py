"""
shaders/block.properties と shaders/item.properties を生成する (正本はこのスクリプト)

ID の番号帯は shaders/lib/ids/*.glsl と一致させること
未登録のブロックはボクセルで「完全な固体」として扱われるので、光を通す形のブロックは必ずどこかに載せる。

使い方: uv run tools/gen_block_properties.py
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"

COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
          "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]
WOODS = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "pale_oak", "bamboo", "crimson", "warped"]
# 酸化していない銅ブロックの ID は copper_block (ワックス付きは waxed_copper_block)。"copper" というブロックは無い
COPPER = ["copper_block", "exposed_copper", "weathered_copper", "oxidized_copper"]
COPPER_PREFIX = ["", "exposed_", "weathered_", "oxidized_"]

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


def with_state(blocks: list[str], state: str) -> list[str]:
    return [f"{b}:{state}" for b in blocks]


# Iris の状態フィルタは 1 プロパティ 1 値の完全一致 (BlockMaterialMapping.checkState)。
# "prop=a,b" のカンマ区切りは何にも一致しないので、値ごとに別エントリへ展開する
def state_values(block: str, prop: str, values: list[str]) -> list[str]:
    return [f"{block}:{prop}={v}" for v in values]


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

    (200, "water", ["water", "bubble_column"]),
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
    (302, "stairs (bottom)", with_state([f"{b}_stairs" for b in SLAB_STAIR_BASES], "half=bottom")),
    (303, "stairs (top)", with_state([f"{b}_stairs" for b in SLAB_STAIR_BASES], "half=top")),
    (304, "fences", [*wood_prefixed("fence", [w for w in WOODS]), "nether_brick_fence"]),
    (305, "walls", [f"{b}_wall" for b in WALL_BASES]),
    (306, "bars (panes other than glass)", ["iron_bars", *[f"{p}copper_bars" for p in COPPER_PREFIX], *[f"waxed_{p}copper_bars" for p in COPPER_PREFIX]]),
    (307, "low blocks", ["stonecutter", "daylight_detector", "lectern", "composter", "farmland", "dirt_path", "sculk_shrieker"]),
    # 積もった雪は層の数で高さが違う (1 層 = 1/8)。遮蔽の形を高さに合わせるため層ごとに分ける (308 = 1 層, 310-316 = 2-8 層)
    (308, "snow layers (1)", ["snow:layers=1"]),
    (309, "closed doors / trapdoors", [*with_state([f"{w}_door" for w in DOOR_TRAPDOOR], "open=false"),
                                 *with_state([f"{w}_trapdoor" for w in DOOR_TRAPDOOR], "open=false")]),
    *[(308 + k, f"snow layers ({k})", [f"snow:layers={k}"]) for k in range(2, 9)],

    # 光源 (1000 + 光源インデックス, lib/ids/light_ids.glsl)
    (1001, "torch", ["torch", "wall_torch"]),
    (1002, "soul torch", ["soul_torch", "soul_wall_torch"]),
    (1003, "redstone torch", ["redstone_torch:lit=true", "redstone_wall_torch:lit=true"]),
    (1004, "copper torch", ["copper_torch", "copper_wall_torch"]),
    (1005, "lantern", ["lantern"]),
    (1006, "soul lantern", ["soul_lantern"]),
    (1007, "copper lantern", [f"{p}copper_lantern" for p in COPPER_PREFIX] + [f"waxed_{p}copper_lantern" for p in COPPER_PREFIX]),
    (1008, "glowstone", ["glowstone"]),
    (1009, "sea lantern", ["sea_lantern"]),
    (1010, "shroomlight", ["shroomlight"]),
    (1011, "jack o'lantern", ["jack_o_lantern"]),
    (1012, "lava", ["lava", "lava_cauldron"]),
    (1013, "fire", ["fire"]),
    (1014, "soul fire", ["soul_fire"]),
    (1015, "campfire", ["campfire:lit=true"]),
    (1016, "soul campfire", ["soul_campfire:lit=true"]),
    (1017, "magma block", ["magma_block"]),
    (1018, "end rod", ["end_rod"]),
    (1019, "beacon", ["beacon"]),
    (1020, "conduit", ["conduit"]),
    (1021, "sea pickle", ["sea_pickle:waterlogged=true"]),
    (1022, "glow lichen", ["glow_lichen"]),
    (1023, "amethyst", ["amethyst_cluster", "large_amethyst_bud", "medium_amethyst_bud", "small_amethyst_bud"]),
    (1024, "crying obsidian", ["crying_obsidian"]),
    (1025, "respawn anchor", state_values("respawn_anchor", "charges", ["1", "2", "3", "4"])),
    (1026, "redstone lamp", ["redstone_lamp:lit=true"]),
    (1027, "ochre froglight", ["ochre_froglight"]),
    (1028, "verdant froglight", ["verdant_froglight"]),
    (1029, "pearlescent froglight", ["pearlescent_froglight"]),
    (1030, "candle", ["candle:lit=true", "candle_cake:lit=true"]),
    *[(1031 + i, f"{c} candle", [f"{c}_candle:lit=true", f"{c}_candle_cake:lit=true"]) for i, c in enumerate(COLORS)],
    (1047, "copper bulb", with_state([f"{p}copper_bulb" for p in COPPER_PREFIX] + [f"waxed_{p}copper_bulb" for p in COPPER_PREFIX], "lit=true")),
    (1048, "lit redstone ore", ["redstone_ore:lit=true", "deepslate_redstone_ore:lit=true"]),
    (1049, "lit furnaces", ["furnace:lit=true", "smoker:lit=true", "blast_furnace:lit=true"]),
    (1050, "brewing stand", ["brewing_stand"]),
    (1051, "enchanting table", ["enchanting_table"]),
    (1052, "end portal frame (with eye)", ["end_portal_frame:eye=true"]),
    (1053, "end portal", ["end_portal", "end_gateway"]),
    (1054, "nether portal", ["nether_portal"]),
    (1055, "light block", ["light"]),
    (1056, "sculk catalyst", ["sculk_catalyst"]),
    (1057, "sculk sensor", ["sculk_sensor", "calibrated_sculk_sensor"]),
    (1058, "glowing cave vines", ["cave_vines:berries=true", "cave_vines_plant:berries=true"]),
    (1059, "dragon egg", ["dragon_egg"]),
    (1060, "ender chest", ["ender_chest"]),
    (1061, "firefly bush", ["firefly_bush"]),
    (1062, "trial spawner / vault (active)", [*state_values("trial_spawner", "trial_spawner_state", ["active", "waiting_for_reward_ejection", "ejecting_reward"]),
                                          *state_values("vault", "vault_state", ["active", "unlocking", "ejecting"])]),
]

# 光るアイテム (heldItemId / currentRenderedItemId)。ブロックアイテムは同じ光源 ID を使う
ITEMS: list[tuple[int, str, list[str]]] = [
    (1001, "torch", ["torch"]),
    (1002, "soul torch", ["soul_torch"]),
    (1003, "redstone torch", ["redstone_torch"]),
    (1004, "copper torch", ["copper_torch"]),
    (1005, "lantern", ["lantern"]),
    (1006, "soul lantern", ["soul_lantern"]),
    (1007, "copper lantern", [f"{p}copper_lantern" for p in COPPER_PREFIX] + [f"waxed_{p}copper_lantern" for p in COPPER_PREFIX]),
    (1008, "glowstone", ["glowstone"]),
    (1009, "sea lantern", ["sea_lantern"]),
    (1010, "shroomlight", ["shroomlight"]),
    (1011, "jack o'lantern", ["jack_o_lantern"]),
    (1015, "campfire", ["campfire"]),
    (1016, "soul campfire", ["soul_campfire"]),
    (1017, "magma block", ["magma_block"]),
    (1018, "end rod", ["end_rod"]),
    (1019, "beacon", ["beacon"]),
    (1020, "conduit", ["conduit"]),
    (1021, "sea pickle", ["sea_pickle"]),
    (1022, "glow lichen", ["glow_lichen"]),
    (1023, "amethyst", ["amethyst_cluster", "large_amethyst_bud", "medium_amethyst_bud", "small_amethyst_bud"]),
    (1024, "crying obsidian", ["crying_obsidian"]),
    (1027, "ochre froglight", ["ochre_froglight"]),
    (1028, "verdant froglight", ["verdant_froglight"]),
    (1029, "pearlescent froglight", ["pearlescent_froglight"]),
    (1055, "light block", ["light"]),
    (1056, "sculk catalyst", ["sculk_catalyst"]),
    (1061, "firefly bush", ["firefly_bush"]),
    (1128, "lava bucket", ["lava_bucket"]),
    (1129, "glowstone dust", ["glowstone_dust"]),
    (1130, "blaze rod / powder", ["blaze_rod", "blaze_powder"]),
    (1131, "magma cream", ["magma_cream"]),
    (1132, "glow ink sac / glow berries", ["glow_ink_sac", "glow_berries"]),
    (1133, "nether star", ["nether_star"]),
    (1134, "spectral arrow", ["spectral_arrow"]),
    (1135, "fire charge", ["fire_charge"]),
    (1136, "bottle o' enchanting", ["experience_bottle"]),
    (1137, "end crystal", ["end_crystal"]),
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


def main() -> None:
    (SHADERS / "block.properties").write_text(render("block", BLOCKS), encoding="utf-8", newline="\n")
    (SHADERS / "item.properties").write_text(render("item", ITEMS), encoding="utf-8", newline="\n")
    print("block.properties / item.properties を生成した")


if __name__ == "__main__":
    main()
