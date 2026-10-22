/*
 * スクリーンスペースのレイマーチ (surface モジュール: SSR / SSGI / レイトレース屈折で共有)
 * スクリーン上で始点と終点を結んで進み (透視補正のため 1/z を線形補間)、厚み判定で当たりを取ってから二分探索で詰める
 * 不透明だけの深度 (depthtex1) を辿る。手 (圧縮された深度) は遮蔽物にしない
 */
#ifndef SURFACE_SCREEN_TRACE_GLSL
#define SURFACE_SCREEN_TRACE_GLSL

const int SCREEN_TRACE_REFINE = 5;
// 遠くを粗く近くを細かく刻む (ステップの分布を t^k にする)
const float SCREEN_TRACE_STEP_POWER = 1.6;

/*
 * startView / dirView: view 空間の始点と方向 (正規化)。maxDist: 最大距離 (ブロック)
 * 戻り値: xy = ヒットの UV, z = ヒット点の深度 [0,1], w = 1 ならヒット (0 は失敗)
 */
vec4 traceScreenRay(vec3 startView, vec3 dirView, float maxDist, int steps, float dither) {
    float len = maxDist;
    // near 面を越えるとスクリーン座標が反転するので手前で止める
    if (dirView.z > 0.0) len = min(len, (-near * 1.5 - startView.z) / dirView.z);
    if (len <= 0.0) return vec4(0.0);
    vec3 endView = startView + dirView * len;

    vec3 s0 = viewToScreen(startView);
    vec3 s1 = viewToScreen(endView);
    // 画面の外へ出る区間を切り落とす
    vec2 d = s1.xy - s0.xy;
    float tMax = 1.0;
    if (d.x != 0.0) tMax = min(tMax, max((d.x > 0.0 ? 1.0 - s0.x : -s0.x) / d.x, 0.0));
    if (d.y != 0.0) tMax = min(tMax, max((d.y > 0.0 ? 1.0 - s0.y : -s0.y) / d.y, 0.0));

    float invZ0 = 1.0 / startView.z;
    float invZ1 = 1.0 / endView.z;
    float tPrev = 0.0;
    for (int i = 0; i < steps; i++) {
        float t = pow((float(i) + dither) / float(steps), SCREEN_TRACE_STEP_POWER) * tMax;
        // スクリーン上の t は view 空間では非線形なので 1/z を補間する
        vec2 uv = mix(s0.xy, s1.xy, t);
        float rayLin = -1.0 / mix(invZ0, invZ1, t);
        float sceneDepth = texture(depthtex1, uv).r;
        if (isHandDepth(sceneDepth)) { tPrev = t; continue; }
        float sceneLin = linearizeDepth(sceneDepth);
        float prevLin = -1.0 / mix(invZ0, invZ1, tPrev);
        // 厚み: 1 ステップで進んだ深度差 + 距離に比例する余裕
        float thickness = abs(rayLin - prevLin) * 1.5 + 0.2 + rayLin * 0.015;
        float diff = rayLin - sceneLin;
        if (diff > 0.0 && diff < thickness && sceneDepth < 1.0) {
            float lo = tPrev;
            float hi = t;
            for (int j = 0; j < SCREEN_TRACE_REFINE; j++) {
                float mid = 0.5 * (lo + hi);
                vec2 muv = mix(s0.xy, s1.xy, mid);
                float mLin = -1.0 / mix(invZ0, invZ1, mid);
                if (mLin > linearizeDepth(texture(depthtex1, muv).r)) hi = mid; else lo = mid;
            }
            vec2 huv = mix(s0.xy, s1.xy, hi);
            return vec4(huv, texture(depthtex1, huv).r, 1.0);
        }
        tPrev = t;
    }
    return vec4(0.0);
}

// 画面端で SSR の結果をフォールバックへ溶かす重み
float screenEdgeFade(vec2 uv) {
    vec2 e = min(uv, 1.0 - uv);
    return saturate(minOf(e) * 12.0);
}

#endif
