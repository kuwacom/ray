"""
ID と光源の表の正本。tools/gen_block_properties.py が次を生成する

    shaders/block.properties, item.properties, entity.properties
    shaders/lib/ids/block_ids.glsl, light_ids.glsl, entity_ids.glsl
    shaders/lib/light/light_table_data.glsl (光源の色・形・フラグ)

光源を足すときは LIGHTS に 1 行足すだけでよい (ブロック・アイテム・エンティティの ID、光源インデックスの定数、光源の表が全部そろう)
番号は保存済みのワールドや表の参照に効くので既存の行の index は変えない
makeLight の式 (色の変換・明るさの扱い) は shaders/lib/light/light_def.glsl に手書きで置く
コメントは .properties にそのまま出るものは ASCII で書く (Iris は ISO-8859-1 で読み、UTF-8 の日本語は前処理を壊す)
"""

from __future__ import annotations

from dataclasses import dataclass

COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
          "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]
# 酸化していない銅ブロックの ID は copper_block (ワックス付きは waxed_copper_block)。"copper" というブロックは無い
COPPER_PREFIX = ["", "exposed_", "weathered_", "oxidized_"]

# 光源インデックス (0-255) の帯と、ID への写し方
LIGHT_ID_BASE = 1000          # ブロック・アイテムの ID = 1000 + 光源インデックス
LIGHT_BLOCK_LAST = 127        # 1-127: ブロック光源
LIGHT_ITEM_FIRST = 128        # 128-191: アイテム専用光源
LIGHT_ITEM_LAST = 191
LIGHT_ENTITY_FIRST = 192      # 192-255: エンティティ光源
LIGHT_ENTITY_LAST = 255
ENTITY_LIGHT_ID_BASE = 5100   # エンティティ ID = 5100 + (光源インデックス - 192)
COLOR_BAND_FIRST = 2000       # 色の付いた固体の ID 帯 (ボクセルには 12bit しか入らない)
COLOR_BAND_LAST = 4095
STAIRS_FIRST = 320            # 階段の ID 帯 320-335 (向き x 上下 x 外角の 16 通り)
STAIRS_LAST = 335
LIGHT_FACING_STRIDE = 256     # 向きのある光源ブロックの ID = 1000 + 256 x 向き (1 東 2 南 3 西) + 光源インデックス。北は向きなしと同じ ID
LIGHT_FACING_LAST = LIGHT_ID_BASE + 3 * LIGHT_FACING_STRIDE + LIGHT_BLOCK_LAST
FACINGS = ["north", "east", "south", "west"]  # 時計回り (上から見て)。ID の向きの番号と同じ順


def with_state(blocks: list[str], state: str) -> list[str]:
    return [f"{b}:{state}" for b in blocks]


# Iris の状態フィルタは 1 プロパティ 1 値の完全一致 (BlockMaterialMapping.checkState)。
# "prop=a,b" のカンマ区切りは何にも一致しないので、値ごとに別エントリへ展開する
def state_values(block: str, prop: str, values: list[str]) -> list[str]:
    return [f"{block}:{prop}={v}" for v in values]


# 発光の見た目の明るさの種類 -> light_def.glsl の LT_* (値は gen_block_properties.py の LIGHT_FLAG_KIND_*)
KIND_FLAGS = {"torch": "LT_TORCH", "fire": "LT_FIRE", "lantern": "LT_LANTERN", "beacon": "LT_BEACON"}


@dataclass(frozen=True)
class Light:
    index: int
    name: str | None                 # GLSL の定数名。None は定数を作らない (LIGHT_DECOR_FIRST の続き)
    title: str                       # block/item.properties のコメント
    make: str                        # makeLight の引数 (sRGB 色, 明るさ, 既定レベル, 光源半径, 発光中心, フリッカー, フラグ)
    blocks: tuple[str, ...] = ()     # block.properties に出す名前 (ID = 1000 + index)
    variants: tuple[tuple[str, tuple[str, ...]], ...] = ()  # 続き番号の ID に別々に出すブロック (コメント, 名前)
    items: tuple[str, ...] = ()      # item.properties に出す名前 (ID = 1000 + index)
    entities: tuple[str, ...] = ()   # entity.properties に出す名前 (ID = 5100 + index - 192)
    entity_note: str = ""            # entity.properties のその行の上のコメント
    comment: str = ""                # 定数の行末コメント
    note: tuple[str, ...] = ()       # 表の case の上に置くコメント
    label: str = ""                  # 表の case の式 (既定は定数名)
    count: int = 1                   # 2 以上は index から count 個を同じ式で処理する (i を使える)
    mask: str = ""                   # 面の光り方を測るブロックと状態 ("redstone_lamp:lit=true")。空なら LT_OCC の光源だけ blocks[0]
    facing: bool = False             # 前面だけが光る向きのあるブロック (かまど・ジャック・オ・ランタン)。向きごとに ID を分ける。mask は facing=north を指定する
    kind: str = ""                   # 発光の見た目の明るさを設定で分ける種類 (KIND_FLAGS のキー)。光源ブロック (LT_OCC) は種類を付けずフラグで分ける

    def make_expr(self) -> str:
        make = self.make + " | LIGHT_FLAG_FACING" if self.facing else self.make
        if not self.kind:
            return make
        flag = KIND_FLAGS[self.kind]
        return make[:-2] + flag if make.endswith("0u") else f"{make} | {flag}"

    def mask_block(self) -> str:
        if self.mask:
            return self.mask
        return self.blocks[0] if self.blocks and self.make.endswith("LT_OCC") else ""

    def is_decor(self) -> bool:
        return self.label.startswith("LIGHT_DECOR_FIRST")


