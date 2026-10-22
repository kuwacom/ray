"""
# ray_steps
ray_agent が実行するステップの実装。ジョブごとに再読み込みされるので、ゲーム内のエージェントを再起動せずに更新できる
"""

import time
import traceback

import minescript as m


def reload_shaders() -> None:
    # Iris の公式 API にリロードが無いため内部の public static メソッドを直接呼ぶ
    iris = m.java_class("net.irisshaders.iris.Iris")
    method = m.java_member(iris, "reload")
    try:
        # static メソッドは target に null ハンドル (0) を渡す。クラスハンドルを渡すと java.lang.Class 側で解決されてしまう
        m.java_call_method(0, method)
    finally:
        m.java_release(method, iris)


def load_shader_pack(name: str) -> str:
    # 比較撮影用に別のパックを一時的に読む。Iris.reload() は iris.properties を読み直すので使わず、
    # 設定の保存 (IrisConfig.save) もしないため iris.properties は書き換わらない。戻すときは reload_shaders()
    iris = m.java_class("net.irisshaders.iris.Iris")
    handles = [iris]
    try:
        def call(target, clazz, method_name, *args):
            method = m.java_member(clazz, method_name)
            handles.append(method)
            result = m.java_call_method(target, method, *args)
            if result:
                handles.append(result)
            return result

        config = call(0, iris, "getIrisConfig")
        config_cls = m.java_class("net.irisshaders.iris.config.IrisConfig")
        manager_cls = m.java_class("net.irisshaders.iris.pipeline.PipelineManager")
        pack_name = m.java_string(name)
        handles += [config_cls, manager_cls, pack_name]
        call(config, config_cls, "setShaderPackName", pack_name)
        # 先に破棄すると描画スレッドが古いパックでパイプラインを作り直してしまうので、読み込んでから破棄する
        call(0, iris, "loadShaderpack")
        manager = call(0, iris, "getPipelineManager")
        call(manager, manager_cls, "destroyPipeline")
        call(manager, manager_cls, "preparePipeline", call(0, iris, "getCurrentDimension"))
        return m.java_to_string(call(0, iris, "getCurrentPackName"))
    finally:
        m.java_release(*handles)


class JavaScope:
    """
    # JavaScope
    java_* API で得たハンドルをまとめて解放するためのスコープ

    ### 特徴
    - with を抜けると取得したハンドルを全て java_release する
    - MC 26.1 は難読化なしなので公式名 (net.minecraft.client.*) で引ける
    """

    def __init__(self):
        self.handles = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.handles:
            m.java_release(*self.handles)
        return False

    def keep(self, handle):
        if handle:
            self.handles.append(handle)
        return handle

    def cls(self, name: str):
        return self.keep(m.java_class(name))

    def field(self, target, clazz, name: str):
        # static フィールドは target に 0 を渡す
        return self.keep(m.java_access_field(target, self.keep(m.java_member(clazz, name))))

    def call(self, target, clazz, name: str, *args):
        return self.keep(m.java_call_method(target, self.keep(m.java_member(clazz, name)), *args))

    def options(self):
        mc_cls = self.cls("net.minecraft.client.Minecraft")
        mc = self.call(0, mc_cls, "getInstance")
        return self.field(mc, mc_cls, "options"), self.cls("net.minecraft.client.Options")


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
        name = m.java_to_string(j.call(options, options_cls, "getCameraType"))
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
            "camera_pos": m.java_to_string(j.call(camera, camera_cls, "position")),
            "camera_detached": m.java_to_string(j.call(camera, camera_cls, "isDetached")) == "true",
        }


def get_fov() -> int:
    with JavaScope() as j:
        options, options_cls = j.options()
        inst = j.call(options, options_cls, "fov")
        return int(m.java_to_string(j.call(inst, j.cls("net.minecraft.client.OptionInstance"), "get")))


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
        j.call(inst, j.cls("net.minecraft.client.OptionInstance"), "set", j.keep(m.java_int(int(value))))
    return get_fov()


def get_hud() -> bool:
    with JavaScope() as j:
        options, options_cls = j.options()
        return m.java_to_string(j.field(options, options_cls, "hideGui")) != "true"


