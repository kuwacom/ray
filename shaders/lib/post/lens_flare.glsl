/*
 * レンズフレア: ゴースト・スターバースト・ハロー・汚れ・ストリーク
 * lib/post/lens.glsl が読む
 */
#ifndef POST_LENS_FLARE_GLSL
#define POST_LENS_FLARE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/color.glsl"
//@include "/lib/common/constants.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/post/camera.glsl"
//@include "/lib/post/lens_ghosts.glsl"
//@include "/lib/post/lens_optics.glsl"
//@include "/lib/post/lens_presets.glsl"
//@include "/lib/post/post_constants.glsl"

uniform sampler2D lensStarburstTex;
uniform sampler2D lensDirtTex;

// ゴースト表の補間
const float GHOST_TABLE_SPACING = 100.0; // nm: 表の波長の間隔
// 3 点 (450 / 550 / 650 nm) の 2 次補間
float ghostLagrange(vec3 v, float l) {
    float t = (l - LENS_REF_WAVELENGTH) / GHOST_TABLE_SPACING;
    return v.y + 0.5 * (v.z - v.x) * t + 0.5 * (v.z - 2.0 * v.y + v.x) * t * t;
}

// 反射率の積 (420 .. 680nm を 65nm 間隔で折れ線補間)
float ghostReflectance(int g, float l) {
    float x = clamp((l - 420.0) / 65.0, 0.0, 3.999);
    int i = int(x);
    float f = x - float(i);
    vec4 r = GHOST_R0[g];
    float a = i == 0 ? r.x : (i == 1 ? r.y : (i == 2 ? r.z : r.w));
    float b = i == 0 ? r.y : (i == 1 ? r.z : (i == 2 ? r.w : GHOST_R1[g]));
    return max(mix(a, b, f), 0.0);
}

float ghostScaleClamp(float a) {
    return a < 0.0 ? min(a, -LENS_GHOST_MIN_SCALE) : max(a, LENS_GHOST_MIN_SCALE);
}

const int LENS_GHOST_COUNT = GHOST_S.length() < LENS_GHOST_LIMIT ? GHOST_S.length() : LENS_GHOST_LIMIT;
const int LENS_SCREEN_GHOST_COUNT = GHOST_S.length() < LENS_SCREEN_GHOST_LIMIT ? GHOST_S.length() : LENS_SCREEN_GHOST_LIMIT;

/*
 * ゴースト (光源 1 個, 解析的)
 * Lee & Eisemann 2013 の近軸行列近似。表のゴーストごとに、画素 y (tan 座標) に届く光線の前玉の高さ h を逆算し、
 * 前玉の縁 (円) と絞り (多角形) の両方を通るかで形を決める。光源の位置 lightTan で 2 つの円がずれるので、
 * 光源が端へ行くほどゴーストは欠けた形 (レモン形・三日月形) になる
 * 明るさ: 照度 E の平行光が入射瞳に入り、倍率 A で広がる -> センサー照度 R E / A^2。
 * シーンの輝度と同じ単位にするためカメラの式 (E_sensor = pi L / 4N^2) で割り戻す
 * 縁にはフレネル回折のリンギング (長波長ほど縞の間隔が広い)。波長ごとに位置と大きさが少しずつ違い、縁が虹色になる
 * 戻り値は照度 1 あたりの輝度 (光源の照度を掛けて使う)
 */