def _lit(*names: str) -> tuple[str, ...]:
    return names


def _copper(suffix: str) -> tuple[str, ...]:
    return tuple([f"{p}{suffix}" for p in COPPER_PREFIX] + [f"waxed_{p}{suffix}" for p in COPPER_PREFIX])


_FIRE_BLAZE = "mix(fire, FIRE_WARM_SRGB, 0.5)"
_FIRE_MILD = "mix(fire, FIRE_WARM_SRGB, 0.3)"
_V = "vec3(0.5, 0.65, 0.5)"
_LAMP = "vec3(0.5, 0.35, 0.5)"
_LOW = "vec3(0.5, 0.4, 0.5)"
_DECOR = "DECOR_LIGHT_BRIGHTNESS, DECOR_LIGHT_LEVEL, 0.5, LT_CENTER, 0.0, LT_OCC"

LIGHTS: list[Light] = [
    Light(1, "LIGHT_TORCH", "torch", f"fire, 1.0, 14.0, 0.08, {_V}, 0.6, 0u",
          blocks=_lit("torch", "wall_torch"), items=_lit("torch"), kind="torch"),
    Light(2, "LIGHT_SOUL_TORCH", "soul torch", f"SOUL_SRGB, 0.8, 10.0, 0.08, {_V}, 0.4, 0u",
          blocks=_lit("soul_torch", "soul_wall_torch"), items=_lit("soul_torch"), kind="torch"),
    Light(3, "LIGHT_REDSTONE_TORCH", "redstone torch", f"vec3(1.0, 0.25, 0.15), 0.6, 7.0, 0.06, {_V}, 0.0, 0u",
          blocks=_lit("redstone_torch:lit=true", "redstone_wall_torch:lit=true"), items=_lit("redstone_torch"), kind="torch"),
    Light(4, "LIGHT_COPPER_TORCH", "copper torch", f"COPPER_FLAME_SRGB, 0.9, 14.0, 0.08, {_V}, 0.5, 0u",
          blocks=_lit("copper_torch", "copper_wall_torch"), items=_lit("copper_torch"), kind="torch"),
    Light(5, "LIGHT_LANTERN", "lantern", f"fire, 1.0, 15.0, 0.15, {_LAMP}, 0.3, 0u",
          blocks=_lit("lantern"), items=_lit("lantern"), mask="lantern", kind="lantern"),
    Light(6, "LIGHT_SOUL_LANTERN", "soul lantern", f"SOUL_SRGB, 0.8, 10.0, 0.15, {_LAMP}, 0.2, 0u",
          blocks=_lit("soul_lantern"), items=_lit("soul_lantern"), mask="soul_lantern", kind="lantern"),
    Light(7, "LIGHT_COPPER_LANTERN", "copper lantern", f"COPPER_FLAME_SRGB, 0.9, 15.0, 0.15, {_LAMP}, 0.3, 0u",
          blocks=_copper("copper_lantern"), items=_copper("copper_lantern"), mask="copper_lantern", kind="lantern"),
    Light(8, "LIGHT_GLOWSTONE", "glowstone", "vec3(1.0, 0.80, 0.52), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("glowstone"), items=_lit("glowstone")),
    Light(9, "LIGHT_SEA_LANTERN", "sea lantern", "vec3(0.85, 0.95, 1.0), 0.75, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("sea_lantern"), items=_lit("sea_lantern"),
          note=("// シーランタンは青緑 (0.75, 0.95, 1.0) だと橙の板が黄緑に転んだので白寄りの水色",
                "// 明るさ 1.0 では近くの炎の灯りを打ち消して室内がオリーブ色に濁ったので控えめに")),
    Light(10, "LIGHT_SHROOMLIGHT", "shroomlight", "vec3(1.0, 0.70, 0.45), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("shroomlight"), items=_lit("shroomlight")),
    Light(11, "LIGHT_JACK_O_LANTERN", "jack o'lantern", "fire, 1.0, 15.0, 0.4, LT_CENTER, 0.3, LT_OCC",
          blocks=_lit("jack_o_lantern"), items=_lit("jack_o_lantern"), mask="jack_o_lantern:facing=north", facing=True),
    Light(12, "LIGHT_LAVA", "lava", "LAVA_SRGB, 1.2, 15.0, 0.5, vec3(0.5, 0.45, 0.5), 0.2, LIGHT_FLAG_FLUID",
          blocks=_lit("lava", "lava_cauldron")),
    Light(13, "LIGHT_FIRE", "fire", f"{_FIRE_MILD}, 1.1, 15.0, 0.4, {_LOW}, 0.8, 0u", blocks=_lit("fire"), kind="fire"),
    Light(14, "LIGHT_SOUL_FIRE", "soul fire", f"SOUL_SRGB, 0.9, 10.0, 0.4, {_LOW}, 0.6, 0u", blocks=_lit("soul_fire"), kind="fire"),
    Light(15, "LIGHT_CAMPFIRE", "campfire", f"fire, 1.1, 15.0, 0.35, {_LOW}, 0.7, 0u",
          blocks=_lit("campfire:lit=true"), items=_lit("campfire"), kind="fire"),
    Light(16, "LIGHT_SOUL_CAMPFIRE", "soul campfire", f"SOUL_SRGB, 0.9, 10.0, 0.35, {_LOW}, 0.5, 0u",
          blocks=_lit("soul_campfire:lit=true"), items=_lit("soul_campfire"), kind="fire"),
    Light(17, "LIGHT_MAGMA_BLOCK", "magma block", "vec3(1.0, 0.40, 0.15), 0.8, 3.0, 0.5, LT_CENTER, 0.1, LT_OCC",
          blocks=_lit("magma_block"), items=_lit("magma_block")),
    Light(18, "LIGHT_END_ROD", "end rod", "vec3(0.95, 0.90, 1.0), 0.9, 14.0, 0.1, LT_CENTER, 0.0, 0u",
          blocks=_lit("end_rod"), items=_lit("end_rod")),
    Light(19, "LIGHT_BEACON", "beacon", "vec3(0.85, 0.95, 1.0), 1.2, 15.0, 0.4, LT_CENTER, 0.0, 0u",
          blocks=_lit("beacon"), items=_lit("beacon"), kind="beacon"),
    Light(20, "LIGHT_CONDUIT", "conduit", "vec3(0.60, 0.90, 1.0), 1.0, 15.0, 0.2, LT_CENTER, 0.0, 0u",
          blocks=_lit("conduit"), items=_lit("conduit")),
    Light(21, "LIGHT_SEA_PICKLE", "sea pickle", "vec3(0.60, 1.0, 0.75), 0.8, 15.0, 0.15, vec3(0.5, 0.3, 0.5), 0.0, 0u",
          blocks=_lit("sea_pickle:waterlogged=true"), items=_lit("sea_pickle")),
    Light(22, "LIGHT_GLOW_LICHEN", "glow lichen", "vec3(0.60, 1.0, 0.85), 0.6, 7.0, 0.3, LT_CENTER, 0.0, 0u",
          blocks=_lit("glow_lichen"), items=_lit("glow_lichen")),
    Light(23, "LIGHT_AMETHYST", "amethyst", f"vec3(0.80, 0.55, 1.0), 0.7, 5.0, 0.2, {_LAMP}, 0.0, 0u",
          blocks=_lit("amethyst_cluster", "large_amethyst_bud", "medium_amethyst_bud", "small_amethyst_bud"),
          items=_lit("amethyst_cluster", "large_amethyst_bud", "medium_amethyst_bud", "small_amethyst_bud")),
    Light(24, "LIGHT_CRYING_OBSIDIAN", "crying obsidian", "vec3(0.60, 0.25, 1.0), 0.8, 10.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("crying_obsidian"), items=_lit("crying_obsidian")),
    Light(25, "LIGHT_RESPAWN_ANCHOR", "respawn anchor", "vec3(0.65, 0.30, 1.0), 1.0, 15.0, 0.4, vec3(0.5, 0.9, 0.5), 0.0, LT_OCC",
          blocks=tuple(state_values("respawn_anchor", "charges", ["1", "2", "3", "4"])), mask="respawn_anchor:charges=4"),
    Light(26, "LIGHT_REDSTONE_LAMP", "redstone lamp", "vec3(1.0, 0.75, 0.55), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("redstone_lamp:lit=true")),
    Light(27, "LIGHT_OCHRE_FROGLIGHT", "ochre froglight", "vec3(1.0, 0.85, 0.55), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("ochre_froglight"), items=_lit("ochre_froglight")),
    Light(28, "LIGHT_VERDANT_FROGLIGHT", "verdant froglight", "vec3(0.75, 1.0, 0.60), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("verdant_froglight"), items=_lit("verdant_froglight")),
    Light(29, "LIGHT_PEARLESCENT_FROGLIGHT", "pearlescent froglight", "vec3(1.0, 0.75, 0.95), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("pearlescent_froglight"), items=_lit("pearlescent_froglight")),
    Light(30, "LIGHT_CANDLE", "candle", f"fire, 1.0, 12.0, 0.05, {_LOW}, 0.5, 0u",
          blocks=_lit("candle:lit=true", "candle_cake:lit=true"), kind="fire"),
    # 色付きロウソク 16 色 (ID は 1031 から続く)
    Light(31, "LIGHT_CANDLE_COLORED", "colored candles",
          f"mix(fire, dyeSrgb(i - LIGHT_CANDLE_COLORED), 0.5), 1.0, 12.0, 0.05, {_LOW}, 0.5, 0u",
          variants=tuple((f"{c} candle", (f"{c}_candle:lit=true", f"{c}_candle_cake:lit=true")) for c in COLORS),
          comment="31-46 (white..black, block_ids の色順)", count=16, kind="fire",
          note=("// 色付きロウソクは炎の色と染料の色の中間 (染料色そのままだと暗い色が光らなくなる)",)),
    Light(47, "LIGHT_COPPER_BULB", "copper bulb", "vec3(1.0, 0.80, 0.60), 1.0, 15.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=tuple(with_state([f"{p}copper_bulb" for p in COPPER_PREFIX] + [f"waxed_{p}copper_bulb" for p in COPPER_PREFIX], "lit=true"))),
    Light(48, "LIGHT_REDSTONE_ORE", "lit redstone ore", "vec3(1.0, 0.20, 0.10), 0.6, 9.0, 0.5, LT_CENTER, 0.0, LT_OCC",
          blocks=_lit("redstone_ore:lit=true", "deepslate_redstone_ore:lit=true")),
    Light(49, "LIGHT_FURNACE", "lit furnaces", f"{_FIRE_BLAZE}, 0.9, 13.0, 0.3, vec3(0.5, 0.3, 0.5), 0.5, LT_OCC",
          blocks=_lit("furnace:lit=true", "smoker:lit=true", "blast_furnace:lit=true"),
          mask="furnace:lit=true:facing=north", facing=True),
    Light(50, "LIGHT_BREWING_STAND", "brewing stand", "vec3(1.0, 0.85, 0.50), 0.6, 1.0, 0.1, vec3(0.5, 0.2, 0.5), 0.0, 0u",
          blocks=_lit("brewing_stand")),
    Light(51, "LIGHT_ENCHANTING_TABLE", "enchanting table", "vec3(0.70, 0.60, 1.0), 0.6, 7.0, 0.3, vec3(0.5, 0.75, 0.5), 0.0, 0u",
          blocks=_lit("enchanting_table")),
    Light(52, "LIGHT_END_PORTAL_FRAME", "end portal frame (with eye)", "vec3(0.50, 0.90, 0.75), 0.5, 1.0, 0.2, vec3(0.5, 0.9, 0.5), 0.0, 0u",
          blocks=_lit("end_portal_frame:eye=true")),
    Light(53, "LIGHT_END_PORTAL", "end portal", "vec3(0.50, 0.75, 0.90), 0.8, 15.0, 0.5, LT_CENTER, 0.0, 0u",
          blocks=_lit("end_portal", "end_gateway")),
    Light(54, "LIGHT_NETHER_PORTAL", "nether portal", "vec3(0.60, 0.25, 1.0), 0.9, 11.0, 0.5, LT_CENTER, 0.2, 0u",
          blocks=_lit("nether_portal")),
    Light(55, "LIGHT_LIGHT_BLOCK", "light block", "vec3(1.0, 0.95, 0.90), 1.0, 15.0, 0.0, LT_CENTER, 0.0, 0u",
          blocks=_lit("light"), items=_lit("light")),
    Light(56, "LIGHT_SCULK_CATALYST", "sculk catalyst", "vec3(0.30, 0.85, 0.90), 0.6, 6.0, 0.4, vec3(0.5, 0.9, 0.5), 0.0, LT_OCC",
          blocks=_lit("sculk_catalyst"), items=_lit("sculk_catalyst")),
    Light(57, "LIGHT_SCULK_SENSOR", "sculk sensor", f"vec3(0.30, 0.85, 0.90), 0.5, 1.0, 0.2, {_LOW}, 0.0, 0u",
          blocks=_lit("sculk_sensor", "calibrated_sculk_sensor")),
    Light(58, "LIGHT_CAVE_VINES", "glowing cave vines", "vec3(1.0, 0.75, 0.40), 0.9, 14.0, 0.15, LT_CENTER, 0.0, 0u",
          blocks=_lit("cave_vines:berries=true", "cave_vines_plant:berries=true")),
    Light(59, "LIGHT_DRAGON_EGG", "dragon egg", "vec3(0.70, 0.30, 1.0), 0.5, 1.0, 0.3, LT_CENTER, 0.0, 0u",
          blocks=_lit("dragon_egg")),
    Light(60, "LIGHT_ENDER_CHEST", "ender chest", "vec3(0.40, 0.90, 0.80), 0.6, 7.0, 0.3, LT_CENTER, 0.0, 0u",
          blocks=_lit("ender_chest")),
    Light(61, "LIGHT_FIREFLY_BUSH", "firefly bush", "vec3(0.85, 1.0, 0.50), 0.5, 2.0, 0.4, vec3(0.5, 0.7, 0.5), 0.6, 0u",
          blocks=_lit("firefly_bush"), items=_lit("firefly_bush")),
    Light(62, "LIGHT_TRIAL_SPAWNER", "trial spawner / vault (active)", "vec3(1.0, 0.70, 0.40), 0.8, 8.0, 0.4, LT_CENTER, 0.3, 0u",
          blocks=tuple([*state_values("trial_spawner", "trial_spawner_state", ["active", "waiting_for_reward_ejection", "ejecting_reward"]),
                        *state_values("vault", "vault_state", ["active", "unlocking", "ejecting"])])),
    # 鉱物ブロック (ブロック ID は 13-18。block.properties は BLOCKS 側)
    Light(63, "LIGHT_DECOR_FIRST", "decorative lapis", f"vec3(0.25, 0.45, 1.00), {_DECOR}",
          comment="63-68: BLOCK_DECOR_* (lapis, emerald, diamond, gold, redstone, amethyst)。DECORATIVE_BLOCK_LIGHTS 2 の時だけ使う",
          label="LIGHT_DECOR_FIRST + 0", mask="lapis_block"),
    Light(64, None, "decorative emerald", f"vec3(0.30, 1.00, 0.50), {_DECOR}", label="LIGHT_DECOR_FIRST + 1", mask="emerald_block"),
    Light(65, None, "decorative diamond", f"vec3(0.50, 0.95, 1.00), {_DECOR}", label="LIGHT_DECOR_FIRST + 2", mask="diamond_block"),
    Light(66, None, "decorative gold", f"vec3(1.00, 0.80, 0.35), {_DECOR}", label="LIGHT_DECOR_FIRST + 3", mask="gold_block"),
    Light(67, None, "decorative redstone", f"vec3(1.00, 0.15, 0.08), {_DECOR}", label="LIGHT_DECOR_FIRST + 4", mask="redstone_block"),
    Light(68, None, "decorative amethyst", f"vec3(0.75, 0.50, 1.00), {_DECOR}", label="LIGHT_DECOR_FIRST + 5", mask="amethyst_block"),

    Light(128, "LIGHT_ITEM_LAVA_BUCKET", "lava bucket", "LAVA_SRGB, 1.0, 15.0, 0.2, LT_CENTER, 0.2, LT_CAT_ITEM", items=_lit("lava_bucket")),
    Light(129, "LIGHT_ITEM_GLOWSTONE_DUST", "glowstone dust", "vec3(1.0, 0.80, 0.52), 0.7, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("glowstone_dust")),
    Light(130, "LIGHT_ITEM_BLAZE", "blaze rod / powder", f"{_FIRE_BLAZE}, 0.8, 10.0, 0.1, LT_CENTER, 0.3, LT_CAT_ITEM", items=_lit("blaze_rod", "blaze_powder")),
    Light(131, "LIGHT_ITEM_MAGMA_CREAM", "magma cream", "LAVA_SRGB, 0.7, 8.0, 0.1, LT_CENTER, 0.1, LT_CAT_ITEM", items=_lit("magma_cream")),
    Light(132, "LIGHT_ITEM_GLOW", "glow ink sac / glow berries", "vec3(0.50, 1.0, 0.85), 0.6, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("glow_ink_sac", "glow_berries")),
    Light(133, "LIGHT_ITEM_NETHER_STAR", "nether star", "vec3(0.95, 0.90, 1.0), 1.0, 12.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("nether_star")),
    Light(134, "LIGHT_ITEM_SPECTRAL_ARROW", "spectral arrow", "vec3(1.0, 0.90, 0.50), 0.6, 8.0, 0.05, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("spectral_arrow")),
    Light(135, "LIGHT_ITEM_FIRE_CHARGE", "fire charge", "fire, 0.8, 10.0, 0.1, LT_CENTER, 0.5, LT_CAT_ITEM", items=_lit("fire_charge")),
    Light(136, "LIGHT_ITEM_EXPERIENCE_BOTTLE", "bottle o' enchanting", "vec3(0.70, 1.0, 0.30), 0.6, 8.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("experience_bottle")),
    Light(137, "LIGHT_ITEM_END_CRYSTAL", "end crystal", "vec3(1.0, 0.70, 0.95), 0.9, 12.0, 0.1, LT_CENTER, 0.0, LT_CAT_ITEM", items=_lit("end_crystal")),

    Light(192, "LIGHT_ENTITY_BLAZE", "blaze", f"{_FIRE_BLAZE}, 1.0, 12.0, 0.4, LT_CENTER, 0.5, LT_CAT_GLOW", entities=_lit("minecraft:blaze")),
    Light(193, "LIGHT_ENTITY_MAGMA_CUBE", "magma cube", "LAVA_SRGB, 0.8, 10.0, 0.4, LT_CENTER, 0.1, LT_CAT_GLOW", entities=_lit("minecraft:magma_cube")),
    Light(194, "LIGHT_ENTITY_GLOW_SQUID", "glow squid", "vec3(0.40, 1.0, 0.90), 0.6, 6.0, 0.4, LT_CENTER, 0.0, LT_CAT_GLOW", entities=_lit("minecraft:glow_squid")),
    Light(195, "LIGHT_ENTITY_ALLAY", "allay", "vec3(0.50, 0.85, 1.0), 0.6, 5.0, 0.2, LT_CENTER, 0.0, LT_CAT_GLOW", entities=_lit("minecraft:allay")),
    Light(196, "LIGHT_ENTITY_END_CRYSTAL", "end crystal", "vec3(1.0, 0.70, 0.95), 1.2, 15.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW", entities=_lit("minecraft:end_crystal")),
    Light(197, "LIGHT_ENTITY_EXPERIENCE_ORB", "experience orb", "vec3(0.70, 1.0, 0.30), 0.5, 5.0, 0.1, LT_CENTER, 0.0, LT_CAT_GLOW", entities=_lit("minecraft:experience_orb")),
    Light(198, "LIGHT_ENTITY_SPECTRAL_ARROW", "spectral arrow", "vec3(1.0, 0.90, 0.50), 0.7, 8.0, 0.05, LT_CENTER, 0.0, LT_CAT_PROJ", entities=_lit("minecraft:spectral_arrow")),
    Light(199, "LIGHT_ENTITY_FIREBALL", "fireball", "fire, 1.0, 13.0, 0.3, LT_CENTER, 0.5, LT_CAT_PROJ", entities=_lit("minecraft:fireball", "minecraft:small_fireball")),
    Light(200, "LIGHT_ENTITY_DRAGON_FIREBALL", "dragon fireball", "vec3(0.85, 0.40, 1.0), 1.0, 12.0, 0.3, LT_CENTER, 0.3, LT_CAT_PROJ", entities=_lit("minecraft:dragon_fireball")),
    Light(201, "LIGHT_ENTITY_TNT", "tnt", "vec3(1.0, 1.0, 1.0), 1.0, 10.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH", entities=_lit("minecraft:tnt")),
    Light(202, "LIGHT_ENTITY_CREEPER", "creeper", "vec3(1.0, 1.0, 1.0), 0.8, 8.0, 0.4, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH", entities=_lit("minecraft:creeper")),
    Light(203, "LIGHT_ENTITY_FIREWORK", "firework rocket", "vec3(1.0, 0.85, 0.60), 0.8, 10.0, 0.1, LT_CENTER, 0.6, LT_CAT_PROJ", entities=_lit("minecraft:firework_rocket")),
    Light(204, "LIGHT_ENTITY_LIGHTNING", "lightning bolt", "vec3(0.80, 0.85, 1.0), 4.0, 15.0, 1.0, LT_CENTER, 0.0, LT_CAT_GLOW", entities=_lit("minecraft:lightning_bolt")),
    Light(205, "LIGHT_ENTITY_FLAME", "entity flame", f"{_FIRE_MILD}, 1.0, 15.0, 0.4, LT_CENTER, 0.8, LT_CAT_BURN",
          entities=_lit("minecraft:entity_flame"), entity_note="Flames on burning entities (Iris hardcoded ID)"),
    Light(206, "LIGHT_ENTITY_SHULKER_BULLET", "shulker bullet", "vec3(1.0, 0.95, 0.85), 0.6, 6.0, 0.1, LT_CENTER, 0.0, LT_CAT_PROJ", entities=_lit("minecraft:shulker_bullet")),
    Light(207, "LIGHT_ENTITY_TNT_MINECART", "tnt minecart", "vec3(1.0, 1.0, 1.0), 1.0, 10.0, 0.5, LT_CENTER, 0.0, LT_CAT_GLOW | LIGHT_FLAG_ENTITY_FLASH", entities=_lit("minecraft:tnt_minecart")),
]

# 光源にならないエンティティ: (ID, 定数名, GLSL のコメント, 名前, entity.properties の上のコメント)
ENTITIES: list[tuple[int, str, str, tuple[str, ...], str]] = [
    (5001, "ENTITY_CURRENT_PLAYER", "Iris のハードコード ID minecraft:current_player", ("minecraft:current_player",),
     "The local player (Iris hardcoded ID). Prevents double hand lighting and drives the self-occlusion bits"),
    (5002, "ENTITY_PLAYER", "他のプレイヤー", ("minecraft:player",), ""),
    (5003, "ENTITY_ITEM", "ドロップアイテム (光るかは currentRenderedItemId で判定)", ("minecraft:item",),
     "Dropped items (whether they glow is decided by currentRenderedItemId)"),
    (5004, "ENTITY_ITEM_FRAME", "額縁 (中のアイテムは光源化しない)", ("minecraft:item_frame", "minecraft:glow_item_frame"),
     "Item frames (the item inside does not become a light)"),
    (5005, "ENTITY_SHADOW", "Iris の minecraft:entity_shadow (丸影, 描かない)", ("minecraft:entity_shadow",),
     "Iris hardcoded IDs (no real shape, excluded from occlusion and shadows)"),
    (5006, "ENTITY_NAME_TAG", "Iris の minecraft:name_tag (ボクセル化しない)", ("minecraft:name_tag",), ""),
    (5007, "ENTITY_BEAM", "Iris の minecraft:end_crystal_beam", ("minecraft:end_crystal_beam",), ""),
]

# 一部だけ金属のブロック・アイテム・エンティティの自動メタリック。金属の画素を選ぶ判定 (gate) を ID に載せる
# ブロックとアイテムは元の ID + gate 番号 x METAL_GATE_STRIDE (下位 12bit が元の ID。ボクセルや光源には元の ID だけを渡す)
# エンティティは ENTITY_METAL_BASE + gate 番号。判定の中身は shaders/lib/surface/material.glsl の metalGatePixel
METAL_GATE_STRIDE = 4096
ENTITY_METAL_BASE = 5200
METAL_GATES = ["all", "gray", "cool", "rail", "gold", "copper", "netherite", "gem"]  # 番号は 1 から (0 は金属なし)


def _copper_all(*bases: str) -> list[str]:
    return [n for b in bases for n in _copper(b)]


def _armor(material: str, *extra: str) -> list[str]:
    return [f"{material}_{p}" for p in ("helmet", "chestplate", "leggings", "boots", *extra)]


def _tools(material: str) -> list[str]:
    return [f"{material}_{t}" for t in ("sword", "axe", "pickaxe", "shovel", "hoe", "spear")]


def metal_blocks() -> dict[str, list[str]]:
    cut = [f"{p}cut_copper_{s}" for p in COPPER_PREFIX for s in ("slab", "stairs")]
    return {
        # テクスチャの全体が金属 (緑青の画素だけは除く)
        "all": [*_copper_all("copper_bars", "copper_chain", "copper_door", "copper_trapdoor", "lightning_rod", "copper_bulb",
                             "copper_chest", "copper_golem_statue", "copper_lantern"),
                *cut, *[f"waxed_{n}" for n in cut],
                "chain", "iron_chain", "iron_door", "iron_trapdoor", "iron_bars", "heavy_weighted_pressure_plate",
                "light_weighted_pressure_plate"],
        # 灰色の画素だけが金属 (木の枕木・水・中身の色は除く)
        "gray": ["tripwire_hook", "hopper", "cauldron", "water_cauldron",
                 "lava_cauldron", "powder_snow_cauldron"],
        # 青みの暗い画素だけが金属 (ランタンの枠。炎は除く)
        "cool": ["lantern", "soul_lantern"],
        # 線路 (灰色の鉄と動力レールの明るい金)。走行で磨かれた面としてほぼ鏡にする
        "rail": ["rail", "activator_rail", "detector_rail", "powered_rail"],
        "gold": ["bell"],
    }


# アイテム (手持ち・ドロップ・額縁・装備)。装備は防具のテクスチャ全体が金属なので all、道具は持ち手 (木) を除く判定
METAL_ITEMS: dict[str, list[str]] = {
    "all": [*_armor("iron", "horse_armor"), *_armor("chainmail"), *_armor("golden", "horse_armor"), *_armor("copper", "horse_armor"),
            *_armor("netherite", "horse_armor"), "iron_nautilus_armor", "golden_nautilus_armor", "copper_nautilus_armor",
            "netherite_nautilus_armor"],
    "gray": [*_tools("iron"), "mace", "iron_ingot", "iron_nugget", "bucket", "water_bucket", "milk_bucket", "powder_snow_bucket",
             "axolotl_bucket", "tadpole_bucket", "cod_bucket", "salmon_bucket", "pufferfish_bucket", "tropical_fish_bucket",
             "shears", "flint_and_steel", "compass", "recovery_compass", "minecart", "chest_minecart", "furnace_minecart",
             "hopper_minecart", "command_block_minecart", "tnt_minecart"],
    "gold": [*_tools("golden"), "gold_ingot", "gold_nugget", "clock"],
    "copper": [*_tools("copper"), "copper_ingot", "copper_nugget"],
    "netherite": [*_tools("netherite"), "netherite_ingot"],
    "gem": [*_tools("diamond"), *_armor("diamond", "horse_armor"), "diamond_nautilus_armor", "diamond"],
}

METAL_ENTITIES: dict[str, list[str]] = {
    "all": ["minecraft:copper_golem"],
    "gray": ["minecraft:minecart", "minecraft:chest_minecart", "minecraft:furnace_minecart", "minecraft:hopper_minecart",
             "minecraft:command_block_minecart", "minecraft:spawner_minecart"],
}

# block_ids.glsl の定数: ("raw", 行) / ("const", 行末コメントの桁, 定数名, 値, コメント, 表に載る)
# 表に載る定数は block.properties に同じ ID の行が無いと生成が止まる (ID のずれの検出)
BLOCK_CONSTS: list[tuple] = [
    ("const", 0, "BLOCK_AIR", 0, "", False),
    ("const", 0, "BLOCK_SOLID", 1, "", False),
    ("raw", ""),
    ("const", 0, "BLOCK_METAL", 10, "", True),
    ("const", 0, "BLOCK_GLOSSY", 11, "", True),
    ("const", 0, "BLOCK_SNOW", 12, "", True),
    ("raw", "// 光らないが鮮やかな鉱物ブロック (DECORATIVE_BLOCK_LIGHTS で発光・光源にする。光源インデックスは LIGHT_DECOR_FIRST から同じ順)"),
    ("const", 0, "BLOCK_DECOR_LAPIS", 13, "", True),
    ("const", 0, "BLOCK_DECOR_EMERALD", 14, "", True),
    ("const", 0, "BLOCK_DECOR_DIAMOND", 15, "", True),
    ("const", 0, "BLOCK_DECOR_GOLD", 16, "", True),
    ("const", 0, "BLOCK_DECOR_REDSTONE", 17, "", True),
    ("const", 0, "BLOCK_DECOR_AMETHYST", 18, "アメジストブロック・芽生えたアメジスト", True),
    ("raw", ""),
    ("const", 40, "BLOCK_PLANT_SHORT", 100, "草・花・苗木 (根元固定で揺れる)", True),
    ("const", 40, "BLOCK_PLANT_TALL_LOWER", 101, "2 ブロックの植物の下半分", True),
    ("const", 40, "BLOCK_PLANT_TALL_UPPER", 102, "2 ブロックの植物の上半分", True),
    ("const", 40, "BLOCK_LEAVES", 103, "", True),
    ("const", 40, "BLOCK_VINES", 104, "", True),
    ("const", 40, "BLOCK_CROPS", 105, "", True),
    ("const", 40, "BLOCK_NON_OCCLUDING", 106, "レール・ボタン・カーペット等 (揺れない)", True),
    ("const", 40, "BLOCK_COBWEB", 107, "", True),
    ("const", 40, "BLOCK_LILY_PAD", 108, "", True),
    ("const", 40, "BLOCK_CANE", 109, "サトウキビ・竹", True),
    ("const", 40, "BLOCK_UNDERWATER_PLANT", 110, "海草・コンブ", True),
    ("raw", ""),
    ("const", 0, "BLOCK_WATER", 200, "", True),
    ("const", 0, "BLOCK_ICE", 201, "", True),
    ("const", 0, "BLOCK_GLASS", 202, "", True),
    ("const", 0, "BLOCK_GLASS_PANE", 203, "", True),
    ("const", 0, "BLOCK_SLIME", 204, "", True),
    ("const", 0, "BLOCK_HONEY", 205, "", True),
    ("const", 0, "BLOCK_TINTED_GLASS", 206, "", True),
    ("const", 42, "BLOCK_WATER_FLOWING", 207, "上面が水源より低い流れる水。頂点で BLOCK_WATER に戻し、ボクセルには印だけ残す", True),
    ("const", 42, "BLOCK_STAINED_GLASS", 210, "210-225 (white, orange, magenta, light_blue, yellow, lime, pink, gray, light_gray, cyan, purple, blue, brown, green, red, black)", True),
    ("const", 42, "BLOCK_STAINED_GLASS_PANE", 230, "230-245 (同順)", True),
    ("raw", ""),
    ("const", 0, "BLOCK_SLAB_BOTTOM", 300, "", True),
    ("const", 0, "BLOCK_SLAB_TOP", 301, "", True),
    ("const", 0, "BLOCK_FENCE", 304, "", True),
    ("const", 0, "BLOCK_WALL", 305, "", True),
    ("const", 0, "BLOCK_PANE_BARS", 306, "", True),
    ("const", 40, "BLOCK_LOW", 307, "ベッド・石切台等の背の低いブロック", True),
    ("const", 40, "BLOCK_SNOW_LAYER", 308, "積もった雪 1 層 (高さ 1/8)", True),
    ("const", 40, "BLOCK_DOOR_CLOSED", 309, "閉じたドア・トラップドア (薄いが光は遮る)", True),
    ("const", 40, "BLOCK_SNOW_LAYER_2", 310, "310-316 = 積もった雪 2-8 層 (層の数 = ID - 308)", True),
    ("const", 40, "BLOCK_SNOW_LAYER_8", 316, "", True),
    ("const", 40, "BLOCK_STAIRS_FIRST", STAIRS_FIRST, "320-335 = 階段 (向き x 上下 x 外角の 16 通り。形は lib/light/light_table.glsl)", True),
    ("const", 40, "BLOCK_STAIRS_LAST", STAIRS_LAST, "", True),
    ("raw", ""),
    ("const", 40, "BLOCK_LIGHT_BASE", LIGHT_ID_BASE, "1001-1255 が光源 (光源インデックス = id - 1000)", False),
    ("const", 40, "BLOCK_LIGHT_FACING_STRIDE", LIGHT_FACING_STRIDE, "向きのある光源は 1000 + 256 x 向き (1 東 2 南 3 西) + 光源インデックス", False),
    ("const", 40, "BLOCK_LIGHT_LAST", LIGHT_FACING_LAST, "光源の ID の上限 (向きのある光源の西)", False),
    ("raw", ""),
    ("const", 40, "BLOCK_COLOR_FIRST", COLOR_BAND_FIRST, "2000 以降は色の付いた固体 (マテリアル・遮蔽は BLOCK_SOLID と同じ)", False),
    ("raw", ""),
    ("const", 40, "METAL_GATE_STRIDE", METAL_GATE_STRIDE, "一部だけ金属の ID = 元の ID + 判定の番号 x この値 (ブロック・アイテム)", False),
    *[("const", 40, f"METAL_GATE_{g.upper()}", i + 1, "", False) for i, g in enumerate(METAL_GATES)],
]