def set_hud(visible: bool) -> bool:
    # 生 API にはフィールド代入が無いため java.lang.reflect.Field 経由で書き換える
    with JavaScope() as j:
        options, options_cls = j.options()
        class_cls = j.cls("java.lang.Class")
        field = j.call(options_cls, class_cls, "getField", j.keep(m.java_string("hideGui")))
        j.call(field, j.cls("java.lang.reflect.Field"), "setBoolean", options, j.keep(m.java_bool(not visible)))
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
                return m.java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true"
            value = SAVED.pop("pause_on_lost_focus")
        else:
            SAVED.setdefault("pause_on_lost_focus", m.java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true")
        field = j.call(options_cls, j.cls("java.lang.Class"), "getField", j.keep(m.java_string("pauseOnLostFocus")))
        j.call(field, j.cls("java.lang.reflect.Field"), "setBoolean", options, j.keep(m.java_bool(bool(value))))
        if not value:
            mc_cls = j.cls("net.minecraft.client.Minecraft")
            mc = j.call(0, mc_cls, "getInstance")
            j.call(mc, mc_cls, "setScreen", 0)
        return m.java_to_string(j.field(options, options_cls, "pauseOnLostFocus")) == "true"


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
        cmd = step["cmd"]
        m.execute(cmd if cmd.startswith("/") else "/" + cmd)
        return None
    if "orient" in step:
        yaw, pitch = step["orient"]
        return m.player_set_orientation(yaw, pitch)
    if "look_at" in step:
        x, y, z = step["look_at"]
        m.player_look_at(x, y, z)
        return None
    if "wait" in step:
        time.sleep(float(step["wait"]))
        return None
    if "reload_shaders" in step:
        reload_shaders()
        return None
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
                saved_limit = int(m.java_to_string(j.call(inst, inst_cls, "get")))
                j.call(inst, inst_cls, "set", j.keep(m.java_int(260)))
                # 入力なしで 1 分経つと AFK 扱いで 30 FPS に落ちるので、計測中は最小化時だけの制限にする
                afk = j.call(options, options_cls, "inactivityFpsLimit")
                SAVED.setdefault("inactivity", m.java_to_string(j.call(afk, inst_cls, "get")))
                j.call(afk, inst_cls, "set", j.field(0, j.cls("net.minecraft.client.InactivityFpsLimit"), "MINIMIZED"))
            time.sleep(1.0)
        samples = []
        for _ in range(int(step["fps"])):
            time.sleep(1.0)
            with JavaScope() as j:
                mc_cls = j.cls("net.minecraft.client.Minecraft")
                samples.append(int(m.java_to_string(j.call(j.call(0, mc_cls, "getInstance"), mc_cls, "getFps"))))
        # 非アクティブ時の FPS 制限 (AFK で 30 に落ちる) に掛かっていないかを一緒に返す
        with JavaScope() as j:
            options, options_cls = j.options()
            inst_cls = j.cls("net.minecraft.client.OptionInstance")
            limits = {name: m.java_to_string(j.call(j.call(options, options_cls, name), inst_cls, "get"))
                      for name in ("framerateLimit", "inactivityFpsLimit")}
            if saved_limit is not None:
                inst = j.call(options, options_cls, "framerateLimit")
                j.call(inst, inst_cls, "set", j.keep(m.java_int(saved_limit)))
                afk = j.call(options, options_cls, "inactivityFpsLimit")
                j.call(afk, inst_cls, "set", j.field(0, j.cls("net.minecraft.client.InactivityFpsLimit"), SAVED.pop("inactivity")))
        return {"fps": samples, **limits}
    if "java_methods" in step:
        # 例: {"java_methods": "net.minecraft.client.Camera"} java_* API で呼ぶメソッド名を調べる用
        with JavaScope() as j:
            return sorted(set(m.java_method_names(j.cls(step["java_methods"]))))
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
        try:
            results.append({"i": i, "ok": True, "value": run_step(step)})
        except Exception:
            ok = False
            results.append({"i": i, "ok": False, "error": traceback.format_exc(limit=3)})
            if not job.get("continue_on_error", False):
                break
    return {"id": job.get("id"), "ok": ok, "results": results, "finished_at": time.time()}