vec3 lensGhosts(vec2 yTan, vec2 lightTan, float fNumber, float pxTan) {
    float rStop = 0.5 / fNumber * GHOST_KA_MAIN;
    float rFront = max(GHOST_FRONT_RADIUS, 0.55 / LP_F_OPEN);

    vec3 wSum = vec3(0.0);
    for (int k = 0; k < LENS_SPECTRAL_SAMPLES; k++) wSum += wavelengthToRgb(lensWavelength(k, LENS_SPECTRAL_SAMPLES));

    vec3 sum = vec3(0.0);
    for (int g = 0; g < LENS_GHOST_COUNT; g++) {
        // 550nm で外接円を求め、画素が入らないゴーストは飛ばす (大半の画素は 0-2 個しか当たらない)
        float s = GHOST_S[g].y;
        float a = ghostScaleClamp(GHOST_A[g].y);
        float ka = GHOST_KA[g].y;
        float kb = GHOST_KB[g].y;
        if (abs(ka) < 1e-4) continue;
        vec2 hStop = -kb * lightTan / ka;
        float rStopH = rStop / abs(ka);
        if (length(hStop) > rFront + rStopH) continue;
        vec2 center = s * lightTan;
        float radius = abs(a) * rFront;
        if (rStopH < rFront) {
            center += a * hStop;
            radius = abs(a) * rStopH;
        }
        vec2 rel = yTan - center;
        rel.x *= LP_SQUEEZE;
        // 波長ごとの位置のずれ (分散) の分だけ広げる
        float spread = (abs(GHOST_S[g].z - GHOST_S[g].x) + abs(GHOST_A[g].z - GHOST_A[g].x) * rFront) * length(lightTan);
        if (length(rel) > radius * 1.15 + spread + 0.02) continue;

        for (int k = 0; k < LENS_SPECTRAL_SAMPLES; k++) {
            float l = lensWavelength(k, LENS_SPECTRAL_SAMPLES);
            float sl = ghostLagrange(GHOST_S[g], l);
            float al = ghostScaleClamp(ghostLagrange(GHOST_A[g], l));
            float kal = ghostLagrange(GHOST_KA[g], l);
            float kbl = ghostLagrange(GHOST_KB[g], l);
            vec2 c = sl * lightTan;
            vec2 yl = c + (yTan - c) * vec2(LP_SQUEEZE, 1.0);
            vec2 h = (yl - c) / al;
            vec2 st = kal * h + kbl * lightTan;
            float rimN = length(h) / rFront;
            float stopN = length(st) / (rStop * apertureShape(atan(st.y, st.x)));
            // 縁の幅 (正規化座標): 画素の大きさと光源の円盤による広がり
            float edgeRim = (pxTan + abs(sl) * LENS_LIGHT_ANGULAR_RADIUS) / (abs(al) * rFront) + 0.01;
            float pxStop = pxTan * abs(kal / al) / rStop;
            float edgeStop = pxStop + abs(kbl) * LENS_LIGHT_ANGULAR_RADIUS / rStop + 0.01;
            float inside = saturate((1.0 - rimN) / edgeRim + 0.5) * saturate((1.0 - stopN) / edgeStop + 0.5);
            if (inside <= 0.0) continue;
            // 縞は縁のくっきりしたゴーストの、縁から数画素の範囲にだけ出す (ぼけたゴーストの内側に同心円が並ばないように)
            float ePx = max(1.0 - stopN, 0.0) / pxStop;
            float sharp = saturate(2.0 * pxStop / edgeStop);
            float ring = 1.0 + LP_RINGING * sharp * exp(-ePx * 0.15) * cos(ePx * 0.8 * (LENS_REF_WAVELENGTH / l));
            float energy = ghostReflectance(g, l) / (al * al);
            sum += wavelengthToRgb(l) * (inside * ring * energy);
        }
    }
    return sum / max(wSum, 1e-6) * (4.0 * fNumber * fNumber / PI);
}

/*
 * スターバースト (絞りの Fraunhofer 回折)
 * 事前ベイクの極座標テクスチャ (tools/gen_lens_textures.py) を引く。光条の向きは絞り羽根に垂直で、
 * 偶数枚なら枚数本、奇数枚なら 2 倍の本数。赤の光条が青より長い
 * 中心 (Airy 円盤) は太陽の円盤と重なるので消す
 * 戻り値は照度 1 あたりの輝度。光条は Airy 円盤のピーク輝度 (1.17 / 半径^2) に対する比で焼いてある
 */
vec3 lensStarburst(vec2 yTan, vec2 lightTan, float airyTan) {
    vec2 d = yTan - lightTan;
    float r = length(d) / airyTan;
    if (r >= LENS_STAR_R_MAX) return vec3(0.0);
#if LENS_BLADES > 0
    const float spikes = float(LENS_BLADES % 2 == 0 ? LENS_BLADES : LENS_BLADES * 2);
    const float period = TAU / spikes;
    float phi = mod(atan(d.y, d.x) - DOF_BLADE_ROTATION, period);
    float local = min(phi, period - phi) / (period * 0.5);
#else
    float local = 0.0;
#endif
    float v = log(max(r, LENS_STAR_R_MIN) / LENS_STAR_R_MIN) / log(LENS_STAR_R_MAX / LENS_STAR_R_MIN);
    const float tileW = 1.0 / 8.0;
    float u = clamp(local, 0.5 / 128.0, 1.0 - 0.5 / 128.0);
    vec3 e = textureLod(lensStarburstTex, vec2((float(LENS_STAR_TILE) + u) * tileW, v), 0.0).rgb;
    e *= e;
    e *= e;
    float window = smoothstep(1.5, 4.0, r) * (1.0 - smoothstep(0.8, 1.0, v));
    return e * window * (1.17 / (airyTan * airyTan));
}

// 広い滲みの点像分布 (平面で積分 1)。中心が鋭く裾の長い形 (1 + (d/σ)^2)^-1.5
float lensWidePsf(float d, float sigma) {
    float t = 1.0 + sqr(d / sigma);
    return 1.0 / (TAU * sigma * sigma * t * sqrt(t));
}

float lensDirt(vec2 uv) {
    float dirt = textureLod(lensDirtTex, uv, 0.0).r;
    // コントラスト: 低いとフレアの形が、高いと汚れの模様が支配的になる (Chapman 2017)
    return mix(0.5, dirt, 0.25 + 1.5 * LP_DIRT_CONTRAST) * 2.0;
}

