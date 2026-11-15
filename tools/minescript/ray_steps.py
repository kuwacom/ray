"""
# ray_steps
ray_agent が実行するステップの実装。ジョブごとに再読み込みされるので、ゲーム内のエージェントを再起動せずに更新できる
"""

import time
import traceback

import minescript as m


def _script_thread(fn):
    def call(*args):
        with m.script_loop:
            return fn(*args)
    return call


# 既定の render_loop は 1 回の呼び出しに 1 フレーム (30 FPS の上限で 33 ms) かかり、JavaScope の 1 操作で 10〜30 回呼ぶ
# クラス・メンバーの検索、フィールドの読み取り、値の変換、ハンドルの解放はゲームの状態を変えないので、フレームを待たずにスクリプトのスレッドで行う
# 状態を変えうるメソッドの呼び出し (java_call_method) とコマンドは描画スレッドのまま
java_class = _script_thread(m.java_class)
java_member = _script_thread(m.java_member)
java_access_field = _script_thread(m.java_access_field)
java_release = _script_thread(m.java_release)
java_to_string = _script_thread(m.java_to_string)
java_string = _script_thread(m.java_string)
java_int = _script_thread(m.java_int)
java_bool = _script_thread(m.java_bool)
java_float = _script_thread(m.java_float)
java_double = _script_thread(m.java_double)

# 1.20.1 の Fabric は Minecraft のクラス・メンバーが intermediary の名前で動き、Minescript 4.0 は名前の対応表を持たない
# 公式の client mappings と FabricMC/intermediary の 1.20.1.tiny から引いた。キーは 26.1 の名前 (版で名前が変わったものも 26.1 の名前で引く)
INTERMEDIARY = {
    "1.20.1": {
        "net.minecraft.client.Minecraft": ("net.minecraft.class_310", {
            "getInstance": "method_1551", "options": "field_1690", "gameRenderer": "field_1773",
            "getSingleplayerServer": "method_1576", "setScreen": "method_1507", "getFps": "method_47599"}),
        "net.minecraft.client.Options": ("net.minecraft.class_315", {
            "getCameraType": "method_31044", "setCameraType": "method_31043", "fov": "method_41808",
            "renderDistance": "method_42503", "cloudStatus": "method_42528", "framerateLimit": "method_42524",
            "hideGui": "field_1842", "pauseOnLostFocus": "field_1837"}),
        "net.minecraft.client.CameraType": ("net.minecraft.class_5498", {
            "FIRST_PERSON": "field_26664", "THIRD_PERSON_BACK": "field_26665", "THIRD_PERSON_FRONT": "field_26666"}),
        # 1.20.1 は Camera.getPosition()
        "net.minecraft.client.Camera": ("net.minecraft.class_4184", {"position": "method_19326", "isDetached": "method_19333"}),
        "net.minecraft.client.renderer.GameRenderer": ("net.minecraft.class_757", {"getMainCamera": "method_19418"}),
        "net.minecraft.client.OptionInstance": ("net.minecraft.class_7172", {"get": "method_41753", "set": "method_41748"}),
        "net.minecraft.client.CloudStatus": ("net.minecraft.class_4063", {
            "OFF": "field_18162", "FAST": "field_18163", "FANCY": "field_18164"}),
        "net.minecraft.server.MinecraftServer": ("net.minecraft.server.MinecraftServer", {"getPlayerList": "method_3760"}),
        "net.minecraft.server.players.PlayerList": ("net.minecraft.class_3324", {"setViewDistance": "method_14608"}),
        # 1.20.1 は Entity.absMoveTo(x, y, z, yaw, pitch) (1.21.5 で absSnapTo に改名)
        "net.minecraft.world.entity.Entity": ("net.minecraft.class_1297", {"absSnapTo": "method_5641"}),
    },
}

