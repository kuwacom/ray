/*
 * 画面空間の光芒 (sky モジュール)
 * 光源 (昼は太陽、夜は月) の画面上の位置へ向かう放射状のぼかしで、木・山・建物の隙間を通る光の筋を出す
 * 手法: Mitchell, "Volumetric Light Scattering as a Post-Process", GPU Gems 3, Chapter 13 (放射状のぼかしと減衰の重み)
 * 入力は明るさの閾値ではなく解析的なマスク (空の画素 x 雲の透過率 x 光源からの角度) にする。
 * 明るい雪・雲の縁・水面の輝点を拾わず、閾値の揺れでちらつかない
 * ぼかしは入れ子の 3 パス (1 パス N タップで実効 N^3 タップ) を低解像度の colortex16 で行い、足すのはフォグの適用 (composite19)
 */
#ifndef SKY_GODRAYS_GLSL
#define SKY_GODRAYS_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/common/samplers.glsl"
//@include "/lib/common/transforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/sky/clouds.glsl"

// 光を出す空の範囲 (rad)。重み exp((cos - 1) / (1 - cos(角))) は角で 1/e、2 倍の角で約 1/55
const float GODRAYS_SOURCE_ANGLE = 0.15;
// ぼかしの全長 (画素から光源までの距離に対する割合)。1 で光源まで届く
const float GODRAYS_LENGTH = 1.0;
// タップの重み exp(-DECAY x t) (t は全長に対する位置)。画素に近い遮蔽を重く見て筋の根元をくっきりさせる
const float GODRAYS_DECAY = 3.0;
// ぼかし結果 (0..1) x 光源の照度を放射輝度に直す倍率
const float GODRAYS_GAIN = 0.4;
// 晴れた空気 (もやだけ) での強さの割合。霧が濃いほど 1 へ近づく
const float GODRAYS_CLEAR_SHARE = 0.25;
// カメラの位置の霧の消散係数 (1/ブロック) がこの値以上で強さ 1
const float GODRAYS_FOG_REF = 4.0e-3;
// これより近い地形の画素では弱める (顔の前のブロックに光の筋を塗らない)
const float GODRAYS_NEAR_FADE = 6.0;
// 光源が画面の外へこの距離 (UV) 出ると 0
const float GODRAYS_OFFSCREEN_RANGE = 0.5;
// 画面の外の分に目の位置の太陽の見え方を掛けきるまでの距離 (UV)。レンズフレアの判定と同じ考え方
const float GODRAYS_EYE_FADE = 0.05;
// 雨で弱める割合
const float GODRAYS_RAIN_FADE = 0.85;

/*
 * 光芒の光源の画面の位置。光源がカメラの後ろなら false
 * outside: 画面の外へのはみ出し (UV)。0 なら画面の中
 */
bool godraysLightUv(out vec2 lightUv, out float outside) {
    lightUv = vec2(0.5);
    outside = 0.0;
    if (shadowLightPosition.z >= 0.0) return false;
    lightUv = viewToScreen(shadowLightPosition).xy;
    outside = length(lightUv - clamp(lightUv, 0.0, 1.0));
    return outside < GODRAYS_OFFSCREEN_RANGE;
}

/*
 * 光を出す空の割合 (マスク)
 * 手を含まない不透明の深度 (depthtex2) の 2x2 のうち空の割合に、雲の透過率と光源からの角度の重みを掛ける。
 * 半透明 (ガラス・水) は遮蔽にしない (窓越しの光芒を残す)。
 * 画面の外は 0 (端の画素を外へ延ばすと、画面の外の山に隠れた太陽の光が漏れる)
 */
float evalGodraysSource(vec2 uv, vec3 lightView) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
    vec4 d = textureGather(depthtex2, uv, 0);
    float sky = dot(vec4(greaterThanEqual(d, vec4(1.0))), vec4(0.25));
    if (sky <= 0.0) return 0.0;
    // 深度 1 の逆投影は無限遠で NaN になりうるので、同じ向きになる中間の深度で求める
    vec3 v = normalize(screenToView(vec3(uv, 0.5)));
    float w = exp((dot(v, lightView) - 1.0) / (1.0 - cos(GODRAYS_SOURCE_ANGLE)));
    return sky * w * getCloudLayer(ivec2(uv * viewSize())).a;
}

// 低解像度の前のパスの結果 (双一次)。画面の外は 0
float fetchGodrays(vec2 uv) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
    return textureLod(colortex16, uv, 0.0).r;
}

/*
 * 画面全体に掛ける係数 (uniform と FrameData だけで決まる)
 * 画面の外へ出るほど弱め、外にある分には目の位置の太陽の見え方 (影マップから求めて平滑化済み) を掛ける。
 * 洞窟・山の裏で画面の端の空から光が差し込まない。カメラが雲の中なら雲の濃さで消し、雨で弱める
 */
float evalGodraysScale(float outside) {
    float s = 1.0 - smoothstep(0.0, GODRAYS_OFFSCREEN_RANGE, outside);
    s *= mix(1.0, saturate(frameData.skyParams[3].y), smoothstep(0.0, GODRAYS_EYE_FADE, outside));
    s *= 1.0 - frameData.skyParams[4].a;
    // 雲がある空は、雨で太陽が見えない (雲の上の雨雲の層が隠す) ので完全に消す。残すと、雲の上に太陽色のぼんやりした光が茶色く浮く
    s *= min(1.0 - GODRAYS_RAIN_FADE * rainStrength, getCloudSunDiscVisibility());
    return s;
}

/*
 * 画素に足す放射輝度。光芒の量は画素までの霧の量ではなくカメラの位置の霧の濃さで一様に決める
 * (画素までの距離に比例させると、光芒の主役の近くの木の前で消える)
 * localExtinction: カメラの位置の霧の消散係数 (1/ブロック)
 */
vec3 evalGodraysRadiance(vec2 uv, bool isSky, float dist, float localExtinction) {
    vec2 lightUv;
    float outside;
    if (!godraysLightUv(lightUv, outside)) return vec3(0.0);
    float medium = mix(GODRAYS_CLEAR_SHARE, 1.0, saturate(localExtinction / GODRAYS_FOG_REF));
    float nearFade = isSky ? 1.0 : saturate(dist / GODRAYS_NEAR_FADE);
    return textureLod(colortex16, uv, 0.0).r * frameData.shadowLightIrradiance.rgb
         * (GODRAYS_GAIN * GODRAYS_STRENGTH * medium * nearFade * evalGodraysScale(outside));
}

#endif
