/*
 * 速度ベクトル (post モジュール)
 * colortex15: rg = 前フレームのスクリーン UV - 今の UV, a = 1 なら gbuffers が書いた有効な値
 * a = 0 のピクセルは深度から再投影する (静止ジオメトリ)
 * 速度はすべてジッターを外した (TAA の揺れのない) スクリーン座標どうしの差
 */
#ifndef POST_VELOCITY_GLSL
#define POST_VELOCITY_GLSL

/*
 * エンティティの gbuffers の fragment から呼ぶ。viewPos は今フレームの view 空間位置 (ジッターを含まない)
 * Iris 26.1 の ENTITY 頂点形式には at_velocity が無い (IrisVertexFormats)。宣言すると未割り当ての属性が
 * 別の頂点属性と重なって不定値になり、静止した mob やドロップが大きくぶれていた
 * 物体自身の動きは分からないので、カメラの動きだけで再投影する。a = 1 は「エンティティ」の印として
 * TAA のディスオクルージョン判定を緩めるのに使う
 */
vec4 encodeVelocity(vec3 viewPos) {
    vec2 cur = viewToScreen(viewPos).xy;
    vec2 prev = playerToPrevScreen(viewToPlayer(viewPos)).xy;
    return vec4(prev - cur, 0.0, 1.0);
}

// 手は画面に貼り付いているので速度 0 として扱う
vec4 encodeHandVelocity() { return vec4(0.0, 0.0, 0.0, 1.0); }

/*
 * 任意のパスから: 画面 UV uv (深度 depth) の前フレーム UV
 * ラスタライズはジッター分ずれているので、ピクセル uv に写っている点は uv - jitter の位置にある
 * その点で速度を求めて uv に足す (ジッターを速度に混ぜると静止時に履歴が揺れてぼける)
 */
vec2 getPreviousUv(vec2 uv, float depth) {
    vec4 v = texture(colortex15, uv);
    if (v.a > 0.5) return uv + v.rg;
    // 半透明の手 (gbuffers_hand_water) は速度を書かないので、ここで止める
    if (isHandDepth(depth)) return uv;

#ifdef TAA
    vec2 unjittered = uv - taaJitterUv();
#else
    vec2 unjittered = uv;
#endif
    vec2 prev;
    if (depth >= 1.0) {
        // 空は回転だけで再投影する
        vec3 dir = viewToPlayerDir(screenToView(vec3(unjittered, 1.0)));
        vec3 prevView = mat3(gbufferPreviousModelView) * dir;
        prev = projectAndDivide(gbufferPreviousProjection, prevView).xy * 0.5 + 0.5;
    } else {
        prev = playerToPrevScreen(screenToPlayer(vec3(unjittered, depth))).xy;
    }
    return uv + (prev - unjittered);
}

// 前フレームのカメラから見た距離 (TAA のディスオクルージョン判定用。静止ジオメトリ前提)
float getPreviousViewDistance(vec2 uv, float depth) {
    vec3 prevPlayer = screenToPlayer(vec3(uv, depth)) + (cameraPosition - previousCameraPosition);
    return length(prevPlayer);
}

#endif