# 26.1 で改名されたゲームルール。1.20.1 では旧名でないと効かない (scenes.json と run_scene.py は 26.1 の名前で書いてある)
GAMERULES = {
    "1.20.1": {"advance_time": "doDaylightCycle", "advance_weather": "doWeatherCycle",
               "spawn_mobs": "doMobSpawning", "block_drops": "doTileDrops"},
}

# ray_steps はジョブごとに reload されるので、版はモジュール dict 上の既存値を引き継いで 1 回だけ問い合わせる
MC_VERSION: str = globals().get("MC_VERSION") or m.version_info().minecraft
NAMES: dict = INTERMEDIARY.get(MC_VERSION, {})
# 1.20.1 には非アクティブ時の FPS 制限 (inactivityFpsLimit, InactivityFpsLimit) が無い
HAS_INACTIVITY_LIMIT = MC_VERSION not in INTERMEDIARY


def reload_shaders() -> None:
    # Iris の公式 API にリロードが無いため内部の public static メソッドを直接呼ぶ
    iris = java_class("net.irisshaders.iris.Iris")
    method = java_member(iris, "reload")
    try:
        # static メソッドは target に null ハンドル (0) を渡す。クラスハンドルを渡すと java.lang.Class 側で解決されてしまう
        m.java_call_method(0, method)
    finally:
        java_release(method, iris)


def load_shader_pack(name: str) -> str:
    # 比較撮影用に別のパックを一時的に読む。Iris.reload() は iris.properties を読み直すので使わず、
    # 設定の保存 (IrisConfig.save) もしないため iris.properties は書き換わらない。戻すときは reload_shaders()
    iris = java_class("net.irisshaders.iris.Iris")
    handles = [iris]
    try:
        def call(target, clazz, method_name, *args):
            method = java_member(clazz, method_name)
            handles.append(method)
            result = m.java_call_method(target, method, *args)
            if result:
                handles.append(result)
            return result

        config = call(0, iris, "getIrisConfig")
        config_cls = java_class("net.irisshaders.iris.config.IrisConfig")
        manager_cls = java_class("net.irisshaders.iris.pipeline.PipelineManager")
        pack_name = java_string(name)
        handles += [config_cls, manager_cls, pack_name]
        call(config, config_cls, "setShaderPackName", pack_name)
        # 先に破棄すると描画スレッドが古いパックでパイプラインを作り直してしまうので、読み込んでから破棄する
        call(0, iris, "loadShaderpack")
        manager = call(0, iris, "getPipelineManager")
        call(manager, manager_cls, "destroyPipeline")
        call(manager, manager_cls, "preparePipeline", call(0, iris, "getCurrentDimension"))
        return java_to_string(call(0, iris, "getCurrentPackName"))
    finally:
        java_release(*handles)


