/*
 * 座標空間の変換
 * - screen: xy = [0,1] の UV, z = [0,1] の深度
 * - view:   カメラ空間 (Iris の view space)
 * - player: カメラ位置を原点とするワールド軸の空間 (Iris の player space)。法線もこの空間で扱う
 * - world:  player + cameraPosition (精度が落ちるので必要な時だけ使う)
 * - voxel:  lib/common/voxel_space.glsl を参照
 */
#ifndef COMMON_TRANSFORMS_GLSL
#define COMMON_TRANSFORMS_GLSL

vec2 viewSize() { return vec2(viewWidth, viewHeight); }
vec2 texelSize() { return 1.0 / vec2(viewWidth, viewHeight); }

vec3 projectAndDivide(mat4 m, vec3 p) {
    vec4 h = m * vec4(p, 1.0);
    return h.xyz / h.w;
}

vec3 screenToView(vec3 screenPos) {
    return projectAndDivide(gbufferProjectionInverse, screenPos * 2.0 - 1.0);
}

vec3 viewToScreen(vec3 viewPos) {
    return projectAndDivide(gbufferProjection, viewPos) * 0.5 + 0.5;
}

vec3 viewToPlayer(vec3 viewPos) {
    return mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
}

vec3 playerToView(vec3 playerPos) {
    return mat3(gbufferModelView) * playerPos + gbufferModelView[3].xyz;
}

vec3 viewToPlayerDir(vec3 v) { return mat3(gbufferModelViewInverse) * v; }
vec3 playerToViewDir(vec3 v) { return mat3(gbufferModelView) * v; }

vec3 screenToPlayer(vec3 screenPos) { return viewToPlayer(screenToView(screenPos)); }

// 深度 [0,1] -> カメラからの視線方向距離 (正の値)
float linearizeDepth(float depth) {
    float z = depth * 2.0 - 1.0;
    /*
     * 投影行列 (の逆) から求める。uniform の far は描画距離で、MC の投影の far 面 (描画距離の数倍) とは違うため、
     * near/far の式では中距離の奥行きが数 % 手前にずれ、接触影・SSR・AO の深度比較が自分の面を遮蔽物と誤判定していた
     * (遠くの雪・氷の床の日向が一面に影になる)。view の z と w は ndc の z だけで決まる (ジッターは x, y のみ)
     */
    return -(gbufferProjectionInverse[2][2] * z + gbufferProjectionInverse[3][2])
        / (gbufferProjectionInverse[2][3] * z + gbufferProjectionInverse[3][3]);
}

// 手持ちアイテムの深度は Iris が圧縮して書くので、通常の投影へ戻す
float fixHandDepth(float depth) {
#ifdef MC_HAND_DEPTH
    return depth < HAND_DEPTH_THRESHOLD ? (depth - 0.5) / MC_HAND_DEPTH + 0.5 : depth;
#else
    return depth;
#endif
}

bool isHandDepth(float depth) { return depth < HAND_DEPTH_THRESHOLD; }

// 前フレームのスクリーン座標へ再投影 (静止ジオメトリ用。動くエンティティは colortex15 の速度を使う)
vec3 playerToPrevScreen(vec3 playerPos) {
    vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
    vec3 prevView = (gbufferPreviousModelView * vec4(prevPlayer, 1.0)).xyz;
    return projectAndDivide(gbufferPreviousProjection, prevView) * 0.5 + 0.5;
}

// 太陽 / 影光源の方向 (player 空間, 正規化)
vec3 getSunDir() { return normalize(viewToPlayerDir(sunPosition)); }
vec3 getMoonDir() { return normalize(viewToPlayerDir(moonPosition)); }
vec3 getShadowLightDir() { return normalize(viewToPlayerDir(shadowLightPosition)); }

#endif