/*
 * 光源 1 個 (太陽・月) のフレア全体。uv は画素の位置、lightUv は光源の画面位置
 * (既存のプリセットは歪曲後の元画像の座標、LENS_FLARE_OUTPUT_SPACE では両方とも出力の座標)
 * 戻り値は照度 1 あたりの輝度 (光源の照度と見え具合を掛けて使う)。lightTint は光源の色 (輝度 1 に正規化)
 * starGain は光条だけに掛ける倍率 (夜の月で弱める)
 */
vec3 lensFlare(vec2 uv, vec2 lightUv, vec3 lightTint, float starGain) {
    vec2 yTan = uvToTan(uv);
    vec2 lightTan = uvToTan(lightUv);
    float fNumber = lensFNumber();
    float pxTan = 2.0 * lensTanHalf().y / viewHeight;
    float dist = length(yTan - lightTan);
    vec3 flare = vec3(0.0);

#ifdef LENS_GHOSTS
    flare += lensGhosts(yTan, lightTan, fNumber, pxTan) * (LP_GHOSTS * LENS_GHOST_GAIN);
#endif

#ifdef LENS_STARBURST
    if (LP_STARBURST > 0.0) {
        // 絞るほど光条は長く強い (回折角は F 値に比例)。丸い羽根ほど光条は弱い
        float n = fNumber / LENS_F_REFERENCE;
        float airy = LENS_STAR_AIRY * LP_STAR_SIZE * sqrt(n);
        float gain = LP_STARBURST * LENS_STAR_GAIN * clamp(n, 0.5, 3.0) * (1.0 - 0.7 * LP_BLADE_ROUNDNESS);
        // 開放付近は羽根が開口の外へ退いて開口がほぼ円になり、光条はほとんど出ない (オールドレンズの開放でくっきりした星にしない)
        float stopDown = saturate((fNumber / LP_F_OPEN - 1.0) / LENS_STAR_STOPDOWN_RANGE);
        gain *= mix(LENS_STAR_OPEN, 1.0, stopDown);
        flare += lensStarburst(yTan, lightTan, airy) * (gain * starGain);
    }
#endif

#ifdef LENS_HALO
    if (LP_HALO > 0.0) {
        // 画面中心を囲む虹色のリング (鏡筒・絞りの反射)。光源の側だけ明るい
        vec2 dir = yTan / max(length(yTan), 1e-5);
        vec2 ldir = lightTan / max(length(lightTan), 1e-5);
        float facing = pow(saturate(dot(dir, ldir) * 0.5 + 0.5), 6.0) * saturate(length(lightTan) * 3.0);
        vec3 ring = vec3(0.0);
        vec3 wSum = vec3(0.0);
        for (int k = 0; k < LENS_SPECTRAL_SAMPLES; k++) {
            float l = lensWavelength(k, LENS_SPECTRAL_SAMPLES);
            vec3 w = wavelengthToRgb(l);
            // 波長による半径の差は幅の半分程度 (幅と同じだと青から赤まで分かれた虹の帯になり、空で目立った)
            float radius = LENS_HALO_RADIUS * (1.0 + 0.025 * (l - LENS_REF_WAVELENGTH) / LENS_CA_WAVELENGTH_RANGE);
            ring += w * exp(-sqr((length(yTan) - radius) / LENS_HALO_WIDTH));
            wSum += w;
        }
        flare += ring / max(wSum, 1e-6) * facing * (LP_HALO * LENS_HALO_GAIN / LENS_HALO_WIDTH);
    }
#endif

#ifdef LENS_VEILING_GLARE
    flare += vec3(lensWidePsf(dist, LENS_VEIL_SUN_SIGMA) * LP_VEILING_GLARE * LENS_VEIL_SUN_GAIN);
#endif

#ifdef LENS_DIRT
    if (LP_DIRT > 0.0) flare += vec3(lensDirt(uv) * lensWidePsf(dist, LENS_DIRT_SUN_SIGMA) * LP_DIRT * LENS_DIRT_SUN_GAIN);
#endif

    if (LP_STREAK > 0.0) {
        // アナモルフィックの横ストリーク: 光源の色に関係なくコーティングの青に染まる
        vec2 d = yTan - lightTan;
        float streak = exp(-abs(d.x) / LENS_STREAK_SUN_LENGTH) * exp(-sqr(d.y / LENS_STREAK_SUN_WIDTH));
        streak /= 2.0 * LENS_STREAK_SUN_LENGTH * sqrt(PI) * LENS_STREAK_SUN_WIDTH;
        // 後で光源の色が掛かるので、その色を打ち消しておく (夕日でも青い)
        vec3 tint = LP_STREAK_TINT / luminance(LP_STREAK_TINT) / max(lightTint, vec3(0.05));
        flare += tint * (streak * LP_STREAK * LENS_STREAK_SUN_GAIN);
    }
    return flare;
}

#endif