class JavaScope:
    """
    # JavaScope
    java_* API で得たハンドルをまとめて解放するためのスコープ

    ### 特徴
    - with を抜けると取得したハンドルを全て java_release する
    - MC 26.1 は難読化なしなので公式名 (net.minecraft.client.*) で引ける
    - 1.20.1 は INTERMEDIARY の表で 26.1 の名前を intermediary の名前に置き換えて引く
    """

    def __init__(self):
        self.handles = []
        # クラスのハンドル -> 26.1 の名前。メンバー名の置き換えに使う
        self.names = {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.handles:
            java_release(*self.handles)
        return False

    def keep(self, handle):
        if handle:
            self.handles.append(handle)
        return handle

    def cls(self, name: str):
        handle = self.keep(java_class(NAMES.get(name, (name,))[0]))
        self.names[handle] = name
        return handle

    def member_name(self, clazz, name: str) -> str:
        # 表に無いもの (Minecraft 以外のクラス、難読化の無い版) はそのまま
        return NAMES.get(self.names.get(clazz), (None, {}))[1].get(name, name)

    def field(self, target, clazz, name: str):
        # static フィールドは target に 0 を渡す
        return self.keep(java_access_field(target, self.keep(java_member(clazz, self.member_name(clazz, name)))))

    def call(self, target, clazz, name: str, *args):
        return self.keep(m.java_call_method(target, self.keep(java_member(clazz, self.member_name(clazz, name))), *args))

    def options(self):
        mc_cls = self.cls("net.minecraft.client.Minecraft")
        mc = self.call(0, mc_cls, "getInstance")
        return self.field(mc, mc_cls, "options"), self.cls("net.minecraft.client.Options")


def iris_frame_count() -> int:
    # Iris の frameCounter ユニフォームの元 (描画したフレーム数)
    with JavaScope() as j:
        counter = j.field(0, j.cls("net.irisshaders.iris.uniforms.SystemTimeUniforms"), "COUNTER")
        return int(java_to_string(j.call(counter, j.cls("java.util.function.IntSupplier"), "getAsInt")))


def iris_frame_time() -> float:
    # Iris の frameTimeCounter ユニフォームの元 (秒。再読み込みで 0 に戻る)
    with JavaScope() as j:
        timer_cls = j.cls("net.irisshaders.iris.uniforms.SystemTimeUniforms$Timer")
        timer = j.field(0, j.cls("net.irisshaders.iris.uniforms.SystemTimeUniforms"), "TIMER")
        return float(java_to_string(j.call(timer, timer_cls, "getFrameTimeCounter")))


# ray_steps はジョブごとに reload されるため、元の設定値はモジュール dict 上の既存値を引き継いで保持する
SAVED: dict = globals().get("SAVED", {})

PERSPECTIVES = {
    "first": "FIRST_PERSON",
    "third_back": "THIRD_PERSON_BACK",
    "third_front": "THIRD_PERSON_FRONT",
}


def get_perspective() -> str:
    with JavaScope() as j:
        options, options_cls = j.options()
        name = java_to_string(j.call(options, options_cls, "getCameraType"))
    return next((k for k, v in PERSPECTIVES.items() if v == name), name)


def set_perspective(mode: str) -> str:
    with JavaScope() as j:
        options, options_cls = j.options()
        camera_cls = j.cls("net.minecraft.client.CameraType")
        j.call(options, options_cls, "setCameraType", j.field(0, camera_cls, PERSPECTIVES[mode]))
    return get_perspective()


def camera_info() -> dict:
    # 三人称で壁に当たるとカメラが寄るので、構図調整では実際のカメラ位置を見る
    with JavaScope() as j:
        mc_cls = j.cls("net.minecraft.client.Minecraft")
        renderer = j.field(j.call(0, mc_cls, "getInstance"), mc_cls, "gameRenderer")
        camera_cls = j.cls("net.minecraft.client.Camera")
        camera = j.call(renderer, j.cls("net.minecraft.client.renderer.GameRenderer"), "getMainCamera")
        return {
            "camera_pos": java_to_string(j.call(camera, camera_cls, "position")),
            "camera_detached": java_to_string(j.call(camera, camera_cls, "isDetached")) == "true",
        }


def get_fov() -> int:
    with JavaScope() as j:
        options, options_cls = j.options()
        inst = j.call(options, options_cls, "fov")
        return int(java_to_string(j.call(inst, j.cls("net.minecraft.client.OptionInstance"), "get")))


def set_fov(value) -> int:
    if value == "restore":
        if "fov" not in SAVED:
            return get_fov()
        value = SAVED.pop("fov")
    else:
        SAVED.setdefault("fov", get_fov())
    with JavaScope() as j:
        options, options_cls = j.options()
        inst = j.call(options, options_cls, "fov")
        j.call(inst, j.cls("net.minecraft.client.OptionInstance"), "set", j.keep(java_int(int(value))))
    return get_fov()


def set_render_distance(value) -> int:
    """
    ### set_render_distance
    描画距離 (チャンク) を実行時だけ切り替える。options.txt は保存しない
    シングルプレイの内部サーバーの送る距離も同じ値にする (クライアントの値だけでは遠くのチャンクが届かない)

    @param value - チャンク数。"restore" で変更前へ戻す
    @returns 変更後の値
    """
    with JavaScope() as j:
        options, options_cls = j.options()
        inst = j.call(options, options_cls, "renderDistance")
        inst_cls = j.cls("net.minecraft.client.OptionInstance")
        current = int(java_to_string(j.call(inst, inst_cls, "get")))
        if value == "restore":
            if "render_distance" not in SAVED:
                return current
            value = SAVED.pop("render_distance")
        else:
            SAVED.setdefault("render_distance", current)
        j.call(inst, inst_cls, "set", j.keep(java_int(int(value))))
        mc_cls = j.cls("net.minecraft.client.Minecraft")
        server = j.call(j.call(0, mc_cls, "getInstance"), mc_cls, "getSingleplayerServer")
        if server:
            server_cls = j.cls("net.minecraft.server.MinecraftServer")
            players = j.call(server, server_cls, "getPlayerList")
            j.call(players, j.cls("net.minecraft.server.players.PlayerList"), "setViewDistance", j.keep(java_int(int(value))))
        return int(java_to_string(j.call(inst, inst_cls, "get")))


def set_cloud_status(value) -> str:
    """
    ### set_cloud_status
    バニラの雲の表示 (OFF / FAST / FANCY) を実行時だけ切り替える。options.txt は保存しない
    CLOUDS=1 でバニラの雲を描いて、体積雲の位置合わせの基準にする

    @param value - "off" / "fast" / "fancy"。"restore" で変更前へ戻す
    @returns 変更後の値
    """
    with JavaScope() as j:
        options, options_cls = j.options()
        inst = j.call(options, options_cls, "cloudStatus")
        inst_cls = j.cls("net.minecraft.client.OptionInstance")
        status_cls = j.cls("net.minecraft.client.CloudStatus")
        if value == "restore":
            if "cloud_status" not in SAVED:
                return java_to_string(j.call(inst, inst_cls, "get"))
            value = SAVED.pop("cloud_status")
        else:
            SAVED.setdefault("cloud_status", java_to_string(j.call(inst, inst_cls, "get")))
        j.call(inst, inst_cls, "set", j.field(0, status_cls, str(value).upper()))
        return java_to_string(j.call(inst, inst_cls, "get"))

def get_hud() -> bool:
    with JavaScope() as j:
        options, options_cls = j.options()
        return java_to_string(j.field(options, options_cls, "hideGui")) != "true"


def set_hud(visible: bool) -> bool:
    # 生 API にはフィールド代入が無いため java.lang.reflect.Field 経由で書き換える
    with JavaScope() as j:
        options, options_cls = j.options()
        class_cls = j.cls("java.lang.Class")
        field = j.call(options_cls, class_cls, "getField", j.keep(java_string(j.member_name(options_cls, "hideGui"))))
        j.call(field, j.cls("java.lang.reflect.Field"), "setBoolean", options, j.keep(java_bool(not visible)))
    return get_hud()


def set_pause_on_lost_focus(value) -> bool:
    """
    ### set_pause_on_lost_focus
    ウィンドウが非アクティブでもポーズしないようにする (実行時のみ。options.txt は保存しない)
    ポーズ中は内蔵サーバーが止まり、time set などの時刻がクライアントに届かない (ディメンション移動の時だけ同期される)

    @param value - false で止めずにポーズメニューを閉じる。"restore" で変更前の値へ戻す
    @returns 変更後の値
    """
    with JavaScope() as j:
        options, options_cls = j.options()
        if value == "restore":
            if "pause_on_lost_focus" not in SAVED:
                return java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true"
            value = SAVED.pop("pause_on_lost_focus")
        else:
            SAVED.setdefault("pause_on_lost_focus", java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true")
        field = j.call(options_cls, j.cls("java.lang.Class"), "getField", j.keep(java_string(j.member_name(options_cls, "pauseOnLostFocus"))))
        j.call(field, j.cls("java.lang.reflect.Field"), "setBoolean", options, j.keep(java_bool(bool(value))))
        if not value:
            mc_cls = j.cls("net.minecraft.client.Minecraft")
            mc = j.call(0, mc_cls, "getInstance")
            j.call(mc, mc_cls, "setScreen", 0)
        return java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true"


def item_name(stack):
    # Minescript 5.0 の HandItems は中身が ItemStack ではなく dict のまま返る
    if not stack:
        return None
    return stack.get("item") if isinstance(stack, dict) else stack.item


def player_info() -> dict:
    hands = m.player_hand_items()
    return {
        "pos": m.player_position(),
        "orientation": m.player_orientation(),
        "main_hand": item_name(hands.main_hand),
        "off_hand": item_name(hands.off_hand),
        "screen": m.screen_name(),
        "perspective": get_perspective(),
        "fov": get_fov(),
        "hud": get_hud(),
        **camera_info(),
    }


# 洞窟の自然湧きモンスターが構図に入り込むので撮影前に消す対象
HOSTILE_TYPES = (
    "zombie", "husk", "drowned", "zombie_villager", "skeleton", "stray", "bogged",
    "creeper", "spider", "cave_spider", "enderman", "witch", "slime", "silverfish",
)

KEY_FUNCS = {
    "forward": m.player_press_forward,
    "backward": m.player_press_backward,
    "left": m.player_press_left,
    "right": m.player_press_right,
    "jump": m.player_press_jump,
    "sprint": m.player_press_sprint,
    "sneak": m.player_press_sneak,
    "use": m.player_press_use,
    "attack": m.player_press_attack,
    "drop": m.player_press_drop,
    "swap_hands": m.player_press_swap_hands,
}


def run_step(step: dict):
    if "cmd" in step:
        cmd = step["cmd"].removeprefix("/")
        rules = GAMERULES.get(MC_VERSION)
        if rules and cmd.startswith("gamerule "):
            _, rule, *rest = cmd.split(" ")
            cmd = " ".join(["gamerule", rules.get(rule, rule), *rest])
        m.execute("/" + cmd)
        return None
    if "orient" in step:
        yaw, pitch = step["orient"]
        return m.player_set_orientation(yaw, pitch)
    if "look_at" in step:
        x, y, z = step["look_at"]
        m.player_look_at(x, y, z)
        return None
    if "wait_frames" in step:
        # 例: {"wait_frames": 30, "timeout": 300} 新しいフレームが N 枚描かれるまで待つ
        # 再読み込みの直後はパイプラインの作成 (ドライバのキャッシュの有無で 10〜150 秒) と最初のフレームの詰まりがあり、
        # 秒の待ちだけでは版によって履歴・露出が溜まる前の数フレーム目を撮ってしまう。カウンタが戻ったら作り直しとみなし 0 から数える
        need = int(step["wait_frames"])
        deadline = time.time() + float(step.get("timeout", 300))
        start = prev = iris_frame_count()
        while time.time() < deadline:
            now = iris_frame_count()
            if now < prev:
                start = 0
            prev = now
            if now - start >= need:
                return now - start
            time.sleep(0.1)
        raise RuntimeError(f"wait_frames: {prev - start} / {need} frames before timeout")
    if "wait_frame_time" in step:
        # 例: {"wait_frame_time": 8, "timeout": 300} Iris の frameTimeCounter (再読み込みで 0 に戻る) が N 秒になるまで待つ
        # 霧・葉・波は frameTimeCounter で動くので、版ごとに再読み込みからの壁時計で撮ると動きの位相がずれ、版の差に見える
        target = float(step["wait_frame_time"])
        deadline = time.time() + float(step.get("timeout", 300))
        while time.time() < deadline:
            now = iris_frame_time()
            if now >= target:
                return round(now, 3)
            time.sleep(min(0.05, max(target - now, 0.0)))
        raise RuntimeError(f"wait_frame_time: {iris_frame_time():.2f} / {target} s before timeout")
    if "wait" in step:
        time.sleep(float(step["wait"]))
        return None
    if "reload_shaders" in step:
        reload_shaders()
        return None
    if "cloud_status" in step:
        # 例: {"cloud_status": "fancy"} バニラの雲を出す。"restore" で戻す
        return set_cloud_status(step["cloud_status"])
    if "shader_pack" in step:
        # 例: {"shader_pack": "iterationT 3.2.0.zip"} 比較用に一時的に切り替える。"restore" で iris.properties のパック (Ray) に戻す
        if step["shader_pack"] == "restore":
            reload_shaders()
            return "restored"
        return load_shader_pack(step["shader_pack"])
    if "screenshot" in step:
        # 例: {"screenshot": "name", "delay": 2.0} は待機してから撮る
        time.sleep(float(step.get("delay", 0)))
        m.screenshot(step["screenshot"])
        return None
    if "burst" in step:
        # 例: {"burst": "name", "count": 24, "turn": 10, "walk": false}
        # name_00 .. name_NN を続けて撮る (turn 度/秒で視線を回し、walk=true なら前進しながら)。ちらつき (連続フレームの差) の計測用
        name = step["burst"]
        count = int(step.get("count", 24))
        speed = float(step.get("turn", 0.0))
        walk = bool(step.get("walk", False))
        yaw, pitch = m.player_orientation()
        if walk:
            m.player_press_forward(True)
        t0 = time.time()
        times = []
        try:
            for i in range(count):
                m.player_set_orientation(yaw + speed * (time.time() - t0), pitch)
                m.screenshot(f"{name}_{i:02d}")
                times.append(round(time.time() - t0, 3))
        finally:
            if walk:
                m.player_press_forward(False)
        return {"times": times}
    if "turn" in step:
        # 例: {"turn": 30, "sec": 2.0, "shot": "name", "walk": false}
        # 毎秒 30 度で視線を回し (walk=true なら前進もし)、途中 (sec の 3/4) で撮影する。動いている時のブラー・TAA の確認用
        speed = float(step["turn"])
        sec = float(step.get("sec", 2.0))
        yaw, pitch = m.player_orientation()
        walk = bool(step.get("walk", False))
        if walk:
            m.player_press_forward(True)
        t0 = time.time()
        shot_done = "shot" not in step
        try:
            while (t := time.time() - t0) < sec:
                m.player_set_orientation(yaw + speed * t, pitch)
                if not shot_done and t >= sec * 0.75:
                    m.screenshot(step["shot"])
                    shot_done = True
                time.sleep(0.005)
        finally:
            if walk:
                m.player_press_forward(False)
        return None
    if "perspective" in step:
        # first / third_back / third_front
        return set_perspective(step["perspective"])
    if "fov" in step:
        # 数値で設定、"restore" で最初に変更する前の値に戻す
        return set_fov(step["fov"])
    if "render_distance" in step:
        # 例: {"render_distance": 48} 描画距離 (チャンク)。"restore" で最初に変更する前の値に戻す
        return set_render_distance(step["render_distance"])
    if "hud" in step:
        # false で F1 相当 (HUD と一人称の手を隠す)
        return set_hud(bool(step["hud"]))
    if "key" in step:
        # 例: {"key": "forward", "sec": 1.0}
        func = KEY_FUNCS[step["key"]]
        func(True)
        time.sleep(float(step.get("sec", 0.1)))
        func(False)
        return None
    if "key_bind" in step:
        # 例: {"key_bind": "key.togglePerspective"} キー割り当て名で押して離す
        # ウィンドウ非アクティブでポーズメニューが開いていると効かない (視点切替は perspective を使う)
        m.press_key_bind(step["key_bind"], True)
        time.sleep(float(step.get("sec", 0.1)))
        m.press_key_bind(step["key_bind"], False)
        return None
    if "freecam" in step:
        # 例: {"freecam": true} Freecam mod (net.xolt.freecam) を有効/無効にする。今の状態と違う時だけ toggle する
        # key_bind "key.freecam.toggle" は押下状態しか変えず、consumeClick で読む Freecam には効かない
        with JavaScope() as j:
            freecam_cls = j.cls("net.xolt.freecam.Freecam")
            if (java_to_string(j.call(0, freecam_cls, "isEnabled")) == "true") != bool(step["freecam"]):
                j.call(0, freecam_cls, "toggle")
            return java_to_string(j.call(0, freecam_cls, "isEnabled")) == "true"
    if "freecam_state" in step:
        # Freecam mod (net.xolt.freecam) の有効状態
        with JavaScope() as j:
            return java_to_string(j.call(0, j.cls("net.xolt.freecam.Freecam"), "isEnabled")) == "true"
    if "freecam_pose" in step:
        # 例: {"freecam_pose": [x, y, z, yaw, pitch]} フリーカメラの位置 (足元、目は +0.4) と向きを決める (視線の操作はマウス入力しか効かないため)
        x, y, z, yaw, pitch = step["freecam_pose"]
        with JavaScope() as j:
            camera = j.call(0, j.cls("net.xolt.freecam.Freecam"), "getFreeCamera")
            if not camera:
                raise RuntimeError("freecam is not enabled")
            j.call(camera, j.cls("net.minecraft.world.entity.Entity"), "absSnapTo",
                   j.keep(java_double(x)), j.keep(java_double(y)), j.keep(java_double(z)),
                   j.keep(java_float(yaw)), j.keep(java_float(pitch)))
        return camera_info()
    if "slot" in step:
        return m.player_inventory_select_slot(int(step["slot"]))
    if "echo" in step:
        m.echo(step["echo"])
        return None
    if "close_screen" in step:
        # チャット欄などが開いたままだとスクリーンショットに写り込むため閉じる
        m.show_chat_screen(False)
        return None
    if "pause_on_lost_focus" in step:
        return set_pause_on_lost_focus(step["pause_on_lost_focus"])
    if "info" in step:
        return player_info()
    if "fps" in step:
        # 例: {"fps": 5} 1 秒ごとに 5 回 Minecraft.getFps() を読む (撮影画像に F3 は写らないため)
        # {"fps": 5, "unlimited": true} は計測中だけ最大フレームレートを無制限 (260) にして元に戻す
        saved_limit = None
        if step.get("unlimited"):
            with JavaScope() as j:
                options, options_cls = j.options()
                inst = j.call(options, options_cls, "framerateLimit")
                inst_cls = j.cls("net.minecraft.client.OptionInstance")
                saved_limit = int(java_to_string(j.call(inst, inst_cls, "get")))
                j.call(inst, inst_cls, "set", j.keep(java_int(260)))
                # 入力なしで 1 分経つと AFK 扱いで 30 FPS に落ちるので、計測中は最小化時だけの制限にする
                if HAS_INACTIVITY_LIMIT:
                    afk = j.call(options, options_cls, "inactivityFpsLimit")
                    SAVED.setdefault("inactivity", java_to_string(j.call(afk, inst_cls, "get")))
                    j.call(afk, inst_cls, "set", j.field(0, j.cls("net.minecraft.client.InactivityFpsLimit"), "MINIMIZED"))
            time.sleep(1.0)
        samples = []
        frames0, wall0 = iris_frame_count(), time.time()
        for _ in range(int(step["fps"])):
            time.sleep(1.0)
            with JavaScope() as j:
                mc_cls = j.cls("net.minecraft.client.Minecraft")
                samples.append(int(java_to_string(j.call(j.call(0, mc_cls, "getInstance"), mc_cls, "getFps"))))
        # getFps は整数で 1 秒ごとの値なので、遅い場面では Iris のフレーム数を計測区間全体で割った 1 フレームの時間 (ms) も返す
        frames = iris_frame_count() - frames0
        frame_ms = round((time.time() - wall0) * 1000.0 / frames, 2) if frames > 0 else None
        # 非アクティブ時の FPS 制限 (AFK で 30 に落ちる) に掛かっていないかを一緒に返す
        with JavaScope() as j:
            options, options_cls = j.options()
            inst_cls = j.cls("net.minecraft.client.OptionInstance")
            limit_names = ("framerateLimit", "inactivityFpsLimit") if HAS_INACTIVITY_LIMIT else ("framerateLimit",)
            limits = {name: java_to_string(j.call(j.call(options, options_cls, name), inst_cls, "get"))
                      for name in limit_names}
            if saved_limit is not None:
                inst = j.call(options, options_cls, "framerateLimit")
                j.call(inst, inst_cls, "set", j.keep(java_int(saved_limit)))
                if HAS_INACTIVITY_LIMIT:
                    afk = j.call(options, options_cls, "inactivityFpsLimit")
                    j.call(afk, inst_cls, "set", j.field(0, j.cls("net.minecraft.client.InactivityFpsLimit"), SAVED.pop("inactivity")))
        return {"fps": samples, "frame_ms": frame_ms, **limits}
    if "java_methods" in step:
        # 例: {"java_methods": "net.minecraft.client.Camera"} java_* API で呼ぶメソッド名を調べる用
        # 1.20.1 では intermediary の名前 (method_*) が返る
        with JavaScope() as j:
            clazz = j.cls(step["java_methods"])
            if hasattr(m, "java_method_names"):
                return sorted(set(m.java_method_names(clazz)))
            # Minescript 4.0 には java_method_names が無いので Class.getMethods() を読む
            methods = j.call(clazz, j.cls("java.lang.Class"), "getMethods")
            method_cls = j.cls("java.lang.reflect.Method")
            return sorted({java_to_string(j.call(j.keep(m.java_array_index(methods, i)), method_cls, "getName"))
                           for i in range(m.java_array_length(methods))})
    if "clear_hostiles" in step:
        # 例: {"clear_hostiles": [x, y, z, r]} シーンで summon したもの (tag=ray) は残す
        # kill だとドロップ品が床に残って写り込むので奈落へ送る
        x, y, z, r = step["clear_hostiles"]
        for t in HOSTILE_TYPES:
            m.execute(f"/execute as @e[type={t},tag=!ray,x={x},y={y},z={z},distance=..{r}] at @s run tp @s ~ -1000 ~")
        return None
    if "entities" in step:
        # 例: {"entities": 16} summon が効いたかを半径内のエンティティ一覧で確かめる
        return [
            {"type": e.type, "name": e.name, "pos": [round(v, 2) for v in e.position]}
            for e in m.entities(max_distance=float(step["entities"]), sort="nearest")
        ]
    if "player_nbt" in step:
        # 透明化などの状態異常や装備がシーンに影響していないかを調べる用
        return m.player(nbt=True).nbt
    if "blocks" in step:
        # 例: {"blocks": [[x, y, z], ...]} シーンの立ち位置や壁の位置を調べる用
        return m.getblocklist([[int(v) for v in p] for p in step["blocks"]])
    raise ValueError(f"unknown step: {step}")


def run_job(job: dict) -> dict:
    results = []
    ok = True
    for i, step in enumerate(job.get("steps", [])):
        # 検証のループの時間の内訳 (待ち・コマンド・Java の呼び出し) を後から数えられるよう、ステップごとの秒を返す
        t0 = time.time()
        try:
            results.append({"i": i, "ok": True, "value": run_step(step), "sec": round(time.time() - t0, 3)})
        except Exception:
            ok = False
            results.append({"i": i, "ok": False, "error": traceback.format_exc(limit=3), "sec": round(time.time() - t0, 3)})
            if not job.get("continue_on_error", False):
                break
    return {"id": job.get("id"), "ok": ok, "results": results, "finished_at": time.time()}
